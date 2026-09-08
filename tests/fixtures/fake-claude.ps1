<#
.SYNOPSIS
    Stand-in for the real `claude` CLI, used by run.Tests.ps1 via run.ps1's -ClaudeCommand seam.

.DESCRIPTION
    Ignores every argument it's given (prompt, --append-system-prompt-file, --settings, ...).
    Each invocation pops one directive from the queue file at $env:FAKE_CLAUDE_QUEUE and reacts.

    Because run.ps1 now always requests --output-format stream-json (the Runtime needs
    `rate_limit_event` for the quota bound, ADR-012), this stub emits real stream-json lines on
    stdout so the Runtime's parser and quota logic are genuinely exercised, not assumed.

    Directives:
      CONTINUE|<reason>        -> stream-json + .ai/STATUS.md = CONTINUE
      DONE|<reason>            -> stream-json + .ai/STATUS.md = DONE
      ESCALATE|<reason>        -> stream-json + .ai/STATUS.md = ESCALATE
      FAILED|<reason>          -> stream-json + .ai/STATUS.md = FAILED
      CRASH                    -> emits nothing, writes nothing (a crashed invocation)
      SLEEP:<seconds>          -> sleeps, writes nothing (run-lock / hard-timeout tests)
      IDLE:<seconds>           -> emits one event, then goes silent (idle-timeout tests)
      QUOTA:<pct>|<directive>  -> emits rate_limit_event at <pct> utilization on five_hour,
                                  then behaves as <directive> (e.g. QUOTA:95|CONTINUE|more work)
      QUOTA7:<pct>|<directive> -> same, but the utilization lands on the seven_day window
      REJECTED                 -> rate_limit_event with status=rejected, writes no status
                                  (an invocation the usage limit refused to run)

    An empty or missing queue writes nothing (a crash), so an unconfigured test fails loudly
    rather than silently looping.
#>

# NO param() block, deliberately: this mirrors the real npm `claude.ps1` shim, which has none
# either. A script with parameters makes PowerShell bind `--append-system-prompt-file` as a named
# parameter and fail; with no param block every argument arrives verbatim in $args.

# Optional: record the exact argument vector run.ps1 passed, so a test can assert the
# invocation contract (e.g. that the engine spec travels by file, not inline).
if ($env:FAKE_CLAUDE_ARGLOG) {
    try { Add-Content -Path $env:FAKE_CLAUDE_ARGLOG -Value ($args -join ' ') } catch {}
}

$RepoRoot = (Get-Location).Path
$AiDir = Join-Path $RepoRoot ".ai"
if (-not (Test-Path $AiDir)) { New-Item -ItemType Directory -Path $AiDir -Force | Out-Null }

$QueueFile = $env:FAKE_CLAUDE_QUEUE
if (-not $QueueFile -or -not (Test-Path $QueueFile)) { exit 0 }

$lines = @(Get-Content $QueueFile)
if ($lines.Count -eq 0) { exit 0 }

$directive = $lines[0]
$rest = if ($lines.Count -gt 1) { $lines[1..($lines.Count - 1)] } else { @() }
Set-Content -Path $QueueFile -Value $rest

# ---------- emitters ----------
function Emit-RateLimit {
    param([double]$FiveHour, [double]$SevenDay, [string]$Status = "allowed")
    # resetsAt is deliberately in the near future so waiting tests stay fast.
    $resets = [int][double]::Parse((Get-Date).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds) + 2
    $obj = @{
        type = "rate_limit_event"
        session_id = "fake-session"
        rate_limit_info = @{
            status = $Status
            rateLimitType = "five_hour"
            resetsAt = $resets
            unifiedWindows = @{
                five_hour = @{ utilization = $FiveHour; resetsAt = $resets }
                seven_day = @{ utilization = $SevenDay; resetsAt = $resets }
            }
        }
    }
    Write-Output ($obj | ConvertTo-Json -Depth 6 -Compress)
}

function Emit-Activity {
    param([string]$Text)
    $assistant = @{
        type = "assistant"
        session_id = "fake-session"
        message = @{ content = @( @{ type = "text"; text = $Text } ) }
    }
    Write-Output ($assistant | ConvertTo-Json -Depth 6 -Compress)
}

function Emit-Result {
    $res = @{
        type = "result"; subtype = "success"; is_error = $false; num_turns = 1
        total_cost_usd = 0.001
        usage = @{ input_tokens = 10; output_tokens = 5; cache_read_input_tokens = 0 }
        subagent_stats = @{ spawned = 0; completed = 0; failed = 0 }
    }
    Write-Output ($res | ConvertTo-Json -Depth 6 -Compress)
}

function Write-Status {
    param([string]$Word, [string]$Reason)
    Set-Content -Path (Join-Path $AiDir "STATUS.md") -Value "$Word`n$Reason"
}

# ---------- non-reporting directives ----------
if ($directive -eq "CRASH") { exit 0 }

if ($directive -like "SLEEP:*") {
    Start-Sleep -Seconds ([int]($directive.Substring(6)))
    exit 0
}

if ($directive -like "IDLE:*") {
    # One event proves the stream started, then silence: exactly the hang the idle bound catches.
    Emit-Activity "starting work"
    Start-Sleep -Seconds ([int]($directive.Substring(5)))
    exit 0
}

if ($directive -eq "REJECTED") {
    Emit-RateLimit -FiveHour 1.0 -SevenDay 0.5 -Status "rejected"
    exit 0
}

# The CLI has THREE statuses, not two: allowed / allowed_warning / rejected. A warned invocation
# was permitted and must never be mistaken for a rejection - doing so would make the Runtime sleep
# for hours on an invocation that simply crashed. WARNED emits the warning and then behaves as the
# following directive, exactly as the real CLI does.
if ($directive -match '^WARNED\|(.+)$') {
    Emit-RateLimit -FiveHour 0.5 -SevenDay 0.2 -Status "allowed_warning"
    $directive = $Matches[1]
}

# WARNCRASH: warned, then dies without a status. This is the trap: the old code treated any
# non-"allowed" status as a rejection and would wait for a reset instead of counting a crash.
if ($directive -eq "WARNCRASH") {
    Emit-RateLimit -FiveHour 0.5 -SevenDay 0.2 -Status "allowed_warning"
    exit 0
}

# ---------- quota-prefixed directives ----------
$fiveHour = 0.37
$sevenDay = 0.18
$emitQuota = $false

if ($directive -match '^QUOTA7?:([0-9.]+)\|(.+)$') {
    $pct = [double]$Matches[1] / 100.0
    if ($directive.StartsWith("QUOTA7:")) { $sevenDay = $pct } else { $fiveHour = $pct }
    $emitQuota = $true
    $directive = $Matches[2]
}

if ($emitQuota) { Emit-RateLimit -FiveHour $fiveHour -SevenDay $sevenDay }

# ---------- reporting directives ----------
$parts = $directive -split '\|', 2
$word = $parts[0]
$reason = if ($parts.Count -gt 1) { $parts[1] } else { "fake-claude stub" }

Emit-Activity "doing $word work"
Write-Status -Word $word -Reason $reason
Emit-Result
exit 0
