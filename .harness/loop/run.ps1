<#
.SYNOPSIS
    Foreman V1 - the thin, intentionally dumb outer loop.

.DESCRIPTION
    The Runtime is the enforcement plane of the AI Software Factory.
    It is purely mechanical and never makes engineering decisions.

    Per iteration it does exactly four things:
      1. Compile human-approved Capability Ledgers into fresh permission settings (a build artifact).
      2. Invoke Claude Code once, with .harness/loop/ENGINE.md as appended system prompt.
      3. Read the Execution Status the engine persisted (.harness/run/STATUS.md).
      4. React: CONTINUE -> invoke again | DONE/DONE_PARTIAL/ESCALATE/FAILED -> stop | no status -> Watchdog.

    Trust chain: Human -> Capability Ledger -> Runtime Compiler -> Permission Settings -> Engine.
    The engine can never modify .harness/loop/, the ledgers, or the generated settings (deny rules below).

.NOTES
    Run from the consumer repository root. Requires: git, Claude Code CLI, PRD.md.
    Exit codes: 0=DONE  2=crash limit  3=ESCALATE  4=FAILED  5=budget (iterations or hours)
                6=quota ceiling  7=DONE_PARTIAL (Autonomous mode only, ADR-027)
#>

param(
    # Mechanical safety bounds - the only "policy" the Runtime owns (ADR-012).
    [int]$MaxIterations = 50,
    [int]$MaxConsecutiveCrashes = 3,
    # Seconds to wait before re-invoking after a Crash, multiplied by the consecutive crash count.
    [int]$CrashBackoffSeconds = 15,
    # Wall-clock bound for this invocation of run.ps1, in hours. 0 = no bound (the default, as before).
    # Meant for Autonomous runs, which never stop to ask and so need a limit the human set up front.
    [double]$MaxHours = 0,
    # Autonomous mode does not stop at MaxConsecutiveCrashes; it backs off exponentially instead, up
    # to this many seconds between attempts (ADR-027).
    [int]$MaxCrashBackoffSeconds = 1800,
    # Idle timeout: no stream event for this long means a hung invocation. Must exceed the longest
    # legitimate single tool call, because one Bash call emits no events while it runs.
    [int]$MaxIdleMinutes = 20,
    # Hard timeout: backstop for an invocation that emits events forever without converging.
    [int]$MaxIterationMinutes = 90,
    # Quota ceiling: stop (or wait) at this utilization percentage, on WHICHEVER usage window
    # trips first - the account has more than one (five_hour and seven_day).
    [int]$QuotaStopPercent = 90,
    # By default the loop sleeps until the quota window resets and then continues. This stops instead.
    [switch]$NoQuotaWait,
    [int]$MaxQuotaWaits = 6,
    # Keep the dynamic (per-machine, per-iteration) sections out of the system prompt so the
    # cacheable prefix stays byte-identical across iterations. This flag opts out.
    [switch]$NoStablePrompt,
    # Invocation mechanics.
    [string]$ClaudeCommand = "claude",
    [string]$Model = "",
    # Optional: stage an external requirement document as PRD.md before the first iteration.
    # Accepts a path relative to the repo root or an absolute path. Leave empty (default) to use
    # whatever PRD.md already sits at the repo root - unchanged from prior behavior.
    [string]$PrdPath = "",
    # Run Mode (ADR-027). Empty (default) keeps the mode this run already has, or Collaborative for a
    # run that has not bootstrapped yet. Stored outside the working tree - see Resolve-ModeFile.
    [ValidateSet("", "Collaborative", "Autonomous")]
    [string]$Mode = "",
    # Suppress the live engine activity feed (feed is on by default for observability).
    [switch]$QuietEngine,
    # Consenting-adult fast path (ADR-004): full permission bypass, for sandboxed/VM runs only.
    [switch]$DangerouslySkipPermissions
)

$ErrorActionPreference = "Stop"

# ---------- Paths ----------
$RepoRoot   = (Get-Location).Path
$LoopDir    = Join-Path (Join-Path $RepoRoot ".harness") "loop"
$RunDir      = Join-Path (Join-Path $RepoRoot ".harness") "run"
$StatusFile = Join-Path $RunDir "STATUS.md"

$EngineSpecPath = Join-Path $LoopDir "ENGINE.md"
if (-not (Test-Path $EngineSpecPath)) { Write-Error ".harness/loop/ENGINE.md not found. Run from the consumer repository root."; exit 1 }

# The engine creates the Loop Branch from HEAD and persists every checkpoint as a commit, so a
# repository with no commit yet cannot be worked in at all. Found in the field: a fresh repo with
# everything still untracked failed deep inside bootstrap, where the cause was far from obvious.
# Checked here instead, where the message can name the fix.
$null = & git rev-parse --verify HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "This repository has no commits yet. The engine branches from HEAD and checkpoints as commits, so it needs a base commit first: git add -A; git commit -m 'initial'."
    exit 1
}
# Passed as --append-system-prompt-file, not as an inline argument: the spec is ~13KB of multi-line
# text, which cannot survive Start-Process argument quoting (needed for the timeout bounds below).
$AgentsDir  = Join-Path $LoopDir "agents"

# ---------- PRD staging (mechanical copy only - never interprets or rewrites content) ----------
if ($PrdPath -ne "") {
    $PrdSource = if (Test-Path $PrdPath) { (Resolve-Path $PrdPath).Path } else { Join-Path $RepoRoot $PrdPath }
    if (-not (Test-Path $PrdSource)) { Write-Error "PRD source not found: $PrdPath"; exit 1 }
    $PrdTarget = Join-Path $RepoRoot "PRD.md"
    if ($PrdSource -ne $PrdTarget) {
        Copy-Item -Path $PrdSource -Destination $PrdTarget -Force
        Write-Host "Staged PRD from: $PrdSource" -ForegroundColor Cyan
    }
}

# The fixed, judgment-free user prompt. All intelligence lives in ENGINE.md and the repository.
$IterationPrompt = "Execute exactly one Iteration according to your Execution Engine Specification, then stop."

# ---------- Run Mode (ADR-027) ----------
# The mode file lives in the git directory, not in .harness/run/. Two reasons, both mechanical:
# a .harness/run/ that exists before bootstrap makes the engine skip bootstrap (ENGINE.md 5), and a
# file the Skill rewrites mid-run inside the working tree is a dirty tree the engine is told to
# treat as crash debris and revert (ENGINE.md 6.1). Nothing under the git directory is ever
# committed or seen as debris. The Skill writes it to switch a live run; this script re-reads it
# every Iteration and never overwrites it except when -Mode is passed explicitly.
function Resolve-ModeFile {
    $gitDir = & git rev-parse --absolute-git-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $gitDir) { return $null }
    return Join-Path $gitDir.Trim() "foreman-mode"
}
function Get-RunMode {
    if ($ModeFile -and (Test-Path $ModeFile)) {
        $value = (Get-Content $ModeFile -TotalCount 1)
        if ($value) { $value = $value.Trim() }
        if (@("Collaborative", "Autonomous") -contains $value) { return $value }
    }
    return "Collaborative"
}
$ModeFile = Resolve-ModeFile
if ($ModeFile) {
    if ($Mode -ne "") {
        Set-Content -Path $ModeFile -Value $Mode -Encoding ascii
    } elseif (-not (Test-Path $RunDir)) {
        # A run that has not bootstrapped is a new run: it never inherits the previous run's mode.
        Set-Content -Path $ModeFile -Value "Collaborative" -Encoding ascii
    }
}
$script:RunMode = Get-RunMode

