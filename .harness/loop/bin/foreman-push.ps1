<#
.SYNOPSIS
    Push the Loop Branch, recording what the remote held before so the push can be undone.
    Never the default branch, never --force (ADR-011): a push the remote rejects as non-fast-forward
    stays rejected.

.EXAMPLE
    powershell -NoProfile -File .harness/loop/bin/foreman-push.ps1
#>
param([string]$Remote = "origin")

. (Join-Path $PSScriptRoot "recovery-common.ps1")

$repoRoot = Get-RepoRoot
$branch = (& git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -notlike "loop/*") {
    Write-Error "Refusing to push '$branch': only a Loop Branch (loop/*) may be pushed (ADR-011)."
    exit 1
}

$before = & git ls-remote $Remote "refs/heads/$branch" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "Cannot reach remote '$Remote'."; exit 1 }
$previous = if ($before) { ($before -split '\s+')[0] } else { "" }
$pushed = (& git rev-parse HEAD).Trim()

& git push $Remote "HEAD:refs/heads/$branch"
if ($LASTEXITCODE -ne 0) { Write-Error "Push rejected. Nothing was changed on '$Remote'."; exit 1 }

if ($previous) {
    $captured = "remote ``$branch`` was at ``$previous`` before this push"
    $restore = "git push --force-with-lease=refs/heads/${branch}:$pushed $Remote ${previous}:refs/heads/$branch"
} else {
    $captured = "remote ``$branch`` did not exist before this push"
    $restore = "git push $Remote --delete $branch"
}
$id = Add-RecoveryEntry -RepoRoot $repoRoot -Action "pushed $branch to $Remote ($pushed)" `
    -Target "$Remote/$branch" -Captured $captured -Restore $restore
Write-Host "Pushed $branch to $Remote ($id in .harness/run/RECOVERY.md)."
