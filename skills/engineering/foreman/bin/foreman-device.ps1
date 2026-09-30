<#
.SYNOPSIS
    Drive an Android device or emulator, acting only on the debug build of this repository (ADR-033).

.DESCRIPTION
    The one route from the engine to a device, in both Run Modes. run.ps1 denies adb itself, in every
    form the permission matcher can see; this script runs adb from its own process, so it decides
    what reaches the device, and it lives in .harness/loop/, which the engine cannot edit.

    - The package is never the engine's free choice. It must be the applicationId of a debug APK this
      repository built (<module>/build/outputs/apk/<...debug...>/output-metadata.json), and the device
      must report it installed and DEBUGGABLE before anything touches it.
    - Every write - install, uninstall, clear, grant, revoke, start, stop - names that package.
    - Input goes only to a node of that package, or of the system permission dialog it raised, found
      by id or text in a fresh view dump. Never to raw coordinates, so never to the navigation bar, the
      notification shade, the launcher or another app.
    - The screen is read only while that app (or its permission dialog) has focus, and shared state -
      notifications, media sessions, logs - is filtered to that package, so another app's text never
      reaches the evidence files a checkpoint commits.

    Nothing here changes a device setting, the clock, the notification shade or another app. There is
    no operation for it, and that absence is the rule.

    Exit codes: 0 done, 1 the device reported a failure, 3 refused by this wrapper's rules. A refusal
    is the human's rule, made in advance: find another approach or report the criterion "not driven".

.EXAMPLE
    powershell -NoProfile -File .harness/loop/bin/foreman-device.ps1 -Op clear
    powershell -NoProfile -File .harness/loop/bin/foreman-device.ps1 -Op tap -ResourceId com.example:id/play
    powershell -NoProfile -File .harness/loop/bin/foreman-device.ps1 -Op dump -Serial emulator-5554
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("devices", "package", "focus", "install", "uninstall", "clear", "grant", "revoke",
                 "start", "stop", "dump", "screenshot", "tap", "swipe", "text", "key",
                 "notifications", "media-session", "package-info", "logcat")]
    [string]$Op,
    [string]$Serial = "",
    [string]$Package = "",
    [string]$Apk = "",
    [string]$Permission = "",
    [string]$Activity = "",
    [string]$ResourceId = "",
    [string]$Text = "",
    [string]$ContentDesc = "",
    [int]$Index = 0,
    [ValidateSet("", "up", "down", "left", "right")]
    [string]$Direction = "",
    [string]$Value = "",
    [ValidateSet("", "BACK", "HOME", "WAKEUP", "MEDIA_PLAY_PAUSE", "MEDIA_PLAY", "MEDIA_PAUSE", "MEDIA_NEXT", "MEDIA_PREVIOUS")]
    [string]$Key = "",
    [string]$Out = ""
)

# Continue, not Stop: Windows PowerShell 5.1 turns a native command's stderr into a terminating error
# under Stop, and adb writes progress to stderr on success.
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# The system dialog an app raises when it asks for a runtime permission. Tapping it is how a
# "grant when asked" or "deny when asked" path is driven; it acts on this app's permissions only.
$DialogPackages = @(
    "com.android.permissioncontroller", "com.google.android.permissioncontroller",
    "com.android.packageinstaller", "com.google.android.packageinstaller"
)

function Deny([string]$why) {
    [Console]::Error.WriteLine("foreman-device: refused - $why")
    exit 3
}
function Broke([string]$why) {
    [Console]::Error.WriteLine("foreman-device: failed - $why")
    exit 1
}

# ---------- adb ----------

function Resolve-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($root in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path "$env:LOCALAPPDATA" "Android\Sdk"))) {
        if ($root) {
            $candidate = Join-Path $root "platform-tools\adb.exe"
            if (Test-Path $candidate) { return $candidate }
        }
    }
    Broke "adb was not found on PATH or in the Android SDK."
}