# Run lock: at most ONE Foreman per repository. Two concurrent engines committing to the
# same branch would corrupt the run - refuse to start if a live instance holds the lock.
$LockFile = Join-Path $env:TEMP ("loop-run-" + (Split-Path $RepoRoot -Leaf) + ".lock")
if (Test-Path $LockFile) {
    $oldPid = (Get-Content $LockFile -TotalCount 1).Trim()
    $alive = $false
    if ($oldPid -match '^\d+$') { $alive = ($null -ne (Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue)) }
    if ($alive) {
        Write-Host "Another Foreman run (PID $oldPid) is already running against this repository. Only one loop may run at a time." -ForegroundColor Red
        exit 1
    }
    # Stale lock from a dead process - take over.
}
"$PID" | Out-File -FilePath $LockFile -Encoding ascii

# Logs, one pair per repository, in TEMP (never inside the repo):
#   .log       human-readable activity feed (what you tail to watch the loop)
#   .raw.jsonl raw engine event stream (debugging only)
# Both opened with FileShare.ReadWrite so a live tail (Get-Content -Wait) never locks the writer
# out, and every write is fail-silent: observability must never be able to kill execution.
function New-SharedLogWriter([string]$path) {
    try {
        $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true
        return $writer
    } catch { Write-Warning "Log unavailable ($path): $_. Continuing without it."; return $null }
}
$RunLog = Join-Path $env:TEMP ("loop-run-" + (Split-Path $RepoRoot -Leaf) + ".log")
$RawLog = Join-Path $env:TEMP ("loop-run-" + (Split-Path $RepoRoot -Leaf) + ".raw.jsonl")
$script:LogWriter = New-SharedLogWriter $RunLog
$script:RawWriter = New-SharedLogWriter $RawLog
function Write-RunLog([string]$line) {
    if ($null -ne $script:LogWriter) { try { $script:LogWriter.WriteLine($line) } catch {} }
}
function Write-RawLog([string]$line) {
    if ($null -ne $script:RawWriter) { try { $script:RawWriter.WriteLine($line) } catch {} }
}
Write-Host "Foreman starting. PID: $PID" -ForegroundColor Cyan
Write-Host "Activity log: $RunLog"
Write-Host "Watch live from another terminal:  Get-Content `"$RunLog`" -Wait -Tail 20"
Write-Host "Raw engine events (debugging): $RawLog"

# ---------- Capability compiler (mechanical: concatenates human-approved rules, never translates) ----------
# Ledger layers, by lifecycle:
#   .harness/loop/capabilities/baseline.json  permanent, ships with the runtime
#   .harness/knowledge/capabilities.json      standing,  per-repository (approved at the DoD gate)
#   .harness/run/capabilities.json            scoped,    per-goal (expires automatically with .harness/run/)
# Each ledger: { "entries": [ { "intent", "command", "scope", "lifetime", "allow": ["<exact rule>"] } ] }
# The runtime reads ONLY the "allow" arrays - exact rule strings the human approved. No interpretation.
function Compile-PermissionSettings {
    $allowRules = @()
    $ledgers = @(
        (Join-Path $LoopDir "capabilities\baseline.json"),
        (Join-Path $RepoRoot ".harness/knowledge/capabilities.json"),
        (Join-Path $RunDir "capabilities.json")
    )
    foreach ($ledger in $ledgers) {
        if (Test-Path $ledger) {
            $parsed = Get-Content $ledger -Raw | ConvertFrom-Json
            foreach ($entry in $parsed.entries) {
                foreach ($rule in $entry.allow) { $allowRules += $rule }
            }
        }
    }

    # Immutable deny rules protecting the enforcement plane itself. Always appended, never configurable.
    $denyRules = @(
        "Edit(.harness/loop/**)",
        "Write(.harness/loop/**)",
        "Edit(.harness/knowledge/capabilities.json)",
        "Write(.harness/knowledge/capabilities.json)",
        "Edit(.harness/run/capabilities.json)",
        "Write(.harness/run/capabilities.json)",
        # Human-owned domain truth. It OUTRANKS the codebase (ENGINE.md, Source of Truth), so an
        # engine able to rewrite it could quietly replace a correct rule with its own misreading -
        # and the Fresh-Context Review would then validate all future code against the corruption.
        "Edit(.harness/knowledge/DOMAIN.md)",
        "Write(.harness/knowledge/DOMAIN.md)",
        # The human's half of the Decision Queue. ESCALATION.md (the engine's questions) and
        # DECISIONS.md (the human's answers) used to be one file with two writers and no signal for
        # when it was safe for the second one to write - a human's answer, written the moment the
        # file appeared, was caught mid-write by the engine and logged as "recording the partial
        # decision." Denying the engine this file, mechanically, is what makes "the engine never
        # writes it" true instead of merely documented (ADR-025).
        "Edit(.harness/run/DECISIONS.md)",
        "Write(.harness/run/DECISIONS.md)",
        # The Run Mode is how much authority the engine holds. An engine able to write it could move
        # itself from Collaborative to Autonomous - the self-granted expansion Invariant 3 forbids
        # (ADR-027).
        "Edit(.git/foreman-mode)",
        "Write(.git/foreman-mode)",
        # Pushing is capability-gated (ADR-011) and scoped to the Loop Branch. These deny the
        # operations that would make the engine an author on shared history rather than a
        # contributor on its own branch - regardless of what any allow rule grants.
        "Edit(.claude/agents/**)",
        "Write(.claude/agents/**)",
        "Bash(git push --force*)",
        "Bash(git push -f*)",
        "Bash(git merge*)",
        "Bash(git rebase*)"
    )

    # Autonomous mode inverts the model (ADR-027): every tool allowed, minus the Deny List shipped in
    # baseline.json's "autonomous" block, plus any "deny" arrays the human added to the repository or
    # run ledgers. The immutable rules above still apply on top - deny always wins over allow.
    if ($script:RunMode -eq "Autonomous") {
        # Without the Deny List there is nothing to compile an Autonomous run from, and silently falling
        # back to Collaborative permissions would run a mode the human did not choose. Stop, and say why.
        $baselinePath = Join-Path $LoopDir "capabilities\baseline.json"
        $baseline = $null
        if (Test-Path $baselinePath) { $baseline = Get-Content $baselinePath -Raw | ConvertFrom-Json }
        if ($null -eq $baseline -or $null -eq $baseline.autonomous) {
            Write-Host "Autonomous mode needs the Deny List in .harness/loop/capabilities/baseline.json ('autonomous' block), and it is missing. Reinstall the runtime (/foreman re-syncs it), or run Collaborative." -ForegroundColor Red
            Stop-Run 4 "FAILED" "Autonomous mode could not compile its permissions: baseline.json has no 'autonomous' Deny List."
        }
        $allowRules = @($baseline.autonomous.allow)
        $denyRules += @($baseline.autonomous.deny)
        foreach ($ledger in $ledgers[1..2]) {
            if (Test-Path $ledger) {
                $parsed = Get-Content $ledger -Raw | ConvertFrom-Json
                foreach ($entry in $parsed.entries) {
                    foreach ($rule in $entry.deny) { $denyRules += $rule }
                }
            }
        }
    }

    $settings = @{
        permissions = @{
            allow = $allowRules
            deny  = $denyRules
        }
    }

    # The compiled settings file is a BUILD artifact: regenerated every iteration, stored outside the repo.
    $settingsPath = Join-Path $env:TEMP ("loop-permissions-" + [System.Guid]::NewGuid().ToString("N") + ".json")
    $settings | ConvertTo-Json -Depth 5 | Out-File -FilePath $settingsPath -Encoding utf8
    return $settingsPath
}

# ---------- Status reader ----------
function Read-ExecutionStatus {
    if (-not (Test-Path $StatusFile)) { return $null }
    $lines = @(Get-Content $StatusFile)
    if ($lines.Count -eq 0) { return $null }
    $word = $lines[0].Trim().ToUpperInvariant()
    if (@("CONTINUE", "DONE", "DONE_PARTIAL", "ESCALATE", "FAILED") -contains $word) {
        $reason = ""
        if ($lines.Count -gt 1) { $reason = ($lines[1..($lines.Count - 1)] -join "`n").Trim() }
        return @{ Word = $word; Reason = $reason }
    }
    return $null  # Malformed status = no status = crash.
}

