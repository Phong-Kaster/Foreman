<#
.SYNOPSIS
    A stand-in for adb, so foreman-device.ps1 can be tested with no device attached.

.DESCRIPTION
    The tests put an adb.cmd shim that calls this script first on PATH. Every call is appended to
    $env:FAKE_ADB_LOG (arguments joined by spaces, "-s <serial>" included), which is how a test proves
    a refused operation never reached the device. What the "device" answers is set per test:

      FAKE_ADB_DEVICES     comma-separated serials that are attached (default FAKE123)
      FAKE_ADB_INSTALLED   0 = the package is not installed (default installed)
      FAKE_ADB_DEBUGGABLE  0 = the installed package is not debuggable (default debuggable)
      FAKE_ADB_FOCUS       the package, or a window name like NotificationShade, holding focus
      FAKE_ADB_FOCUS_AFTER what holds focus once the screen has been read (a dump or a screencap):
                           Kanso's Run 4, 2026-10-09, where the shade came down mid-read
      FAKE_ADB_UIXML       a file whose content is the uiautomator dump
      FAKE_ADB_NOTIF       a file whose content is `dumpsys notification`
      FAKE_ADB_MEDIA       a file whose content is `dumpsys media_session`
#>
$a = @($args)
if ($env:FAKE_ADB_LOG) { Add-Content -Path $env:FAKE_ADB_LOG -Value ($a -join ' ') }
if ($a.Count -ge 2 -and $a[0] -eq '-s') { $a = @($a | Select-Object -Skip 2) }
$cmd = $a -join ' '

function Emit-File([string]$path) { if ($path -and (Test-Path $path)) { Get-Content $path } }

switch -Regex ($cmd) {
    '^devices' {
        "List of devices attached"
        $serials = if ($env:FAKE_ADB_DEVICES) { $env:FAKE_ADB_DEVICES } else { "FAKE123" }
        foreach ($s in ($serials -split ',')) { "$s`tdevice" }
        ""
        exit 0
    }
    '^shell dumpsys package (\S+)$' {
        if ($env:FAKE_ADB_INSTALLED -ne '0') {
            "Packages:"
            "  Package [$($Matches[1])] (1a2b3c):"
            if ($env:FAKE_ADB_DEBUGGABLE -ne '0') { "    flags=[ DEBUGGABLE HAS_CODE ALLOW_CLEAR_USER_DATA ]" }
            else { "    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]" }
        }
        exit 0
    }
    '^shell dumpsys window' {
        $focus = if ($env:FAKE_ADB_FOCUS) { $env:FAKE_ADB_FOCUS } else { "com.example.app" }
        if ($env:FAKE_ADB_FOCUS_AFTER -and $env:FAKE_ADB_UIXML -and (Test-Path "$($env:FAKE_ADB_UIXML).read")) { $focus = $env:FAKE_ADB_FOCUS_AFTER }
        if ($focus.Contains('.')) { "  mCurrentFocus=Window{a1b2c3 u0 $focus/$focus.MainActivity}" }
        else { "  mCurrentFocus=Window{a1b2c3 u0 $focus}" }
        exit 0
    }
    '^shell (uiautomator dump|screencap)' {
        if ($env:FAKE_ADB_UIXML) { Set-Content -Path "$($env:FAKE_ADB_UIXML).read" -Value "read" }
        if ($Matches[1] -eq 'uiautomator dump') { "UI hierchary dumped to: /sdcard/foreman-ui.xml" }
        exit 0
    }
    '^exec-out cat' { Emit-File $env:FAKE_ADB_UIXML; exit 0 }
    '^shell dumpsys notification' { Emit-File $env:FAKE_ADB_NOTIF; exit 0 }
    '^shell dumpsys media_session' { Emit-File $env:FAKE_ADB_MEDIA; exit 0 }
    '^shell cmd package resolve-activity' { "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true"; "com.example.app/.MainActivity"; exit 0 }
    '^shell am start' { "Starting: Intent { cmp=com.example.app/.MainActivity }"; "Status: ok"; exit 0 }
    '^shell pm (clear|grant|revoke)' { if ($Matches[1] -eq 'clear') { "Success" }; exit 0 }
    '^(install|uninstall)' { "Success"; exit 0 }
    default { exit 0 }
}
