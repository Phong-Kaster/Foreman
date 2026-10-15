# foreman-read-guard.ps1 - a PreToolUse hook that keeps a subagent out of the files it was not
# meant to read (ADR-040).
#
# Every Read, Grep and Glob the engine or one of its subagents makes passes through here first. The
# hook input names the subagent (`agent_type`) on a subagent's call and names nothing on the main
# engine's own calls, measured on Claude Code 2.1.296. The main engine is governed by ENGINE.md and
# its permission rules, so its calls pass untouched. A subagent may read the repository's code freely
# and, under .harness/, only what its role needs:
#
#   loop-worker    .harness/knowledge/reference/**, .harness/knowledge/DOMAIN.md
#   loop-reviewer  the Worker's set, .harness/run/evidence/**, .harness/loop/POLICIES.md
#   loop-analyst   everything under .harness/ except .harness/archive/**
#   anything else  the Worker's set - an engine cannot dodge the guard by dispatching a generic agent
#
# Kanso Run 7, Iteration 5 is what earned it: the T-003 Worker read DoD.md three times and the whole
# PROJECT.md before writing a line, and the Reviewers and Workers of five iterations opened DoD.md
# whole 15 times between them. Every token read is re-sent on every later call of that context.
#
# Exit 2 refuses the call; Claude Code hands stderr to the subagent, so the message says where the
# information it wanted lives instead. Any input this script cannot parse is let through: a guard
# that broke every Read would stop the run, which is worse than one missed refusal.

$ErrorActionPreference = "Stop"

try {
    $raw = [Console]::In.ReadToEnd()
    $hook = $raw | ConvertFrom-Json
} catch { exit 0 }

$agent = "$($hook.agent_type)"
if (-not $agent) { exit 0 }

$tool = "$($hook.tool_name)"
$input_ = $hook.tool_input
$target = switch ($tool) {
    "Read" { "$($input_.file_path)" }
    "Grep" { "$($input_.path)" }
    "Glob" { "$($input_.path)" }
    default { "" }
}

# A Glob pattern can name .harness/ itself while its path is the repository root.
$pattern = if ($tool -eq "Glob") { "$($input_.pattern)" } else { "" }

$root = "$($hook.cwd)"
if (-not $root) { $root = (Get-Location).Path }

function ConvertTo-RepoPath([string]$p) {
    if (-not $p) { return "" }
    $p = $p -replace '\\', '/'
    $r = ($root -replace '\\', '/').TrimEnd('/')
    if ($p -match '^[A-Za-z]:/' -or $p.StartsWith('/')) {
        if ($p.ToLowerInvariant().StartsWith($r.ToLowerInvariant() + '/')) { $p = $p.Substring($r.Length + 1) }
        elseif ($p.ToLowerInvariant() -eq $r.ToLowerInvariant()) { $p = "" }
    }
    $p = $p -replace '^\./', ''
    return $p.TrimEnd('/')
}

$rel = ConvertTo-RepoPath $target
$candidates = @($rel)
if ($pattern) {
    $candidates += if ($rel) { "$rel/$($pattern -replace '\\', '/')" } else { ($pattern -replace '\\', '/') }
}

$workerAllowed = @('.harness/knowledge/reference', '.harness/knowledge/reference/*', '.harness/knowledge/domain.md')
$allowed = switch ($agent) {
    "loop-analyst"  { @('.harness/*') }
    "loop-reviewer" { $workerAllowed + @('.harness/run/evidence', '.harness/run/evidence/*', '.harness/loop/policies.md') }
    default         { $workerAllowed }
}

function Test-Refused([string]$path) {
    $p = $path.ToLowerInvariant()
    # Only .harness/ is guarded; the repository's code is every subagent's to read.
    if (-not ($p -eq '.harness' -or $p.StartsWith('.harness/') -or $p.StartsWith('**/.harness') -or $p.StartsWith('.harness*'))) { return $false }
    if ($p.StartsWith('.harness/archive')) { return $true }
    foreach ($a in $allowed) { if ($p -like $a) { return $false } }
    return $true
}

foreach ($c in $candidates) {
    if ($c -and (Test-Refused $c)) {
        # A Glob outside .harness/ that still lists files inside it shows names, never contents, and
        # reading any of them is refused here; only a pattern or path aimed at .harness/ is refused.
        $hint = switch -Wildcard ($c.ToLowerInvariant()) {
            "*dod.md*"     { "The DoD criteria your task cites are quoted in your Brief (or your review prompt)." }
            "*project.md*" { "The Constraints are quoted in your Brief; conventions live in .harness/knowledge/reference/<topic>.md, listed in your Brief." }
            "*issues*"     { "Open issues that touch your files are quoted in your Brief." }
            default        { "Everything your role needs from .harness/ is in your Brief or prompt; read the repository's code instead." }
        }
        [Console]::Error.WriteLine("Refused by Foreman's read guard (ADR-040): $agent may not read $c. $hint")
        exit 2
    }
}

# A Grep over the repository, or any folder above .harness/, returns matching lines from every file
# beneath it: measured, a Worker's pattern-only Grep printed lines of DoD.md, PROJECT.md and the
# archive. Unless the role may read all of .harness/, the search is rewritten to skip it. Its own glob
# is kept: "!.harness/**" joins it after a comma, and both apply (measured on 2.1.296). No permission
# decision is returned, so the call still passes every permission rule as before.
if ($tool -eq "Grep" -and $agent -ne "loop-analyst" -and -not $rel.ToLowerInvariant().StartsWith('.harness/')) {
    $glob = "$($input_.glob)"
    $exclude = '!.harness/**'
    $input_ | Add-Member -NotePropertyName glob -NotePropertyValue ($(if ($glob) { "$glob,$exclude" } else { $exclude })) -Force
    @{ hookSpecificOutput = @{ hookEventName = "PreToolUse"; updatedInput = $input_ } } | ConvertTo-Json -Depth 8 -Compress
}
exit 0
