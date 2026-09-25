<#
.SYNOPSIS
    Records Compose screenshot references for cases that have none, and refuses to overwrite one
    that already exists.

.DESCRIPTION
    `updateDebugScreenshotTest` does two things that look identical to a permission matcher and are
    not remotely equivalent in what they permit:

      1. recording a reference for a case that has never had one  - safe, and necessary
      2. overwriting the reference a currently-failing case is measured against - evidence laundering

    (2) gives an engine facing a red screenshot test a one-command route to re-recording wrong output
    as correct, which is the same class of act as editing an approved Definition of Done. That is why
    the standing grant for the raw command was withdrawn.

    Because `Bash(*updateDebugScreenshotTest*)` cannot distinguish the two, a human had to sit at the
    decision - and on the Calendar-Note alarms run the SAME grant was requested four times (D-003,
    D-004, D-006, D-007), stopping the loop each time while nothing new was actually being decided.

    A script can make the distinction the matcher cannot. This one hashes every existing reference
    before the run and restores any that changed, so only NEW files survive. Grant this wrapper for
    the run instead of granting the raw command, and the question stops being asked without the
    protection being given up.

.PARAMETER TestFilter
    Gradle --tests pattern, e.g. "*AlarmsEmptyStateCase*".

.PARAMETER Module
    Gradle module path. Defaults to :app.

.PARAMETER ReferenceRoot
    Where reference PNGs live. Defaults to app/src/screenshotTestDebug/reference.

.EXAMPLE
    powershell skills/knowledge/android/compose-visual-testing/record-new-references.ps1 -TestFilter "*AlarmsPermissionNoticeCase*"

.OUTPUTS
    Exit 0 - the run succeeded and every changed file was a new one.
    Exit 2 - the run tried to overwrite an existing reference. Originals restored, nothing recorded.
    Exit 3 - Gradle itself failed. Its exit code is checked directly, never through a pipe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TestFilter,
    [string]$Module = ":app",
    [string]$ReferenceRoot = "app/src/screenshotTestDebug/reference"
)

$ErrorActionPreference = "Stop"

function Get-ReferenceHashes([string]$root) {
    $map = @{}
    if (-not (Test-Path $root)) { return $map }
    foreach ($f in Get-ChildItem -Path $root -Recurse -Filter *.png -File) {
        $map[$f.FullName] = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}

Write-Host "Snapshotting existing references under $ReferenceRoot" -ForegroundColor Cyan
$before = Get-ReferenceHashes $ReferenceRoot
Write-Host "  $($before.Count) reference image(s) present before the run."

# Back up only what exists; a file that is not there cannot be overwritten.
$backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ("refbak-" + [Guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $backupDir -Force
$index = @{}
$i = 0
foreach ($path in $before.Keys) {
    $i++
    $slot = Join-Path $backupDir "$i.png"
    Copy-Item -Path $path -Destination $slot -Force
    $index[$path] = $slot
}

$gradlew = if ($IsLinux -or $IsMacOS) { "./gradlew" } else { ".\gradlew.bat" }
Write-Host "Running $gradlew $Module`:updateDebugScreenshotTest --tests `"$TestFilter`"" -ForegroundColor Cyan

# No pipe. A piped exit code belongs to the last command in the pipe, not to Gradle.
& $gradlew "$Module`:updateDebugScreenshotTest" "--tests" $TestFilter
$gradleExit = $LASTEXITCODE

if ($gradleExit -ne 0) {
    Write-Host "Gradle exited $gradleExit. Nothing is being kept." -ForegroundColor Red
    foreach ($path in $index.Keys) { Copy-Item -Path $index[$path] -Destination $path -Force }
    Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 3
}

$after = Get-ReferenceHashes $ReferenceRoot
$overwritten = @()
foreach ($path in $before.Keys) {
    if (-not $after.ContainsKey($path)) { $overwritten += "$path (deleted)"; continue }
    if ($after[$path] -ne $before[$path]) { $overwritten += $path }
}
$created = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })

if ($overwritten.Count -gt 0) {
    Write-Host ""
    Write-Host "REFUSED: the run modified $($overwritten.Count) reference image(s) that already existed." -ForegroundColor Red
    foreach ($p in $overwritten) { Write-Host "  $p" }
    Write-Host "Restoring the originals. Moving an existing baseline is a human decision - escalate for it." -ForegroundColor Red
    foreach ($path in $index.Keys) { if (Test-Path $index[$path]) { Copy-Item -Path $index[$path] -Destination $path -Force } }
    foreach ($p in $created) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 2
}

Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Recorded $($created.Count) NEW reference image(s); 0 existing image(s) modified." -ForegroundColor Green
foreach ($p in $created) { Write-Host "  + $p" }
Write-Host "Before: $($before.Count) file(s). After: $($after.Count) file(s)."
exit 0