# ---------- Quota reader (ADR-012) ----------
# claude -p --output-format stream-json emits `rate_limit_event` carrying structured utilization:
#   { "type":"rate_limit_event", "rate_limit_info": {
#       "status":"allowed" | "allowed_warning" | "rejected",
#       "rateLimitType":"five_hour", "resetsAt":<unix>,
#       "unifiedWindows": { "five_hour": {"utilization":0.37,"resetsAt":<unix>},
#                           "seven_day": {"utilization":0.18,"resetsAt":<unix>} } } }
#
# Two things learned from a real run, both of which shaped the code below:
#
#  1. `allowed_warning` is a real status, distinct from both `allowed` and `rejected`. Treating
#     "anything that is not allowed" as a rejection would make the Runtime sleep for hours on a
#     merely-warned invocation - the silent-hang failure mode this design exists to avoid. Only an
#     explicit `rejected` is a rejection.
#  2. The utilization reading available between iterations is measured when the finished iteration
#     STARTED making calls. A single iteration can consume a large share of a window, so a 90%
#     ceiling on stale data does not stop the loop reaching 100% mid-iteration - observed going
#     40% -> 100% inside one iteration. Therefore: track the PEAK seen mid-stream rather than the
#     last value, and treat the CLI's own `allowed_warning` as a trip regardless of arithmetic -
#     but only a warning ABOUT the five-hour window (its `rateLimitType`). The seven-day window
#     cannot move 40% -> 100% inside one iteration, the same event reports its utilization fresh,
#     and the CLI warns about it from 75% on. Treating that warning as a five-hour trip made a
#     field run (Calendar-Note, loop/music-player, 2026-09-24) sleep until the five-hour reset
#     with five_hour at 45% and seven_day at 88% - a wait that could never clear the warning.
#     The ceiling remains a between-iteration guard; it cannot preempt a single expensive
#     iteration, and no threshold can. Lower the ceiling when iterations are costly.
$script:LatestRateLimit = $null
$script:QuotaWarned     = $false
$script:PeakUtilization = @{}

