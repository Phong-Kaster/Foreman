<#
.SYNOPSIS
    Unit tests for .harness/loop/run.ps1's mechanics, using a fake `claude` stub so no real API calls,
    no nested-agent invocation, and no dependency on git ever happen.

.DESCRIPTION
    run.ps1 calls git for exactly one thing: verifying the repository has a base commit, because
    the engine branches from HEAD and checkpoints as commits (a fresh repo with everything still
    untracked failed deep inside bootstrap in the field). So a test repo is a real git repo with
    one commit -- everything else about git still belongs to the engine. The fake-claude.ps1 fixture
    (invoked via run.ps1's existing -ClaudeCommand seam) is driven by a queue file so each test can
    script exactly what "the engine" does on each iteration, deterministically.

    run.ps1 is always launched as a genuine child process (powershell -File ...), never dot-sourced
    or called in-process - its internal `exit N` calls would otherwise terminate the test runner
    itself instead of just ending the script.

.NOTES
    Run with: Invoke-Pester -Script @{ Path = 'tests/run.Tests.ps1' }
#>

$RepoRootDir = Split-Path -Parent $PSScriptRoot
$RunPs1 = Join-Path $RepoRootDir ".harness/loop/run.ps1"
$FakeClaude = Join-Path $PSScriptRoot "fixtures\fake-claude.ps1"

function New-TestRepo {
    param([switch]$WithoutEngineSpec, [switch]$WithoutCommit)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("foreman-unit-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 12))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if (-not $WithoutEngineSpec) {
        New-Item -ItemType Directory -Path (Join-Path $dir ".harness/loop") -Force | Out-Null
        Set-Content -Path (Join-Path $dir ".harness/loop/ENGINE.md") -Value "# fake engine spec for tests"
    }
    # A real repository with a base commit: run.ps1 refuses to start without one, and refusing is
    # the behaviour under test in "run.ps1 prerequisites".
    Push-Location $dir
    try {
        & git init --quiet 2>$null | Out-Null
        if (-not $WithoutCommit) {
            Set-Content -Path (Join-Path $dir "seed.txt") -Value "base commit for the loop to branch from"
            & git add -A 2>$null | Out-Null
            & git -c user.email=test@local -c user.name=LoopTest commit --quiet -m "initial" 2>$null | Out-Null
        }
    } finally { Pop-Location }
    return $dir
}

function Set-FakeClaudeQueue {
    param([string]$TestRepo, [string[]]$Directives)
    $queueFile = Join-Path $TestRepo "queue.txt"
    Set-Content -Path $queueFile -Value $Directives
    $env:FAKE_CLAUDE_QUEUE = $queueFile
}

function Invoke-RunPs1 {
    param([string]$TestRepo, [string[]]$ExtraArgs = @())
    Push-Location $TestRepo
    try {
        $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RunPs1, "-ClaudeCommand", $FakeClaude, "-QuietEngine") + $ExtraArgs
        & powershell @args | Out-Null
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Remove-TestRepo {
    param([string]$TestRepo)
    $leaf = Split-Path $TestRepo -Leaf
    Remove-Item -Path $TestRepo -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $env:TEMP "loop-run-$leaf.lock") -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $env:TEMP "loop-run-$leaf.log") -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $env:TEMP "loop-run-$leaf.raw.jsonl") -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\FAKE_CLAUDE_QUEUE -ErrorAction SilentlyContinue
    Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
    Remove-Item Env:\FAKE_CLAUDE_AGENTLOG -ErrorAction SilentlyContinue
    Remove-Item Env:\FAKE_CLAUDE_STDINLOG -ErrorAction SilentlyContinue
}

