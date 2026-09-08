<#
.SYNOPSIS
    Loop Runtime V1 - the thin, intentionally dumb outer loop.

.DESCRIPTION
    The Runtime is the enforcement plane of the AI Software Factory.
    It is purely mechanical and never makes engineering decisions.

    Per iteration it does exactly four things:
      1. Compile human-approved Capability Ledgers into fresh permission settings (a build artifact).
      2. Invoke Claude Code once, with .harness/loop/ENGINE.md as appended system prompt.
      3. Read the Execution Status the engine persisted (.harness/run/STATUS.md).
      4. React: CONTINUE -> invoke again | DONE/ESCALATE/FAILED -> stop | no status -> Watchdog.

    Trust chain: Human -> Capability Ledger -> Runtime Compiler -> Permission Settings -> Engine.
    The engine can never modify .harness/loop/, the ledgers, or the generated settings (deny rules below).

.NOTES
    Run from the consumer repository root. Requires: git, Claude Code CLI, PRD.md.
    Exit codes: 0=DONE  2=crash limit  3=ESCALATE  4=FAILED  5=iteration budget  6=quota ceiling
#>

param(
    # Mechanical safety bounds - the only "policy" the Runtime owns (ADR-012).
    [int]$MaxIterations = 50,
    [int]$MaxConsecutiveCrashes = 3,
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

# Run lock: at most ONE Loop Runtime per repository. Two concurrent engines committing to the
# same branch would corrupt the run - refuse to start if a live instance holds the lock.
$LockFile = Join-Path $env:TEMP ("loop-run-" + (Split-Path $RepoRoot -Leaf) + ".lock")
if (Test-Path $LockFile) {
    $oldPid = (Get-Content $LockFile -TotalCount 1).Trim()
    $alive = $false
    if ($oldPid -match '^\d+$') { $alive = ($null -ne (Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue)) }
    if ($alive) {
        Write-Host "Another Loop Runtime (PID $oldPid) is already running against this repository. Only one loop may run at a time." -ForegroundColor Red
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
Write-Host "Loop Runtime starting. PID: $PID" -ForegroundColor Cyan
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
    if (@("CONTINUE", "DONE", "ESCALATE", "FAILED") -contains $word) {
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
#     last value, and treat the CLI's own `allowed_warning` as a trip regardless of arithmetic.
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
        if ($info.status -eq "allowed_warning" -or $info.status -eq "rejected") { $script:QuotaWarned = $true }
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
    $msg = "Quota window '$Window' at/above $QuotaStopPercent%. Waiting until $($target.ToString('yyyy-MM-dd HH:mm:ss')) for reset."
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

    $launch = Resolve-EngineLaunch -EngineArgs $EngineArgs
    # -WorkingDirectory is explicit and load-bearing: Start-Process launches in .NET's current
    # directory, which is NOT PowerShell's location. Without it the engine runs somewhere else
    # entirely and writes its status file outside the consumer repository.
    $proc = Start-Process -FilePath $launch.Exe -ArgumentList $launch.ArgString `
                          -WorkingDirectory $RepoRoot `
                          -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
                          -NoNewWindow -PassThru

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
    return "{0:00}:{1:00}:{2:00}" -f [int]$span.TotalHours, $span.Minutes, $span.Seconds
}

# ---------- The loop ----------
$consecutiveCrashes = 0
$quotaWaits = 0

try {
for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
    $IterStart = Get-Date
    Write-Host ""
    Write-Host "=== Iteration $iteration / $MaxIterations === started $(Get-Date -Format 'HH:mm:ss') | total elapsed $(Format-Elapsed $RunStart)" -ForegroundColor Cyan
    Write-RunLog "=== Iteration $iteration / $MaxIterations === $(Get-Date -Format o)"

    # Status file is transport, not state: delete before invoking so absence-after = crash (mechanical detection).
    if (Test-Path $StatusFile) { Remove-Item $StatusFile -Force }

    # Fresh permission settings every iteration - build artifact, never a source artifact.
    # The engine spec goes in by FILE, not as an inline argument: it is ~13KB of multi-line text,
    # which cannot survive Start-Process argument quoting (needed for the timeout bounds).
    $claudeArgs = @("-p", $IterationPrompt, "--append-system-prompt-file", $EngineSpecPath)
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
            exit 6
        }
        $quotaWaits++
        if ($quotaWaits -gt $MaxQuotaWaits) {
            Write-Host "Waited for a quota reset $MaxQuotaWaits times already. Stopping deterministically." -ForegroundColor Red
            exit 6
        }
        Wait-ForQuotaReset -ResetsAt $resetsAt -Window "rejected"
        $iteration--   # this iteration never executed; do not spend it from the budget
        continue
    }

    if ($null -eq $status) {
        # Crash: the engine died without reporting. Only the Runtime can detect this (Watchdog).
        # A timeout kill lands here deliberately - it IS a crash, and existing recovery applies:
        # the next invocation finds a dirty tree and recovers per ENGINE.md 6.1.
        $consecutiveCrashes++
        $why = "no Execution Status"
        if ($timeoutKind -ne "") { $why = "$timeoutKind timeout" }
        Write-Warning "Crash detected ($why). Consecutive crashes: $consecutiveCrashes / $MaxConsecutiveCrashes"
        if ($consecutiveCrashes -ge $MaxConsecutiveCrashes) {
            Write-Host "Watchdog limit reached. Stopping. The next run's engine will recover from the last Stable Checkpoint." -ForegroundColor Red
            exit 2
        }
        continue
    }

    $consecutiveCrashes = 0
    Remove-Item $StatusFile -Force
    Write-RunLog "=== Status: $($status.Word) === $(Get-Date -Format o)"
    Write-Host ("Status: {0} (iteration took {1}, total elapsed {2})" -f $status.Word, (Format-Elapsed $IterStart), (Format-Elapsed $RunStart)) -ForegroundColor Yellow
    if ($status.Reason -ne "") { Write-Host $status.Reason }

    switch ($status.Word) {
        "DONE"     { Write-Host "Goal verified complete. Review and merge the Loop Branch." -ForegroundColor Green; exit 0 }
        "ESCALATE" { Write-Host "Human decision required. See .harness/run/ESCALATION.md - answer the queued decisions, then re-run." -ForegroundColor Magenta; exit 3 }
        "FAILED"   { Write-Host "Execution broken. Human repair required. See .harness/run/STATE.md for the engine's last findings." -ForegroundColor Red; exit 4 }
    }

    # ---- CONTINUE: check the resource bound before spending another iteration ----
    $trip = Get-QuotaTrip
    if ($null -ne $trip) {
        $pct = [Math]::Round($trip.Percent, 1)
        Write-Host "Quota window '$($trip.Window)' at $pct% (ceiling $QuotaStopPercent%)." -ForegroundColor Yellow
        Write-RunLog "=== Quota ceiling: $($trip.Window) at $pct% === $(Get-Date -Format o)"
        if ($NoQuotaWait -or $null -eq $trip.ResetsAt) {
            Write-Host "Stopping to leave usage headroom. Re-run to continue from the last Stable Checkpoint." -ForegroundColor Yellow
            exit 6
        }
        $quotaWaits++
        if ($quotaWaits -gt $MaxQuotaWaits) {
            Write-Host "Waited for a quota reset $MaxQuotaWaits times already. Stopping deterministically." -ForegroundColor Red
            exit 6
        }
        Wait-ForQuotaReset -ResetsAt $trip.ResetsAt -Window $trip.Window
    }
}

# Iteration budget exhausted: a deterministic safety stop, never an interpretation of task failure.
Write-Host "Iteration budget ($MaxIterations) exhausted. Stopping deterministically." -ForegroundColor Red
Write-Host "This is a Runtime safety bound, not a judgment about the work. Inspect .harness/run/STATE.md and re-run to continue from the last Stable Checkpoint."
exit 5
} finally {
    # Cleanup always runs, even on exit: release the log writers and the run lock.
    if ($null -ne $script:LogWriter) { try { $script:LogWriter.Dispose() } catch {} }
    if ($null -ne $script:RawWriter) { try { $script:RawWriter.Dispose() } catch {} }
    try { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } catch {}
}
