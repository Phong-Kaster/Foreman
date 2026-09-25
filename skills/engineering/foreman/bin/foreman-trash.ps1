<#
.SYNOPSIS
    Delete a file or directory recoverably: move it into .harness/trash/ and record how to move it back.

.EXAMPLE
    powershell -NoProfile -File .harness/loop/bin/foreman-trash.ps1 -Path C:\build\cache
#>
param([Parameter(Mandatory = $true)][string]$Path)

. (Join-Path $PSScriptRoot "recovery-common.ps1")

$repoRoot = Get-RepoRoot
if (-not (Test-Path -LiteralPath $Path)) { Write-Error "Nothing to delete: $Path does not exist."; exit 1 }
$target = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')

# Refuse what could never be restored from inside the repository, or would destroy the repository
# itself: a drive root, the repository or anything containing it, its git directory, the trash.
$gitDir = (& git rev-parse --absolute-git-dir).Trim()
$refusals = @(
    @{ Test = ($target -match '^[A-Za-z]:$' -or $target -eq ''); Why = "a drive root" },
    @{ Test = ($repoRoot.StartsWith($target + '\', 'OrdinalIgnoreCase') -or $repoRoot -ieq $target); Why = "the repository or a folder containing it" },
    @{ Test = ($target -ieq (Resolve-Path $gitDir).Path -or $target.StartsWith((Resolve-Path $gitDir).Path + '\', 'OrdinalIgnoreCase')); Why = "the git directory" },
    @{ Test = ($target.StartsWith((Join-Path $repoRoot ".harness\trash"), 'OrdinalIgnoreCase')); Why = "the recovery trash itself" }
)
foreach ($r in $refusals) {
    if ($r.Test) { Write-Error "Refusing to delete $target - it is $($r.Why)."; exit 1 }
}

$trash = Get-TrashDir $repoRoot
$captured = Join-Path $trash (Split-Path $target -Leaf)
# Move-Item cannot move a directory across volumes, and a path outside the repository is often on
# another drive. Copy then remove is the portable form of the same thing.
Copy-Item -LiteralPath $target -Destination $captured -Recurse -Force
Remove-Item -LiteralPath $target -Recurse -Force

$id = Add-RecoveryEntry -RepoRoot $repoRoot -Action "deleted" -Target $target `
    -Captured "moved to ``$captured``" `
    -Restore "Copy-Item -LiteralPath '$captured' -Destination '$target' -Recurse"
Write-Host "Deleted $target (recoverable: $id in .harness/run/RECOVERY.md)."
