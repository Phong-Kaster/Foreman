<#
.SYNOPSIS
    Capture a file or directory before a destructive change (a local database file, a data folder)
    and record how to put it back. The destructive change itself is the caller's next command.

.EXAMPLE
    powershell -NoProfile -File .harness/loop/bin/foreman-snapshot.ps1 -Path app/data/notes.db
#>
param([Parameter(Mandatory = $true)][string]$Path)

. (Join-Path $PSScriptRoot "recovery-common.ps1")

$repoRoot = Get-RepoRoot
if (-not (Test-Path -LiteralPath $Path)) { Write-Error "Nothing to snapshot: $Path does not exist."; exit 1 }
$target = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')

$trash = Get-TrashDir $repoRoot
$captured = Join-Path $trash (Split-Path $target -Leaf)
Copy-Item -LiteralPath $target -Destination $captured -Recurse -Force

$id = Add-RecoveryEntry -RepoRoot $repoRoot -Action "snapshot before a destructive change" -Target $target `
    -Captured "copied to ``$captured``" `
    -Restore "Remove-Item -LiteralPath '$target' -Recurse -Force; Copy-Item -LiteralPath '$captured' -Destination '$target' -Recurse"
Write-Host "Snapshot of $target taken ($id in .harness/run/RECOVERY.md). Proceed with the change."