# Every adb call is echoed to stderr as "+ adb ...", so the exact command is on record beside its
# output (POLICIES.md, Evidence Requirements) without mixing into what a caller parses from stdout.
function Invoke-Adb([string[]]$adbArgs, [switch]$Quiet) {
    $full = @()
    if ($script:DeviceSerial) { $full += @("-s", $script:DeviceSerial) }
    $full += $adbArgs
    if (-not $Quiet) { [Console]::Error.WriteLine("+ adb " + ($full -join " ")) }
    $output = & $script:Adb @full 2>&1 | ForEach-Object { "$_" }
    $script:AdbExit = $LASTEXITCODE
    return , @($output)
}

function Select-Serial {
    $listed = & $script:Adb devices 2>$null
    $ready = @($listed | Where-Object { "$_" -match '^(\S+)\s+device\s*$' } | ForEach-Object { ("$_" -split '\s+')[0] })
    if ($Serial) {
        if ($Serial -notmatch '^[A-Za-z0-9._:-]+$') { Deny "'$Serial' is not a device serial." }
        if ($ready -notcontains $Serial) { Broke "device $Serial is not attached and authorized (attached: $($ready -join ', '))." }
        return $Serial
    }
    if ($ready.Count -eq 1) { return $ready[0] }
    if ($ready.Count -eq 0) { Broke "no device is attached and authorized." }
    Deny "several devices are attached ($($ready -join ', ')); name one with -Serial."
}

# ---------- the app under development ----------

