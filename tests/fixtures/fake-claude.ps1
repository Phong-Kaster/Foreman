<#
.SYNOPSIS
    Stand-in for the real `claude` CLI, used by run.Tests.ps1 via run.ps1's -ClaudeCommand seam.

.DESCRIPTION
    Ignores every argument it's given (prompt, --append-system-prompt, --settings, --model, ...).
    Each invocation pops one directive from the queue file at $env:FAKE_CLAUDE_QUEUE and reacts:

      CONTINUE|<reason>   -> writes .ai/STATUS.md = CONTINUE
      DONE|<reason>       -> writes .ai/STATUS.md = DONE
      ESCALATE|<reason>   -> writes .ai/STATUS.md = ESCALATE
      FAILED|<reason>     -> writes .ai/STATUS.md = FAILED
      CRASH               -> emits a tool_use event, then writes nothing. This is a REAL crash:
                             the engine did work and died before reporting.
      REFUSE|<message>    -> prints <message>, makes no tool call, writes nothing. Simulates the
                             CLI declining on purpose (quota, auth) and exiting 0.
      SILENT              -> exits 0 having printed nothing and done nothing.
      SLEEP:<seconds>     -> sleeps, writes nothing (used for run-lock overlap tests)

    An empty or missing queue also writes nothing (crash), so an unconfigured test fails loudly
    rather than silently looping.
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PassThroughArgs
)

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

# A crash is "did work, then died". The tool_use event is what makes it distinguishable from a
# refusal, which is exactly the distinction run.ps1's classifier depends on.
if ($directive -eq "CRASH") {
    $evt = '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo working"}}]}}'
    Write-Output $evt
    exit 0
}

# Ran, declined on purpose, exited 0. No tool call, no status.
if ($directive -like "REFUSE|*") {
    $message = $directive.Substring(7)
    $clean = $message -replace '[\\\\"]', ''
    Write-Output ('{"type":"assistant","message":{"content":[{"type":"text","text":"' + $clean + '"}]}}')
    exit 0
}

# Ran, said nothing, did nothing.
if ($directive -eq "SILENT") { exit 0 }

if ($directive -like "SLEEP:*") {
    $seconds = [int]($directive.Substring(6))
    Start-Sleep -Seconds $seconds
    exit 0
}

$parts = $directive -split '\|', 2
$word = $parts[0]
$reason = if ($parts.Count -gt 1) { $parts[1] } else { "fake-claude stub" }

Set-Content -Path (Join-Path $AiDir "STATUS.md") -Value "$word`n$reason"
exit 0
