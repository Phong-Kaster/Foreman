<#
.SYNOPSIS
    Foreman V1 — the thin, intentionally dumb outer loop.

.DESCRIPTION
    The Runtime is the enforcement plane of the AI Software Factory.
    It is purely mechanical and never makes engineering decisions.

    Per iteration it does exactly four things:
      1. Compile human-approved Capability Ledgers into fresh permission settings (a build artifact).
      2. Invoke Claude Code once, with .loop/ENGINE.md as appended system prompt.
      3. Read the Execution Status the engine persisted (.ai/STATUS.md).
      4. React: CONTINUE -> invoke again | DONE/ESCALATE/FAILED -> stop | no status -> Watchdog.

    Trust chain: Human -> Capability Ledger -> Runtime Compiler -> Permission Settings -> Engine.
    The engine can never modify .loop/, the ledgers, or the generated settings (deny rules below).

.NOTES
    Run from the consumer repository root. Requires: git, Claude Code CLI, PRD.md.
    Exit codes: 0=DONE  2=crash limit  3=ESCALATE  4=FAILED  5=iteration budget exhausted
#>

param(
    # Mechanical safety bounds — the only "policy" the Runtime owns.
    [int]$MaxIterations = 50,
    [int]$MaxConsecutiveCrashes = 3,
    # Invocation mechanics.
    [string]$ClaudeCommand = "claude",
    [string]$Model = "",
    # Optional: stage an external requirement document as PRD.md before the first iteration.
    # Accepts a path relative to the repo root or an absolute path. Leave empty (default) to use
    # whatever PRD.md already sits at the repo root — unchanged from prior behavior.
    [string]$PrdPath = "",
    # Suppress the live engine activity feed (feed is on by default for observability).
    [switch]$QuietEngine,
    # Consenting-adult fast path (ADR-004): full permission bypass, for sandboxed/VM runs only.
    [switch]$DangerouslySkipPermissions
)

$ErrorActionPreference = "Stop"

# ---------- Paths ----------
$RepoRoot   = (Get-Location).Path
$LoopDir    = Join-Path $RepoRoot ".loop"
$AiDir      = Join-Path $RepoRoot ".ai"
$StatusFile = Join-Path $AiDir "STATUS.md"

$EngineSpecPath = Join-Path $LoopDir "ENGINE.md"
if (-not (Test-Path $EngineSpecPath)) { Write-Error ".loop/ENGINE.md not found. Run from the consumer repository root."; exit 1 }
$EngineSpec = Get-Content $EngineSpecPath -Raw

# ---------- PRD staging (mechanical copy only — never interprets or rewrites content) ----------
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

