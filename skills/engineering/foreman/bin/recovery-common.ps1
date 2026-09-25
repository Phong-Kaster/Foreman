<#
    Shared plumbing for the Recovery Wrappers (ENGINE.md 14.3, ADR-027). Dot-sourced, never run.

    A wrapper captures what an action is about to destroy, performs the action, and appends the
    captured location and the exact restore command to .harness/run/RECOVERY.md. The wrappers live in
    .harness/loop/, which the engine is denied write access to, so the engine can call them but
    cannot change what they record.
#>

$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    $top = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $top) { throw "Not inside a git repository." }
    return (Resolve-Path $top.Trim()).Path
}

# .harness/trash/ holds captured copies. It must never enter a checkpoint commit, and it must never
# show up as a dirty tree the engine would treat as crash debris (ENGINE.md 6.1) - so it is excluded
# through .git/info/exclude, which is itself outside the working tree.
function Get-TrashDir([string]$repoRoot) {
    $gitDir = (& git rev-parse --absolute-git-dir).Trim()
    $exclude = Join-Path $gitDir "info/exclude"
    New-Item -ItemType Directory -Path (Split-Path $exclude) -Force | Out-Null
    $present = (Test-Path $exclude) -and (@(Get-Content $exclude) -contains "/.harness/trash/")
    if (-not $present) { Add-Content -Path $exclude -Value "/.harness/trash/" }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $dir = Join-Path $repoRoot ".harness/trash/$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Add-RecoveryEntry {
    param([string]$RepoRoot, [string]$Action, [string]$Target, [string]$Captured, [string]$Restore)
    $runDir = Join-Path $RepoRoot ".harness/run"
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $ledger = Join-Path $runDir "RECOVERY.md"
    if (-not (Test-Path $ledger)) {
        $template = Join-Path $RepoRoot ".harness/loop/templates/RECOVERY.template.md"
        if (Test-Path $template) { Copy-Item $template $ledger } else { Set-Content -Path $ledger -Value "# RECOVERY`n`n---" }
    }
    $count = @(Get-Content $ledger | Where-Object { $_ -match '^## R-\d+' }).Count
    $id = "R-{0:000}" -f ($count + 1)
    $entry = @(
        "",
        "## $id - $Action",
        "",
        "- **When:** $(Get-Date -Format o)",
        "- **Target:** ``$Target``",
        "- **Captured:** $Captured",
        "- **Restore:** ``$Restore``"
    )
    Add-Content -Path $ledger -Value $entry
    return $id
}