# The applicationIds of every debug APK this repository has built, read from the build's own output
# metadata. A test APK (androidTest) is not the app, and neither is a release build.
function Get-BuiltDebugApps([string]$repoRoot) {
    $modules = @($repoRoot)
    foreach ($d in @(Get-ChildItem -Path $repoRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^\.|^node_modules$|^build$') { continue }
        $modules += $d.FullName
        foreach ($s in @(Get-ChildItem -Path $d.FullName -Directory -ErrorAction SilentlyContinue)) {
            if ($s.Name -match '^\.|^node_modules$|^build$|^src$') { continue }
            $modules += $s.FullName
        }
    }
    $apps = @()
    foreach ($m in $modules) {
        $apkDir = Join-Path $m "build\outputs\apk"
        if (-not (Test-Path $apkDir)) { continue }
        foreach ($meta in @(Get-ChildItem -Path $apkDir -Recurse -Filter "output-metadata.json" -File -ErrorAction SilentlyContinue)) {
            $relative = $meta.DirectoryName.Substring($apkDir.Length)
            if ($relative -match 'androidTest' -or $relative -notmatch '(?i)debug') { continue }
            try { $parsed = Get-Content $meta.FullName -Raw | ConvertFrom-Json } catch { continue }
            $id = "$($parsed.applicationId)"
            if ($id -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') { continue }
            $files = @($parsed.elements | ForEach-Object { Join-Path $meta.DirectoryName "$($_.outputFile)" } | Where-Object { Test-Path $_ })
            $apps += [pscustomobject]@{ Package = $id; Apks = $files }
        }
    }
    return , @($apps)
}

function Resolve-AppPackage($apps) {
    if ($apps.Count -eq 0) {
        Deny "this repository has no debug APK built yet. Build it first (for example ./gradlew assembleDebug) - only a debug package this repository built can be driven."
    }
    $ids = @($apps | ForEach-Object { $_.Package } | Select-Object -Unique)
    if ($Package) {
        if ($ids -notcontains $Package) {
            Deny "$Package is not a debug build of this repository (built: $($ids -join ', ')). Foreman drives only the app it is writing."
        }
        return $Package
    }
    if ($ids.Count -eq 1) { return $ids[0] }
    Deny "this repository built several debug packages ($($ids -join ', ')); name one with -Package."
}

# The device's own word that this is a debug build of the app: installed, and DEBUGGABLE. A release
# build or a store install under the same applicationId is not the app under development.
function Assert-DebuggableInstalled {
    $info = Invoke-Adb @("shell", "dumpsys", "package", $script:Pkg) -Quiet
    $escaped = [regex]::Escape($script:Pkg)
    if (-not ($info | Where-Object { $_ -match "^\s*Package \[$escaped\]" })) {
        Deny "$($script:Pkg) is not installed on $($script:DeviceSerial). Install the debug build first (-Op install)."
    }
    if (-not ($info | Where-Object { $_ -match '^\s*(pkgFlags|flags)=\[.*\bDEBUGGABLE\b' })) {
        Deny "$($script:Pkg) on $($script:DeviceSerial) is not a debuggable build. Foreman drives only a debug build of the app it is writing."
    }
}

# ---------- what is on screen ----------

function Get-FocusPackage {
    for ($i = 0; $i -lt 3; $i++) {
        $window = Invoke-Adb @("shell", "dumpsys", "window") -Quiet
        $line = $window | Where-Object { $_ -match 'mCurrentFocus=' } | Select-Object -First 1
        if ($line -match 'mCurrentFocus=Window\{\S+ \S+ ([^/\s}]+)') { return $Matches[1] }
        Start-Sleep -Milliseconds 700
    }
    return ""
}

function Assert-Focus([switch]$AllowDialog) {
    $focus = Get-FocusPackage
    $allowed = @($script:Pkg)
    if ($AllowDialog) { $allowed += $DialogPackages }
    if ($allowed -notcontains $focus) {
        if (-not $focus) { $focus = "nothing (locked, off, or between windows)" }
        Deny "the screen belongs to $focus, not $($script:Pkg). Foreman reads and touches only the app it is writing - start it (-Op start), wake the device, or ask a person to unlock it."
    }
    return $focus
}

function Get-UiDump {
    for ($i = 1; $i -le 3; $i++) {
        $result = Invoke-Adb @("shell", "uiautomator", "dump", "/sdcard/foreman-ui.xml")
        if (($result -join "`n") -match 'dumped to') {
            $xml = (Invoke-Adb @("exec-out", "cat", "/sdcard/foreman-ui.xml") -Quiet) -join "`n"
            Invoke-Adb @("shell", "rm", "-f", "/sdcard/foreman-ui.xml") -Quiet | Out-Null
            if ($xml -match '<hierarchy') {
                try { $doc = [xml]$xml } catch { $doc = $null }
                if ($null -ne $doc) { return , @($xml, $doc) }
            }
        }
        Start-Sleep -Seconds 1
    }
    Broke "uiautomator could not dump the screen after 3 tries. A screen that never goes idle (a running animation or marquee) cannot be dumped, and changing the device's animation settings is not allowed - pause the animation in the app's debug build, or report the criterion not driven."
}

# A dump taken while this app has focus can still carry the system bars. It must not carry another
# app's screen: focus can move between the check and the dump.
function Assert-DumpIsOurs($doc) {
    $allowed = @($script:Pkg) + $DialogPackages + @("com.android.systemui")
    $foreign = @($doc.SelectNodes("//node") | ForEach-Object { $_.GetAttribute("package") } | Where-Object { $_ -and ($allowed -notcontains $_) } | Select-Object -Unique)
    if ($foreign.Count -gt 0) { Deny "the screen changed to $($foreign -join ', ') while it was being read; nothing was kept." }
}

function Find-TargetNode($doc, [string[]]$owners) {
    if (-not $ResourceId -and -not $Text -and -not $ContentDesc) {
        Deny "name the target with -ResourceId, -Text or -ContentDesc. Raw coordinates are not accepted: they cannot be checked against the app that owns them."
    }
    $matched = @($doc.SelectNodes("//node") | Where-Object {
            (-not $ResourceId -or $_.GetAttribute("resource-id") -eq $ResourceId) -and
            (-not $Text -or $_.GetAttribute("text") -eq $Text) -and
            (-not $ContentDesc -or $_.GetAttribute("content-desc") -eq $ContentDesc)
        })
    if ($matched.Count -le $Index) { Broke "no node on screen matches (found $($matched.Count), wanted index $Index)." }
    $node = $matched[$Index]
    $owner = $node.GetAttribute("package")
    if ($owners -notcontains $owner) {
        Deny "the matching node belongs to $owner, not $($script:Pkg). Foreman touches only the app it is writing and the permission dialog it raised."
    }
    if ($node.GetAttribute("bounds") -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { Broke "the matching node has no bounds." }
    $box = @{ X1 = [int]$Matches[1]; Y1 = [int]$Matches[2]; X2 = [int]$Matches[3]; Y2 = [int]$Matches[4] }
    if ($box.X2 -le $box.X1 -or $box.Y2 -le $box.Y1) { Broke "the matching node has no area on screen." }
    return $box
}

# Keep the records of shared state that belong to this package: from a header line to the next line
# indented no deeper than it.
function Select-OwnBlocks([string[]]$lines, [scriptblock]$isHeader, [string]$ownPattern) {
    $kept = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $lines.Count) {
        if (& $isHeader $lines $i) {
            $indent = ($lines[$i] -replace '^(\s*).*$', '$1').Length
            $block = @($lines[$i])
            $j = $i + 1
            while ($j -lt $lines.Count -and (($lines[$j] -replace '^(\s*).*$', '$1').Length -gt $indent -or $lines[$j].Trim() -eq "")) {
                $block += $lines[$j]; $j++
            }
            if (($block -join "`n") -match $ownPattern) { foreach ($b in $block) { $kept.Add($b) } }
            $i = $j
        } else { $i++ }
    }
    return , $kept.ToArray()
}

function Assert-InsideRepo([string]$path, [string]$what) {
    if (-not $path) { Deny "name the $what with -Out." }
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $path))
    if (-not $full.StartsWith($script:RepoRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        Deny "the $what must be written inside this repository (for example .harness/run/evidence/)."
    }
    New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
    return $full
}

# ---------- operations ----------

$script:Adb = Resolve-Adb

if ($Op -eq "devices") {
    & $script:Adb devices -l
    exit $LASTEXITCODE
}

$top = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $top) { Broke "not inside a git repository." }
$script:RepoRoot = (Resolve-Path "$top".Trim()).Path.TrimEnd('\', '/')
$apps = Get-BuiltDebugApps $script:RepoRoot
$script:Pkg = Resolve-AppPackage $apps

if ($Op -eq "package") { Write-Output $script:Pkg; exit 0 }

$script:DeviceSerial = Select-Serial

switch ($Op) {
    "install" {
        $known = @($apps | Where-Object { $_.Package -eq $script:Pkg } | ForEach-Object { $_.Apks })
        if ($Apk) {
            $wanted = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $Apk))
            if (-not ($known | Where-Object { $_ -ieq $wanted })) {
                Deny "$Apk is not a debug APK this repository built for $($script:Pkg) (built: $($known -join ', '))."
            }
        } else {
            if ($known.Count -ne 1) { Deny "name the APK with -Apk (built: $($known -join ', '))." }
            $wanted = $known[0]
        }
        $result = Invoke-Adb @("install", "-r", "-t", $wanted)
        $result
        if ($script:AdbExit -ne 0 -or -not (($result -join "`n") -match 'Success')) { Broke "the install did not succeed." }
        Assert-DebuggableInstalled
        exit 0
    }
}