Describe "run.ps1 status reactions" {

    It "exits 0 (DONE) after CONTINUE, CONTINUE, DONE" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|step one", "CONTINUE|step two", "DONE|all good")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "exits 3 (ESCALATE) immediately when the engine asks a question" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("ESCALATE|need a decision")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")
            $exit | Should Be 3
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "exits 4 (FAILED) when execution is broken" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("FAILED|environment broken")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")
            $exit | Should Be 4
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "exits 5 (budget exhausted) when the engine never resolves within MaxIterations" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|a", "CONTINUE|b", "CONTINUE|c")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2")
            $exit | Should Be 5
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "exits 2 (watchdog) after MaxConsecutiveCrashes crashes in a row" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CRASH", "CRASH")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "2", "-CrashBackoffSeconds", "0")
            $exit | Should Be 2
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 prerequisites" {

    It "exits 1 when the repository has no commit yet, without invoking the engine" {
        # Found in the field on a fresh Android repo where everything was still untracked: the
        # engine branches from HEAD and checkpoints as commits, so with no HEAD it failed deep
        # inside bootstrap where the cause was not obvious. Refused here instead.
        $repo = New-TestRepo -WithoutCommit
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|should never run")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")
            $exit | Should Be 1
            (Test-Path (Join-Path $repo ".harness/run/STATUS.md")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "exits 1 immediately when .harness/loop/ENGINE.md is missing, without invoking the engine" {
        $repo = New-TestRepo -WithoutEngineSpec
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|should never run")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")
            $exit | Should Be 1
            (Test-Path (Join-Path $repo ".harness/run/STATUS.md")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 quota bound (ADR-012)" {

    It "stops with exit 6 when the five-hour window is at or above the ceiling" {
        $repo = New-TestRepo
        try {
            # 95% > 90% ceiling. -NoQuotaWait makes the trip a stop rather than a sleep.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("QUOTA:95|CONTINUE|more work", "DONE|never reached")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-NoQuotaWait")
            $exit | Should Be 6
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "stops on the seven-day window too, not only the five-hour one" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("QUOTA7:96|CONTINUE|more work", "DONE|never reached")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-NoQuotaWait")
            $exit | Should Be 6
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "keeps going when utilization is below the ceiling" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("QUOTA:40|CONTINUE|fine", "DONE|all good")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-NoQuotaWait")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "respects a custom ceiling" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("QUOTA:40|CONTINUE|fine", "DONE|never reached")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-NoQuotaWait", "-QuotaStopPercent", "30")
            $exit | Should Be 6
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "treats a rejected invocation as a quota stop, NOT as a crash" {
        $repo = New-TestRepo
        try {
            # Three REJECTED in a row would trip the watchdog (exit 2) if they counted as crashes.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REJECTED", "REJECTED", "REJECTED")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "2", "-NoQuotaWait")
            $exit | Should Be 6
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "treats allowed_warning as a crash when the engine dies, NOT as a quota wait" {
        $repo = New-TestRepo
        try {
            # The trap this test exists for: the CLI has three statuses, and code that checks
            # "status is not allowed" classifies a merely-warned invocation as rejected, then
            # sleeps for hours instead of letting the Watchdog retry. Two warned crashes with a
            # crash limit of 2 must exit 2 (watchdog), never 6 (quota).
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("WARNCRASH", "WARNCRASH")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "2")
            $exit | Should Be 2
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "stops on the CLI's own warning even when reported utilization is below the ceiling" {
        $repo = New-TestRepo
        try {
            # 50% is well under the 90% ceiling, but the CLI warned. It knows the true headroom;
            # the utilization figure available between iterations was measured before this
            # iteration spent anything. A real run went 40% -> 100% inside one iteration.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("WARNED|CONTINUE|more work", "DONE|never reached")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-NoQuotaWait")
            $exit | Should Be 6
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "does not treat a seven-day warning below the ceiling as a five-hour trip" {
        $repo = New-TestRepo
        try {
            # Field run, 2026-09-24: five_hour 45%, seven_day 88%, CLI warning typed seven_day. The
            # Runtime slept until the five-hour reset, which could never clear a seven-day warning.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("WARNED7|CONTINUE|more work", "DONE|kept going")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-NoQuotaWait")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "still stops on the seven-day window once it reaches the ceiling" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("WARNED7|CONTINUE|more work", "DONE|never reached")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-NoQuotaWait", "-QuotaStopPercent", "85")
            $exit | Should Be 6
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "stops at the hour budget instead of sleeping past it for a quota reset" {
        $repo = New-TestRepo
        try {
            # QUOTA:95 trips the ceiling; its reset is ~2 s away, beyond a budget of ~0.4 s.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("QUOTA:95|CONTINUE|more work", "DONE|never reached")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxHours", "0.0001")
            $exit | Should Be 5
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "waits for the reset and then continues, instead of stopping" {
        $repo = New-TestRepo
        try {
            # The fixture sets resetsAt ~2s out, so the wait is real but short.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REJECTED", "DONE|resumed after the wait")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "does not spend an iteration from the budget on a rejected invocation" {
        $repo = New-TestRepo
        try {
            # Budget of 1. The rejection must not consume it, or DONE would never be reached.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REJECTED", "DONE|used the only budgeted iteration")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "1")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 timeout bounds (ADR-012)" {

    It "kills a silent invocation on the idle bound and counts it as a crash" {
        $repo = New-TestRepo
        try {
            # Emits one event then goes quiet for 60s. Idle bound of 1 minute fires first.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("IDLE:60", "IDLE:60")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "2", "-MaxIdleMinutes", "1")
            $exit | Should Be 2
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "does not kill an invocation that reports within the idle bound" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|quick", "DONE|quick")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxIdleMinutes", "1")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 engine invocation contract" {

    It "passes the engine spec by file, never as an inline argument" {
        $repo = New-TestRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $recorded = Get-Content $argLog -Raw
            $recorded | Should Match "--append-system-prompt-file"
            # The spec BODY must never appear on the command line - only its path. The marker is
            # the test repo's spec content, not a phrase from the fixed prompt (PowerShell regex
            # is case-insensitive, and the prompt itself names the Execution Engine Specification).
            $recorded | Should Match "ENGINE.md"
            $recorded | Should Not Match "fake engine spec"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }
}

Describe "run.ps1 engine stdin" {

    It 'hands the engine a FINITE stdin, so the npm shim cannot block draining it' {
        # The npm `claude` shim is a PowerShell script:
        #   if ($MyInvocation.ExpectingInput) { $input | & claude.exe $args } else { & claude.exe $args }
        # Redirecting stdout but not stdin leaves the child inheriting the Runtime's stdin. When
        # that is a pipe which never delivers and never closes -- exactly what it is when the
        # Runtime runs from a script or background task, which is how the Skill launches it --
        # draining $input blocks forever and claude.exe is never spawned at all. Measured in the
        # field: 11 minutes alive, 0.3s CPU, zero bytes on stdout AND stderr, no error.
        #
        # Note what is NOT asserted: that stdin is unredirected. With -RedirectStandardInput it is
        # redirected and ExpectingInput stays True. Finiteness is the property that matters.
        # A/B proof of the fix: without it the launch still hung at 45s; with it, 5.1s.
        #
        # -MaxIdleMinutes 1 so a regression fails in about a minute instead of hanging the suite.
        $repo = New-TestRepo
        try {
            $stdinLog = Join-Path $repo "stdin-verdict.txt"
            $env:FAKE_CLAUDE_STDINLOG = $stdinLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-MaxIdleMinutes", "1") | Out-Null

            (Get-Content $stdinLog -Raw).Trim() | Should Be "stdinItems=0"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_STDINLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }
}

Describe "run.ps1 agent definitions" {

    It "materializes the real agent definitions into .claude/agents before invoking" {
        $repo = New-TestRepo
        try {
            # The REAL definitions, not hand-written stand-ins. These were once passed as a
            # --agents JSON argument; the npm claude shim is itself a PowerShell script that
            # re-quotes its arguments, and PowerShell 5.1 mangles embedded double quotes at that
            # hop, so the CLI received unparsable JSON. Files avoid command-line quoting entirely.
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/agents") -Force | Out-Null
            Copy-Item -Path (Join-Path $RepoRootDir ".harness/loop/agents/*.md") -Destination (Join-Path $repo ".harness/loop/agents") -Force

            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $published = Join-Path $repo ".claude\agents"
            (Test-Path (Join-Path $published "loop-worker.md")) | Should Be $true
            (Test-Path (Join-Path $published "loop-reviewer.md")) | Should Be $true
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "gives the Worker no Bash tool, so 'no git, no build, no test' is harness-enforced" {
        $repo = New-TestRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/agents") -Force | Out-Null
            Copy-Item -Path (Join-Path $RepoRootDir ".harness/loop/agents/*.md") -Destination (Join-Path $repo ".harness/loop/agents") -Force
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $worker = Get-Content (Join-Path $repo ".claude\agents\loop-worker.md") -Raw
            $toolLine = ($worker -split "`n" | Where-Object { $_ -match "^tools:" })
            $toolLine | Should Not Match "Bash"
            $toolLine | Should Match "Read"
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "runs normally when no agent definitions are present" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 -PrdPath staging" {

    It "copies an existing source file onto PRD.md at the repo root" {
        $repo = New-TestRepo
        try {
            $source = Join-Path $repo "external-requirement.txt"
            Set-Content -Path $source -Value "write a hello world notification"
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")

            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-PrdPath", $source)

            $exit | Should Be 0
            (Get-Content (Join-Path $repo "PRD.md") -Raw).Trim() | Should Be "write a hello world notification"
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "errors before invoking the engine when the PRD source does not exist" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|should never run")

            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-PrdPath", "does-not-exist.md")

            $exit | Should Be 1
            (Test-Path (Join-Path $repo ".harness/run/STATUS.md")) | Should Be $false
            (Test-Path (Join-Path $repo "PRD.md")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "leaves an existing PRD.md untouched when -PrdPath is not given" {
        $repo = New-TestRepo
        try {
            Set-Content -Path (Join-Path $repo "PRD.md") -Value "original requirement text"
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")

            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")

            $exit | Should Be 0
            (Get-Content (Join-Path $repo "PRD.md") -Raw).Trim() | Should Be "original requirement text"
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 classifies a launch failure" {

    # feat/proactive-loop already separates a quota rejection from a Crash, and covers it above with
    # a real rate_limit_event rather than by matching text. What it does not separate is an
    # invocation that never STARTED: the exception is caught, downgraded to a warning, and then
    # counted as a Crash because no status file appeared. Three retries against a missing binary.

    It "exits 4 (FAILED) when the engine binary cannot be started, without burning the watchdog" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|must not be reached")
            Push-Location $repo
            try {
                $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RunPs1,
                          "-ClaudeCommand", "claude-does-not-exist-on-this-machine",
                          "-QuietEngine", "-MaxIterations", "5", "-CrashBackoffSeconds", "0")
                & powershell @args | Out-Null
                $exit = $LASTEXITCODE
            } finally { Pop-Location }

            # 4, not 2: a missing binary cannot appear between attempts. And the queued DONE must be
            # untouched, which is what proves it stopped on the first attempt rather than retrying.
            $exit | Should Be 4
            $remaining = @(Get-Content (Join-Path $repo "queue.txt") | Where-Object { $_.Trim() -ne "" })
            $remaining.Count | Should Be 1
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 iteration budget survives a restart" {

    # $iteration was a `for`-loop variable, local to one process. ESCALATE, a Crash-limit and a
    # FAILED all exit the process expecting to be re-run, so the counter reset to 1 every time -
    # a run that escalated five times got 250 iterations, not 50. The fix counts commits already
    # on the branch instead, because ENGINE.md 6 requires every Iteration to end in exactly one.
    #
    # fake-claude never commits (it only writes STATUS.md), so three real commits are made here to
    # stand in for three iterations a PRIOR process already completed before exiting and being
    # re-run - exactly what a restart after ESCALATE or a Crash-limit looks like on disk.

    It "counts prior commits on the branch instead of restarting the budget at 1" {
        $repo = New-TestRepo
        try {
            Push-Location $repo
            try {
                # New-TestRepo's `git init` may name the initial branch "main" or "master"
                # depending on the machine's config - pin it to "main" so the base this run
                # branched from is known, the way run.ps1 itself resolves it.
                $initialBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
                if ($initialBranch -ne "main") { & git branch -m $initialBranch main | Out-Null }
                & git checkout -b loop/restart-budget --quiet | Out-Null
                1..3 | ForEach-Object {
                    Set-Content -Path (Join-Path $repo "checkpoint-$_.txt") -Value "iteration $_"
                    & git add -A | Out-Null
                    & git -c user.email=test@local -c user.name=LoopTest commit --quiet -m "checkpoint $_" | Out-Null
                }
            } finally { Pop-Location }

            # Three iterations are already checkpointed. A fresh process with MaxIterations 4 must
            # resume at iteration 4, not iteration 1 - so exactly one more CONTINUE exhausts the
            # budget. Unfixed, this queue underruns instead (iteration 2 finds an empty queue,
            # which fake-claude treats as a Crash) and the run stops at exit 2, not exit 5.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|d")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "4")
            $exit | Should Be 5
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "starts a fresh branch at iteration 1, same as today" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|a", "DONE|b")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 protects the human's half of the Decision Queue" {

    # ESCALATION.md (the engine's questions) and DECISIONS.md (the human's answers) used to be one
    # file with two writers and no signal for when the second one could safely write - an answer
    # written the moment the file appeared was caught mid-write by the engine and logged as
    # "recording the partial decision." Splitting the files only holds if the engine truly cannot
    # write the human's half, and only a permission denial makes that mechanical rather than advisory.

    It "denies the engine Edit and Write on DECISIONS.md" {
        $repo = New-TestRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $recorded = (Get-Content $argLog -Raw)
            $recorded | Should Match "--settings"
            $settingsPath = ($recorded -split '--settings\s+')[1].Split(' ')[0].Trim()
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            # `Should Contain` in this Pester version checks a FILE's content, not collection
            # membership - the plain `-contains` operator is the array-membership check here.
            ($settings.permissions.deny -contains "Edit(.harness/run/DECISIONS.md)") | Should Be $true
            ($settings.permissions.deny -contains "Write(.harness/run/DECISIONS.md)") | Should Be $true
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "provisions DECISIONS.md itself, since the engine that needs it cannot create what it cannot write" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $decisionsFile = Join-Path $repo ".harness/run/DECISIONS.md"
            (Test-Path $decisionsFile) | Should Be $true
            (Get-Content $decisionsFile -Raw) | Should Match "DECISIONS"
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "does not touch an existing DECISIONS.md" {
        # A human may already have written an answer before this invocation - provisioning must
        # never overwrite it.
        $repo = New-TestRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/run/DECISIONS.md") -Value "## D-001`n`nApproved - ship it."
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            (Get-Content (Join-Path $repo ".harness/run/DECISIONS.md") -Raw) | Should Match "Approved - ship it."
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 Run Mode switch (ADR-027)" {

    # The mode is how much authority the engine holds, so it lives where the engine cannot write it
    # and where the Skill can rewrite it mid-run without leaving a dirty tree the engine would revert
    # as crash debris (ENGINE.md 6.1): the git directory.

    function Get-ModeFile([string]$repo) { Join-Path $repo ".git/foreman-mode" }
    function Get-RunLogText([string]$repo) {
        Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw
    }

    It "records -Mode Autonomous in the git directory and logs it on every iteration header" {
        $repo = New-TestRepo
        try {
            # Autonomous permissions compile from the real Deny List, as in any installed runtime.
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
            Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/")
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|a", "DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "3", "-Mode", "Autonomous") | Out-Null

            (Get-Content (Get-ModeFile $repo) -TotalCount 1).Trim() | Should Be "Autonomous"
            $headers = @((Get-RunLogText $repo) -split "`n" | Where-Object { $_ -match '=== Iteration' })
            $headers.Count | Should Be 2
            ($headers | Where-Object { $_ -notmatch 'mode Autonomous' }).Count | Should Be 0
            # Never inside the working tree: .harness/run/ existing before bootstrap would skip it.
            (Test-Path (Join-Path $repo ".harness/run/MODE")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "starts a run that has not bootstrapped in Collaborative, whatever the previous run used" {
        $repo = New-TestRepo
        try {
            Set-Content -Path (Get-ModeFile $repo) -Value "Autonomous"
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            (Get-Content (Get-ModeFile $repo) -TotalCount 1).Trim() | Should Be "Collaborative"
            (Get-RunLogText $repo) | Should Match 'mode Collaborative'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "keeps the mode of a run already in progress when relaunched without -Mode" {
        $repo = New-TestRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
            # Autonomous permissions compile from the real Deny List, as in any installed runtime.
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
            Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/")
            Set-Content -Path (Get-ModeFile $repo) -Value "Autonomous"
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            (Get-Content (Get-ModeFile $repo) -TotalCount 1).Trim() | Should Be "Autonomous"
            (Get-RunLogText $repo) | Should Match 'mode Autonomous'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "picks up a mode switch written mid-run at the next iteration, without being overwritten by -Mode" {
        $repo = New-TestRepo
        try {
            # Autonomous permissions compile from the real Deny List, as in any installed runtime.
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
            Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/")
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("SETMODE:Autonomous|CONTINUE|a", "CONTINUE|b", "DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "4", "-Mode", "Collaborative") | Out-Null

            $log = Get-RunLogText $repo
            $log | Should Match 'mode switched: Collaborative -> Autonomous'
            $headers = @($log -split "`n" | Where-Object { $_ -match '=== Iteration' })
            $headers[0] | Should Match 'mode Collaborative'
            $headers[1] | Should Match 'mode Autonomous'
            $headers[2] | Should Match 'mode Autonomous'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "denies the engine Edit and Write on the mode file" {
        $repo = New-TestRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $recorded = (Get-Content $argLog -Raw)
            $settingsPath = ($recorded -split '--settings\s+')[1].Split(' ')[0].Trim()
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            ($settings.permissions.deny -contains "Edit(.git/foreman-mode)") | Should Be $true
            ($settings.permissions.deny -contains "Write(.git/foreman-mode)") | Should Be $true
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "refuses a mode it does not know" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Mode", "Yolo")
            $code | Should Not Be 0
            (Test-Path (Get-ModeFile $repo)) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "run.ps1 dirties the tree with DECISIONS.md, and ENGINE.md 6.1 knows it" {

    # The Runtime provisions DECISIONS.md AFTER the bootstrap Iteration has committed (the directory
    # does not exist before it), so the Iteration after bootstrap always enters on a dirty tree - and
    # ENGINE.md 6.1 used to read any dirty tree as crash debris to salvage or revert. The same holds
    # after every answer the human writes. This pins both halves: the dirt is real, and the spec
    # names it as never-debris.

    It "leaves DECISIONS.md as the only dirt the next Iteration finds after a bootstrap checkpoint" {
        $repo = New-TestRepo
        try {
            $statusLog = Join-Path $env:TEMP ("foreman-status-" + (Split-Path $repo -Leaf) + ".txt")
            $env:FAKE_CLAUDE_GITSTATUSLOG = $statusLog
            # The queue file lives outside the repo so it is not itself dirt.
            $queue = Join-Path $env:TEMP ("foreman-queue-" + (Split-Path $repo -Leaf) + ".txt")
            Set-Content -Path $queue -Value @("COMMIT|CONTINUE|bootstrap", "DONE|ok")
            $env:FAKE_CLAUDE_QUEUE = $queue
            Push-Location $repo
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $RunPs1 -ClaudeCommand $FakeClaude -QuietEngine -MaxIterations 3 | Out-Null
            } finally { Pop-Location }

            $entries = @(Get-Content $statusLog)
            $entries[1] | Should Be "entry: ?? .harness/run/DECISIONS.md"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_GITSTATUSLOG -ErrorAction SilentlyContinue
            Remove-Item $statusLog, $queue -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "has ENGINE.md 6.1 exempt DECISIONS.md from crash-debris recovery" {
        $spec = Get-Content (Join-Path $RepoRootDir ".harness/loop/ENGINE.md") -Raw
        $recover = ($spec -split '## 6\.1 Recover')[1].Split([string[]]@('## 6.2'), 'None')[0]
        $recover | Should Match 'DECISIONS\.md.{0,40}never debris'
    }
}

Describe "Recovery Wrappers (ENGINE.md 14.3, ADR-027)" {

    # Autonomous mode lets the engine take destructive actions only through these wrappers, on the
    # promise that each one is captured first and can be put back. These tests hold them to that:
    # perform the action, then run the recorded restore command and check the original is back.

    $BinDir = Join-Path $RepoRootDir ".harness/loop/bin"

    function Invoke-Wrapper([string]$repo, [string]$name, [string[]]$wrapperArgs) {
        Push-Location $repo
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir $name) @wrapperArgs 2>&1 | Out-Null
            return $LASTEXITCODE
        } finally { Pop-Location }
    }
    function Get-RestoreCommands([string]$repo) {
        # The leading comma stops PowerShell unrolling a one-element array into a bare string.
        return ,@(Get-Content (Join-Path $repo ".harness/run/RECOVERY.md") | Where-Object { $_ -match '^- \*\*Restore:\*\* `(.+)`$' } | ForEach-Object { $Matches[1] })
    }

    It "trash moves a path outside the repo into .harness/trash and its restore command brings it back" {
        $repo = New-TestRepo
        $outside = Join-Path $env:TEMP ("foreman-outside-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        try {
            New-Item -ItemType Directory -Path (Join-Path $outside "sub") -Force | Out-Null
            Set-Content -Path (Join-Path $outside "sub/data.txt") -Value "precious"

            Invoke-Wrapper $repo "foreman-trash.ps1" @("-Path", $outside) | Should Be 0
            (Test-Path $outside) | Should Be $false

            $restore = Get-RestoreCommands $repo
            $restore.Count | Should Be 1
            Invoke-Expression $restore[0]
            (Get-Content (Join-Path $outside "sub/data.txt")) | Should Be "precious"
        } finally {
            Remove-Item $outside -Recurse -Force -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "trash keeps the captured copy out of git and out of the dirty tree" {
        $repo = New-TestRepo
        $outside = Join-Path $env:TEMP ("foreman-outside-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        try {
            Set-Content -Path $outside -Value "x"
            Invoke-Wrapper $repo "foreman-trash.ps1" @("-Path", $outside) | Should Be 0
            Push-Location $repo
            try { $dirty = @(& git status --porcelain --untracked-files=all) } finally { Pop-Location }
            # Only the ledger is new; the trash is excluded through .git/info/exclude.
            ($dirty | Where-Object { $_ -match 'trash' }).Count | Should Be 0
            ($dirty -join ';') | Should Match 'RECOVERY\.md'
        } finally {
            Remove-Item $outside -Force -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "trash refuses the repository itself and a drive root" {
        $repo = New-TestRepo
        try {
            Invoke-Wrapper $repo "foreman-trash.ps1" @("-Path", $repo) | Should Not Be 0
            Invoke-Wrapper $repo "foreman-trash.ps1" @("-Path", "C:\") | Should Not Be 0
            (Test-Path (Join-Path $repo "seed.txt")) | Should Be $true
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "snapshot captures a file whose restore command undoes a later overwrite" {
        $repo = New-TestRepo
        try {
            $db = Join-Path $repo "notes.db"
            Set-Content -Path $db -Value "original rows"
            Invoke-Wrapper $repo "foreman-snapshot.ps1" @("-Path", $db) | Should Be 0
            Set-Content -Path $db -Value "dropped"

            Invoke-Expression (Get-RestoreCommands $repo)[0]
            (Get-Content $db) | Should Be "original rows"
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "push refuses any branch that is not a Loop Branch" {
        $repo = New-TestRepo
        try {
            Invoke-Wrapper $repo "foreman-push.ps1" @() | Should Not Be 0
            (Test-Path (Join-Path $repo ".harness/run/RECOVERY.md")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "push records the remote's previous SHA, and its restore command puts the remote back" {
        $repo = New-TestRepo
        $remote = Join-Path $env:TEMP ("foreman-remote-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        try {
            & git init --bare --quiet $remote 2>$null | Out-Null
            Push-Location $repo
            try {
                & git remote add origin $remote
                & git checkout --quiet -b loop/demo 2>$null
                & git push --quiet origin HEAD:refs/heads/loop/demo 2>$null
                $first = (& git rev-parse HEAD).Trim()
                Set-Content -Path "more.txt" -Value "phase 1"
                & git add -A; & git -c user.email=t@l -c user.name=t commit --quiet -m "phase 1"
            } finally { Pop-Location }

            Invoke-Wrapper $repo "foreman-push.ps1" @() | Should Be 0
            Push-Location $repo
            try {
                ((& git ls-remote origin refs/heads/loop/demo) -split '\s+')[0] | Should Not Be $first
                Invoke-Expression (Get-RestoreCommands $repo)[0] 2>$null
                ((& git ls-remote origin refs/heads/loop/demo) -split '\s+')[0] | Should Be $first
            } finally { Pop-Location }
        } finally {
            Remove-Item $remote -Recurse -Force -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }
}

Describe "run.ps1 in Autonomous mode (ADR-027)" {

    function Get-CompiledSettings([string]$argLog) {
        $recorded = (Get-Content $argLog -Raw)
        $settingsPath = ($recorded -split '--settings\s+')[1].Split(' ')[0].Trim()
        return (Get-Content $settingsPath -Raw | ConvertFrom-Json)
    }
    function Copy-RealBaseline([string]$repo) {
        New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
        Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/baseline.json")
    }
    function Copy-ReportTemplate([string]$repo) {
        New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/templates") -Force | Out-Null
        Copy-Item (Join-Path $RepoRootDir ".harness/loop/templates/RUN-REPORT.template.html") (Join-Path $repo ".harness/loop/templates/")
    }

    It "tells the engine its mode in the prompt, never in the system prompt" {
        $repo = New-TestRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Copy-RealBaseline $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", "Autonomous") | Out-Null
            (Get-Content $argLog -Raw) | Should Match "Run Mode: Autonomous\."
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "compiles every tool as allowed, the Deny List and the immutable rules as denied" {
        $repo = New-TestRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Copy-RealBaseline $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/knowledge") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/knowledge/capabilities.json") -Value '{"entries":[{"intent":"repo-specific denial","deny":["Bash(./deploy.sh*)"]}]}'
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", "Autonomous") | Out-Null

            $settings = Get-CompiledSettings $argLog
            ($settings.permissions.allow -contains "Bash") | Should Be $true
            ($settings.permissions.deny -contains "Bash(git push*)") | Should Be $true
            ($settings.permissions.deny -contains "Bash(npm publish*)") | Should Be $true
            ($settings.permissions.deny -contains "Bash(./deploy.sh*)") | Should Be $true
            ($settings.permissions.deny -contains "Write(.harness/loop/**)") | Should Be $true
            ($settings.permissions.deny -contains "Write(.git/foreman-mode)") | Should Be $true
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "leaves Collaborative permissions exactly as the ledgers say" {
        $repo = New-TestRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Copy-RealBaseline $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $settings = Get-CompiledSettings $argLog
            ($settings.permissions.allow -contains "Bash") | Should Be $false
            ($settings.permissions.allow -contains "Bash(git status*)") | Should Be $true
            ($settings.permissions.deny -contains "Bash(npm publish*)") | Should Be $false
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "ends DONE_PARTIAL with exit 7 and a Run Report that git never sees" {
        $repo = New-TestRepo
        try {
            Copy-RealBaseline $repo; Copy-ReportTemplate $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE_PARTIAL|two criteria await a person")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", "Autonomous")
            $code | Should Be 7

            $report = Get-Content (Join-Path $repo "RUN-REPORT.html") -Raw
            $report | Should Match 'DONE_PARTIAL'
            $report | Should Match 'two criteria await a person'
            $report | Should Not Match '\{\{'
            Push-Location $repo
            try { (@(& git status --porcelain) -join ';') | Should Not Match 'RUN-REPORT' } finally { Pop-Location }
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "renders the ledgers into the report, HTML-escaped" {
        $repo = New-TestRepo
        try {
            Copy-RealBaseline $repo; Copy-ReportTemplate $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
            $tick = [char]96
            Set-Content -Path (Join-Path $repo ".harness/run/ASSUMPTIONS.md") -Value @("# ASSUMPTIONS", "", "## A-001 - chose Room over SQLDelight", "", "- **Tier:** 2", ("- **Revert:** " + $tick + "git revert abc123" + $tick), "", "Evil <script>alert(1)</script> text")
            Set-Content -Path (Join-Path $repo ".harness/run/RECOVERY.md") -Value @("# RECOVERY", "", "## R-001 - deleted", "", "## R-002 - pushed loop/x")
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", "Autonomous") | Out-Null

            $report = Get-Content (Join-Path $repo "RUN-REPORT.html") -Raw
            $report | Should Match 'A-001 - chose Room over SQLDelight'
            $report | Should Match '<code>git revert abc123</code>'
            $report | Should Match '&lt;script&gt;'
            $report | Should Not Match '<script>alert'
            $report | Should Match '<dd>1</dd>'
            $report | Should Match '<dd>2</dd>'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "reads DoD.md from history once the Cleanup Commit has removed .harness/run/" {
        $repo = New-TestRepo
        try {
            Copy-RealBaseline $repo; Copy-ReportTemplate $repo
            Push-Location $repo
            try {
                New-Item -ItemType Directory -Path ".harness/run" -Force | Out-Null
                Set-Content -Path ".harness/run/DoD.md" -Value "criterion 7: notes survive a restart"
                & git add -A; & git -c user.email=t@l -c user.name=t commit --quiet -m "phase"
                & git rm -r --quiet .harness/run; & git -c user.email=t@l -c user.name=t commit --quiet -m "cleanup"
            } finally { Pop-Location }
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|verified")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", "Autonomous") | Out-Null

            (Get-Content (Join-Path $repo "RUN-REPORT.html") -Raw) | Should Match 'criterion 7: notes survive a restart'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "backs off past the crash limit instead of stopping" {
        $repo = New-TestRepo
        try {
            Copy-RealBaseline $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CRASH", "CRASH", "CRASH", "DONE|recovered")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "6", "-MaxConsecutiveCrashes", "2", "-CrashBackoffSeconds", "0", "-Mode", "Autonomous")
            $code | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "still stops at the crash limit in Collaborative mode" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CRASH", "CRASH", "CRASH", "DONE|recovered")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "6", "-MaxConsecutiveCrashes", "2", "-CrashBackoffSeconds", "0")
            $code | Should Be 2
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "stops at the hour budget with exit 5 and still writes the report" {
        $repo = New-TestRepo
        try {
            Copy-RealBaseline $repo; Copy-ReportTemplate $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|a", "CONTINUE|b", "CONTINUE|c")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxHours", "0.00001", "-Mode", "Autonomous")
            $code | Should Be 5
            (Get-Content (Join-Path $repo "RUN-REPORT.html") -Raw) | Should Match 'Hour budget'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "fails cleanly, instead of falling back to Collaborative, when the Deny List is missing" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", "Autonomous")
            $code | Should Be 4
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "writes no report in Collaborative mode" {
        $repo = New-TestRepo
        try {
            Copy-ReportTemplate $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null
            (Test-Path (Join-Path $repo "RUN-REPORT.html")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}