# Run lock: at most ONE Foreman run per repository. Two concurrent engines committing to the
# same branch would corrupt the run — refuse to start if a live instance holds the lock.
$LockFile = Join-Path $env:TEMP ("loop-run-" + (Split-Path $RepoRoot -Leaf) + ".lock")
if (Test-Path $LockFile) {
    $oldPid = (Get-Content $LockFile -TotalCount 1).Trim()
    $alive = $false
    if ($oldPid -match '^\d+$') { $alive = ($null -ne (Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue)) }
    if ($alive) {
        Write-Host "Another Foreman run (PID $oldPid) is already running against this repository. Only one loop may run at a time." -ForegroundColor Red
        exit 1
    }
    # Stale lock from a dead process — take over.
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
#   .loop/capabilities/baseline.json   permanent, ships with the runtime
#   knowledge/capabilities.json        standing,  per-repository (approved at the DoD gate)
#   .ai/capabilities.json              scoped,    per-goal (expires automatically with .ai/)
# Each ledger: { "entries": [ { "intent", "command", "scope", "lifetime", "allow": ["<exact rule>"] } ] }
# The runtime reads ONLY the "allow" arrays — exact rule strings the human approved. No interpretation.
function Compile-PermissionSettings {
    $allowRules = @()
    $ledgers = @(
        (Join-Path $LoopDir "capabilities\baseline.json"),
        (Join-Path $RepoRoot "knowledge\capabilities.json"),
        (Join-Path $AiDir "capabilities.json")
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
        "Edit(.loop/**)",
        "Write(.loop/**)",
        "Edit(knowledge/capabilities.json)",
        "Write(knowledge/capabilities.json)",
        "Edit(.ai/capabilities.json)",
        "Write(.ai/capabilities.json)"
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

# ---------- Timer ----------
$RunStart = Get-Date
function Format-Elapsed([datetime]$since) {
    $span = (Get-Date) - $since
    return "{0:00}:{1:00}:{2:00}" -f [int]$span.TotalHours, $span.Minutes, $span.Seconds
}

# ---------- The loop ----------
$consecutiveCrashes = 0

try {
for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
    $IterStart = Get-Date
    Write-Host ""
    Write-Host "=== Iteration $iteration / $MaxIterations === started $(Get-Date -Format 'HH:mm:ss') | total elapsed $(Format-Elapsed $RunStart)" -ForegroundColor Cyan
    Write-RunLog "=== Iteration $iteration / $MaxIterations === $(Get-Date -Format o)"

    # Status file is transport, not state: delete before invoking so absence-after = crash (mechanical detection).
    if (Test-Path $StatusFile) { Remove-Item $StatusFile -Force }

    # Fresh permission settings every iteration — build artifact, never a source artifact.
    $claudeArgs = @("-p", $IterationPrompt, "--append-system-prompt", $EngineSpec)
    if ($DangerouslySkipPermissions) {
        $claudeArgs += "--dangerously-skip-permissions"
    } else {
        $settingsPath = Compile-PermissionSettings
        $claudeArgs += @("--settings", $settingsPath)
    }
    if ($Model -ne "") { $claudeArgs += @("--model", $Model) }

    # Invoke the engine. Its exit code is irrelevant; only the persisted status counts.
    # Default: stream engine events so a human can SEE that the loop is alive and what it is doing.
    # Purely mechanical passthrough — the Runtime relays events, it never interprets them.
    if ($QuietEngine) {
        try { & $ClaudeCommand @claudeArgs } catch { Write-Warning "Engine process error: $_" }
    } else {
        $claudeArgs += @("--output-format", "stream-json", "--verbose")
        try {
            & $ClaudeCommand @claudeArgs | ForEach-Object {
                Write-RawLog $_
                $evt = $null
                try { $evt = $_ | ConvertFrom-Json } catch {}
                if ($null -ne $evt) {
                    # Timestamp + iteration stopwatch: proof of life on every engine event.
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
            }
        } catch { Write-Warning "Engine process error: $_" }
    }

    $status = Read-ExecutionStatus

    if ($null -eq $status) {
        # Crash: the engine died without reporting. Only the Runtime can detect this (Watchdog).
        $consecutiveCrashes++
        Write-Warning "Crash detected (no Execution Status). Consecutive crashes: $consecutiveCrashes / $MaxConsecutiveCrashes"
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
        "CONTINUE" { continue }
        "DONE"     { Write-Host "Goal verified complete. Review and merge the Loop Branch." -ForegroundColor Green; exit 0 }
        "ESCALATE" { Write-Host "Human decision required. See .ai/ESCALATION.md, fill the Decision section, then re-run." -ForegroundColor Magenta; exit 3 }
        "FAILED"   { Write-Host "Execution broken. Human repair required. See .ai/STATE.md for the engine's last findings." -ForegroundColor Red; exit 4 }
    }
}

# Iteration budget exhausted: a deterministic safety stop, never an interpretation of task failure.
Write-Host "Iteration budget ($MaxIterations) exhausted. Stopping deterministically." -ForegroundColor Red
Write-Host "This is a Runtime safety bound, not a judgment about the work. Inspect .ai/STATE.md and re-run to continue from the last Stable Checkpoint."
exit 5
} finally {
    # Cleanup always runs, even on exit: release the log writers and the run lock.
    if ($null -ne $script:LogWriter) { try { $script:LogWriter.Dispose() } catch {} }
    if ($null -ne $script:RawWriter) { try { $script:RawWriter.Dispose() } catch {} }
    try { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } catch {}
}