function ConvertFrom-UnixSeconds([long]$seconds) {
    return [System.DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime
}

function Test-HasProperty($obj, [string]$name) {
    if ($null -eq $obj) { return $false }
    return (@($obj.PSObject.Properties.Name) -contains $name)
}

# Record one rate_limit_event. Called for every such event, including mid-iteration ones, because
# the peak matters and a later event can report a lower figure than one already seen.
function Register-RateLimit($info) {
    $script:LatestRateLimit = $info
    if (Test-HasProperty $info "status") {
        if ($info.status -eq "allowed_warning" -or $info.status -eq "rejected") {
            # A warning names its window; an event without one is read as five-hour, as before.
            $warnedWindow = "five_hour"
            if ((Test-HasProperty $info "rateLimitType") -and $info.rateLimitType) { $warnedWindow = "" + $info.rateLimitType }
            if ($warnedWindow -eq "five_hour") { $script:QuotaWarned = $true }
        }
    }
    if (Test-HasProperty $info "unifiedWindows") {
        foreach ($prop in $info.unifiedWindows.PSObject.Properties) {
            $w = $prop.Value
            if (-not (Test-HasProperty $w "utilization")) { continue }
            $pct = [double]$w.utilization * 100.0
            $resets = $null
            if (Test-HasProperty $w "resetsAt") { $resets = ConvertFrom-UnixSeconds ([long]$w.resetsAt) }
            $prev = $null
            if ($script:PeakUtilization.ContainsKey($prop.Name)) { $prev = $script:PeakUtilization[$prop.Name] }
            if ($null -eq $prev -or $pct -gt $prev.Percent) {
                $script:PeakUtilization[$prop.Name] = @{ Window = $prop.Name; Percent = $pct; ResetsAt = $resets }
            }
        }
    }
}

# Returns $null when below the ceiling, otherwise the tripped window with its reset time.
# Checks EVERY window: the five-hour one is not the only limit, and exhausting the seven-day
# window locks the human out for days rather than hours.
function Get-QuotaTrip {
    $tripped = $null
    foreach ($key in $script:PeakUtilization.Keys) {
        $w = $script:PeakUtilization[$key]
        $isOver = ($w.Percent -ge $QuotaStopPercent)
        # The CLI's own warning outranks the arithmetic: it knows the true remaining headroom,
        # and the utilization figure available here may have been measured before this iteration
        # spent anything.
        if (-not $isOver -and $script:QuotaWarned -and $key -eq "five_hour") { $isOver = $true }
        if (-not $isOver) { continue }
        if ($null -eq $tripped) {
            $tripped = $w
        } elseif ($null -ne $w.ResetsAt -and $null -ne $tripped.ResetsAt -and $w.ResetsAt -lt $tripped.ResetsAt) {
            # When several windows trip, the earliest reset is the one worth waiting for.
            $tripped = $w
        }
    }
    return $tripped
}

# A rejected invocation never ran, so the Watchdog counter must not move. Before this was
# distinguished, exhausting the quota burned three crashes and ended the run.
# `allowed_warning` is NOT a rejection - the invocation was permitted.
function Test-QuotaRejected {
    $info = $script:LatestRateLimit
    if ($null -eq $info) { return $false }
    if (-not (Test-HasProperty $info "status")) { return $false }
    return ($info.status -eq "rejected")
}

function Get-QuotaResetTime {
    $info = $script:LatestRateLimit
    if ($null -ne $info -and (Test-HasProperty $info "resetsAt")) { return ConvertFrom-UnixSeconds ([long]$info.resetsAt) }
    return $null
}

# Sleep until the window resets, logging a heartbeat: a silent stream reads as a hang to a human
# watching the feed. Waiting time is excluded from both iteration timeouts by construction.
function Wait-ForQuotaReset {
    param([datetime]$ResetsAt, [string]$Window)

    $target = $ResetsAt.AddSeconds(30)   # small buffer past the boundary
    # Sleeping past the hour budget only to stop on waking wastes the wait and hides the reason.
    if ($MaxHours -gt 0 -and $target -gt $RunStart.AddHours($MaxHours)) {
        Write-Host "The quota window '$Window' resets at $($target.ToString('HH:mm')), after the hour budget ($MaxHours h) ends. Stopping instead of waiting." -ForegroundColor Red
        Stop-Run 5 "BUDGET" "The quota window '$Window' resets at $($target.ToString('yyyy-MM-dd HH:mm')), after the hour budget ($MaxHours h) ends."
    }
    $msg = "Quota window '$Window' tripped (ceiling $QuotaStopPercent%, or a five-hour warning from the CLI). Waiting until $($target.ToString('yyyy-MM-dd HH:mm:ss')) for reset."
    Write-Host $msg -ForegroundColor Yellow
    Write-RunLog $msg

    while ((Get-Date) -lt $target) {
        $remaining = $target - (Get-Date)
        $beat = "[$(Get-Date -Format 'HH:mm:ss')] waiting for quota reset - {0:00}:{1:00}:{2:00} remaining" -f [int]$remaining.TotalHours, $remaining.Minutes, $remaining.Seconds
        Write-Host $beat -ForegroundColor DarkGray
        Write-RunLog $beat
        $chunk = [Math]::Min(300, [Math]::Max(5, [int]$remaining.TotalSeconds))
        Start-Sleep -Seconds $chunk
    }
    # The window has reset: clear what was learned before it, or the next check trips instantly.
    $script:QuotaWarned = $false
    $script:PeakUtilization = @{}
    $script:LatestRateLimit = $null
    Write-RunLog "Quota wait finished at $(Get-Date -Format o)"
}

# ---------- Child-process launcher ----------
# Invoke-EngineOnce needs a tracked child process (so a hung invocation can be killed), which means
# Start-Process rather than the `& cmd @args` call operator. Two consequences must be handled here:
#
#  1. The engine command is often a PowerShell SCRIPT, not an executable -- the npm-installed
#     `claude` resolves to claude.ps1, and the test fixture is a .ps1 too. Start-Process cannot
#     execute a .ps1, so a script is launched through powershell.exe -File.
#  2. Start-Process takes one argument STRING, so each argument is quoted here rather than trusting
#     -ArgumentList array joining, which does not quote reliably on Windows PowerShell 5.1.
function Format-ProcArg([string]$value) {
    if ($value -eq "") { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    # Double any run of backslashes immediately before the closing quote, then escape quotes.
    $escaped = $value -replace '(\\+)$', '$1$1'
    $escaped = $escaped -replace '"', '\"'
    return '"' + $escaped + '"'
}

function Resolve-EngineLaunch {
    param([string[]]$EngineArgs)

    $resolved = $null
    try { $resolved = Get-Command $ClaudeCommand -ErrorAction Stop } catch {}

    $exe = $ClaudeCommand
    $argv = $EngineArgs

    if ($null -ne $resolved) {
        if ($resolved.CommandType -eq "ExternalScript") {
            $exe = (Get-Command powershell.exe).Source
            $argv = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolved.Source) + $EngineArgs
        } elseif ($resolved.CommandType -eq "Application") {
            $exe = $resolved.Source
        }
    }

    $argString = ($argv | ForEach-Object { Format-ProcArg $_ }) -join " "
    return @{ Exe = $exe; ArgString = $argString }
}

# Agent definitions are materialized as FILES, not passed as a --agents argument. The JSON route
# was tried and abandoned: the definitions contain many double quotes, and the npm `claude` shim is
# itself a PowerShell script that re-quotes its arguments when calling claude.exe -- PowerShell 5.1
# mangles embedded quotes at that hop, so the CLI received unparsable JSON. Files avoid command-line
# quoting entirely and work regardless of which shim resolves.
#
# Like the permission settings, these are a BUILD artifact: regenerated from .harness/loop/agents/ every
# iteration and deny-listed against the engine's own edits, so a Worker's tool restriction stays
# enforced by the harness rather than by instruction.
function Publish-AgentDefinitions {
    $source = Join-Path $LoopDir "agents"
    if (-not (Test-Path $source)) { return }
    try {
        # Join-Path twice rather than embedding a separator: a literal backslash in this path was
        # how a stray control character got in here once, and it silently created a
        # differently-named directory that the CLI then never discovered.
        $target = Join-Path (Join-Path $RepoRoot ".claude") "agents"
        if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        Copy-Item -Path (Join-Path $source "*.md") -Destination $target -Force
    } catch {
        # Never let this stop a run: without the definitions the engine simply has no Workers.
        Write-Warning "Could not publish agent definitions ($_). Continuing without Workers."
    }
}

# The human's half of the Decision Queue (ADR-025). The engine is deny-listed from writing this
# file above, which means it can also never CREATE it - so the Runtime provisions it, once,
# mechanically, the same way it provisions the compiled permission settings. Skipped before
# bootstrap (no .harness/run/ yet): there is nothing to answer until the engine has asked something.
function Ensure-DecisionsFile {
    if (-not (Test-Path $RunDir)) { return }
    $decisionsFile = Join-Path $RunDir "DECISIONS.md"
    if (Test-Path $decisionsFile) { return }
    $templatePath = Join-Path $LoopDir "templates/DECISIONS.template.md"
    if (Test-Path $templatePath) {
        Copy-Item -Path $templatePath -Destination $decisionsFile
    } else {
        Set-Content -Path $decisionsFile -Value "# DECISIONS`n"
    }
}

# ---------- Engine invocation with idle + hard timeout (ADR-012) ----------
# Run as a tracked child process rather than a pipeline, so a hung invocation can actually be
# killed. An engine doing work emits tool_use events continuously; silence is the hang signal -
# which is why the idle bound, not the wall-clock bound, is the real hang detector.
# Returns "" on a completed invocation, or "idle" / "hard" when a timeout killed it.
function Invoke-EngineOnce {
    param([string[]]$EngineArgs, [datetime]$IterStart, [bool]$Stream)

    $stdoutFile = Join-Path $env:TEMP ("loop-engine-" + [System.Guid]::NewGuid().ToString("N") + ".out")
    $stderrFile = "$stdoutFile.err"
    $timeoutKind = ""
    # Cleared per invocation. Set only when the process could not be STARTED, which is a different
    # condition from one that started and died - see the classification at the crash block.
    $script:LaunchError = $null

    $launch = Resolve-EngineLaunch -EngineArgs $EngineArgs

    # Empty stdin, and it is load-bearing. The npm `claude` shim is a PowerShell script that does
    #   if ($MyInvocation.ExpectingInput) { $input | & claude.exe $args } else { & claude.exe $args }
    # Redirecting stdout without redirecting stdin leaves the child inheriting OUR stdin. When that
    # is a pipe that never delivers data and never closes -- which is exactly what it is when the
    # Runtime itself was launched from a script or a background task -- ExpectingInput is true and
    # `$input` blocks forever enumerating a stream that never ends. claude.exe is then never
    # spawned at all: the engine hangs before it starts, with no output and no error, and only the
    # idle timeout eventually notices. Observed in the field, hanging 11 minutes with 0.3s of CPU.
    $stdinFile = Join-Path $env:TEMP ("loop-engine-stdin-" + [System.Guid]::NewGuid().ToString("N") + ".txt")
    Set-Content -Path $stdinFile -Value "" -NoNewline

    # -WorkingDirectory is explicit and load-bearing: Start-Process launches in .NET's current
    # directory, which is NOT PowerShell's location. Without it the engine runs somewhere else
    # entirely and writes its status file outside the consumer repository.
    # Start-Process sits outside the streaming try/catch below, so a failure to launch was
    # previously an unhandled terminating error: the run died with exit 1 and no explanation.
    # Catch it here and record it, so the caller can tell "never started" from "started and died".
    try {
        $proc = Start-Process -FilePath $launch.Exe -ArgumentList $launch.ArgString `
                              -WorkingDirectory $RepoRoot `
                              -RedirectStandardInput $stdinFile `
                              -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
                              -NoNewWindow -PassThru
    } catch {
        $script:LaunchError = "$_"
        return ""
    }

    $idleLimit   = New-TimeSpan -Minutes $MaxIdleMinutes
    $hardLimit   = New-TimeSpan -Minutes $MaxIterationMinutes
    $lastEventAt = Get-Date
    $reader      = $null
    $fileStream  = $null
    $buffer      = ""

    try {
        while (-not (Test-Path $stdoutFile) -and -not $proc.HasExited) { Start-Sleep -Milliseconds 100 }
        if (Test-Path $stdoutFile) {
            # Shared read: the child holds this file open for writing for the whole invocation.
            $fileStream = New-Object System.IO.FileStream($stdoutFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fileStream)
        }

        while ($true) {
            $sawOutput = $false
            if ($null -ne $reader) {
                # ReadToEnd on a growing file returns what is available now. Split on newlines and
                # keep the trailing fragment: a half-written line is not parsable JSON yet.
                $chunk = $reader.ReadToEnd()
                if ($chunk.Length -gt 0) {
                    $sawOutput = $true
                    $lastEventAt = Get-Date
                    $buffer += $chunk
                    $parts = $buffer -split "`n"
                    $buffer = $parts[$parts.Count - 1]
                    if ($parts.Count -gt 1) {
                        foreach ($line in $parts[0..($parts.Count - 2)]) {
                            Read-EngineEvent -Line $line.TrimEnd("`r") -IterStart $IterStart -Stream $Stream
                        }
                    }
                }
            }

            if ($proc.HasExited -and -not $sawOutput) { break }

            if (((Get-Date) - $lastEventAt) -gt $idleLimit) {
                $timeoutKind = "idle"
                Write-Warning ("No engine event for {0} minutes - treating as a hung invocation." -f $MaxIdleMinutes)
                break
            }
            if (((Get-Date) - $IterStart) -gt $hardLimit) {
                $timeoutKind = "hard"
                Write-Warning ("Iteration exceeded {0} minutes - hard timeout." -f $MaxIterationMinutes)
                break
            }
            if (-not $sawOutput) { Start-Sleep -Milliseconds 250 }
        }

        if ($timeoutKind -ne "") {
            # Kill the whole tree: the engine spawns Workers, and orphans would keep writing.
            try { & taskkill /PID $proc.Id /T /F | Out-Null } catch {}
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
            Write-RunLog "=== Timeout ($timeoutKind) killed the engine process tree === $(Get-Date -Format o)"
        }
    } catch {
        $script:LaunchError = "$_"
        Write-Warning "Engine process error: $_"
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        if ($null -ne $fileStream) { try { $fileStream.Dispose() } catch {} }
        try {
            if ((Test-Path $stderrFile) -and (Get-Item $stderrFile).Length -gt 0) {
                $errText = (Get-Content $stderrFile -Raw).Trim()
                if ($errText -ne "") {
                    Write-RawLog $errText
                    # Surface it: an invocation that dies without a status is otherwise reported as
                    # a bare "Crash detected", and the only explanation sits in a log file the human
                    # has to know to open. Show the tail on the console too.
                    $errLines = @($errText -split "`n")
                    $tail = $errLines[([Math]::Max(0, $errLines.Count - 12))..($errLines.Count - 1)]
                    foreach ($l in $tail) {
                        $line = "[engine stderr] " + $l.TrimEnd("`r")
                        Write-Host $line -ForegroundColor DarkYellow
                        Write-RunLog $line
                    }
                }
            }
        } catch {}
        Remove-Item $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stdinFile -Force -ErrorAction SilentlyContinue
    }

    return $timeoutKind
}

