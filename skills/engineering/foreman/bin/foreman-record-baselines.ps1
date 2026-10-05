<#
.SYNOPSIS
    Record the Roborazzi baselines that do not exist yet, and nothing else (ADR-036).

.DESCRIPTION
    Runs the module's Roborazzi record task, then puts back every baseline that existed before it ran,
    so a recording can add images but never move one already approved. The record tasks themselves
    are denied to the engine in both Run Modes; this script runs Gradle from its own process, and it
    lives in .harness/loop/, which the engine cannot edit.

    The one exception is a baseline listed under a "## Baselines" heading in
    .harness/run/DECISIONS.md - the human's file, which the engine cannot write. Listing one there is
    the human approving its re-recording, so its new version is kept.

    Baselines live in <module>/src/test/screenshots/ (packs/android/roborazzi.md).

.EXAMPLE
    powershell -NoProfile -File .harness/loop/bin/foreman-record-baselines.ps1 -Module app
    powershell -NoProfile -File .harness/loop/bin/foreman-record-baselines.ps1 -Module app -Tests "com.example.screenshot.*"
#>
param(
    [string]$Module = "app",
    [string]$Variant = "Debug",
    [string]$Tests = ""
)

$ErrorActionPreference = "Continue"

function Deny([string]$why) {
    [Console]::Error.WriteLine("foreman-record-baselines: refused - $why")
    exit 3
}

# Each value reaches Gradle's command line, so only what a module, a variant or a test filter can be.
if ($Module -notmatch '^:?[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)*$') { Deny "'$Module' is not a Gradle module path." }
if ($Variant -notmatch '^[A-Za-z0-9]+$') { Deny "'$Variant' is not a build variant." }
if ($Tests -and $Tests -notmatch '^[A-Za-z0-9_.*$]+$') { Deny "'$Tests' is not a test filter." }

$top = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $top) { [Console]::Error.WriteLine("foreman-record-baselines: not inside a git repository."); exit 1 }
$repoRoot = (Resolve-Path "$top".Trim()).Path.TrimEnd('\', '/')
$modulePath = $Module.Trim(':') -replace ':', '/'
$baselineDir = Join-Path $repoRoot ($modulePath + "/src/test/screenshots")

$gradlew = Join-Path $repoRoot "gradlew.bat"
if (-not (Test-Path $gradlew)) { $gradlew = Join-Path $repoRoot "gradlew" }
if (-not (Test-Path $gradlew)) { [Console]::Error.WriteLine("foreman-record-baselines: no Gradle wrapper at the repository root."); exit 1 }

function Get-RelativePath([string]$full) {
    return ($full.Substring($baselineDir.Length).TrimStart('\', '/') -replace '\\', '/')
}

# The human's approvals: repository-relative paths listed under "## Baselines" in DECISIONS.md.
$approved = @()
$decisions = Join-Path $repoRoot ".harness/run/DECISIONS.md"
if (Test-Path $decisions) {
    $text = [regex]::Replace((Get-Content $decisions -Raw -Encoding UTF8), '(?s)<!--.*?-->', '')
    $section = [regex]::Match($text, '(?ms)^##[ \t]+Baselines[ \t]*\r?$(.*?)(?=^##[ \t]|\z)')
    if ($section.Success) {
        foreach ($line in ($section.Groups[1].Value -split "`r?`n")) {
            if ($line -match '^\s*[-*]\s+`?([^`\s]+)`?') { $approved += ($Matches[1] -replace '\\', '/').TrimStart('./') }
        }
    }
}

# What exists before recording, and a copy of it to put back.
$saved = Join-Path ([System.IO.Path]::GetTempPath()) ("foreman-baselines-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$before = @{}
if (Test-Path $baselineDir) {
    foreach ($file in @(Get-ChildItem -Path $baselineDir -Recurse -File)) {
        $rel = Get-RelativePath $file.FullName
        $copy = Join-Path $saved $rel
        New-Item -ItemType Directory -Path (Split-Path $copy) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $copy
        $before[$rel] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}

$task = ":" + ($Module.Trim(':')) + ":recordRoborazzi" + $Variant
$gradleArgs = @($task)
if ($Tests) { $gradleArgs += @("--tests", $Tests) }
[Console]::Error.WriteLine("+ gradlew " + ($gradleArgs -join " "))
Push-Location $repoRoot
try { & $gradlew @gradleArgs; $gradleExit = $LASTEXITCODE } finally { Pop-Location }

$added = @(); $restored = @(); $rerecorded = @()
if (Test-Path $baselineDir) {
    foreach ($file in @(Get-ChildItem -Path $baselineDir -Recurse -File)) {
        $rel = Get-RelativePath $file.FullName
        if (-not $before.ContainsKey($rel)) { $added += $rel; continue }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -eq $before[$rel]) { continue }
        if ($approved -contains ($modulePath + "/src/test/screenshots/" + $rel)) { $rerecorded += $rel; continue }
        Copy-Item -LiteralPath (Join-Path $saved $rel) -Destination $file.FullName -Force
        $restored += $rel
    }
}
# A recording never deletes a baseline, but if one is gone it comes back too.
foreach ($rel in @($before.Keys)) {
    $path = Join-Path $baselineDir $rel
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $saved $rel) -Destination $path -Force
        $restored += $rel
    }
}
Remove-Item -LiteralPath $saved -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "new baselines recorded: $($added.Count)"
foreach ($rel in $added) { Write-Output "  + $rel  (open it and judge it before you commit it)" }
Write-Output "existing baselines put back unchanged: $($restored.Count)"
foreach ($rel in $restored) { Write-Output "  = $rel" }
Write-Output "re-recorded with the human's approval: $($rerecorded.Count)"
foreach ($rel in $rerecorded) { Write-Output "  ~ $rel" }
exit $gradleExit
