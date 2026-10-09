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
    # After the engine has reported its result, how long its process may stay silent before the
    # Runtime ends it. A background shell it left running keeps the process alive (Kanso, 2026-10-07).
    [int]$ResultGraceSeconds = 120,
    # A Gradle test JVM of this repository still running after this many minutes is ended, so a test that
    # never finishes fails the build instead of holding the iteration (Kanso, 2026-10-07).
    [double]$MaxTestWorkerMinutes = 30,
    # Hard timeout: backstop for an invocation that emits events forever without converging.
    [int]$MaxIterationMinutes = 90,
    # Quota ceiling: stop (or wait) at this utilization percentage, on WHICHEVER usage window
    # trips first - the account has more than one (five_hour and seven_day).
    [int]$QuotaStopPercent = 90,
    # By default the loop sleeps until the quota window resets and then continues. This stops instead.
    [switch]$NoQuotaWait,
    # ESCALATE opens the decision queue in the default browser. Headless CI wants this off.
    [switch]$NoOpenEscalation,
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
    [switch]$DangerouslySkipPermissions,
    # Render FOREMAN.html - the one page a person reads (ADR-034) - open it, and stop. Invokes no
    # engine, takes no lock and leaves the Run Mode alone, so it is safe beside a live run.
    [switch]$Page
)

$ErrorActionPreference = "Stop"

# ---------- Paths ----------
$RepoRoot   = (Get-Location).Path
$LoopDir    = Join-Path (Join-Path $RepoRoot ".harness") "loop"
$RunDir      = Join-Path (Join-Path $RepoRoot ".harness") "run"
$StatusFile = Join-Path $RunDir "STATUS.md"
$StateFile  = Join-Path $RunDir "STATE.md"
$ModelsPath = Join-Path $LoopDir "models.json"
# Per-iteration measurements, one row per iteration. Deliberately NOT under .harness/run/, which the
# Cleanup Commit deletes: the whole point is to still have the numbers after the run that produced
# them has finished.
$TelemetryFile = Join-Path (Join-Path $RepoRoot ".harness") "TELEMETRY.tsv"

$EngineSpecPath = Join-Path $LoopDir "ENGINE.md"
if (-not (Test-Path $EngineSpecPath)) { Write-Error ".harness/loop/ENGINE.md not found. Run from the consumer repository root."; exit 1 }