# Mechanical passthrough of one stream-json line. The Runtime relays events, never interprets them.
function Read-EngineEvent {
    param([string]$Line, [datetime]$IterStart, [bool]$Stream)

    if ($Line.Trim() -eq "") { return }
    Write-RawLog $Line

    $evt = $null
    try { $evt = $Line | ConvertFrom-Json } catch { return }
    if ($null -eq $evt) { return }

    # Quota is tracked even when the activity feed is suppressed: it is a safety bound, not output.
    if ($evt.type -eq "rate_limit_event" -and (Test-HasProperty $evt "rate_limit_info")) {
        Register-RateLimit $evt.rate_limit_info
    }
    if (-not $Stream) { return }

    $stamp = "$(Get-Date -Format 'HH:mm:ss') +$(Format-Elapsed $IterStart)"
    if ($evt.type -eq "assistant" -and $null -ne $evt.message.content) {
        foreach ($block in $evt.message.content) {
            if ($block.type -eq "tool_use") {
                $detail = ""
                if ($null -ne $block.input.file_path) { $detail = " " + $block.input.file_path }
                elseif ($null -ne $block.input.command) { $detail = " " + $block.input.command }
                $line = "[$stamp] engine> $($block.name)$detail"
                Write-Host $line -ForegroundColor DarkGray
                Write-RunLog $line
            }
            if ($block.type -eq "text" -and $block.text.Trim() -ne "") {
                $snippet = ($block.text.Trim() -replace "\s+", " ")
                if ($snippet.Length -gt 160) { $snippet = $snippet.Substring(0, 160) + "..." }
                $line = "[$stamp] engine: $snippet"
                Write-Host $line -ForegroundColor Gray
                Write-RunLog $line
            }
        }
    }
    if ($evt.type -eq "result") {
        $line = "[$stamp] engine invocation finished ($($evt.subtype))"
        Write-Host $line -ForegroundColor DarkGray
        Write-RunLog $line
    }
}

# ---------- Timer ----------
$RunStart = Get-Date
function Format-Elapsed([datetime]$since) {
    $span = (Get-Date) - $since
    # [Math]::Floor, not [int]: [int] rounds, so 36 minutes would render as 01:36:00.
    return "{0:00}:{1:00}:{2:00}" -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
}

# ---------- Iteration budget: counted from commits, not from this process's memory ----------
# $iteration was a `for`-loop variable, so it reset to 1 every time this script was re-invoked -
# and ESCALATE, a Crash-limit, FAILED and a quota wait ALL exit the process (see the `exit` calls
# below), expecting the human or the Skill to run.ps1 again. MaxIterations therefore never bounded
# a run; it bounded one continuous process, and a run that escalates or crashes its way through
# restarts gets the budget again, free, every time. Observed in the field: six restarts in one run,
# each handed a fresh 50.
#
# ENGINE.md 6 requires every non-crashed Iteration to end at "exactly one Stable Checkpoint...
# persisted as one atomic git commit" - so commits already on the branch ARE the count of
# iterations already spent, and that count survives a process exit because git does. No new file:
# the default branch is resolved the same way a human would (origin's HEAD, then a local main or
# master), and if none can be found the count is 0 - identical to today's behavior, never worse.
function Resolve-DefaultBranchRef {
    $ref = & git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $ref) { return $ref }
    foreach ($name in @("main", "master")) {
        & git show-ref --verify --quiet "refs/heads/$name" 2>$null
        if ($LASTEXITCODE -eq 0) { return $name }
    }
    return $null
}
function Get-PriorIterationCount {
    $base = Resolve-DefaultBranchRef
    if (-not $base) { return 0 }
    $countText = & git rev-list --count "$base..HEAD" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $countText) { return 0 }
    return [int]$countText.Trim()
}

