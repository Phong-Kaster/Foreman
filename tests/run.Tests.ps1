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
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "2")
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