# Every `git` below runs through this function, which PowerShell prefers over git.exe. Under
# ErrorActionPreference Stop, Windows PowerShell 5.1 turns whatever a native command writes to stderr
# into a terminating error, `2>$null` or not, so one git that failed ended the whole Runtime with
# exit 1 (reproduced 2026-10-07 with a broken index; ADR-037). Here stderr is only a stream again:
# the caller's redirection still discards it, and the caller still reads $LASTEXITCODE.
$script:GitExe = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $script:GitExe) { Write-Error "git was not found on PATH."; exit 1 }
function git {
    $ErrorActionPreference = "Continue"
    & $script:GitExe @args
}

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
if ($ModeFile -and -not $Page) {
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
if ($Page) {
    # Rendering a page is not a run: no lock to take, and none to wait for.
} elseif (Test-Path $LockFile) {
    $oldPid = (Get-Content $LockFile -TotalCount 1).Trim()
    $alive = $false
    if ($oldPid -match '^\d+$') { $alive = ($null -ne (Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue)) }
    if ($alive) {
        Write-Host "Another Foreman run (PID $oldPid) is already running against this repository. Only one loop may run at a time." -ForegroundColor Red
        exit 1
    }
    # Stale lock from a dead process - take over.
}
if (-not $Page) { "$PID" | Out-File -FilePath $LockFile -Encoding ascii }

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
if (-not $Page) {
    Write-Host "Foreman starting. PID: $PID" -ForegroundColor Cyan
    Write-Host "Activity log: $RunLog"
    Write-Host "Watch live from another terminal:  Get-Content `"$RunLog`" -Wait -Tail 20"
    Write-Host "Raw engine events (debugging): $RawLog"
}

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
        "Bash(git rebase*)",
        # A device is driven only through .harness/loop/bin/foreman-device.ps1, which acts on nothing
        # but the debug build this repository produced - never another app, never a device setting
        # (ADR-033). These are adb in every form the matcher was measured to catch: plain and .exe, by
        # full path, behind an env prefix or `cd &&`, and inside bash -c, cmd or powershell. They are
        # anchored so that a commit message which merely mentions adb still commits.
        "Bash(adb *)",
        "Bash(adb)",
        "Bash(adb.exe*)",
        "Bash(*/adb *)",
        "Bash(*/adb)",
        "Bash(*adb.exe *)",
        "Bash(*platform-tools*)",
        "Bash(bash -c*adb*)",
        "Bash(sh -c*adb*)",
        "Bash(cmd *adb*)",
        "Bash(powershell*adb *)",
        "Bash(pwsh*adb *)",
        "Bash(*xargs*adb*)",
        # The two device-automation MCP servers ADR-031 reviewed and rejected, denied outright so no
        # ledger can grant them back.
        "mcp__android-agent",
        "mcp__mobile-mcp",
        # Approved screenshot baselines are never re-recorded by the engine (ADR-036). These are every
        # Gradle route to it measured against the real matcher: the record and clear tasks, and the
        # record property on any task. New baselines go through bin/foreman-record-baselines.ps1.
        "Bash(*gradlew*recordRoborazzi*)",
        "Bash(*gradlew*RecordRoborazzi*)",
        "Bash(*gradlew*clearRoborazzi*)",
        "Bash(*gradlew*roborazzi.test.record*)",
        # Gradle state the whole machine shares is never the run's to change. Kanso's Run 3,
        # 2026-10-07: after a build was killed mid-write, the engine ran `./gradlew --stop`, which
        # stops every daemon of that Gradle version on the machine, other projects' builds
        # included, then moved 264 entries and finally the whole transforms directory out of
        # ~/.gradle/caches. Measured against the real matcher the same day: these deny --stop
        # through gradlew, `cd &&` and `sh`, and every rm, mv or wrapper call naming the cache in
        # either slash direction; ordinary builds with --no-daemon still run. No rule here may
        # contain a backslash: one rule with a backslash makes the CLI ignore the whole settings
        # file, every other deny with it, silently (measured the same day).
        "Bash(*gradlew*--stop*)",
        "Bash(*gradle *--stop*)",
        "Bash(*.gradle*caches*)"
    )

    # Autonomous mode inverts the model (ADR-027): every tool allowed, minus the Deny List shipped in
    # baseline.json's "autonomous" block. The immutable rules above still apply on top, and so do the
    # ledgers' own "deny" arrays below - deny always wins over allow.
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
    }

    # A repository's own "deny" arrays apply in BOTH modes. They are how a repository switches off
    # something the baseline grants everywhere - the Context7 lookup, which sends a library name and a
    # concept to a hosted service, is the first such grant (ADR-032). Deny always wins over allow.
    foreach ($ledger in $ledgers[1..2]) {
        if (Test-Path $ledger) {
            $parsed = Get-Content $ledger -Raw | ConvertFrom-Json
            foreach ($entry in $parsed.entries) {
                foreach ($rule in $entry.deny) { $denyRules += $rule }
            }
        }
    }

    # One rule with a backslash in it makes the CLI ignore the whole settings file - every deny above
    # with it, the Deny List and the protection of DECISIONS.md included - and nothing says so
    # (measured 2026-10-07: a deny on `git log` stopped working the moment a second rule held
    # `\caches`). A Windows path in a ledger is the easy way to write one, so refuse to run instead.
    $backslashed = @(@($allowRules) + @($denyRules) | Where-Object { "$_".Contains('\') })
    if ($backslashed.Count -gt 0) {
        $message = "A permission rule contains a backslash, which would make Claude Code ignore every rule: " + ($backslashed -join ", ") + ". Write paths in capability ledgers with forward slashes."
        Write-Host $message -ForegroundColor Red
        Write-RunLog $message
        Stop-Run 4 "FAILED" $message
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

# ---------- Model tier for the top-level Iteration (ADR-013) ----------
# The tier map exists so the engine can dispatch a Worker at the right model. Nothing ever applied
# it to the Iteration ITSELF: --model was passed only when a human supplied -Model, so the top-level
# session silently ran at whatever the CLI defaults to. Measured on the Calendar-Note alarms run:
# 979 of 1,215 Orchestrator messages ran on the default model while the Workers ran on the expensive
# one - the tier system exactly inverted, and the Verifier (the one role POLICIES.md marks "Always
# Capable, no exception") verified the whole run below Capable. One --model argument closes it.
function Resolve-TierModel([string]$tier) {
    if (-not (Test-Path $ModelsPath)) { return "" }
    try {
        $map = Get-Content $ModelsPath -Raw | ConvertFrom-Json
        if (Test-HasProperty $map $tier) {
            $entry = $map.$tier
            if ((Test-HasProperty $entry "model") -and "$($entry.model)" -ne "") { return [string]$entry.model }
        }
    } catch { Write-Warning "models.json unreadable ($_). Falling back to the CLI default model." }
    return ""
}

# The tier's effort level, or "" for the CLI default. It has to be Foreman's to set: the engine no
# longer reads the operator's own settings (ADR-038), which is where it used to come from.
function Resolve-TierEffort([string]$tier) {
    if (-not (Test-Path $ModelsPath)) { return "" }
    try {
        $map = Get-Content $ModelsPath -Raw | ConvertFrom-Json
        if ((Test-HasProperty $map $tier) -and (Test-HasProperty $map.$tier "effort")) {
            $effort = "$($map.$tier.effort)"
            if ($effort -match '^(low|medium|high|xhigh|max)$') { return $effort }
            if ($effort -ne "") { Write-Warning "models.json: '$effort' is not an effort level. Using the CLI default." }
        }
    } catch { }
    return ""
}

# One --model is fixed for a whole invocation, so the tier has to be chosen BEFORE the engine starts
# - the engine cannot switch its own model at ENGINE.md 11. STATE.md's DONE-candidate is the only
# mechanical signal available in advance that the next invocation verifies rather than builds, and it
# is the same flag ENGINE.md 6.3 branches on, so the two cannot disagree.
function Test-DoneCandidate {
    if (-not (Test-Path $StateFile)) { return $false }
    try {
        foreach ($line in @(Get-Content $StateFile)) {
            # Tolerates the bold/colon shapes STATE.md actually uses: "**DONE-candidate:** yes",
            # "- DONE-candidate: yes". Only space, colon and asterisk may sit between the two words,
            # so "DONE-candidate: no" cannot match.
            if ($line -match '(?i)DONE-candidate[\s:*]*yes') { return $true }
        }
    } catch { }
    return $false
}

# ---------- Per-iteration measurement ----------
# The Runtime already saw every number below and threw all of them away: duration went to the console
# via Write-Host and nowhere else. After the Calendar-Note run finished, nothing on disk could say
# which iteration was slow or what any of them cost, so the first question asked of it - "why did this
# take 13 hours" - had to be answered by parsing a debug log out of %TEMP% that only survived by luck.
$script:IterCost = 0.0
$script:IterTurns = 0
$script:IterCacheRead = 0
function Reset-IterationUsage {
    $script:IterCost = 0.0
    $script:IterTurns = 0
    $script:IterCacheRead = 0
}
function Register-ResultUsage($evt) {
    # An invocation can emit several `result` events and they are CUMULATIVE, not additive - four
    # events carrying $15.26 each mean one $15.26 invocation. Taking the maximum is what stops this
    # row reporting four times the real figure.
    try {
        if (Test-HasProperty $evt "total_cost_usd") {
            $c = [double]$evt.total_cost_usd
            if ($c -gt $script:IterCost) { $script:IterCost = $c }
        }
        if (Test-HasProperty $evt "num_turns") {
            $t = [int]$evt.num_turns
            if ($t -gt $script:IterTurns) { $script:IterTurns = $t }
        }
        if ((Test-HasProperty $evt "usage") -and (Test-HasProperty $evt.usage "cache_read_input_tokens")) {
            $r = [long]$evt.usage.cache_read_input_tokens
            if ($r -gt $script:IterCacheRead) { $script:IterCacheRead = $r }
        }
    } catch { }
}
function Write-Telemetry {
    param([int]$Iteration, [string]$Status, [datetime]$IterStart, [string]$Tier, [string]$Model)
    try {
        if (-not (Test-Path $TelemetryFile)) {
            $header = @("when","iteration","status","seconds","tier","model","turns","cache_read_tokens","cost_usd") -join "`t"
            # -Encoding utf8 writes a BOM on PowerShell 5.1, which lands inside the first column name
            # and breaks any strict TSV reader. The rows are ASCII; write them without one.
            [System.IO.File]::WriteAllLines($TelemetryFile, @($header), (New-Object System.Text.UTF8Encoding($false)))
        }
        $row = @(
            (Get-Date -Format o),
            $Iteration,
            $Status,
            [int]((Get-Date) - $IterStart).TotalSeconds,
            $Tier,
            $Model,
            $script:IterTurns,
            $script:IterCacheRead,
            ("{0:F4}" -f $script:IterCost)
        ) -join "`t"
        [System.IO.File]::AppendAllLines($TelemetryFile, [string[]]@($row), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }   # Measurement must never be able to stop execution.
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
        $beat = "[$(Get-Date -Format 'HH:mm:ss')] waiting for quota reset - {0:00}:{1:00}:{2:00} remaining" -f [int][Math]::Floor($remaining.TotalHours), $remaining.Minutes, $remaining.Seconds
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

# After DONE: remove .harness/run/ only if it is empty - the directory the engine's STATUS.md
# recreated after the Cleanup Commit, now that STATUS.md itself has been read and deleted.
function Remove-EmptyRunDir {
    if (-not (Test-Path $RunDir)) { return }
    if (@(Get-ChildItem -LiteralPath $RunDir -Force).Count -gt 0) { return }
    Remove-Item -LiteralPath $RunDir -Force
}

# ---------- Hung test workers ----------
# One Robolectric test spun for 35 minutes at 100% of a core on a preview that never settled (Kanso's
# Run 3, 2026-10-07). The iteration kept polling the build log, so the idle bound never fired, and the
# operator ended the JVM by hand. This ends a Gradle test worker of THIS repository - its work
# directory sits under the repository and under a test task's build/tmp - once it has run longer than
# -MaxTestWorkerMinutes; the build then fails and names the test. Another project's JVMs never match.
function Stop-HungTestWorkers {
    $root = ($RepoRoot -replace '/', '\').TrimEnd('\') + '\'
    try { $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.CommandLine }) } catch { return }
    foreach ($p in $procs) {
        $cmd = $p.CommandLine
        if ($cmd.IndexOf('-Dorg.gradle.internal.worker.tmpdir=', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($cmd.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($cmd -notmatch '(?i)\\build\\tmp\\[^\\\s]*test[^\\\s]*\\work') { continue }
        $age = (Get-Date) - $p.CreationDate
        if ($age.TotalMinutes -le $MaxTestWorkerMinutes) { continue }
        try { & taskkill /PID $p.ProcessId /T /F 2>$null | Out-Null } catch { }
        $line = "test guard: ended Gradle test worker $($p.ProcessId) of this repository after $([Math]::Floor($age.TotalMinutes)) min - a test never finished"
        Write-Warning $line
        Write-RunLog $line
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
    $script:LastResultAt = $null
    $lastWorkerCheck = Get-Date
    $workerCheckSeconds = [Math]::Max(1, [Math]::Min(30, $MaxTestWorkerMinutes * 30))
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

            if (((Get-Date) - $lastWorkerCheck).TotalSeconds -ge $workerCheckSeconds) {
                $lastWorkerCheck = Get-Date
                Stop-HungTestWorkers
            }

            if (((Get-Date) - $lastEventAt) -gt $idleLimit) {
                $timeoutKind = "idle"
                Write-Warning ("No engine event for {0} minutes - treating as a hung invocation." -f $MaxIdleMinutes)
                break
            }
            # The engine has answered, but its process will not end. Kanso's Run 3, 2026-10-07: the result
            # came at 16:04:46 while a background shell it had started sat on a malformed heredoc, and the
            # Runtime would have waited for the 20-minute idle bound. The status file is already written,
            # so ending the leftover process loses nothing; a missing status is still a crash below.
            if ($null -ne $script:LastResultAt -and -not $proc.HasExited -and ((Get-Date) - $lastEventAt).TotalSeconds -gt $ResultGraceSeconds) {
                $timeoutKind = "after-result"
                Write-Warning ("The engine reported its result but its process did not end within {0} s - ending it." -f $ResultGraceSeconds)
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
    # Same reasoning as quota: a measurement is not output, so -QuietEngine must not suppress it.
    if ($evt.type -eq "result") { Register-ResultUsage $evt; $script:LastResultAt = Get-Date }
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
    # [int] ROUNDS. [int]3.95 is 4, so 3h57m rendered as "04:57" and the hours field jumped back and
    # forth as the minutes crossed 30. Floor, always.
    return "{0:00}:{1:00}:{2:00}" -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
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
    # *emphasis*, which may hold a code span, but never inside one: `Bash(*DebugAndroidTest*)` is a
    # rule, not italics. A span whose code holds an asterisk is left as written.
    $html = [regex]::Replace($html, '(<code>.*?</code>)|(?<![\w*])\*(?![\s*])([^*]+?)(?<!\s)\*(?![\w*])', [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        if ($m.Groups[1].Success) { return $m.Value }
        return '<em>' + $m.Groups[2].Value + '</em>'
    })
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
            # A task-list box reads as a box: unticked waits on someone, ticked is signed.
            $li = (ConvertTo-InlineHtml $item) -replace '^\[ \]\s*', '<span class="box">&#9744;</span> ' -replace '^\[[xX]\]\s*', '<span class="box done">&#9745;</span> '
            $out.Add("<li>" + $li + "</li>")
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

# ---------- Definition of Done, as the page shows it ----------
# The Definition of Done tab of FOREMAN.html: the DoD a person is asked to approve, numbered and grouped
# exactly as DoD.md writes it, followed by every earlier DoD the repository's git history still holds,
# newest first. DoD.md stays the source; this is only a rendering of it.
$DodGitPath = ".harness/run/DoD.md"
$script:DodAwaiting = $false

# git prints through the console's code page, which is not UTF-8 on Windows: a DoD quoting a
# Vietnamese PRD came back as mojibake. Read git's output as UTF-8 for the length of one call.
function Invoke-GitUtf8([string[]]$gitArgs) {
    $saved = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
        $lines = & git @gitArgs 2>$null
        $script:GitExit = $LASTEXITCODE
        return , @($lines)
    } finally { try { [Console]::OutputEncoding = $saved } catch {} }
}

# A label the page's chrome translates in the browser (the dictionary is in FOREMAN.template.html). Text
# the dictionary does not know - an engine-chosen heading - stays as the engine wrote it.
function ConvertTo-DodLabel([string]$text) {
    $plain = $text.Trim()
    return '<span class="t" data-en="' + (ConvertTo-HtmlText $plain) + '">' + (ConvertTo-InlineHtml $plain) + '</span>'
}

# DoD.md to HTML. Criteria keep the numbers DoD.md gives them - an <ol> would renumber every list from 1
# under each category heading - and carry their Verification Class as a chip. Everything that is not a
# heading or a criterion goes through ConvertFrom-LedgerMarkdown unchanged.
function ConvertFrom-DodMarkdown([string]$markdown) {
    if (-not $markdown) { return '<p class="empty">(nothing recorded)</p>' }
    $markdown = [regex]::Replace($markdown, '(?s)<!--.*?-->', '')
    $out = New-Object System.Collections.Generic.List[string]
    $other = New-Object System.Collections.Generic.List[string]
    $st = @{ Crit = $null; InList = $false; Fence = $false }
    $flushOther = {
        if (($other -join '').Trim()) { $out.Add((ConvertFrom-LedgerMarkdown ($other -join "`n"))) }
        $other.Clear()
    }
    $closeCrit = {
        if ($null -ne $st.Crit) {
            $text = ($st.Crit.Lines -join ' ').Trim()
            $chip = ''
            if ($text -match '^\[(machine-then-human|human-only|machine|human)\]\s*(.*)$') {
                $chip = '<span class="cls ' + $Matches[1] + '">' + $Matches[1] + '</span>'
                $text = $Matches[2]
            }
            # The sentence is the person's; the Proof is the engine's, folded away under it (ADR-035).
            $proof = ''
            if ($st.Crit.Proof.Count -gt 0) {
                $proof = '<details class="proof"><summary>' + (ConvertTo-DodLabel "How the engine checks it") + '</summary><div>' + (ConvertTo-InlineHtml (($st.Crit.Proof -join ' ').Trim())) + '</div></details>'
            }
            $out.Add('<li class="crit"><span class="num">' + (ConvertTo-HtmlText $st.Crit.Num) + '</span><div class="txt">' + $chip + (ConvertTo-InlineHtml $text) + $proof + '</div></li>')
            $st.Crit = $null
        }
    }
    $closeList = { & $closeCrit; if ($st.InList) { $out.Add('</ol>'); $st.InList = $false } }

    foreach ($raw in ($markdown -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*```') { & $closeList; $other.Add($raw); $st.Fence = -not $st.Fence; continue }
        if ($st.Fence) { $other.Add($raw); continue }
        if ($line -match '^(#{1,6})\s+(.*)$') {
            & $closeList; & $flushOther
            # The title is the card's own heading; ## is a section, ### and below a category.
            if ($Matches[1].Length -eq 1) { continue }
            $tag = if ($Matches[1].Length -eq 2) { "h3" } else { "h4" }
            $out.Add("<$tag>" + (ConvertTo-DodLabel $Matches[2]) + "</$tag>")
            continue
        }
        # A criterion opens a line, numbered. Some DoDs already split it the same way as a Proof line
        # does, with the sentence in bold - `**1. [machine] It compiles.** gradlew ...` (Calendar-Note's
        # Alarms DoD, 2026-09-13) - so the bold part is the sentence and the rest is the Proof.
        if ($line -match '^\s*\*\*(R?\d+)\.\s+(.+?)\*\*\s*(.*)$' -or $line -match '^\s*(R?\d+)\.\s+(.*)$') {
            $num = $Matches[1]; $sentence = $Matches[2]; $rest = if ($Matches.Count -gt 3) { $Matches[3] } else { "" }
            & $flushOther; & $closeCrit
            if (-not $st.InList) { $out.Add('<ol class="crits">'); $st.InList = $true }
            $st.Crit = @{ Num = $num; Lines = New-Object System.Collections.Generic.List[string]; Proof = New-Object System.Collections.Generic.List[string]; InProof = $false }
            $st.Crit.Lines.Add($sentence)
            if ($line -match '^\s*\*\*') { $st.Crit.InProof = $true; if ($rest) { $st.Crit.Proof.Add($rest) } }
            continue
        }
        # An indented line continues the criterion above it - DoDs wrap long criteria that way. An
        # indented `Proof:` line starts the engine's half, and everything indented after it belongs there.
        if ($null -ne $st.Crit -and $line -match '^\s+(\*\*)?Proof:(\*\*)?\s*(.*)$') {
            $st.Crit.InProof = $true; $st.Crit.Proof.Add($Matches[3]); continue
        }
        if ($null -ne $st.Crit -and $line -match '^\s+\S') {
            if ($st.Crit.InProof) { $st.Crit.Proof.Add($line.Trim()) } else { $st.Crit.Lines.Add($line.Trim()) }
            continue
        }
        if ($line -eq '') {
            if ($null -ne $st.Crit -or $st.InList) { & $closeCrit } else { $other.Add('') }
            continue
        }
        & $closeList
        $other.Add($raw)
    }
    & $closeList; & $flushOther
    return ($out -join "`n")
}

# Every DoD this repository's history holds, one entry per run. A run's DoD is born in the commit that
# adds .harness/run/DoD.md (its bootstrap) and ends in the one that deletes it (its Cleanup Commit, or a
# new goal clearing the old run); each commit in between belongs to the most recent birth in its own
# ancestry. Newest first.
function Get-DodHistory {
    $log = Invoke-GitUtf8 @("log", "--all", "--format=@@%H%x09%cI%x09%s", "--name-status", "--", $DodGitPath)
    if ($script:GitExit -ne 0) { return , @() }
    $commits = New-Object System.Collections.Generic.List[object]
    $last = $null
    foreach ($l in $log) {
        if ("$l" -match '^@@([0-9a-f]{40})\t([^\t]+)\t(.*)$') {
            $last = [pscustomobject]@{ Sha = $Matches[1]; Date = [DateTimeOffset]::Parse($Matches[2]); Subject = $Matches[3]; Status = "" }
            $commits.Add($last)
        } elseif ($null -ne $last -and "$l" -match '^([AMD])\t') { $last.Status = $Matches[1] }
    }
    $byBirth = @{}
    foreach ($c in $commits) {
        $birth = $c.Sha
        if ($c.Status -ne "A") {
            $birth = ("" + (& git log -1 --diff-filter=A --format=%H $c.Sha -- $DodGitPath 2>$null)).Trim()
        }
        if (-not $birth) { continue }
        if (-not $byBirth.ContainsKey($birth)) { $byBirth[$birth] = New-Object System.Collections.Generic.List[object] }
        $byBirth[$birth].Add($c)
    }
    $runs = @()
    foreach ($birth in $byBirth.Keys) {
        $members = @($byBirth[$birth] | Sort-Object { $_.Date })
        $born = @($members | Where-Object { $_.Sha -eq $birth }) | Select-Object -First 1
        if ($null -eq $born) { $born = $members[0] }
        $latest = @($members | Where-Object { $_.Status -ne "D" }) | Select-Object -Last 1
        if ($null -eq $latest) { continue }
        $closed = @($members | Where-Object { $_.Status -eq "D" }) | Select-Object -Last 1
        $runs += [pscustomobject]@{ Birth = $birth; Born = $born.Date; Subject = $born.Subject; Latest = $latest.Sha; Closed = $closed }
    }
    return , @($runs | Sort-Object { $_.Born } -Descending)
}

function Get-DodBranchName([string]$sha) {
    $name = ("" + (& git name-rev --name-only "--refs=refs/heads/loop/*" "--refs=refs/remotes/*/loop/*" $sha 2>$null)).Trim()
    if (-not $name -or $name -eq "undefined") { $name = ("" + (& git name-rev --name-only $sha 2>$null)).Trim() }
    if ($name -eq "undefined") { return "" }
    # A branch shows as the remote sees it (origin/loop/x, upstream/loop/x); the page wants loop/x.
    return (($name -replace '[~^].*$', '') -replace '^remotes/', '' -replace '^[^/]+/(?=loop/)', '')
}

function ConvertTo-DodCard($dod, [int]$index) {
    $md = [regex]::Replace($dod.Markdown, '(?s)<!--.*?-->', '')
    $title = $dod.Subject -replace '^loop\([^)]*\):\s*', ''
    $h1 = [regex]::Match($md, '(?m)^#\s+Definition of Done\s*[-:\u2013\u2014]+\s*(.+?)\s*$')
    if ($h1.Success) { $title = $h1.Groups[1].Value }

    $approved = $md -match '(?mi)^\s*-\s*\[x\]\s*APPROVED'
    $awaiting = $false
    # The engine usually ticks the box when it consumes the approval, but not always: the human's own
    # answer in DECISIONS.md is the approval, so a current run counts as approved once that answer exists.
    if (-not $approved -and $dod.Current) {
        $id = "D-001"
        $status = [regex]::Match($md, '(?mi)^\s*-\s*\[ \]\s*APPROVED.*?\b(D-\d{3})\b')
        if ($status.Success) { $id = $status.Groups[1].Value }
        if ((Get-AnsweredDecisionIds).ContainsKey($id)) { $approved = $true } else { $awaiting = $true }
    }

    $badges = @()
    if ($dod.Current) { $badges += '<span class="badge current">' + (ConvertTo-DodLabel "Current run") + '</span>' }
    if ($approved) { $badges += '<span class="badge approved">' + (ConvertTo-DodLabel "Approved") + '</span>' }
    if ($awaiting) { $badges += '<span class="badge awaiting">' + (ConvertTo-DodLabel "Awaiting your approval") + '</span>' }
    if ($null -ne $dod.Closed) { $badges += '<span class="badge closed">' + (ConvertTo-DodLabel "Closed") + '</span>' }
    elseif (-not $dod.Current) { $badges += '<span class="badge open">' + (ConvertTo-DodLabel "Left open") + '</span>' }

    $criteria = [regex]::Matches($md, '(?m)^\s*(\*\*)?\d+\.\s+\S').Count
    $removals = [regex]::Matches($md, '(?m)^\s*(\*\*)?R\d+\.\s+\S').Count
    $byCommand = [regex]::Matches($md, '(?m)^\s*(\*\*)?R?\d+\.\s+\[machine\]').Count
    $byPerson = [regex]::Matches($md, '(?m)^\s*(\*\*)?R?\d+\.\s+\[(human|human-only|machine-then-human)\]').Count
    $tally = '<p class="tally">' +
        '<span><b>' + $criteria + '</b>' + (ConvertTo-DodLabel "criteria") + '</span>' +
        '<span><b>' + $removals + '</b>' + (ConvertTo-DodLabel "removals") + '</span>' +
        '<span><b>' + $byCommand + '</b>' + (ConvertTo-DodLabel "proved by a command") + '</span>' +
        '<span><b>' + $byPerson + '</b>' + (ConvertTo-DodLabel "need a person") + '</span></p>'
    $closing = ""
    if ($null -ne $dod.Closed) {
        $closing = '<p class="closing">' + (ConvertTo-DodLabel "Closed by") + ' <code>' + (ConvertTo-HtmlText $dod.Closed.Sha.Substring(0, 7)) + '</code> ' + (ConvertTo-HtmlText $dod.Closed.Subject) + '</p>'
    }
    $meta = '<span>' + (ConvertTo-HtmlText $dod.When) + '</span>'
    if ($dod.Branch) { $meta += '<span class="branch">' + (ConvertTo-HtmlText $dod.Branch) + '</span>' }
    $open = if ($index -eq 0) { " open" } else { "" }
    $current = if ($dod.Current) { " current" } else { "" }
    # Each piece in its own parentheses: in PowerShell the comma binds tighter than +, so a bare
    # 'a' + $b inside a list splits into separate elements.
    return @(
        ("<article class=`"dod$current`" id=`"dod-$($index + 1)`"><details$open><summary>"),
        ("<p class=`"meta`">$meta</p>"),
        ('<span class="dod-title">' + (ConvertTo-InlineHtml $title) + '</span>'),
        ('<p class="badges">' + ($badges -join ' ') + '</p>'),
        $tally, $closing,
        "</summary>",
        ('<div class="md">' + (ConvertFrom-DodMarkdown $md) + '</div>'),
        "</details></article>"
    ) -join "`n"
}

# Every Definition of Done as page cards: the current run's first, read from disk so a person's edits
# before approving show up, then every earlier one from git, newest first. Sets $script:DodAwaiting
# when the current run's DoD has not been approved yet.
function Get-DodCards {
    $script:DodAwaiting = $false
    $history = Get-DodHistory
    $dods = @()
    $onDisk = Join-Path $RepoRoot $DodGitPath
    $currentBirth = ""
    if (Test-Path $onDisk) {
        # The run in this working tree: its birth is the newest add in HEAD's history, unless the file
        # was deleted after that add - then what is on disk is a DoD no commit holds yet.
        $lastTouch = Invoke-GitUtf8 @("log", "-1", "--format=%H%x09%cI", "--name-status", "HEAD", "--", $DodGitPath)
        $deletedSince = ($lastTouch | Where-Object { "$_" -match '^D\t' }).Count -gt 0
        if (-not $deletedSince) {
            $currentBirth = ("" + (& git log -1 --diff-filter=A --format=%H HEAD -- $DodGitPath 2>$null)).Trim()
        }
        $born = @($history | Where-Object { $_.Birth -eq $currentBirth }) | Select-Object -First 1
        $dods += [pscustomobject]@{
            Current = $true; Markdown = (Get-Content $onDisk -Raw -Encoding UTF8)
            Subject = if ($born) { $born.Subject } else { "" }
            When = if ($born) { $born.Born.ToString("yyyy-MM-dd") } else { (Get-Date -Format "yyyy-MM-dd") }
            Branch = ("" + (& git rev-parse --abbrev-ref HEAD 2>$null)).Trim(); Closed = $null
        }
    }
    foreach ($run in $history) {
        if ($run.Birth -eq $currentBirth) { continue }
        $text = (Invoke-GitUtf8 @("show", "$($run.Latest):$DodGitPath")) -join "`n"
        if ($script:GitExit -ne 0) { continue }
        $dods += [pscustomobject]@{
            Current = $false; Markdown = $text; Subject = $run.Subject
            When = $run.Born.ToString("yyyy-MM-dd"); Branch = (Get-DodBranchName $run.Latest); Closed = $run.Closed
        }
    }
    $cards = @()
    for ($i = 0; $i -lt $dods.Count; $i++) { $cards += ConvertTo-DodCard $dods[$i] $i }
    if ($dods.Count -gt 0) { $script:DodAwaiting = ($dods[0].Current -and ($cards[0] -match 'badge awaiting')) }
    return , @($cards)
}

# The ids the human has actually answered in DECISIONS.md. A heading alone is not an answer: the file
# is provisioned with an empty "## D-001" over a placeholder comment, and counting that heading made
# FOREMAN.html show nothing waiting and the DoD "Approved" at Kanso's first gate (2026-10-05) while
# D-001 was still pending. ENGINE.md 6.2 reads the file the same way: an empty body is not a decision.
function Get-AnsweredDecisionIds {
    $answered = @{}
    $decisions = Join-Path $RunDir "DECISIONS.md"
    if (-not (Test-Path $decisions)) { return $answered }
    $text = [regex]::Replace((Get-Content $decisions -Raw -Encoding UTF8), '(?s)<!--.*?-->', '')
    $headings = [regex]::Matches($text, '(?m)^(#{1,6})[ \t]+(.*?)[ \t]*\r?$')
    for ($i = 0; $i -lt $headings.Count; $i++) {
        if ($headings[$i].Groups[2].Value -notmatch '^(D-\d{3})(?![0-9])') { continue }
        $id = $Matches[1]
        # The answer runs to the next heading at its own level or above, so a sub-heading inside an
        # answer stays part of it.
        $level = $headings[$i].Groups[1].Value.Length
        $start = $headings[$i].Index + $headings[$i].Length
        $end = $text.Length
        for ($j = $i + 1; $j -lt $headings.Count; $j++) {
            if ($headings[$j].Groups[1].Value.Length -le $level) { $end = $headings[$j].Index; break }
        }
        $body = $text.Substring($start, $end - $start) -replace '(?m)^\s*-{3,}\s*$', ''
        if ($body.Trim()) { $answered[$id] = $true }
    }
    return $answered
}

# The Decision Queue entries still waiting: in ESCALATION.md, not marked answered or archived, and with
# no answer of their own in DECISIONS.md yet - the same test the /foreman skill applies.
function Get-PendingDecisions {
    $escalation = Join-Path $RunDir "ESCALATION.md"
    if (-not (Test-Path $escalation)) { return , @() }
    $text = [regex]::Replace((Get-Content $escalation -Raw -Encoding UTF8), '(?s)<!--.*?-->', '')
    $answered = Get-AnsweredDecisionIds
    $headings = [regex]::Matches($text, '(?m)^(#{1,6})[ \t]+(.*)$')
    $pending = @()
    for ($i = 0; $i -lt $headings.Count; $i++) {
        $h = $headings[$i]
        if ($h.Groups[2].Value -notmatch '^(D-\d{3})(?![0-9])') { continue }
        $id = $Matches[1]
        # An entry runs to the next heading at its own level or above, so its sub-headings stay in it.
        $level = $h.Groups[1].Value.Length
        $end = $text.Length
        for ($j = $i + 1; $j -lt $headings.Count; $j++) {
            if ($headings[$j].Groups[1].Value.Length -le $level) { $end = $headings[$j].Index; break }
        }
        $entry = $text.Substring($h.Index, $end - $h.Index)
        if ($entry -match '(?mi)^\s*-\s*\*\*Status:\*\*\s*(answered|archived)\b') { continue }
        if ($answered.ContainsKey($id)) { continue }
        $pending += [pscustomobject]@{ Id = $id; Markdown = ($entry -replace '(?m)^\s*-{3,}\s*$', '') }
    }
    return , @($pending)
}

# ISSUES.md's "Awaiting a person": the checklist an Autonomous run reports instead of queueing
# (ENGINE.md 14.2). $null when the section is missing or holds only its empty table header.
function Get-AwaitingPerson {
    $issues = [regex]::Replace((Read-RunArtifact ".harness/ISSUES.md"), '(?s)<!--.*?-->', '')
    # Every section whose heading starts "Awaiting a person", at any level. Engines wrote
    # "## Awaiting a person (unsigned)" (Kanso Run 1) and "### Awaiting a person, Run 3"; the old exact
    # match on "## Awaiting a person" counted neither, so the page said nothing was waiting while 17
    # checks were. A section runs to the next heading at its own level or above; one nested inside a
    # section already taken is part of it, not counted twice. \r? because the files are CRLF.
    $headings = [regex]::Matches($issues, '(?m)^(#{2,6})[ \t]+(.*?)[ \t]*\r?$')
    $parts = @(); $takenUntil = -1
    for ($i = 0; $i -lt $headings.Count; $i++) {
        $h = $headings[$i]
        if ($h.Index -lt $takenUntil -or $h.Groups[2].Value -notmatch '^(?i)Awaiting a person') { continue }
        $level = $h.Groups[1].Value.Length
        $end = $issues.Length
        for ($j = $i + 1; $j -lt $headings.Count; $j++) {
            if ($headings[$j].Groups[1].Value.Length -le $level) { $end = $headings[$j].Index; break }
        }
        $start = $h.Index + $h.Length
        $parts += $issues.Substring($start, $end - $start)
        $takenUntil = $end
    }
    if ($parts.Count -eq 0) { return $null }
    $body = $parts -join "`n"
    $lines = @($body -split "`r?`n")
    $rows = @($lines | Where-Object { $_ -match '^\s*\|' -and $_ -notmatch '^\s*\|[\s:|-]+\|\s*$' })
    # A ticked box is signed, so it is not waiting; an unticked box or a plain item is.
    $items = @($lines | Where-Object { $_ -match '^\s*([-*]|\d+\.)\s+\S' -and $_ -notmatch '^\s*[-*]\s+\[[xX]\]' })
    $count = [Math]::Max(0, $rows.Count - 1) + $items.Count
    if ($count -eq 0) { return $null }
    return [pscustomobject]@{ Markdown = $body; Count = $count }
}

# ---------- The Foreman page (ADR-034) ----------
# FOREMAN.html at the repository root is the one page a person reads: what is waiting on them, every
# Definition of Done, this run's ledgers and the Suggestion Box, as four tabs. The engine writes
# Markdown only; this renders all of it after every iteration and on every exit, so the page cannot go
# stale. It replaced three pages, and the one the engine had to keep current - SUGGESTIONS.html's
# Escalate tab - was the one that went stale: on the Calendar-Note alarms run it was never refreshed
# once, and the human waited about 46 minutes across two decisions nobody knew were queued.
# Excluded through .git/info/exclude, so it is never committed and never crash debris.
$ForemanPage = Join-Path $RepoRoot "FOREMAN.html"

function Write-ForemanPage([string]$Outcome = "", [string]$Reason = "") {
    $template = Join-Path $LoopDir "templates/FOREMAN.template.html"
    if (-not (Test-Path $template)) { Write-RunLog "foreman page: no template at $template"; return $null }

    # What is waiting on the human.
    $pending = Get-PendingDecisions
    $awaiting = Get-AwaitingPerson
    $needs = @()
    if ($pending.Count -gt 0) {
        $needs += '<h2>' + (ConvertTo-DodLabel "Decisions waiting for an answer") + '<span class="n">' + $pending.Count + '</span></h2>'
        foreach ($p in $pending) { $needs += '<div class="card pending" id="' + $p.Id + '"><div class="md">' + (ConvertFrom-LedgerMarkdown $p.Markdown) + '</div></div>' }
    }
    if ($null -ne $awaiting) {
        $needs += '<h2>' + (ConvertTo-DodLabel "Checks waiting for a person") + '<span class="n">' + $awaiting.Count + '</span></h2>'
        $needs += '<div class="card pending"><div class="md">' + (ConvertFrom-LedgerMarkdown $awaiting.Markdown) + '</div></div>'
    }
    $nNeeds = $pending.Count + $(if ($null -ne $awaiting) { $awaiting.Count } else { 0 })
    if ($nNeeds -eq 0) { $needs += '<p class="calm">' + (ConvertTo-DodLabel "Nothing is waiting on you.") + '</p>' }

    $cards = Get-DodCards
    $dodSection = if ($cards.Count -gt 0) { $cards -join "`n" } else { '<p class="empty">(nothing recorded)</p>' }

    $assumptions = Read-RunArtifact ".harness/run/ASSUMPTIONS.md"
    $recovery = Read-RunArtifact ".harness/run/RECOVERY.md"
    $suggestions = Read-RunArtifact ".harness/SUGGESTIONS.md"
    $nSuggestions = ([regex]::Matches([regex]::Replace($suggestions, '(?s)<!--.*?-->', ''), '(?m)^##\s+S-\d+')).Count
    # A SUGGESTIONS.html from before this page is the engine's committed file, not the Runtime's to
    # delete: link it, so what it holds is not lost from view.
    $legacy = ""
    if (Test-Path (Join-Path $RepoRoot "SUGGESTIONS.html")) {
        $legacy = '<p class="note">' + (ConvertTo-DodLabel "Earlier suggestions, written before this page existed:") + ' <a href="SUGGESTIONS.html">SUGGESTIONS.html</a></p>'
    }

    if (-not $Outcome) {
        $last = Read-ExecutionStatus
        if ($null -ne $last) { $Outcome = $last.Word; if (-not $Reason) { $Reason = $last.Reason } } else { $Outcome = "RUNNING" }
    }
    $outcomeClass = switch ($Outcome) { "DONE" { "ok" } "DONE_PARTIAL" { "partial" } "ESCALATE" { "partial" } "RUNNING" { "running" } "CONTINUE" { "running" } default { "bad" } }
    $outcomeHtml = if ($Outcome -eq "RUNNING") { ConvertTo-DodLabel "RUNNING" } else { ConvertTo-HtmlText $Outcome }
    $defaultTab = if ($nNeeds -gt 0) { "needs" } elseif ($Outcome -ne "RUNNING" -and $Outcome -ne "CONTINUE") { "run" } elseif ($cards.Count -gt 0) { "dod" } else { "run" }
    $branch = & git rev-parse --abbrev-ref HEAD 2>$null

    $values = [ordered]@{
        "{{REPO}}"                = ConvertTo-HtmlText (Split-Path $RepoRoot -Leaf)
        "{{MODE}}"                = ConvertTo-HtmlText $script:RunMode
        "{{MODE_CLASS}}"          = $script:RunMode.ToLowerInvariant()
        "{{BRANCH}}"              = ConvertTo-HtmlText ("" + $branch).Trim()
        "{{GENERATED}}"           = Get-Date -Format "yyyy-MM-dd HH:mm"
        "{{DEFAULT_TAB}}"         = $defaultTab
        "{{N_NEEDS}}"             = "" + $nNeeds
        "{{NEEDS_HOT}}"           = $(if ($nNeeds -gt 0) { "hot" } else { "" })
        "{{SECTION_NEEDS}}"       = ($needs -join "`n")
        "{{N_DODS}}"              = "" + $cards.Count
        "{{SECTION_DODS}}"        = $dodSection
        "{{OUTCOME}}"             = $outcomeHtml
        "{{OUTCOME_CLASS}}"       = $outcomeClass
        "{{REASON}}"              = ConvertTo-InlineHtml $Reason
        "{{ITERATIONS}}"          = "" + (Get-PriorIterationCount)
        "{{ELAPSED}}"             = Format-Elapsed $RunStart
        "{{N_ASSUMPTIONS}}"       = "" + ([regex]::Matches($assumptions, '(?m)^## A-\d+')).Count
        "{{N_RECOVERY}}"          = "" + ([regex]::Matches($recovery, '(?m)^## R-\d+')).Count
        "{{SECTION_ISSUES}}"      = ConvertFrom-LedgerMarkdown (Read-RunArtifact ".harness/ISSUES.md")
        "{{SECTION_ASSUMPTIONS}}" = ConvertFrom-LedgerMarkdown $assumptions
        "{{SECTION_RECOVERY}}"    = ConvertFrom-LedgerMarkdown $recovery
        "{{SECTION_STATE}}"       = ConvertFrom-LedgerMarkdown (Read-RunArtifact ".harness/run/STATE.md")
        "{{N_SUGGESTIONS}}"       = "" + $nSuggestions
        "{{SECTION_SUGGESTIONS}}" = ConvertFrom-LedgerMarkdown $suggestions
        "{{LEGACY_SUGGESTIONS}}"  = $legacy
    }
    $html = Get-Content $template -Raw -Encoding UTF8
    foreach ($key in $values.Keys) { $html = $html.Replace($key, $values[$key]) }
    [System.IO.File]::WriteAllText($ForemanPage, $html, (New-Object System.Text.UTF8Encoding($false)))
    Add-GitExclude "/FOREMAN.html"
    # The pages this one replaced were the Runtime's own, excluded from git: remove them so a person
    # never reads a stale one beside the live one.
    foreach ($old in @("RUN-REPORT.html", "DOD.html")) {
        $oldPath = Join-Path $RepoRoot $old
        if (Test-Path $oldPath) { Remove-Item $oldPath -Force -ErrorAction SilentlyContinue; Write-RunLog "foreman page: removed the superseded $old" }
    }
    Write-RunLog "foreman page: $ForemanPage (waiting on the human: $nNeeds, DoD: $($cards.Count), DoD awaiting approval: $($script:DodAwaiting))"
    return $ForemanPage
}

# Opens the page for the human. -NoOpenEscalation suppresses the browser, never the rendering: a
# headless box still gets the page.
function Open-ForemanPage([string]$pagePath, [string]$why) {
    if (-not $pagePath) { return }
    if ($NoOpenEscalation) {
        Write-Host "Foreman page: $pagePath (not opening; -NoOpenEscalation)" -ForegroundColor Magenta
        Write-RunLog "foreman page (not opened): $pagePath - $why"
        return
    }
    Write-Host "Opening FOREMAN.html - $why" -ForegroundColor Magenta
    Write-RunLog "opened for the human: $pagePath - $why"
    # Fail-silent: no browser, no display, a locked-down desktop - none of that is a reason to fail a
    # run whose engineering work already succeeded.
    try { Start-Process $pagePath | Out-Null } catch { Write-Warning "Could not open $pagePath automatically: $_" }
}

# -Page: render FOREMAN.html, open it, and stop. No engine, no lock, no change to the Run Mode - safe
# to run beside a live loop.
if ($Page) {
    $rendered = Write-ForemanPage
    if (-not $rendered) { Write-Host "No page template in .harness/loop/templates - reinstall the runtime (/foreman re-syncs it)." -ForegroundColor Yellow; exit 1 }
    Write-Host "Foreman page: $rendered" -ForegroundColor Cyan
    if (-not $NoOpenEscalation) { try { Start-Process $rendered | Out-Null } catch { Write-Warning "Could not open $rendered automatically: $_" } }
    exit 0
}

# ---------- Baseline guard (ADR-036) ----------
# Approved screenshot baselines are the exam a UI is graded against, and the engine never moves one.
# The record routes are denied above, but a baseline can still change another way: with
# roborazzi.test.record=true in gradle.properties the ordinary test task re-records every image.
# Measured on Foreman-Proving-Ground, 2026-10-05: a contrast defect was recorded as the new truth and
# verifyRoborazziDebug then passed with the defect in place. So the Runtime checks the files
# themselves after every iteration, whatever changed them. New baselines are free; an existing one
# may change only when the human lists it under "## Baselines" in DECISIONS.md.
$BaselinePathspec = ':(glob)**/src/test/screenshots/**'
$script:BaselineSnapshot = $null

function Get-BaselineSnapshot {
    $snapshot = @{}
    # A git that could not answer is not an empty directory. Kanso's Run 3, 2026-10-07: as the
    # machine shut the run down, git failed and the guard logged all 16 baselines as removed while
    # every one was still on disk. And a git that prints an error kills the whole Runtime here,
    # because Windows PowerShell 5.1 turns a native command's stderr into a terminating error under
    # ErrorActionPreference Stop. $null means "unknown"; the guard compares nothing this time.
    try { $files = & git ls-files -c -o --exclude-standard -- $BaselinePathspec 2>$null } catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($rel in @($files)) {
        if (-not $rel) { continue }
        $full = Join-Path $RepoRoot $rel
        if (Test-Path -LiteralPath $full -PathType Leaf) { $snapshot[$rel] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
    }
    return $snapshot
}

function Get-ApprovedBaselines {
    $decisions = Join-Path $RunDir "DECISIONS.md"
    if (-not (Test-Path $decisions)) { return , @() }
    $text = [regex]::Replace((Get-Content $decisions -Raw -Encoding UTF8), '(?s)<!--.*?-->', '')
    $section = [regex]::Match($text, '(?ms)^##[ \t]+Baselines[ \t]*\r?$(.*?)(?=^##[ \t]|\z)')
    if (-not $section.Success) { return , @() }
    $paths = @()
    foreach ($line in ($section.Groups[1].Value -split "`r?`n")) {
        if ($line -match '^\s*[-*]\s+`?([^`\s]+)`?') { $paths += ($Matches[1] -replace '\\', '/').TrimStart('./') }
    }
    return , $paths
}

function Assert-BaselinesUnmoved {
    $now = Get-BaselineSnapshot
    if ($null -eq $now) { Write-RunLog "baseline guard: git could not list the baselines; nothing compared this time"; return }
    if ($null -eq $script:BaselineSnapshot) { $script:BaselineSnapshot = $now; return }
    $approved = Get-ApprovedBaselines
    $moved = @(); $gone = @()
    foreach ($rel in @($script:BaselineSnapshot.Keys)) {
        if (-not $now.ContainsKey($rel)) { $gone += $rel; continue }
        if ($now[$rel] -ne $script:BaselineSnapshot[$rel] -and ($approved -notcontains $rel)) { $moved += $rel }
    }
    if ($gone.Count -gt 0) { Write-RunLog "baseline guard: removed (not stopped): $($gone -join ', ')" }
    if ($moved.Count -gt 0) {
        $list = $moved -join ', '
        Write-Host "An approved baseline image changed without the human's approval: $list" -ForegroundColor Red
        Write-RunLog "baseline guard: changed without approval: $list"
        Stop-Run 4 "FAILED" ("An approved screenshot baseline changed without the human's approval: $list. " +
            "Re-recording a baseline is the human's decision (ADR-036): put it back with git checkout, or list it " +
            "under '## Baselines' in .harness/run/DECISIONS.md to approve the new version.")
    }
    $script:BaselineSnapshot = $now
}

# ---------- Checklist guard ----------
# An unsigned item in .harness/ISSUES.md is a claim of "done" that nobody has checked yet, and it
# leaves only by being ticked. Kanso's Run 2 (0670172) regenerated the Issues Report from its own run
# and dropped five items Run 1 had left unsigned; nothing noticed until a person went looking. The
# count is what is compared, not the wording: open items may only go down by as many as get ticked.
$script:ChecklistSnapshot = $null

# The id an item opens with - "Run 1 12", "5", "Run 3 7" - or $null when it has none. Identity is what
# lets the guard see an item swapped for another: counting alone passes a swap.
function Get-ChecklistKey([string]$item) {
    $t = $item -replace '^[\s*_]+', ''
    if ($t -match '^((?:Run\s+\d+\s+)?\d+)(?=[\s:.)-]|$)') { return ($Matches[1] -replace '\s+', ' ') }
    return $null
}

function Get-ChecklistSnapshot {
    $path = Join-Path $RepoRoot ".harness/ISSUES.md"
    $open = @(); $done = 0; $openKeys = @(); $doneKeys = @()
    if (Test-Path $path) {
        $text = [regex]::Replace((Get-Content $path -Raw -Encoding UTF8), '(?s)<!--.*?-->', '')
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '^\s*[-*]\s+\[ \]\s*(.*)$') {
                $open += $Matches[1].Trim()
                $key = Get-ChecklistKey $open[-1]; if ($key) { $openKeys += $key }
            } elseif ($line -match '^\s*[-*]\s+\[[xX]\]\s*(.*)$') {
                $done++
                $key = Get-ChecklistKey $Matches[1].Trim(); if ($key) { $doneKeys += $key }
            }
        }
    }
    return [pscustomobject]@{ Open = $open; Done = $done; OpenKeys = $openKeys; DoneKeys = $doneKeys }
}

function Assert-ChecklistKept {
    $now = Get-ChecklistSnapshot
    if ($null -ne $script:ChecklistSnapshot) {
        $before = $script:ChecklistSnapshot
        $lost = ($before.Open.Count - $now.Open.Count) - ($now.Done - $before.Done)
        # An item with an id must still be there, open or ticked, whatever the counts say.
        $missing = @($before.OpenKeys | Where-Object { $now.OpenKeys -notcontains $_ -and $now.DoneKeys -notcontains $_ })
        if ($missing.Count -gt $lost) { $lost = $missing.Count }
        if ($lost -gt 0) {
            $gone = @($before.Open | Where-Object { $now.Open -notcontains $_ -and ($missing.Count -eq 0 -or $missing -contains (Get-ChecklistKey $_)) })
            $list = ($gone | ForEach-Object { if ($_.Length -gt 70) { $_.Substring(0, 70) + "..." } else { $_ } }) -join " / "
            $message = "$lost unsigned item(s) left .harness/ISSUES.md without being ticked: $list"
            Write-Host $message -ForegroundColor Red
            Write-RunLog "checklist guard: $message"
            Stop-Run 4 "FAILED" ($message + ". An unsigned item leaves only by being ticked. Put the items back " +
                "(git show HEAD~1:.harness/ISSUES.md), then re-run.")
        }
    }
    $script:ChecklistSnapshot = $now
}

# ---------- The loop ----------
$consecutiveCrashes = 0
$quotaWaits = 0
$priorIterations = Get-PriorIterationCount
if ($priorIterations -gt 0) {
    Write-Host "Resuming: $priorIterations iteration(s) already checkpointed on this branch." -ForegroundColor DarkGray
    Write-RunLog "resuming at iteration $($priorIterations + 1) - $priorIterations already checkpointed"
}

$script:BaselineSnapshot = Get-BaselineSnapshot
$script:ChecklistSnapshot = Get-ChecklistSnapshot

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
    Reset-IterationUsage

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
    # No MCP server reaches the engine. Without this it inherits every server the person running
    # Foreman configured for themselves: measured 2026-10-07 on Kanso's Run 3, 22 servers and 21 MCP
    # tools, among them a phone-control server that bypasses foreman-device.ps1 (ADR-033) and the
    # person's connected claude.ai Google Drive. Autonomous mode allows every tool not on the Deny
    # List, so each one was reachable. Nothing Foreman does needs MCP (library docs: ctx7, ADR-032).
    $claudeArgs += "--strict-mcp-config"
    # Nor does the rest of the operator's own configuration. Measured 2026-10-08 on Claude Code 2.1.292:
    # by default the engine loaded the person's six plugins, 92 skills, 127 slash commands and their
    # SessionStart hook, which injects a personal formatting ruleset into every invocation. Without the
    # user layer: the four built-in plugins, 22 skills, 57 commands, no hook; the login, the deny rules
    # from --settings, and what `sonnet` and `opus` resolve to are unchanged (ADR-038).
    $claudeArgs += @("--setting-sources", "project,local")
    # The user layer was also where auto-memory was turned off. Left on, the engine could carry notes
    # from one invocation to the next outside the repository, and iterations are stateless (ADR-001).
    $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1"
    # The Iteration is the Orchestrator, and at ENGINE.md 11 it is the Verifier. Pick its tier here:
    # one --model is fixed for the whole invocation, so this is the last moment a choice exists.
    # An explicit -Model still wins - a human overriding the map is not the map being ignored.
    $iterModel = $Model
    $iterTier  = "override"
    if ($iterModel -eq "") {
        $iterTier  = if (Test-DoneCandidate) { "capable" } else { "fast" }
        $iterModel = Resolve-TierModel $iterTier
        if ($iterModel -eq "") { $iterTier = "cli-default" }
    }
    if ($iterModel -ne "") {
        $claudeArgs += @("--model", $iterModel)
        Write-RunLog "iteration tier: $iterTier -> $iterModel"
    }
    # The effort level used to come from the operator's settings; it is the tier's now (models.json).
    $iterEffort = Resolve-TierEffort $(if (Test-DoneCandidate) { "capable" } else { "fast" })
    if ($iterEffort -ne "") { $claudeArgs += @("--effort", $iterEffort) }
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
    # Before anything else reacts to this iteration: a moved baseline is a changed exam.
    Assert-BaselinesUnmoved
    # ...and an unsigned item that vanished is a question made to disappear.
    Assert-ChecklistKept

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
        Write-Telemetry -Iteration $iteration -Status "CRASH" -IterStart $IterStart -Tier $iterTier -Model $iterModel
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
    Write-Telemetry -Iteration $iteration -Status $status.Word -IterStart $IterStart -Tier $iterTier -Model $iterModel
    Write-Host ("Status: {0} (iteration took {1}, total elapsed {2}, {3} turns, USD {4:F2})" -f $status.Word, (Format-Elapsed $IterStart), (Format-Elapsed $RunStart), $script:IterTurns, $script:IterCost) -ForegroundColor Yellow
    if ($status.Reason -ne "") { Write-Host $status.Reason }

    # Provisioned here too, not only before invoking: bootstrap is the Iteration that FIRST creates
    # .harness/run/, and ESCALATE can fire on that very Iteration (the DoD approval gate always
    # does). Provisioning only before invocation would leave a human staring at an ESCALATION.md
    # with no DECISIONS.md to answer into until they ran the Runtime a second time for no reason.
    #
    # Never after DONE. The Cleanup Commit has removed .harness/run/ by then, and the engine's last
    # act - writing STATUS.md - recreates the directory, so provisioning here copied the template
    # back into a run that had just finished. Calendar-Note hit it twice (after b5691ce and after
    # bb00487): a merge-ready branch with an untracked .harness/run/DECISIONS.md, and ENGINE.md 5
    # reads "no .harness/run/" as the signal to bootstrap, so the next goal on that branch was told
    # the opposite. After DONE the only thing this does is drop the directory STATUS.md recreated,
    # if that is all it holds; anything else in it is the engine's to explain, not ours to delete.
    if ($status.Word -eq "DONE") {
        Remove-EmptyRunDir
    } else {
        Ensure-DecisionsFile
    }
    # After every iteration, so the page a person reads is the run as this iteration left it.
    $pagePath = $null
    try { $pagePath = Write-ForemanPage -Outcome $status.Word -Reason $status.Reason } catch { Write-RunLog "foreman page could not be rendered: $_" }

    switch ($status.Word) {
        "DONE"     { Write-Host "Goal verified complete. Review and merge the Loop Branch." -ForegroundColor Green; Stop-Run 0 "DONE" $status.Reason }
        "DONE_PARTIAL" { Write-Host "Run finished without every criterion met. See the This run tab of FOREMAN.html for what was decided, done, and left." -ForegroundColor Yellow; Stop-Run 7 "DONE_PARTIAL" $status.Reason }
        "ESCALATE" {
            Write-Host "Human decision required. See the Needs you tab of FOREMAN.html - answer the queued decisions, then re-run." -ForegroundColor Magenta
            Open-ForemanPage $pagePath "a decision is waiting on you"
            Stop-Run 3 "ESCALATE" $status.Reason
        }
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
    # The page is rendered here too, on every exit path and in both modes, because the exits the
    # engine never sees coming - budget, crash limit, quota - are exactly when the human most needs
    # it (ADR-027, ADR-034).
    try {
        $final = Write-ForemanPage -Outcome $script:Outcome -Reason $script:OutcomeReason
        if ($final) { Write-Host "Foreman page: $final" -ForegroundColor Cyan }
    } catch { Write-Warning "Could not render FOREMAN.html ($_)." }
    # Cleanup always runs, even on exit: release the log writers and the run lock.
    if ($null -ne $script:LogWriter) { try { $script:LogWriter.Dispose() } catch {} }
    if ($null -ne $script:RawWriter) { try { $script:RawWriter.Dispose() } catch {} }
    try { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } catch {}
}