# ---------- Stopping, and the Run Report (ADR-027) ----------
# Every stop inside the loop goes through here so the finally block knows how the run ended.
# `exit` inside a function still ends the script, and still runs the finally block.
$script:Outcome = "INTERRUPTED"
$script:OutcomeReason = "The Runtime was stopped before the run reached a status."
function Stop-Run([int]$code, [string]$outcome, [string]$reason) {
    $script:Outcome = $outcome
    $script:OutcomeReason = $reason
    exit $code
}

# A run artifact as it stood last: on disk, or - once the Cleanup Commit has removed .harness/run/ -
# from the parent of the commit that deleted it. Returns "" when the file never existed.
function Read-RunArtifact([string]$relativePath) {
    $onDisk = Join-Path $RepoRoot $relativePath
    if (Test-Path $onDisk) { return (Get-Content $onDisk -Raw -Encoding UTF8) }
    $gitPath = $relativePath -replace '\\', '/'
    $deletedIn = & git rev-list -1 HEAD -- $gitPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $deletedIn) { return "" }
    $text = & git show "$($deletedIn.Trim())^:$gitPath" 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return ($text -join "`n")
}

function ConvertTo-HtmlText([string]$text) {
    return [System.Net.WebUtility]::HtmlEncode($text)
}
function ConvertTo-InlineHtml([string]$text) {
    $html = ConvertTo-HtmlText $text
    $html = [regex]::Replace($html, '`([^`]+)`', '<code>$1</code>')
    $html = [regex]::Replace($html, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    return $html
}

# Mechanical Markdown to HTML for the engine's ledgers: headings, lists, tables, fences, quotes,
# rules and paragraphs. No judgment and no reformatting - a line the converter does not recognise
# stays a line of text. Template comments are dropped so an empty ledger renders as empty.
function ConvertFrom-LedgerMarkdown([string]$markdown) {
    if (-not $markdown) { return '<p class="empty">(nothing recorded)</p>' }
    $markdown = [regex]::Replace($markdown, '(?s)<!--.*?-->', '')
    $out = New-Object System.Collections.Generic.List[string]
    $para = New-Object System.Collections.Generic.List[string]
    $list = $null; $table = $null; $fence = $null
    $flushPara = { if ($para.Count -gt 0) { $out.Add("<p>" + (($para | ForEach-Object { ConvertTo-InlineHtml $_ }) -join " ") + "</p>"); $para.Clear() } }
    $flushList = { if ($null -ne $list) { $out.Add("</$list>"); Set-Variable -Name list -Value $null -Scope 1 } }
    $flushTable = { if ($null -ne $table) { $out.Add('<div class="scroll"><table>' + ($table -join '') + '</table></div>'); Set-Variable -Name table -Value $null -Scope 1 } }
    foreach ($raw in ($markdown -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if ($null -ne $fence) {
            if ($line -match '^\s*```') { $out.Add("<pre><code>" + (ConvertTo-HtmlText ($fence -join "`n")) + "</code></pre>"); $fence = $null }
            else { $fence += $raw }
            continue
        }
        if ($line -match '^\s*```') { & $flushPara; & $flushList; & $flushTable; $fence = @(); continue }
        if ($line -match '^\s*\|.*\|\s*$') {
            & $flushPara; & $flushList
            if ($line -match '^\s*\|[\s:|-]+\|\s*$') { continue }
            $cells = $line.Trim().Trim('|') -split '\|'
            $tag = if ($null -eq $table) { "th" } else { "td" }
            if ($null -eq $table) { $table = @() }
            $table += "<tr>" + (($cells | ForEach-Object { "<$tag>" + (ConvertTo-InlineHtml $_.Trim()) + "</$tag>" }) -join '') + "</tr>"
            continue
        }
        & $flushTable
        if ($line -match '^(#{1,6})\s+(.*)$') {
            & $flushPara; & $flushList
            $level = [Math]::Min(6, $Matches[1].Length + 2)
            $out.Add("<h$level>" + (ConvertTo-InlineHtml $Matches[2]) + "</h$level>")
        } elseif ($line -match '^\s*[-*]\s+(.*)$' -or $line -match '^\s*\d+\.\s+(.*)$') {
            & $flushPara
            $want = if ($line -match '^\s*\d+\.') { "ol" } else { "ul" }
            $item = if ($line -match '^\s*[-*]\s+(.*)$') { $Matches[1] } else { ($line -replace '^\s*\d+\.\s+', '') }
            if ($list -ne $want) { & $flushList; $out.Add("<$want>"); $list = $want }
            $out.Add("<li>" + (ConvertTo-InlineHtml $item) + "</li>")
        } elseif ($line -match '^\s*>\s?(.*)$') {
            & $flushPara; & $flushList
            $out.Add("<blockquote>" + (ConvertTo-InlineHtml $Matches[1]) + "</blockquote>")
        } elseif ($line -match '^\s*-{3,}\s*$') {
            & $flushPara; & $flushList
            $out.Add("<hr>")
        } elseif ($line -eq '') {
            & $flushPara; & $flushList
        } else {
            & $flushList
            $para.Add($line.Trim())
        }
    }
    if ($null -ne $fence) { $out.Add("<pre><code>" + (ConvertTo-HtmlText ($fence -join "`n")) + "</code></pre>") }
    & $flushPara; & $flushList; & $flushTable
    return ($out -join "`n")
}

function Add-GitExclude([string]$pattern) {
    $gitDir = & git rev-parse --absolute-git-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $gitDir) { return }
    $exclude = Join-Path $gitDir.Trim() "info/exclude"
    New-Item -ItemType Directory -Path (Split-Path $exclude) -Force | Out-Null
    if ((Test-Path $exclude) -and (@(Get-Content $exclude) -contains $pattern)) { return }
    Add-Content -Path $exclude -Value $pattern
}

# RUN-REPORT.html at the repository root. Excluded through .git/info/exclude so it is never
# committed and never shows up as a dirty tree the next run's engine would treat as crash debris.
function Write-RunReport {
    $template = Join-Path $LoopDir "templates/RUN-REPORT.template.html"
    if (-not (Test-Path $template)) { Write-Warning "No RUN-REPORT template at $template; skipping the report."; return }
    $assumptions = Read-RunArtifact ".harness/run/ASSUMPTIONS.md"
    $recovery = Read-RunArtifact ".harness/run/RECOVERY.md"
    $outcomeClass = switch ($script:Outcome) { "DONE" { "ok" } "DONE_PARTIAL" { "partial" } default { "bad" } }
    $branch = & git rev-parse --abbrev-ref HEAD 2>$null
    $values = [ordered]@{
        "{{REPO}}"                = ConvertTo-HtmlText (Split-Path $RepoRoot -Leaf)
        "{{MODE}}"                = ConvertTo-HtmlText $script:RunMode
        "{{BRANCH}}"              = ConvertTo-HtmlText ("" + $branch).Trim()
        "{{OUTCOME}}"             = ConvertTo-HtmlText $script:Outcome
        "{{OUTCOME_CLASS}}"       = $outcomeClass
        "{{REASON}}"              = ConvertTo-InlineHtml $script:OutcomeReason
        "{{ITERATIONS}}"          = "" + (Get-PriorIterationCount)
        "{{ELAPSED}}"             = Format-Elapsed $RunStart
        "{{GENERATED}}"           = Get-Date -Format "yyyy-MM-dd HH:mm"
        "{{N_ASSUMPTIONS}}"       = "" + ([regex]::Matches($assumptions, '(?m)^## A-\d+')).Count
        "{{N_RECOVERY}}"          = "" + ([regex]::Matches($recovery, '(?m)^## R-\d+')).Count
        "{{SECTION_ASSUMPTIONS}}" = ConvertFrom-LedgerMarkdown $assumptions
        "{{SECTION_RECOVERY}}"    = ConvertFrom-LedgerMarkdown $recovery
        "{{SECTION_ISSUES}}"      = ConvertFrom-LedgerMarkdown (Read-RunArtifact ".harness/ISSUES.md")
        "{{SECTION_DOD}}"         = ConvertFrom-LedgerMarkdown (Read-RunArtifact ".harness/run/DoD.md")
        "{{SECTION_STATE}}"       = ConvertFrom-LedgerMarkdown (Read-RunArtifact ".harness/run/STATE.md")
    }
    $html = Get-Content $template -Raw -Encoding UTF8
    foreach ($key in $values.Keys) { $html = $html.Replace($key, $values[$key]) }
    $reportPath = Join-Path $RepoRoot "RUN-REPORT.html"
    [System.IO.File]::WriteAllText($reportPath, $html, (New-Object System.Text.UTF8Encoding($false)))
    Add-GitExclude "/RUN-REPORT.html"
    Write-Host "Run Report: $reportPath" -ForegroundColor Cyan
    Write-RunLog "run report: $reportPath"
}

# ---------- The loop ----------
$consecutiveCrashes = 0
$quotaWaits = 0
$priorIterations = Get-PriorIterationCount
if ($priorIterations -gt 0) {
    Write-Host "Resuming: $priorIterations iteration(s) already checkpointed on this branch." -ForegroundColor DarkGray
    Write-RunLog "resuming at iteration $($priorIterations + 1) - $priorIterations already checkpointed"
}

try {
for ($iteration = $priorIterations + 1; $iteration -le $MaxIterations; $iteration++) {
    $IterStart = Get-Date
    if ($MaxHours -gt 0 -and ((Get-Date) - $RunStart).TotalHours -ge $MaxHours) {
        Write-Host "Hour budget ($MaxHours h) exhausted. Stopping deterministically." -ForegroundColor Red
        Stop-Run 5 "BUDGET" "Hour budget ($MaxHours h) exhausted - a Runtime safety bound, not a judgment about the work."
    }
    # Re-read every Iteration: the Skill switches a live run by rewriting the mode file (ADR-027).
    $modeNow = Get-RunMode
    if ($modeNow -ne $script:RunMode) {
        Write-Host "Mode switched: $($script:RunMode) -> $modeNow (takes effect this iteration)" -ForegroundColor Magenta
        Write-RunLog "mode switched: $($script:RunMode) -> $modeNow"
        $script:RunMode = $modeNow
    }
    Write-Host ""
    Write-Host "=== Iteration $iteration / $MaxIterations === started $(Get-Date -Format 'HH:mm:ss') | total elapsed $(Format-Elapsed $RunStart) | mode $($script:RunMode)" -ForegroundColor Cyan
    Write-RunLog "=== Iteration $iteration / $MaxIterations === $(Get-Date -Format o) | mode $($script:RunMode)"

    # Status file is transport, not state: delete before invoking so absence-after = crash (mechanical detection).
    if (Test-Path $StatusFile) { Remove-Item $StatusFile -Force }

    # Fresh permission settings every iteration - build artifact, never a source artifact.
    # The engine spec goes in by FILE, not as an inline argument: it is ~13KB of multi-line text,
    # which cannot survive Start-Process argument quoting (needed for the timeout bounds).
    # The mode travels in the prompt, not the system prompt, so the cached spec prefix stays
    # byte-identical whichever mode a run is in (ENGINE.md 14).
    $prompt = "$IterationPrompt Run Mode: $($script:RunMode)."
    $claudeArgs = @("-p", $prompt, "--append-system-prompt-file", $EngineSpecPath)
    if ($DangerouslySkipPermissions) {
        $claudeArgs += "--dangerously-skip-permissions"
    } else {
        $settingsPath = Compile-PermissionSettings
        $claudeArgs += @("--settings", $settingsPath)
    }
    if ($Model -ne "") { $claudeArgs += @("--model", $Model) }
    # Worker/Reviewer definitions come from .harness/loop/, which is deny-listed against the engine's own
    # edits: a Worker's tool restriction must be enforced by the harness, not by instruction the
    # engine could reason around. Omitting Bash from its tools is what makes "no git, no build,
    # no test" real rather than advisory.
    Publish-AgentDefinitions
    Ensure-DecisionsFile
    # Keep per-machine, per-iteration sections (cwd, env, git status) out of the system prompt so
    # the cacheable prefix stays byte-identical across iterations. Git status changes every
    # checkpoint, so leaving it in the prefix would break the cache for the spec that follows it.
    if (-not $NoStablePrompt) { $claudeArgs += "--exclude-dynamic-system-prompt-sections" }

    # stream-json is always requested: the Runtime needs `rate_limit_event` for the quota bound
    # (ADR-012) even when the human-facing activity feed is suppressed.
    $claudeArgs += @("--output-format", "stream-json", "--verbose")

    # Invoke the engine. Its exit code is irrelevant; only the persisted status counts.
    $timeoutKind = Invoke-EngineOnce -EngineArgs $claudeArgs -IterStart $IterStart -Stream (-not $QuietEngine)

    $status = Read-ExecutionStatus

    # ---- Quota comes first: it is neither a Crash nor an engineering outcome (ADR-012) ----
    # A rejected invocation never ran, so the Watchdog counter must not move. Checking this before
    # crash handling is what stops an exhausted quota from burning three crashes and ending the run.
    if ($null -eq $status -and (Test-QuotaRejected)) {
        $resetsAt = Get-QuotaResetTime
        Write-Host "Usage limit reached - the engine could not run this iteration." -ForegroundColor Yellow
        Write-RunLog "=== Quota rejected === $(Get-Date -Format o)"
        if ($NoQuotaWait -or $null -eq $resetsAt) {
            Write-Host "Stopping at the usage limit. Re-run after it resets to continue from the last Stable Checkpoint." -ForegroundColor Yellow
            Stop-Run 6 "QUOTA" "Stopped at the usage limit before the quota window reset."
        }
        $quotaWaits++
        if ($quotaWaits -gt $MaxQuotaWaits) {
            Write-Host "Waited for a quota reset $MaxQuotaWaits times already. Stopping deterministically." -ForegroundColor Red
            Stop-Run 6 "QUOTA" "Waited for a quota reset $MaxQuotaWaits times already."
        }
        Wait-ForQuotaReset -ResetsAt $resetsAt -Window "rejected"
        $iteration--   # this iteration never executed; do not spend it from the budget
        continue
    }

    # ---- A process that never STARTED is not a Crash either ----
    # Same reasoning as the quota branch above: the Watchdog's budget exists for faults that a retry
    # can clear. A missing CLI or an over-long argument list clears only when a human acts, so three
    # retries burn the budget and then report the failure as "probably transient, start it again".
    # The distinguishing fact - the exception fired before the process ran - is already in hand.
    if ($null -eq $status -and $null -ne $script:LaunchError) {
        Write-Host ""
        Write-Host "The engine could not be started." -ForegroundColor Red
        Write-Host "  $script:LaunchError"
        Write-Host "This is not a crash, so it is not retried: another invocation would fail the same way."
        Write-Host "Repair the environment, then start the run again. It resumes from the last Stable Checkpoint."
        Write-RunLog "=== Status: FAILED (launch) === $(Get-Date -Format o)"
        Write-RunLog "FAILED: engine could not be started: $script:LaunchError"
        Stop-Run 4 "FAILED" "The engine could not be started: $script:LaunchError"
    }

    if ($null -eq $status) {
        # Crash: the engine died without reporting. Only the Runtime can detect this (Watchdog).
        # A timeout kill lands here deliberately - it IS a crash, and existing recovery applies:
        # the next invocation finds a dirty tree and recovers per ENGINE.md 6.1.
        $consecutiveCrashes++
        $why = "no Execution Status"
        if ($timeoutKind -ne "") { $why = "$timeoutKind timeout" }
        Write-Warning "Crash detected ($why). Consecutive crashes: $consecutiveCrashes / $MaxConsecutiveCrashes"
        if ($consecutiveCrashes -ge $MaxConsecutiveCrashes -and $script:RunMode -ne "Autonomous") {
            Write-Host "Watchdog limit reached. Stopping. The next run's engine will recover from the last Stable Checkpoint." -ForegroundColor Red
            Stop-Run 2 "CRASH LIMIT" "The engine died without reporting $consecutiveCrashes times in a row."
        }
        # Give a transient fault room to clear. Retrying three times inside a few seconds spends the
        # budget before the condition it protects against has had any chance to pass.
        $wait = $CrashBackoffSeconds * $consecutiveCrashes
        if ($script:RunMode -eq "Autonomous" -and $consecutiveCrashes -ge $MaxConsecutiveCrashes) {
            # Nobody is there to restart an Autonomous run, so the Watchdog keeps going - doubling the
            # wait each time, capped - and the iteration and hour budgets remain the hard stop (ADR-027).
            $wait = [Math]::Min($MaxCrashBackoffSeconds, $CrashBackoffSeconds * [Math]::Pow(2, $consecutiveCrashes - 1))
            Write-Host "Autonomous mode: backing off instead of stopping at the crash limit." -ForegroundColor DarkYellow
            Write-RunLog "autonomous: crash $consecutiveCrashes past the limit - backing off, not stopping"
        }
        if ($wait -gt 0) {
            Write-Host "Waiting $wait s before re-invoking (backoff)." -ForegroundColor DarkGray
            Write-RunLog "backoff $wait s after crash $consecutiveCrashes"
            Start-Sleep -Seconds $wait
        }
        continue
    }

    $consecutiveCrashes = 0
    Remove-Item $StatusFile -Force
    Write-RunLog "=== Status: $($status.Word) === $(Get-Date -Format o)"
    Write-Host ("Status: {0} (iteration took {1}, total elapsed {2})" -f $status.Word, (Format-Elapsed $IterStart), (Format-Elapsed $RunStart)) -ForegroundColor Yellow
    if ($status.Reason -ne "") { Write-Host $status.Reason }

    # Provisioned here too, not only before invoking: bootstrap is the Iteration that FIRST creates
    # .harness/run/, and ESCALATE can fire on that very Iteration (the DoD approval gate always
    # does). Provisioning only before invocation would leave a human staring at an ESCALATION.md
    # with no DECISIONS.md to answer into until they ran the Runtime a second time for no reason.
    Ensure-DecisionsFile

    switch ($status.Word) {
        "DONE"     { Write-Host "Goal verified complete. Review and merge the Loop Branch." -ForegroundColor Green; Stop-Run 0 "DONE" $status.Reason }
        "DONE_PARTIAL" { Write-Host "Run finished without every criterion met. See RUN-REPORT.html for what was decided, done, and left." -ForegroundColor Yellow; Stop-Run 7 "DONE_PARTIAL" $status.Reason }
        "ESCALATE" { Write-Host "Human decision required. See .harness/run/ESCALATION.md - answer the queued decisions, then re-run." -ForegroundColor Magenta; Stop-Run 3 "ESCALATE" $status.Reason }
        "FAILED"   { Write-Host "Execution broken. Human repair required. See .harness/run/STATE.md for the engine's last findings." -ForegroundColor Red; Stop-Run 4 "FAILED" $status.Reason }
    }

    # ---- CONTINUE: check the resource bound before spending another iteration ----
    $trip = Get-QuotaTrip
    if ($null -ne $trip) {
        $pct = [Math]::Round($trip.Percent, 1)
        Write-Host "Quota window '$($trip.Window)' at $pct% (ceiling $QuotaStopPercent%)." -ForegroundColor Yellow
        Write-RunLog "=== Quota ceiling: $($trip.Window) at $pct% === $(Get-Date -Format o)"
        if ($NoQuotaWait -or $null -eq $trip.ResetsAt) {
            Write-Host "Stopping to leave usage headroom. Re-run to continue from the last Stable Checkpoint." -ForegroundColor Yellow
            Stop-Run 6 "QUOTA" "Stopped at the quota ceiling to leave usage headroom."
        }
        $quotaWaits++
        if ($quotaWaits -gt $MaxQuotaWaits) {
            Write-Host "Waited for a quota reset $MaxQuotaWaits times already. Stopping deterministically." -ForegroundColor Red
            Stop-Run 6 "QUOTA" "Waited for a quota reset $MaxQuotaWaits times already."
        }
        Wait-ForQuotaReset -ResetsAt $trip.ResetsAt -Window $trip.Window
    }
}

# Iteration budget exhausted: a deterministic safety stop, never an interpretation of task failure.
Write-Host "Iteration budget ($MaxIterations) exhausted. Stopping deterministically." -ForegroundColor Red
Write-Host "This is a Runtime safety bound, not a judgment about the work. Inspect .harness/run/STATE.md and re-run to continue from the last Stable Checkpoint."
Stop-Run 5 "BUDGET" "Iteration budget ($MaxIterations) exhausted - a Runtime safety bound, not a judgment about the work."
} finally {
    # The Run Report is rendered here, on every exit path, because the exits the engine never sees
    # coming - budget, crash limit, quota - are exactly when the human most needs it (ADR-027).
    if ($script:RunMode -eq "Autonomous") {
        try { Write-RunReport } catch { Write-Warning "Could not render RUN-REPORT.html ($_)." }
    }
    # Cleanup always runs, even on exit: release the log writers and the run lock.
    if ($null -ne $script:LogWriter) { try { $script:LogWriter.Dispose() } catch {} }
    if ($null -ne $script:RawWriter) { try { $script:RawWriter.Dispose() } catch {} }
    try { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } catch {}
}