Assert-DebuggableInstalled

switch ($Op) {
    "focus" { Write-Output (Get-FocusPackage); exit 0 }

    "uninstall" {
        $result = Invoke-Adb @("uninstall", $script:Pkg); $result
        if (($result -join "`n") -notmatch 'Success') { Broke "the uninstall did not succeed." }
    }

    "clear" {
        $result = Invoke-Adb @("shell", "pm", "clear", $script:Pkg); $result
        if (($result -join "`n") -notmatch 'Success') { Broke "pm clear did not succeed." }
    }

    { $_ -in @("grant", "revoke") } {
        if ($Permission -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*\.permission\.[A-Za-z0-9_]+$') {
            Deny "'$Permission' is not a permission name (for example android.permission.POST_NOTIFICATIONS)."
        }
        $result = Invoke-Adb @("shell", "pm", $Op, $script:Pkg, $Permission); $result
        if ($script:AdbExit -ne 0 -or ($result -join "`n") -match 'Exception|Error') { Broke "pm $Op did not succeed." }
    }

    "start" {
        if ($Activity) {
            if ($Activity -notmatch '^\.?[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*)*$') { Deny "'$Activity' is not an activity class name." }
            if (-not $Activity.StartsWith(".") -and -not $Activity.StartsWith("$($script:Pkg).")) {
                Deny "$Activity is not an activity of $($script:Pkg)."
            }
            $component = "$($script:Pkg)/$Activity"
        } else {
            $resolved = Invoke-Adb @("shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", $script:Pkg) -Quiet
            $component = @($resolved | Where-Object { $_ -match "^$([regex]::Escape($script:Pkg))/" }) | Select-Object -Last 1
            if (-not $component) { Broke "$($script:Pkg) has no launcher activity; name one with -Activity." }
        }
        $result = Invoke-Adb @("shell", "am", "start", "-W", "-n", $component); $result
        if (($result -join "`n") -match '(?m)^Error') { Broke "am start did not succeed." }
    }

    "stop" { Invoke-Adb @("shell", "am", "force-stop", $script:Pkg) }

    "dump" {
        Assert-Focus -AllowDialog | Out-Null
        $dump = Get-UiDump
        Assert-DumpIsOurs $dump[1]
        if ($Out) { $path = Assert-InsideRepo $Out "dump"; Set-Content -Path $path -Value $dump[0] -Encoding UTF8; Write-Output $path }
        else { Write-Output $dump[0] }
    }

    "screenshot" {
        $path = Assert-InsideRepo $Out "screenshot"
        Assert-Focus -AllowDialog | Out-Null
        Invoke-Adb @("shell", "screencap", "-p", "/sdcard/foreman-shot.png") | Out-Null
        Invoke-Adb @("pull", "/sdcard/foreman-shot.png", $path) | Out-Null
        $pulled = $script:AdbExit
        Invoke-Adb @("shell", "rm", "-f", "/sdcard/foreman-shot.png") -Quiet | Out-Null
        if ($pulled -ne 0) { Broke "the screenshot could not be copied off the device." }
        Write-Output $path
    }

    "tap" {
        Assert-Focus -AllowDialog | Out-Null
        $dump = Get-UiDump
        Assert-DumpIsOurs $dump[1]
        $box = Find-TargetNode $dump[1] (@($script:Pkg) + $DialogPackages)
        $x = [Math]::Floor(($box.X1 + $box.X2) / 2); $y = [Math]::Floor(($box.Y1 + $box.Y2) / 2)
        Invoke-Adb @("shell", "input", "tap", "$x", "$y")
    }

    "swipe" {
        if (-not $Direction) { Deny "name the direction with -Direction up|down|left|right." }
        Assert-Focus | Out-Null
        $dump = Get-UiDump
        Assert-DumpIsOurs $dump[1]
        $box = Find-TargetNode $dump[1] @($script:Pkg)
        # Inside the node, 20% in from its edges: a swipe that starts at a screen edge is a system
        # gesture (back, home, the shade), not input to this app.
        $w = $box.X2 - $box.X1; $h = $box.Y2 - $box.Y1
        $cx = [Math]::Floor($box.X1 + $w / 2); $cy = [Math]::Floor($box.Y1 + $h / 2)
        $near = { param($a, $len) [Math]::Floor($a + $len * 0.2) }; $far = { param($a, $len) [Math]::Floor($a + $len * 0.8) }
        switch ($Direction) {
            "up"    { $from = @($cx, (& $far $box.Y1 $h));  $to = @($cx, (& $near $box.Y1 $h)) }
            "down"  { $from = @($cx, (& $near $box.Y1 $h)); $to = @($cx, (& $far $box.Y1 $h)) }
            "left"  { $from = @((& $far $box.X1 $w), $cy);  $to = @((& $near $box.X1 $w), $cy) }
            "right" { $from = @((& $near $box.X1 $w), $cy); $to = @((& $far $box.X1 $w), $cy) }
        }
        Invoke-Adb @("shell", "input", "swipe", "$($from[0])", "$($from[1])", "$($to[0])", "$($to[1])", "300")
    }

    "text" {
        # The value reaches the device's shell, so only characters that shell cannot read as syntax.
        if ($Value -notmatch '^[A-Za-z0-9._@,:+-]+( [A-Za-z0-9._@,:+-]+)*$') {
            Deny "-Value may hold only letters, digits, spaces and . _ @ , : + - (input text cannot type anything else safely)."
        }
        Assert-Focus | Out-Null
        $dump = Get-UiDump
        Assert-DumpIsOurs $dump[1]
        $focused = @($dump[1].SelectNodes("//node[@focused='true']") | Where-Object { $_.GetAttribute("package") -eq $script:Pkg })
        if ($focused.Count -eq 0) { Broke "no field of $($script:Pkg) has input focus; tap one first." }
        Invoke-Adb @("shell", "input", "text", ($Value -replace ' ', '%s'))
    }

    "key" {
        if (-not $Key) { Deny "name the key with -Key." }
        # WAKEUP only turns the screen on. Every other key acts on whatever has focus, so this app must.
        if ($Key -ne "WAKEUP") { Assert-Focus | Out-Null }
        Invoke-Adb @("shell", "input", "keyevent", "KEYCODE_$Key")
    }

    "notifications" {
        $lines = Invoke-Adb @("shell", "dumpsys", "notification", "--noredact")
        $own = Select-OwnBlocks $lines { param($l, $i) $l[$i] -match '^\s*NotificationRecord\(' } "pkg=$([regex]::Escape($script:Pkg))\s"
        if ($own.Count -eq 0) { Write-Output "no notification of $($script:Pkg) is posted." } else { $own }
    }

    "media-session" {
        $lines = Invoke-Adb @("shell", "dumpsys", "media_session")
        $own = Select-OwnBlocks $lines { param($l, $i) ($i + 1) -lt $l.Count -and $l[$i + 1] -match '^\s*ownerPid=' } "package=$([regex]::Escape($script:Pkg))(\s|$)"
        if ($own.Count -eq 0) { Write-Output "no media session of $($script:Pkg) exists." } else { $own }
    }

    "package-info" { Invoke-Adb @("shell", "dumpsys", "package", $script:Pkg) }

    "logcat" {
        $escaped = [regex]::Escape($script:Pkg)
        Write-Output "--- crash buffer, lines naming $($script:Pkg)"
        $crash = Invoke-Adb @("logcat", "-d", "-b", "crash")
        $crash | Where-Object { $_ -match $escaped }
        $appPid = ((Invoke-Adb @("shell", "pidof", $script:Pkg) -Quiet) -join " ").Trim()
        if ($appPid -match '^\d+$') {
            Write-Output "--- main log of pid $appPid"
            Invoke-Adb @("logcat", "-d", "--pid=$appPid")
        } else { Write-Output "--- $($script:Pkg) is not running, so it has no live log." }
    }
}

if ($script:AdbExit -and $script:AdbExit -ne 0) { exit 1 }
exit 0
