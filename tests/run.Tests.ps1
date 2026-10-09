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

# The page template the Runtime renders FOREMAN.html from (ADR-034), copied into a test repository.
function Copy-PageTemplate([string]$repo) {
    New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/templates") -Force | Out-Null
    Copy-Item (Join-Path $RepoRootDir ".harness/loop/templates/FOREMAN.template.html") (Join-Path $repo ".harness/loop/templates/")
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

    # Windows PowerShell 5.1 turns a native command's stderr into a terminating error under
    # ErrorActionPreference Stop, `2>$null` or not (ADR-037). Reproduced 2026-10-08: an origin/HEAD
    # pointing at a remote branch that is not there made `git rev-list --count origin/main..HEAD` print
    # an error, and the Runtime exited 1 before the first iteration.
    It "survives a git that prints an error, such as an origin/HEAD pointing at a missing branch" {
        $repo = New-TestRepo
        try {
            Push-Location $repo
            try { & git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>$null | Out-Null } finally { Pop-Location }
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Should Be 0
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

    # Kanso's Run 3, 2026-10-07: one Robolectric test spun for 35 minutes on a preview that never
    # settled; the iteration polled the build log, so the idle bound never fired, and the operator
    # ended the JVM by hand. Stand-ins carry a Gradle test worker's command line: one of this
    # repository, one of another project's, which must be left alone.
    It "ends a Gradle test worker of this repository that runs past its bound, and nobody else's" {
        $repo = New-TestRepo
        $mine = $null; $theirs = $null
        try {
            $marker = "-Dorg.gradle.internal.worker.tmpdir=$repo\app\build\tmp\testDebugUnitTest\work"
            $other = "-Dorg.gradle.internal.worker.tmpdir=D:\elsewhere\app\build\tmp\testDebugUnitTest\work"
            $mine = Start-Process cmd.exe -ArgumentList "/c ping -n 90 127.0.0.1 >nul & rem $marker" -WindowStyle Hidden -PassThru
            $theirs = Start-Process cmd.exe -ArgumentList "/c ping -n 90 127.0.0.1 >nul & rem $other" -WindowStyle Hidden -PassThru
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("LINGER|DONE|a test in the build never finishes")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-ResultGraceSeconds", "8", "-MaxTestWorkerMinutes", "0.02") | Should Be 0
            $mine.HasExited | Should Be $true
            $theirs.HasExited | Should Be $false
            $log = Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw
            $log | Should Match "test guard: ended Gradle test worker $($mine.Id) of this repository"
        } finally {
            foreach ($p in @($mine, $theirs)) { if ($p -and -not $p.HasExited) { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } }
            Remove-TestRepo -TestRepo $repo
        }
    }

    # Kanso's Run 3, 2026-10-07: the engine's result came at 16:04:46, but a background shell it had
    # started sat on a malformed heredoc and kept its process alive. The Runtime would have waited
    # for the 20-minute idle bound before reading a status that was already written.
    It "ends an engine that reported its result but whose process lingers, and keeps its status" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("LINGER|DONE|reported, then a shell kept the process alive")
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-ResultGraceSeconds", "3")
            $clock.Stop()
            $exit | Should Be 0
            ($clock.Elapsed.TotalSeconds -lt 120) | Should Be $true
            $log = Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw
            $log | Should Match 'Timeout \(after-result\) killed the engine process tree'
            $log | Should Match '=== Status: DONE ==='
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

    # Kanso's Run 3, 2026-10-07: the engine process had the owner's phone-control MCP server and
    # browser server as children, and its init event listed 22 MCP servers - the owner's own, their
    # plugins' and their claude.ai connectors, Google Drive among them. Autonomous mode allows every
    # tool not on the Deny List. Measured on the real CLI the same day: --strict-mcp-config with no
    # --mcp-config leaves 0 servers and 0 MCP tools.
    It "gives the engine no MCP server of the person running it, in either Run Mode" {
        foreach ($mode in @("Collaborative", "Autonomous")) {
            $repo = New-TestRepo
            try {
                $argLog = Join-Path $repo "args.txt"
                $env:FAKE_CLAUDE_ARGLOG = $argLog
                # Autonomous mode refuses to start without the Deny List (ADR-027).
                New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
                Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/baseline.json")
                Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
                Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", $mode) | Out-Null
                $recorded = Get-Content $argLog -Raw
                $recorded | Should Match "--strict-mcp-config"
                $recorded | Should Not Match "--mcp-config"
            } finally {
                Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
                Remove-TestRepo -TestRepo $repo
            }
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
            # ESCALATE, not DONE: the bootstrap DoD gate is what this provisioning exists for. This
            # test once used DONE for convenience, which pinned the defect of re-provisioning after
            # a Cleanup Commit (see "leaves no .harness/run/ behind a DONE").
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("ESCALATE|approve the DoD")
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

Describe "run.ps1 pins the top-level Iteration's Model Tier" {

    # The tier map existed to route Workers, and nothing ever applied it to the Iteration itself:
    # --model was passed only when a human supplied -Model, so the Orchestrator - and the Verifier,
    # which POLICIES.md marks "Always Capable, no exception" - ran at whatever the CLI defaults to.
    # Measured on the Calendar-Note alarms run: 979 of 1,215 Orchestrator messages below Capable.

    function Set-TestModels {
        param([string]$TestRepo)
        $json = '{ "fast": { "model": "tier-fast" }, "capable": { "model": "tier-capable" } }'
        Set-Content -Path (Join-Path $TestRepo ".harness/loop/models.json") -Value $json
    }

    # Measured 2026-10-08: by default the engine loaded the operator's six plugins, 92 skills and a
    # SessionStart hook injecting their personal formatting rules; their effortLevel set the engine's.
    It "leaves the operator's own settings out, and takes each tier's effort from models.json" {
        $repo = New-TestRepo
        try {
            Set-Content -Path (Join-Path $repo ".harness/loop/models.json") -Value '{ "fast": { "model": "tier-fast", "effort": "high" }, "capable": { "model": "tier-capable", "effort": "xhigh" } }'
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null
            $recorded = Get-Content $argLog -Raw
            $recorded | Should Match "--setting-sources project,local"
            $recorded | Should Match "--effort high"
            $recorded | Should Match "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "passes no effort when the tier names none, and ignores one that is not an effort level" {
        $repo = New-TestRepo
        try {
            Set-Content -Path (Join-Path $repo ".harness/loop/models.json") -Value '{ "fast": { "model": "tier-fast", "effort": "turbo" }, "capable": { "model": "tier-capable" } }'
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null
            (Get-Content $argLog -Raw) | Should Not Match "--effort"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "dispatches an ordinary iteration at the Fast tier from models.json" {
        $repo = New-TestRepo
        try {
            Set-TestModels -TestRepo $repo
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $recorded = Get-Content $argLog -Raw
            $recorded | Should Match "--model"
            $recorded | Should Match "tier-fast"
            $recorded | Should Not Match "tier-capable"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "raises the Verifier iteration to Capable when STATE.md records a DONE-candidate" {
        $repo = New-TestRepo
        try {
            Set-TestModels -TestRepo $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
            # The exact shape STATE.md uses in the field, bold markers and all.
            Set-Content -Path (Join-Path $repo ".harness/run/STATE.md") -Value "- **DONE-candidate:** yes, re-confirmed this iteration"
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            $recorded = Get-Content $argLog -Raw
            $recorded | Should Match "tier-capable"
            $recorded | Should Not Match "tier-fast"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "does not raise the tier when STATE.md says the run is NOT a DONE-candidate" {
        $repo = New-TestRepo
        try {
            Set-TestModels -TestRepo $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/run/STATE.md") -Value "- **DONE-candidate:** no"
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            (Get-Content $argLog -Raw) | Should Match "tier-fast"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "lets an explicit -Model override the map, since a human overriding it is not it being ignored" {
        $repo = New-TestRepo
        try {
            Set-TestModels -TestRepo $repo
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Model", "human-choice") | Out-Null

            $recorded = Get-Content $argLog -Raw
            $recorded | Should Match "human-choice"
            $recorded | Should Not Match "tier-fast"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "falls back to the CLI default when models.json is absent, rather than failing the run" {
        $repo = New-TestRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2")

            $code | Should Be 0
            (Get-Content $argLog -Raw) | Should Not Match "--model"
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }
}

Describe "run.ps1 records what each iteration cost" {

    # run.ps1 measured every iteration's duration and printed it to the console with Write-Host, so
    # after the Calendar-Note run nothing on disk could say which iteration was slow or what any of
    # them cost. The first question asked of that run had to be answered by parsing a debug log out
    # of %TEMP% that survived only by luck.

    It "writes one row per iteration, with the columns needed to find the expensive one" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|working", "DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "4") | Out-Null

            $telemetry = Join-Path $repo ".harness/TELEMETRY.tsv"
            Test-Path $telemetry | Should Be $true
            $rows = @(Get-Content $telemetry)
            $rows[0] | Should Match "iteration"
            $rows[0] | Should Match "seconds"
            $rows[0] | Should Match "cost_usd"
            # header + one row per iteration
            $rows.Count | Should Be 3
            $rows[1] | Should Match "CONTINUE"
            $rows[2] | Should Match "DONE"
        } finally {
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "keeps the rows outside .harness/run/, which the Cleanup Commit deletes" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null

            Test-Path (Join-Path $repo ".harness/TELEMETRY.tsv") | Should Be $true
            Test-Path (Join-Path $repo ".harness/run/TELEMETRY.tsv") | Should Be $false
        } finally {
            Remove-TestRepo -TestRepo $repo
        }
    }
}

Describe "run.ps1 surfaces an ESCALATE to the human" {

    # ESCALATE stops the loop dead and the run waits on a human who has no idea they are being
    # waited on - about 46 minutes of pure idle across two decisions on the Calendar-Note run. The
    # page built for this, SUGGESTIONS.html's Escalate tab, was the engine's to regenerate and was
    # never regenerated once. The Runtime now renders the queue itself (ADR-034), so the page cannot
    # be stale; these pin that it shows what is pending, and only that.

    It "puts every pending decision on the Needs you tab, and leaves an answered one off" {
        $repo = New-TestRepo
        try {
            Copy-PageTemplate $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/run/ESCALATION.md") -Value @(
                "# DECISION QUEUE", "", "## D-001 - approve the Definition of Done", "", "- **Status:** pending", "",
                "### Question", "", "Approve it?", "", "---", "",
                "## D-002 - which database", "", "- **Status:** pending", "",
                "## D-003 - an old question", "", "- **Status:** archived")
            Set-Content -Path (Join-Path $repo ".harness/run/DECISIONS.md") -Value @("## D-002", "", "Room.")
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("ESCALATE|question")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-NoOpenEscalation") | Should Be 3

            $html = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $html | Should Match 'id="D-001"'
            $html | Should Match 'Approve it\?'
            $html | Should Not Match 'id="D-002"'
            $html | Should Not Match 'id="D-003"'
            $html | Should Match 'data-default-tab="needs"'
            $html | Should Match 'class="count hot">1<'
            $log = Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")
            (Get-Content $log -Raw) | Should Match 'foreman page \(not opened\)'
        } finally {
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "counts the unticked checks an Autonomous run leaves for a person, not the ticked ones" {
        $repo = New-TestRepo
        try {
            Copy-PageTemplate $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/ISSUES.md") -Value @(
                "# ISSUES", "", "## Awaiting a person", "", "Tick these in DECISIONS.md.", "",
                "- [ ] **7 - Empty library.** Open the app with no music.",
                "- [x] **8 - Playing.** Already signed.",
                "- [ ] **9 - Lock screen.** Lock and wake the phone.", "", "## Assumptions", "", "- none")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $html | Should Match 'class="count hot">2<'
            $html | Should Match '<span class="box">'
            $html | Should Match '<span class="box done">'
        } finally {
            Remove-TestRepo -TestRepo $repo
        }
    }

    # The headings Kanso's engines actually wrote: Run 1 "## Awaiting a person (unsigned)", Run 3 a
    # "### Awaiting a person, Run 3" nested in another section. The page counted none of them.
    It "counts every Awaiting-a-person section as the engine titles it, and a nested one once" {
        $repo = New-TestRepo
        try {
            Copy-PageTemplate $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/ISSUES.md") -Value @(
                "# ISSUES", "", "## Awaiting a person (unsigned)", "",
                "- [ ] Run 1 12 - the splash, then Home",
                "- [ ] Run 1 19 - the accent follows the wallpaper", "",
                "## Awaiting a person", "",
                "- [ ] 5 Gallery scroll with 2,000 photos", "",
                "### Awaiting a person, Run 3", "",
                "- [ ] Run 3 10 - the app looks as it did after Run 2", "",
                "## Review notes recorded, not fixed", "", "- T-002: a probe class lives in main")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $html | Should Match 'class="count hot">4<'
            $html | Should Match 'the accent follows the wallpaper'
            $html | Should Match 'looks as it did after Run 2'
        } finally {
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "still exits 3 when the engine queued nothing it could name" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("ESCALATE|question")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-NoOpenEscalation") | Should Be 3
        } finally {
            Remove-TestRepo -TestRepo $repo
        }
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

    It "leaves only Runtime-written files as the dirt the next Iteration finds after a bootstrap checkpoint" {
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

            # DECISIONS.md is provisioned after the bootstrap commit (ADR-025) and TELEMETRY.tsv gains a
            # row after every Iteration (ADR-029): both are Runtime writes the engine must commit, never
            # crash debris. Anything else here would be dirt ENGINE.md 6.1 does not account for.
            $dirt = @(((Get-Content $statusLog)[1] -replace '^entry: ', '') -split ';' | Where-Object { $_ })
            ($dirt -contains "?? .harness/run/DECISIONS.md") | Should Be $true
            @($dirt | Where-Object { $_ -notin @("?? .harness/run/DECISIONS.md", "?? .harness/TELEMETRY.tsv", " M .harness/TELEMETRY.tsv") }).Count | Should Be 0
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_GITSTATUSLOG -ErrorAction SilentlyContinue
            Remove-Item $statusLog, $queue -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "has ENGINE.md 6.1 exempt DECISIONS.md and TELEMETRY.tsv from crash-debris recovery" {
        $spec = Get-Content (Join-Path $RepoRootDir ".harness/loop/ENGINE.md") -Raw
        $recover = ($spec -split '## 6\.1 Recover')[1].Split([string[]]@('## 6.2'), 'None')[0]
        $recover | Should Match 'never debris'
        $recover | Should Match 'DECISIONS\.md'
        $recover | Should Match 'TELEMETRY\.tsv'
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
    function Copy-ReportTemplate([string]$repo) { Copy-PageTemplate $repo }

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

    It "ends DONE_PARTIAL with exit 7 and a page that git never sees" {
        $repo = New-TestRepo
        try {
            Copy-RealBaseline $repo; Copy-ReportTemplate $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE_PARTIAL|two criteria await a person")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", "Autonomous")
            $code | Should Be 7

            $report = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $report | Should Match 'DONE_PARTIAL'
            $report | Should Match 'two criteria await a person'
            $report | Should Not Match '\{\{'
            Push-Location $repo
            try { (@(& git status --porcelain) -join ';') | Should Not Match 'FOREMAN' } finally { Pop-Location }
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

            $report = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
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

            (Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8) | Should Match 'criterion 7: notes survive a restart'
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

    It "stops at the hour budget with exit 5 and still writes the page" {
        $repo = New-TestRepo
        try {
            Copy-RealBaseline $repo; Copy-ReportTemplate $repo
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CONTINUE|a", "CONTINUE|b", "CONTINUE|c")
            $code = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxHours", "0.00001", "-Mode", "Autonomous")
            $code | Should Be 5
            (Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8) | Should Match 'Hour budget'
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

    It "writes the page in Collaborative mode too, without the Autonomous warning, and removes the pages it replaced" {
        $repo = New-TestRepo
        try {
            Copy-ReportTemplate $repo
            # Pages the Runtime used to write, excluded from git: left in place they would be read as current.
            Set-Content -Path (Join-Path $repo "RUN-REPORT.html") -Value "<html>an old report</html>"
            Set-Content -Path (Join-Path $repo "DOD.html") -Value "<html>an old checklist</html>"
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null
            $html = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $html | Should Match 'class="warn collaborative"'
            $html | Should Match 'data-default-tab="run"'
            $html | Should Not Match '\{\{'
            (Test-Path (Join-Path $repo "RUN-REPORT.html")) | Should Be $false
            (Test-Path (Join-Path $repo "DOD.html")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "The spec asks what the PRD makes unnecessary (ADR-028)" {

    # Calendar-Note loop/music-player, 2026-09-24: a music player built on a pristine skeleton kept
    # its Home and Setting screens, a posts API, a weather API and location / exact-alarm permissions -
    # 61 of 99 Kotlin files unreachable from the feature - because every DoD criterion asserted that
    # something existed and none asserted that something was gone. These pin the four places that
    # now ask the question, so a later edit cannot quietly drop one.

    $Spec = Get-Content (Join-Path $RepoRootDir ".harness/loop/ENGINE.md") -Raw
    $Policies = Get-Content (Join-Path $RepoRootDir ".harness/loop/POLICIES.md") -Raw
    $Reviewer = Get-Content (Join-Path $RepoRootDir ".harness/loop/agents/loop-reviewer.md") -Raw
    $DodTemplate = Get-Content (Join-Path $RepoRootDir ".harness/loop/templates/DoD.template.md") -Raw

    It "has bootstrap classify the repository as a template or a product" {
        $bootstrap = ($Spec -split '# 5\. Bootstrap Iteration')[1].Split([string[]]@('# 6. The Iteration'), 'None')[0]
        $bootstrap | Should Match '\*\*template\*\*'
        $bootstrap | Should Match '\*\*product\*\*'
    }

    It "has bootstrap put a Removals section of absence criteria in the DoD" {
        $bootstrap = ($Spec -split '# 5\. Bootstrap Iteration')[1].Split([string[]]@('# 6. The Iteration'), 'None')[0]
        $bootstrap | Should Match 'Removals section'
        $bootstrap | Should Match 'absence'
        $DodTemplate | Should Match '## Removals'
    }

    It "never lets an Autonomous run settle whether a feature stays as an Assumption" {
        $autonomous = ($Spec -split '## 14\.1 Decisions become assumptions')[1].Split([string[]]@('## 14.2'), 'None')[0]
        $autonomous | Should Match 'never an Assumption'
    }

    It "treats dead code as a review finding, in the policy and in the reviewer it is handed to" {
        $Policies | Should Match 'Dead code is a finding'
        $Reviewer | Should Match 'Dead code'
    }
}

Describe "run.ps1 leaves no .harness/run/ behind a DONE" {

    # Calendar-Note, twice: after b5691ce and after bb00487 (loop/music-player-v2, 2026-09-25) the
    # Cleanup Commit removed .harness/run/, the engine then wrote STATUS.md - its last act, which
    # recreates the directory - and the Runtime, having read DONE and deleted STATUS.md, called
    # Ensure-DecisionsFile, found the directory and copied the template back in. The branch that
    # should have been merge-ready had an untracked .harness/run/DECISIONS.md, and ENGINE.md 5 reads
    # "no .harness/run/" as the signal to bootstrap, so the next goal on the branch was told the
    # opposite. The fake engine below does exactly that last act: it writes STATUS.md into a
    # .harness/run/ that did not exist until it wrote it.

    It "does not re-provision DECISIONS.md, or leave the directory STATUS.md recreated, after DONE" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|verified; Cleanup Commit written")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null
            (Test-Path (Join-Path $repo ".harness/run/DECISIONS.md")) | Should Be $false
            (Test-Path (Join-Path $repo ".harness/run")) | Should Be $false
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "leaves a .harness/run/ that still holds files alone after DONE" {
        $repo = New-TestRepo
        try {
            # If the engine reported DONE without cleaning up, what is left is its to explain. The
            # Runtime removes only the empty directory STATUS.md recreated, never files. (The directory
            # existed before the invocation, so DECISIONS.md is provisioned before it, as for any run
            # in progress - that is not what this checks.)
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/run/STATE.md") -Value "left behind"
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Out-Null
            (Test-Path (Join-Path $repo ".harness/run/STATE.md")) | Should Be $true
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "The library-docs pack (ADR-032)" {

    # Context7 is reached through its CLI, by the engine only, and only after a failure names a
    # library's API. By the human's decision it is on by default: the baseline grants the two read
    # commands in every repository and both Run Modes, and a repository switches it off with a deny rule.

    $Pack = Join-Path $RepoRootDir "skills/knowledge/general/library-docs"
    $Policies = Get-Content (Join-Path $RepoRootDir ".harness/loop/POLICIES.md") -Raw
    $Brief = Get-Content (Join-Path $RepoRootDir ".harness/loop/templates/WORKER-BRIEF.template.md") -Raw
    $CtxRules = @("Bash(CTX7_TELEMETRY_DISABLED=1 npx -y ctx7 library *)", "Bash(CTX7_TELEMETRY_DISABLED=1 npx -y ctx7 docs *)")

    function Get-CompiledSettingsFor([string]$repo, [string[]]$extra) {
        $argLog = Join-Path $repo "args.txt"
        $env:FAKE_CLAUDE_ARGLOG = $argLog
        New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
        Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/")
        Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
        Invoke-RunPs1 -TestRepo $repo -ExtraArgs (@("-MaxIterations", "2") + $extra) | Out-Null
        Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
        $recorded = Get-Content $argLog -Raw
        $settingsPath = ($recorded -split '--settings\s+')[1].Split(' ')[0].Trim()
        return (Get-Content $settingsPath -Raw | ConvertFrom-Json)
    }

    It "ships a SKILL.md" {
        (Test-Path (Join-Path $Pack "SKILL.md")) | Should Be $true
    }

    It "grants only ctx7 library and ctx7 docs in the baseline, never setup, login or remove" {
        $baseline = Get-Content (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") -Raw | ConvertFrom-Json
        $ctx = @($baseline.entries | ForEach-Object { $_.allow } | Where-Object { $_ -match 'ctx7' })
        $ctx.Count | Should Be 2
        ($ctx | Where-Object { $CtxRules -notcontains $_ }).Count | Should Be 0
        ($ctx | Where-Object { $_ -match 'setup|login|remove' }).Count | Should Be 0
    }

    It "reaches a Collaborative run with no grant from the repository" {
        $repo = New-TestRepo
        try {
            $settings = Get-CompiledSettingsFor $repo @()
            foreach ($r in $CtxRules) { ($settings.permissions.allow -contains $r) | Should Be $true }
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "is switched off in a Collaborative run by a deny rule in the repository's own ledger" {
        $repo = New-TestRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/knowledge") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/knowledge/capabilities.json") -Value '{"entries":[{"intent":"no lookups leave this machine","deny":["Bash(CTX7_TELEMETRY_DISABLED=1 npx -y ctx7 *)"]}]}'
            $settings = Get-CompiledSettingsFor $repo @()
            ($settings.permissions.deny -contains "Bash(CTX7_TELEMETRY_DISABLED=1 npx -y ctx7 *)") | Should Be $true
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "is consulted from the retry policy, which carries the commands and names a skill that exists" {
        $Policies | Should Match 'library-docs'
        $Policies | Should Match 'third-party library'
        # The command forms are in the policy itself: in a consumer repository the pack is an
        # installed skill, not a path under skills/knowledge/, and may not be installed at all.
        $Policies | Should Match 'npx -y ctx7 library'
        $Policies | Should Match 'ctx7 docs'
        $Policies | Should Match 'every repository and both Run Modes'
        # The first check (context7-check-report.html) found a task-shaped query reaching the fix only
        # by luck; the policy now says to ask about the symbol that failed.
        $Policies | Should Match 'symbol that failed'
        (Test-Path (Join-Path $RepoRootDir "skills/knowledge/general/library-docs/SKILL.md")) | Should Be $true
    }

    It "reaches a Worker only through the Brief, since Workers have no network" {
        $Brief | Should Match '## Library documentation'
        $worker = Get-Content (Join-Path $RepoRootDir ".harness/loop/agents/loop-worker.md") -Raw
        $worker | Should Not Match '(?m)^tools:.*Bash'
    }
}

Describe "The /foreman skill brings Foreman's skills up to date before every launch" {

    # A stale installed skill reverts a consumer's .harness/loop/ to an older runtime on every /foreman
    # (distributable-parity.md). The skill now updates Foreman's own skills first. The updater prints
    # "Updated" even when nothing changed - measured 2026-09-29 - so the decision must come from git.

    $Skill = Get-Content (Join-Path $RepoRootDir "skills/engineering/foreman/SKILL.md") -Raw

    It "updates only skills whose source is Phong-Kaster/Foreman, found in skills-lock.json" {
        $Skill | Should Match '## 0b\. Bring Foreman''s skills up to date'
        $Skill | Should Match 'skills-lock\.json'
        $Skill | Should Match 'Phong-Kaster/Foreman'
        $Skill | Should Match 'never the repository''s other skills'
    }

    It "decides from git, not from the updater's output, and commits a change before syncing" {
        $Skill | Should Match 'ignore the output'
        $Skill | Should Match 'Decide from git'
        $Skill | Should Match 'chore\(foreman\): update Foreman skills'
    }

    It "never blocks a run on the check, and skips it for mode switches" {
        $Skill | Should Match 'Never block a run on an update check'
        $Skill | Should Match 'Skip this step for the `mode`'
    }

    It "is reached from step 0 before the runtime is synced" {
        $zeroB = $Skill.IndexOf('## 0b.')
        $one = $Skill.IndexOf('## 1. Locate the installed runtime files')
        ($zeroB -gt 0 -and $zeroB -lt $one) | Should Be $true
        $Skill | Should Match 'Continue to step 0b'
    }
}

Describe "The device wrapper acts only on the debug build of this repository (ADR-033)" {

    # adb is denied to the engine in both Run Modes; foreman-device.ps1 is the only route to a device.
    # Decided by the human, 2026-09-30: the engine may clear, grant, revoke and drive the app it is
    # building, and nothing else - no other app, no device setting. These tests run the wrapper against
    # tests/fixtures/fake-adb.ps1 and read its call log, so "refused" means the device never heard of it.

    $Device = Join-Path $RepoRootDir ".harness/loop/bin/foreman-device.ps1"
    $FakeAdb = Join-Path $PSScriptRoot "fixtures\fake-adb.ps1"

    $OwnScreen = @'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example.app" content-desc="" focused="false" bounds="[0,0][1080,2400]"><node index="0" text="Play" resource-id="com.example.app:id/play" class="android.widget.Button" package="com.example.app" content-desc="" focused="false" bounds="[440,1100][640,1300]" /><node index="1" text="" resource-id="com.example.app:id/list" class="android.view.View" package="com.example.app" content-desc="" focused="false" bounds="[0,200][1080,1000]" /></node><node index="1" text="" resource-id="com.android.systemui:id/home_button" class="android.widget.ImageView" package="com.android.systemui" content-desc="Home" focused="false" bounds="[480,2300][600,2400]" /></hierarchy>
'@
    $DialogScreen = @'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="Allow Music to send you notifications?" resource-id="com.android.permissioncontroller:id/permission_message" class="android.widget.TextView" package="com.android.permissioncontroller" content-desc="" focused="false" bounds="[100,1300][980,1400]" /><node index="1" text="Allow" resource-id="com.android.permissioncontroller:id/permission_allow_button" class="android.widget.Button" package="com.android.permissioncontroller" content-desc="" focused="false" bounds="[100,1500][980,1600]" /></hierarchy>
'@
    $ForeignScreen = @'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="Secret message from Bob" resource-id="com.whatsapp:id/message" class="android.widget.TextView" package="com.whatsapp" content-desc="" focused="false" bounds="[0,0][1080,2400]" /></hierarchy>
'@

    function New-AppRepo([switch]$Unbuilt) {
        $repo = New-TestRepo
        # What a Gradle debug build leaves behind, plus the test APK, which is not the app.
        $testDir = Join-Path $repo "app/build/outputs/apk/androidTest/debug"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Set-Content -Path (Join-Path $testDir "output-metadata.json") -Value '{"applicationId":"com.example.app.test","variantName":"debugAndroidTest","elements":[{"outputFile":"app-debug-androidTest.apk"}]}'
        if (-not $Unbuilt) {
            $debugDir = Join-Path $repo "app/build/outputs/apk/debug"
            New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
            Set-Content -Path (Join-Path $debugDir "output-metadata.json") -Value '{"applicationId":"com.example.app","variantName":"debug","elements":[{"outputFile":"app-debug.apk"}]}'
            Set-Content -Path (Join-Path $debugDir "app-debug.apk") -Value "apk"
        }
        $bin = Join-Path $repo "fakebin"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -Path (Join-Path $bin "adb.cmd") -Value "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$FakeAdb`" %*`r`nexit /b %ERRORLEVEL%" -Encoding ASCII
        $env:FAKE_ADB_LOG = Join-Path $repo "adb-calls.txt"
        return $repo
    }
    function Invoke-Device([string]$repo, [string[]]$deviceArgs) {
        $savedPath = $env:PATH
        $env:PATH = (Join-Path $repo "fakebin") + ";" + $env:PATH
        Push-Location $repo
        try {
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Device @deviceArgs 2>$null | Out-String
            return @{ Code = $LASTEXITCODE; Out = $out }
        } finally { Pop-Location; $env:PATH = $savedPath }
    }
    function Get-AdbCalls([string]$repo) {
        $log = Join-Path $repo "adb-calls.txt"
        if (-not (Test-Path $log)) { return "" }
        return (Get-Content $log) -join "`n"
    }
    function Set-Screen([string]$repo, [string]$xml, [string]$focus = "com.example.app") {
        $path = Join-Path $repo "screen.xml"
        Set-Content -Path $path -Value $xml -Encoding UTF8
        $env:FAKE_ADB_UIXML = $path
        $env:FAKE_ADB_FOCUS = $focus
    }
    function Clear-FakeAdb([string]$repo) {
        foreach ($v in @("FAKE_ADB_LOG", "FAKE_ADB_DEVICES", "FAKE_ADB_INSTALLED", "FAKE_ADB_DEBUGGABLE", "FAKE_ADB_FOCUS", "FAKE_ADB_UIXML", "FAKE_ADB_NOTIF", "FAKE_ADB_MEDIA")) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
        Remove-TestRepo -TestRepo $repo
    }

    It "clears the data of the debug package this repository built, and of nothing else" {
        $repo = New-AppRepo
        try {
            (Invoke-Device $repo @("-Op", "clear")).Code | Should Be 0
            (Get-AdbCalls $repo) | Should Match '(?m)^-s FAKE123 shell pm clear com\.example\.app$'

            (Invoke-Device $repo @("-Op", "clear", "-Package", "com.android.settings")).Code | Should Be 3
            (Invoke-Device $repo @("-Op", "grant", "-Package", "com.whatsapp", "-Permission", "android.permission.CAMERA")).Code | Should Be 3
            (Get-AdbCalls $repo) | Should Not Match 'settings|whatsapp'
        } finally { Clear-FakeAdb $repo }
    }

    It "refuses a package the device does not report as an installed debug build" {
        $repo = New-AppRepo
        try {
            $env:FAKE_ADB_DEBUGGABLE = "0"
            (Invoke-Device $repo @("-Op", "clear")).Code | Should Be 3
            $env:FAKE_ADB_DEBUGGABLE = "1"; $env:FAKE_ADB_INSTALLED = "0"
            (Invoke-Device $repo @("-Op", "uninstall")).Code | Should Be 3
            (Get-AdbCalls $repo) | Should Not Match 'pm clear|uninstall'
        } finally { Clear-FakeAdb $repo }
    }

    It "refuses everything until a debug APK exists, and never takes the test APK for the app" {
        $repo = New-AppRepo -Unbuilt
        try {
            (Invoke-Device $repo @("-Op", "clear")).Code | Should Be 3
            (Invoke-Device $repo @("-Op", "clear", "-Package", "com.example.app.test")).Code | Should Be 3
            (Get-AdbCalls $repo) | Should Not Match 'pm clear'
        } finally { Clear-FakeAdb $repo }
    }

    It "has no operation that changes a device setting, the clock or the shade" {
        $repo = New-AppRepo
        try {
            foreach ($op in @("settings", "date", "shell", "statusbar")) {
                (Invoke-Device $repo @("-Op", $op)).Code | Should Not Be 0
            }
            (Get-AdbCalls $repo) | Should Not Match 'settings put|date|statusbar'
        } finally { Clear-FakeAdb $repo }
    }

    It "taps a control of the app, found by id, at the centre of its bounds" {
        $repo = New-AppRepo
        try {
            Set-Screen $repo $OwnScreen
            (Invoke-Device $repo @("-Op", "tap", "-ResourceId", "com.example.app:id/play")).Code | Should Be 0
            (Get-AdbCalls $repo) | Should Match '(?m)^-s FAKE123 shell input tap 540 1200$'
        } finally { Clear-FakeAdb $repo }
    }

    It "refuses to tap the navigation bar, or anything another package owns, and takes no coordinates" {
        $repo = New-AppRepo
        try {
            Set-Screen $repo $OwnScreen
            (Invoke-Device $repo @("-Op", "tap", "-ContentDesc", "Home")).Code | Should Be 3
            (Invoke-Device $repo @("-Op", "tap")).Code | Should Be 3
            (Get-AdbCalls $repo) | Should Not Match 'input tap'
        } finally { Clear-FakeAdb $repo }
    }

    It "taps the system permission dialog the app raised" {
        $repo = New-AppRepo
        try {
            Set-Screen $repo $DialogScreen "com.android.permissioncontroller"
            (Invoke-Device $repo @("-Op", "tap", "-ResourceId", "com.android.permissioncontroller:id/permission_allow_button")).Code | Should Be 0
            (Get-AdbCalls $repo) | Should Match 'shell input tap 540 1550'
        } finally { Clear-FakeAdb $repo }
    }

    It "reads nothing while another app holds the screen, and drops a dump that caught one" {
        $repo = New-AppRepo
        try {
            Set-Screen $repo $ForeignScreen "com.whatsapp"
            (Invoke-Device $repo @("-Op", "dump")).Code | Should Be 3
            (Invoke-Device $repo @("-Op", "key", "-Key", "BACK")).Code | Should Be 3
            (Get-AdbCalls $repo) | Should Not Match 'uiautomator|keyevent'

            # Focus says the app; the screen changed before the dump was read.
            Set-Screen $repo $ForeignScreen "com.example.app"
            $r = Invoke-Device $repo @("-Op", "dump")
            $r.Code | Should Be 3
            $r.Out | Should Not Match 'Secret message'
        } finally { Clear-FakeAdb $repo }
    }

    It "keeps only the app's own notifications and media sessions" {
        $repo = New-AppRepo
        try {
            $notif = Join-Path $repo "notif.txt"
            Set-Content -Path $notif -Value @(
                "  Notification List:",
                "    NotificationRecord(0x0a1 : pkg=com.example.app user=UserHandle{0} id=1 tag=null importance=2 key=0|com.example.app|1|null|10123: Notification(channel=playback))",
                "      uid=10123 userId=0",
                "      android.title=String (Song One)",
                "    NotificationRecord(0x0b2 : pkg=com.whatsapp user=UserHandle{0} id=7 tag=null importance=4 key=0|com.whatsapp|7|null|10200: Notification(channel=msg))",
                "      uid=10200 userId=0",
                "      android.title=String (Secret message from Bob)")
            $media = Join-Path $repo "media.txt"
            Set-Content -Path $media -Value @(
                "  Sessions Stack - have 2 sessions:",
                "    MusicService com.example.app/MusicService (userId=0)",
                "      ownerPid=123, ownerUid=10123, userId=0",
                "      package=com.example.app",
                "      state=PlaybackState {state=PLAYING(3), position=0}",
                "    Spotify com.spotify.music/spotify (userId=0)",
                "      ownerPid=456, ownerUid=10300, userId=0",
                "      package=com.spotify.music",
                "      state=PlaybackState {state=PAUSED(2)}")
            $env:FAKE_ADB_NOTIF = $notif; $env:FAKE_ADB_MEDIA = $media

            $n = Invoke-Device $repo @("-Op", "notifications")
            $n.Out | Should Match 'Song One'
            $n.Out | Should Not Match 'Secret message'
            $m = Invoke-Device $repo @("-Op", "media-session")
            $m.Out | Should Match 'PLAYING\(3\)'
            $m.Out | Should Not Match 'spotify'
        } finally { Clear-FakeAdb $repo }
    }

    It "refuses shell syntax in a permission name or in typed text" {
        $repo = New-AppRepo
        try {
            Set-Screen $repo $OwnScreen
            (Invoke-Device $repo @("-Op", "grant", "-Permission", "android.permission.CAMERA;pm clear com.whatsapp")).Code | Should Be 3
            (Invoke-Device $repo @("-Op", "text", "-Value", "hi;settings put global adb_enabled 0")).Code | Should Be 3
            (Get-AdbCalls $repo) | Should Not Match 'pm grant|input text'
        } finally { Clear-FakeAdb $repo }
    }

    It "installs only an APK this repository built for the app" {
        $repo = New-AppRepo
        try {
            $stray = Join-Path $repo "other.apk"
            Set-Content -Path $stray -Value "apk"
            (Invoke-Device $repo @("-Op", "install", "-Apk", $stray)).Code | Should Be 3
            (Get-AdbCalls $repo) | Should Not Match '(?m)^-s \S+ install'

            (Invoke-Device $repo @("-Op", "install")).Code | Should Be 0
            (Get-AdbCalls $repo) | Should Match 'install -r -t .*app-debug\.apk'
        } finally { Clear-FakeAdb $repo }
    }

    It "run.ps1 denies adb itself in both Run Modes and grants the wrapper" {
        foreach ($mode in @("Collaborative", "Autonomous")) {
            $repo = New-TestRepo
            try {
                $argLog = Join-Path $repo "args.txt"
                $env:FAKE_CLAUDE_ARGLOG = $argLog
                New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
                Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/baseline.json")
                Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
                Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", $mode) | Out-Null

                $settingsPath = ((Get-Content $argLog -Raw) -split '--settings\s+')[1].Split(' ')[0].Trim()
                $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
                foreach ($rule in @("Bash(adb *)", "Bash(*/adb *)", "Bash(*adb.exe *)", "Bash(*platform-tools*)", "Bash(bash -c*adb*)", "Bash(powershell*adb *)", "mcp__android-agent")) {
                    ($settings.permissions.deny -contains $rule) | Should Be $true
                }
                if ($mode -eq "Collaborative") {
                    ($settings.permissions.allow -contains "Bash(powershell -NoProfile -File .harness/loop/bin/foreman-device.ps1 *)") | Should Be $true
                }
            } finally {
                Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
                Remove-TestRepo -TestRepo $repo
            }
        }
    }
}

Describe "FOREMAN.html shows every Definition of Done, newest first" {

    # Asked for by the human, 2026-10-02: DoD.md stays the source, but the checklist is read on a page,
    # numbered and grouped by category, with the newest DoD first and the earlier ones below it. The
    # earlier ones exist only in git - the Cleanup Commit deletes .harness/run/ - so the page is rebuilt
    # from history. Checked by hand against Calendar-Note's seven DoDs before these were written.

    $DodPageTemplate = Join-Path $RepoRootDir ".harness/loop/templates/FOREMAN.template.html"
    # "Nghe duoc nhac" with its Vietnamese marks, built from code points: this file is not UTF-8 to
    # Windows PowerShell, and git's console output was not either until the page asked for UTF-8.
    $Vietnamese = "Nghe " + [char]0x0111 + [char]0x01B0 + [char]0x1EE3 + "c nh" + [char]0x1EA1 + "c"

    function New-DodRepo {
        $repo = New-TestRepo
        New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/templates") -Force | Out-Null
        Copy-Item $DodPageTemplate (Join-Path $repo ".harness/loop/templates/FOREMAN.template.html")
        return $repo
    }
    function Set-Dod([string]$repo, [string]$text) {
        $path = Join-Path $repo ".harness/run/DoD.md"
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
    function Save-All([string]$repo, [string]$message, [string]$date) {
        Push-Location $repo
        try {
            $env:GIT_AUTHOR_DATE = $date; $env:GIT_COMMITTER_DATE = $date
            & git add -A 2>$null | Out-Null
            & git -c user.email=test@local -c user.name=LoopTest commit --quiet -m $message 2>$null | Out-Null
        } finally {
            Remove-Item Env:\GIT_AUTHOR_DATE, Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
            Pop-Location
        }
    }
    function Get-DodPage([string]$repo) {
        $page = Join-Path $repo "FOREMAN.html"
        if (-not (Test-Path $page)) { return "" }
        return [System.IO.File]::ReadAllText($page, [System.Text.Encoding]::UTF8)
    }
    $SecondGoal = @"
# Definition of Done - second goal

## Status

- [ ] APPROVED - approve via the pending D-001 in .harness/run/ESCALATION.md

## Acceptance Criteria

### Behaviour

1. [machine] tapping a song plays it
2. [human] you hear the song

### Permissions the user is asked for

3. [machine] the app asks for notifications on first play

## Removals

R1. [machine] the demo screen is gone
"@

    It "puts the current run's DoD first, read from disk, then earlier ones from git, newest first" {
        $repo = New-DodRepo
        try {
            $argLog = Join-Path $repo "args.txt"
            $env:FAKE_CLAUDE_ARGLOG = $argLog
            Set-Dod $repo "# Definition of Done - first goal`n`n## Acceptance Criteria`n`n1. [machine] $Vietnamese works`n"
            Save-All $repo "loop(bootstrap): plan the first goal" "2026-09-01T10:00:00+07:00"
            Remove-Item (Join-Path $repo ".harness/run") -Recurse -Force
            Save-All $repo "loop(done): the first goal ships" "2026-09-02T10:00:00+07:00"
            Set-Dod $repo $SecondGoal
            Save-All $repo "loop(bootstrap): plan the second goal" "2026-09-10T10:00:00+07:00"
            # A person's edit before approving: on disk, in no commit yet.
            Set-Dod $repo ($SecondGoal.Replace("3. [machine] the app asks", "4. [human] an edit nobody committed`n3. [machine] the app asks"))

            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-DodPage $repo
            ($html.IndexOf("second goal") -ge 0 -and $html.IndexOf("second goal") -lt $html.IndexOf("first goal")) | Should Be $true
            $html | Should Match 'an edit nobody committed'
            $html.Contains($Vietnamese) | Should Be $true
            $html | Should Match 'the first goal ships'
            $html | Should Match 'badge current'
            $html | Should Match 'badge closed'
            $html | Should Not Match '\{\{'
            (Test-Path $argLog) | Should Be $false
            Push-Location $repo
            try { (@(& git status --porcelain) -join ';') | Should Not Match 'FOREMAN\.html' } finally { Pop-Location }
        } finally {
            Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "keeps each criterion's own number under its category, with its Verification Class" {
        $repo = New-DodRepo
        try {
            Set-Dod $repo $SecondGoal
            Save-All $repo "loop(bootstrap): plan the second goal" "2026-09-10T10:00:00+07:00"
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-DodPage $repo
            # An <ol> would have restarted at 1 under the second heading.
            $permissions = $html.IndexOf('data-en="Permissions the user is asked for"')
            ($permissions -gt 0 -and $html.IndexOf('<span class="num">3</span>') -gt $permissions) | Should Be $true
            $html | Should Match '<span class="num">R1</span>'
            $html | Should Match '<span class="cls human">human</span>you hear the song'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "opens the page at the approval gate while the DoD waits, and counts it approved once DECISIONS.md answers" {
        $repo = New-DodRepo
        $leaf = Split-Path $repo -Leaf
        try {
            Set-Dod $repo $SecondGoal
            Save-All $repo "loop(bootstrap): plan the second goal" "2026-09-10T10:00:00+07:00"
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("ESCALATE|approve the Definition of Done")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-NoOpenEscalation") | Should Be 3
            (Get-Content (Join-Path $env:TEMP "loop-run-$leaf.log") -Raw) | Should Match 'foreman page \(not opened\)'
            (Get-DodPage $repo) | Should Match 'badge awaiting'

            Set-Content -Path (Join-Path $repo ".harness/run/DECISIONS.md") -Value "## D-001`n`nApproved as written."
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-DodPage $repo
            $html | Should Match 'badge approved'
            $html | Should Not Match 'badge awaiting'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    # Kanso's first gate, 2026-10-05: DECISIONS.md is provisioned from a template that already carries
    # an empty "## D-001" over a placeholder comment. The page counted that heading as the answer, so
    # it showed nothing waiting and the DoD "Approved" while D-001 was pending. The test above missed
    # it because its repository had no template, so the provisioned file had no heading at all.
    It "does not take the provisioned, empty D-001 heading for an answer" {
        $repo = New-DodRepo
        try {
            Copy-Item (Join-Path $RepoRootDir ".harness/loop/templates/DECISIONS.template.md") (Join-Path $repo ".harness/loop/templates/")
            Set-Dod $repo $SecondGoal
            Save-All $repo "loop(bootstrap): plan the second goal" "2026-09-10T10:00:00+07:00"
            # The entry Kanso's bootstrap queued, in its shape: the fake ESCALATE writes only STATUS.md.
            Set-Content -Path (Join-Path $repo ".harness/run/ESCALATION.md") -Value @(
                "# ESCALATION", "", "---", "", "## D-001 - Approve the Definition of Done", "",
                "- **Status:** pending", "- **Type:** DoD approval", "", "### Question", "",
                "Approve ``.harness/run/DoD.md``.")
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("ESCALATE|approve the Definition of Done")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-NoOpenEscalation") | Should Be 3
            $decisions = Join-Path $repo ".harness/run/DECISIONS.md"
            (Get-Content $decisions -Raw) | Should Match '(?m)^## D-001'
            $html = Get-DodPage $repo
            $html | Should Match 'badge awaiting'
            $html | Should Match 'class="count hot">1<'
            $html | Should Match 'data-default-tab="needs"'

            $text = (Get-Content $decisions -Raw) -replace '<!-- Your decision and rationale\. -->', 'Approved as written.'
            [System.IO.File]::WriteAllText($decisions, $text, (New-Object System.Text.UTF8Encoding($false)))
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-DodPage $repo
            $html | Should Match 'badge approved'
            $html | Should Match 'class="count ">0<'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "-Page leaves the Run Mode and a live run's lock alone" {
        $repo = New-DodRepo
        $leaf = Split-Path $repo -Leaf
        $lock = Join-Path $env:TEMP "loop-run-$leaf.lock"
        try {
            Set-Dod $repo $SecondGoal
            Save-All $repo "loop(bootstrap): plan the second goal" "2026-09-10T10:00:00+07:00"
            Remove-Item (Join-Path $repo ".harness/run") -Recurse -Force
            Push-Location $repo
            try { $modeFile = Join-Path (& git rev-parse --absolute-git-dir).Trim() "foreman-mode" } finally { Pop-Location }
            # Before bootstrap a run would reset this to Collaborative; rendering a page must not.
            Set-Content -Path $modeFile -Value "Autonomous" -Encoding ascii
            # A live process holds the lock - this test's own.
            "$PID" | Out-File -FilePath $lock -Encoding ascii

            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            (Get-Content $modeFile -TotalCount 1).Trim() | Should Be "Autonomous"
            (Get-Content $lock -TotalCount 1).Trim() | Should Be "$PID"
            (Get-DodPage $repo) | Should Match 'badge open'
        } finally {
            Remove-Item $lock -Force -ErrorAction SilentlyContinue
            Remove-TestRepo -TestRepo $repo
        }
    }

    It "has the DoD template group criteria by category and number them straight through" {
        $template = Get-Content (Join-Path $RepoRootDir ".harness/loop/templates/DoD.template.md") -Raw
        $order = @("### Behaviour", "### Permissions the user is asked for", "### Background work and notifications",
                   "### Appearance and reachability", "### Data and storage", "### Build, start and quality")
        $at = @($order | ForEach-Object { $template.IndexOf($_) })
        ($at | Where-Object { $_ -lt 0 }).Count | Should Be 0
        for ($i = 1; $i -lt $at.Count; $i++) { ($at[$i] -gt $at[$i - 1]) | Should Be $true }
        $template | Should Match 'never restarting at a heading'
        # The page translates exactly these headings; a renamed one would silently stay English.
        $page = Get-Content $DodPageTemplate -Raw -Encoding UTF8
        foreach ($h in $order) { $page.Contains('"' + $h.Substring(4) + '"') | Should Be $true }
    }
}

Describe "FOREMAN.html is the one page, and the engine writes no HTML (ADR-034)" {

    # Asked for by the human, 2026-10-02: one HTML file to read, instead of SUGGESTIONS.html,
    # RUN-REPORT.html and DOD.html. Two of those were already the Runtime's; the third was the engine's,
    # and it was the one that went stale. These pin that the engine is never again told to write one.

    $Spec = Get-Content (Join-Path $RepoRootDir ".harness/loop/ENGINE.md") -Raw
    $Policies = Get-Content (Join-Path $RepoRootDir ".harness/loop/POLICIES.md") -Raw

    It "never asks the engine for a page, and points it at the Markdown the page is built from" {
        $Spec | Should Not Match 'SUGGESTIONS\.html'
        $Policies | Should Not Match 'SUGGESTIONS\.html'
        $Spec | Should Not Match 'RUN-REPORT\.html'
        $Spec | Should Match 'No HTML, ever'
        $Spec | Should Match '\.harness/SUGGESTIONS\.md'
        $Policies | Should Match '\.harness/SUGGESTIONS\.md'
    }

    It "renders the Suggestion Box from .harness/SUGGESTIONS.md, and links a SUGGESTIONS.html left from before" {
        $repo = New-TestRepo
        try {
            Copy-PageTemplate $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/SUGGESTIONS.md") -Value @(
                "# SUGGESTION BOX", "", "---", "",
                "## S-001 - ask for POST_NOTIFICATIONS before posting", "", "- **Destination:** stack android", "",
                "## S-002 - a pipe hides the exit code", "", "- **Destination:** loop")
            Set-Content -Path (Join-Path $repo "SUGGESTIONS.html") -Value "<html>the engine's old page</html>"
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $html | Should Match 'S-001 - ask for POST_NOTIFICATIONS before posting'
            $html | Should Match 'data-tab="suggestions"><span data-lang="en">Suggestions</span><span data-lang="vi">[^<]*</span><span class="count">2<'
            $html | Should Match 'href="SUGGESTIONS.html"'
            # The engine's committed file is not the Runtime's to delete.
            (Test-Path (Join-Path $repo "SUGGESTIONS.html")) | Should Be $true
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "counts no suggestion in a Suggestion Box fresh from its template" {
        $repo = New-TestRepo
        try {
            Copy-PageTemplate $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness") -Force | Out-Null
            Copy-Item (Join-Path $RepoRootDir ".harness/loop/templates/SUGGESTIONS.template.md") (Join-Path $repo ".harness/SUGGESTIONS.md")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $html | Should Match '<span class="count">0</span></button>\s*</nav>'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "keeps a code span's asterisks literal while rendering emphasis around it" {
        $repo = New-TestRepo
        try {
            Copy-PageTemplate $repo
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness") -Force | Out-Null
            $tick = [char]96
            Set-Content -Path (Join-Path $repo ".harness/SUGGESTIONS.md") -Value @("## S-001 - rules", "", ("*Driven on the emulator:* grant " + $tick + "Bash(*DebugAndroidTest*)" + $tick + " only"), "", ("*Screenshot: " + $tick + "run/evidence/c7.png" + $tick + ", still unlooked-at*"))
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Should Be 0
            $html = Get-Content (Join-Path $repo "FOREMAN.html") -Raw -Encoding UTF8
            $html | Should Match '<em>Driven on the emulator:</em>'
            $html | Should Match '<em>Screenshot: <code>run/evidence/c7.png</code>, still unlooked-at</em>'
            $html | Should Match '<code>Bash\(\*DebugAndroidTest\*\)</code>'
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}

Describe "A DoD criterion is written twice, once for the person and once for the engine (ADR-035)" {

    # Calendar-Note loop/music-player-v3, 2026-09-29: all 32 criteria were written for a command to
    # read, the human approved them verbatim, and on 2026-10-02 said they were hard to understand.
    # Decided by the human the same day: a plain sentence for the person, a Proof for the engine,
    # always in English, and the page shows the sentence with the Proof folded under it.

    function Show-Dod([string]$text) {
        $repo = New-TestRepo
        Copy-PageTemplate $repo
        New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo ".harness/run/DoD.md"), $text, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-Page", "-NoOpenEscalation") | Out-Null
        $html = [System.IO.File]::ReadAllText((Join-Path $repo "FOREMAN.html"), [System.Text.Encoding]::UTF8)
        Remove-TestRepo -TestRepo $repo
        return $html
    }

    It "shows the person's sentence and folds the engine's Proof under it" {
        $tick = [char]96
        $html = Show-Dod ("# Definition of Done`n`n## Acceptance Criteria`n`n" +
            "8. [machine] Tapping a song plays it.`n" +
            "   Proof: " + $tick + "dumpsys media_session" + $tick + " shows state PLAYING(3),`n" +
            "   driven from a fresh install.`n" +
            "9. [human] An old-style criterion with no Proof line.`n")
        $html | Should Match '<span class="cls machine">machine</span>Tapping a song plays it\.<details class="proof">'
        $html | Should Match '<code>dumpsys media_session</code> shows state PLAYING\(3\), driven from a fresh install\.</div></details>'
        # The Proof never leaks into the sentence, and a criterion without one has no fold at all.
        $html | Should Not Match 'plays it\. Proof:'
        $html | Should Match 'An old-style criterion with no Proof line\.</div></li>'
    }

    It "reads a bold sentence as the sentence and the rest of its line as the Proof" {
        $html = Show-Dod ("## Acceptance Criteria`n`n**1. [machine] The whole app compiles.** gradlew assembleDebug exits 0.`n")
        $html | Should Match '<span class="cls machine">machine</span>The whole app compiles\.<details class="proof">'
        $html | Should Match 'gradlew assembleDebug exits 0\.</div></details>'
        $html | Should Match '<b>1</b>'
    }

    It "has ENGINE.md and the DoD template ask for both halves, in English" {
        $spec = Get-Content (Join-Path $RepoRootDir ".harness/loop/ENGINE.md") -Raw
        $spec | Should Match 'Every criterion is written twice, in English'
        $spec | Should Match 'a Proof that checks\s+less than its sentence promises is a defect'
        $template = Get-Content (Join-Path $RepoRootDir ".harness/loop/templates/DoD.template.md") -Raw
        $template | Should Match 'Every criterion is written twice'
        $template | Should Match '(?m)^1\. \[machine\] .+\r?\n   Proof: '
        $template | Should Match '(?m)^R1\. \[machine\] .+\r?\n    Proof: '
    }
}

Describe "Roborazzi is the default UI check for Android, and its baselines are out of the engine's reach (ADR-036)" {

    # Decided by the human, 2026-10-05, after a spike on Foreman-Proving-Ground (loop/music-player-v3):
    # Roborazzi captured the real screens after taps on the JVM, caught an injected contrast defect in
    # 21 s, and went green again once it was fixed. The same spike measured the hole these close:
    # `testDebugUnitTest -Proborazzi.test.record=true` re-recorded the defect as correct, and verify
    # then passed with the defect in place.

    $Wrapper = Join-Path $RepoRootDir ".harness/loop/bin/foreman-record-baselines.ps1"

    function New-BaselineRepo([switch]$WithRealBaseline) {
        $repo = New-TestRepo
        $dir = Join-Path $repo "app/src/test/screenshots"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir "1_library.png") -Value "approved library" -Encoding ASCII
        Set-Content -Path (Join-Path $dir "2_playing.png") -Value "approved playing" -Encoding ASCII
        Push-Location $repo
        try {
            & git add -A 2>$null | Out-Null
            & git -c user.email=t@l -c user.name=t commit --quiet -m "approved baselines" 2>$null | Out-Null
        } finally { Pop-Location }
        return $repo
    }
    function Set-Approvals([string]$repo, [string[]]$paths) {
        New-Item -ItemType Directory -Path (Join-Path $repo ".harness/run") -Force | Out-Null
        $lines = @("# DECISIONS", "", "## Baselines", "") + @($paths | ForEach-Object { "- " + $_ })
        Set-Content -Path (Join-Path $repo ".harness/run/DECISIONS.md") -Value $lines
    }

    It "denies every Gradle route to re-recording in both Run Modes, and grants verify, compare and the wrapper" {
        foreach ($mode in @("Collaborative", "Autonomous")) {
            $repo = New-TestRepo
            try {
                $argLog = Join-Path $repo "args.txt"
                $env:FAKE_CLAUDE_ARGLOG = $argLog
                New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
                Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/baseline.json")
                Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
                Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", $mode) | Out-Null
                $settingsPath = ((Get-Content $argLog -Raw) -split '--settings\s+')[1].Split(' ')[0].Trim()
                $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
                foreach ($rule in @("Bash(*gradlew*recordRoborazzi*)", "Bash(*gradlew*RecordRoborazzi*)", "Bash(*gradlew*clearRoborazzi*)", "Bash(*gradlew*roborazzi.test.record*)")) {
                    ($settings.permissions.deny -contains $rule) | Should Be $true
                }
                if ($mode -eq "Collaborative") {
                    ($settings.permissions.allow -contains "Bash(*gradlew*verifyRoborazzi*)") | Should Be $true
                    ($settings.permissions.allow -contains "Bash(powershell -NoProfile -File .harness/loop/bin/foreman-record-baselines.ps1*)") | Should Be $true
                }
            } finally {
                Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue
                Remove-TestRepo -TestRepo $repo
            }
        }
    }

    It "stops the run when an approved baseline changes, whatever changed it" {
        $repo = New-BaselineRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("TOUCH:app/src/test/screenshots/2_playing.png|COMMIT|CONTINUE|recorded the defect as correct", "DONE|never reached")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "3") | Should Be 4
            $log = Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw
            $log | Should Match 'baseline guard: changed without approval: app/src/test/screenshots/2_playing\.png'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "lets a baseline change once the human lists it under ## Baselines, and never minds a new one" {
        $repo = New-BaselineRepo
        try {
            Set-Approvals $repo @("app/src/test/screenshots/2_playing.png")
            Set-Content -Path (Join-Path $repo "app/src/test/screenshots/3_now_playing.png") -Value "new" -Encoding ASCII
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("TOUCH:app/src/test/screenshots/2_playing.png|COMMIT|DONE|re-recorded with approval")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "records new baselines through the wrapper and puts every existing one back" {
        $repo = New-BaselineRepo
        try {
            # A Gradle stand-in that does what a record task does: rewrites what exists, adds what does not.
            Set-Content -Path (Join-Path $repo "gradlew.bat") -Encoding ASCII -Value @(
                "@echo off",
                "echo gradle %* > gradle-args.txt",
                "echo rewritten > app\src\test\screenshots\1_library.png",
                "echo rewritten > app\src\test\screenshots\2_playing.png",
                "echo new screen > app\src\test\screenshots\3_now_playing.png",
                "exit /b 0")
            Set-Approvals $repo @("app/src/test/screenshots/2_playing.png")
            Push-Location $repo
            try {
                $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Wrapper -Module app 2>$null | Out-String
                $LASTEXITCODE | Should Be 0
            } finally { Pop-Location }
            (Get-Content (Join-Path $repo "gradle-args.txt") -Raw) | Should Match ':app:recordRoborazziDebug'
            (Get-Content (Join-Path $repo "app/src/test/screenshots/1_library.png") -Raw).Trim() | Should Be "approved library"
            (Get-Content (Join-Path $repo "app/src/test/screenshots/2_playing.png") -Raw).Trim() | Should Be "rewritten"
            (Get-Content (Join-Path $repo "app/src/test/screenshots/3_now_playing.png") -Raw).Trim() | Should Be "new screen"
            $out | Should Match 'new baselines recorded: 1'
            $out | Should Match 'existing baselines put back unchanged: 1'
            $out | Should Match "re-recorded with the human's approval: 1"
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    # Kanso's Run 2, 2026-10-06: the engine deleted 16_tool_photo_light.png and 17_tool_photo_dark.png,
    # approved baselines, then called the wrapper, which recorded them as new. Deleting first was a
    # way around the human's approval; only the Runtime's guard caught it, and only after the fact.
    It "puts back a committed baseline deleted before recording, so deleting first gets around nothing" {
        $repo = New-BaselineRepo
        try {
            Set-Content -Path (Join-Path $repo "gradlew.bat") -Encoding ASCII -Value @(
                "@echo off",
                "echo rewritten > app\src\test\screenshots\1_library.png",
                "echo rewritten > app\src\test\screenshots\2_playing.png",
                "exit /b 0")
            Remove-Item (Join-Path $repo "app/src/test/screenshots/1_library.png")
            Remove-Item (Join-Path $repo "app/src/test/screenshots/2_playing.png")
            Set-Approvals $repo @("app/src/test/screenshots/2_playing.png")
            Push-Location $repo
            try {
                $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Wrapper -Module app 2>$null | Out-String
            } finally { Pop-Location }
            (Get-Content (Join-Path $repo "app/src/test/screenshots/1_library.png") -Raw).Trim() | Should Be "approved library"
            # The human listed this one, so its re-recording stands even though it was deleted first.
            (Get-Content (Join-Path $repo "app/src/test/screenshots/2_playing.png") -Raw).Trim() | Should Be "rewritten"
            $out | Should Match 'new baselines recorded: 0'
            $out | Should Match 'existing baselines put back unchanged: 1'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "refuses a module, variant or test filter that could carry shell syntax" {
        $repo = New-BaselineRepo
        try {
            Push-Location $repo
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $Wrapper -Module "app;del x" 2>$null | Out-Null
                $LASTEXITCODE | Should Be 3
                & powershell -NoProfile -ExecutionPolicy Bypass -File $Wrapper -Module app -Tests "a & b" 2>$null | Out-Null
                $LASTEXITCODE | Should Be 3
            } finally { Pop-Location }
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "has ENGINE.md make Roborazzi the Android default, from the pack that ships with the runtime" {
        $spec = Get-Content (Join-Path $RepoRootDir ".harness/loop/ENGINE.md") -Raw
        $spec | Should Match 'Roborazzi is the default UI check'
        $spec | Should Match '\.harness/loop/packs/android/roborazzi\.md'
        # Decided by the human the same day: the default libraries are not an approval item at the gate.
        $spec | Should Match 'without asking: the human made them Foreman''s standing toolchain'
        $spec | Should Match 'not an approval item at the DoD gate'
        (Test-Path (Join-Path $RepoRootDir ".harness/loop/packs/android/roborazzi.md")) | Should Be $true
        $policies = Get-Content (Join-Path $RepoRootDir ".harness/loop/POLICIES.md") -Raw
        $policies | Should Match 'foreman-record-baselines\.ps1'
    }
}

Describe "Foreman declares what it installs, for itself and for the consumer, and shows both (ADR-036)" {

    # Asked for by the human, 2026-10-05: a section in README and the guide naming every library and
    # repository Foreman uses, why, and where it comes from; Foreman's own tools kept apart from what
    # goes into a consumer repository; and the tools fetched or offered automatically wherever Foreman
    # is installed. One manifest feeds all of it, so these keep the three in step.

    $Deps = Get-Content (Join-Path $RepoRootDir ".harness/loop/dependencies.json") -Raw | ConvertFrom-Json
    $Readme = Get-Content (Join-Path $RepoRootDir "README.md") -Raw -Encoding UTF8
    $Guide = Get-Content (Join-Path $RepoRootDir "docs/index.html") -Raw -Encoding UTF8
    $Skill = Get-Content (Join-Path $RepoRootDir "skills/engineering/foreman/SKILL.md") -Raw -Encoding UTF8

    It "keeps two groups that never mix, each entry with a reason and a source" {
        @($Deps.foreman).Count | Should BeGreaterThan 0
        @($Deps.consumer.android).Count | Should BeGreaterThan 0
        foreach ($d in @($Deps.foreman) + @($Deps.consumer.android)) {
            "$($d.why)" | Should Not BeNullOrEmpty
            "$($d.repo)" | Should Match '^https://'
        }
        # A library that goes into the consumer's build is never also one of Foreman's own tools.
        $own = @($Deps.foreman | ForEach-Object { $_.name })
        @($Deps.consumer.android | Where-Object { $own -contains $_.name }).Count | Should Be 0
    }

    It "lists every entry, with its source, in README and in both halves of the guide's section" {
        $Readme | Should Match '## What Foreman depends on'
        $Readme | Should Match "### Foreman's own tools"
        $Readme | Should Match '### Libraries Foreman adds to your repository'
        $Guide | Should Match 'id="dependencies"'
        $Guide | Should Match 'href="#dependencies"'
        foreach ($d in @($Deps.foreman) + @($Deps.consumer.android)) {
            $Readme.Contains($d.name) | Should Be $true
            $Readme.Contains($d.repo) | Should Be $true
            $Guide.Contains("href=`"$($d.repo)`"") | Should Be $true
        }
    }

    It "has /foreman check Foreman's own tools before every launch and ask before installing one" {
        $Skill | Should Match '## 0c\. Make sure Foreman''s own tools are here'
        $Skill | Should Match 'dependencies\.json'
        $Skill | Should Match 'Never install system software unasked'
        $Skill | Should Match '\*\*Do not\s+install those here\.\*\*'
        $zeroC = $Skill.IndexOf('## 0c.'); $one = $Skill.IndexOf('## 1. Locate the installed runtime files')
        ($zeroC -gt 0 -and $zeroC -lt $one) | Should Be $true
    }

    It "ships the manifest and the packs with the runtime, so every install has them" {
        $Skill | Should Match '`dependencies\.json`, `agents/`, `bin/`, `capabilities/`,\s*`packs/`'
        $Deps.consumer.android | Where-Object { $_.default } | ForEach-Object {
            (Test-Path (Join-Path $RepoRootDir $_.pack)) | Should Be $true
        }
    }
}

Describe "The engine never changes what other projects on the machine share" {
    # Kanso's Run 3, 2026-10-07: after a killed build left the global Gradle cache half-written, the
    # engine ran `./gradlew --stop` (every daemon of that Gradle version on the machine, other
    # projects' builds included) and moved 264 entries, then the whole transforms directory, out of
    # ~/.gradle/caches. The same day it showed it inherits the owner's own MCP servers.

    function Get-SettingsFor([string]$repo, [string]$mode) {
        $argLog = Join-Path $repo "args.txt"
        $env:FAKE_CLAUDE_ARGLOG = $argLog
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/loop/capabilities") -Force | Out-Null
            Copy-Item (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") (Join-Path $repo ".harness/loop/capabilities/baseline.json")
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|ok")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2", "-Mode", $mode)
            $recorded = if (Test-Path $argLog) { Get-Content $argLog -Raw } else { "" }
            return [pscustomobject]@{ Exit = $exit; Args = $recorded }
        } finally { Remove-Item Env:\FAKE_CLAUDE_ARGLOG -ErrorAction SilentlyContinue }
    }

    It "denies stopping Gradle daemons and touching the Gradle cache, in both Run Modes" {
        foreach ($mode in @("Collaborative", "Autonomous")) {
            $repo = New-TestRepo
            try {
                $run = Get-SettingsFor $repo $mode
                $settingsPath = ($run.Args -split '--settings\s+')[1].Split(' ')[0].Trim()
                $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
                foreach ($rule in @("Bash(*gradlew*--stop*)", "Bash(*gradle *--stop*)", "Bash(*.gradle*caches*)")) {
                    ($settings.permissions.deny -contains $rule) | Should Be $true
                }
            } finally { Remove-TestRepo -TestRepo $repo }
        }
    }

    # Measured 2026-10-07: one rule holding a backslash makes the CLI ignore the whole settings file,
    # so every deny - DECISIONS.md, the Deny List, adb - stops applying, and nothing reports it.
    It "refuses to run when a ledger rule holds a backslash, instead of silently losing every rule" {
        $repo = New-TestRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $repo ".harness/knowledge") -Force | Out-Null
            Set-Content -Path (Join-Path $repo ".harness/knowledge/capabilities.json") -Value '{"entries":[{"intent":"keep the build cache","deny":["Bash(*C:\\Users\\me\\.cache*)"]}]}'
            $run = Get-SettingsFor $repo "Collaborative"
            $run.Exit | Should Be 4
            $run.Args | Should Be ""
            (Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw) | Should Match 'backslash'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "ships no backslash in any rule of its own" {
        $baseline = Get-Content (Join-Path $RepoRootDir ".harness/loop/capabilities/baseline.json") -Raw
        $baseline.Contains('\') | Should Be $false
        $runtime = Get-Content (Join-Path $RepoRootDir ".harness/loop/run.ps1") -Raw
        @([regex]::Matches($runtime, '"(?:Bash|Edit|Write|Read)\([^"]*\)"') | Where-Object { $_.Value.Contains('\') }).Count | Should Be 0
    }
}

Describe "Nothing a person still has to check disappears, and a git that cannot answer proves nothing" {
    function New-ChecklistRepo {
        $repo = New-TestRepo
        New-Item -ItemType Directory -Path (Join-Path $repo ".harness") -Force | Out-Null
        Set-Content -Path (Join-Path $repo ".harness/ISSUES.md") -Value @(
            "# ISSUES", "", "## Awaiting a person", "",
            "- [ ] Run 1 12 - kill the app, open it from the launcher: the splash, then Home",
            "- [ ] Run 1 22 - back from a tool goes Home; back again closes the app")
        Push-Location $repo
        try {
            & git add -A 2>$null | Out-Null
            & git -c user.email=t@l -c user.name=t commit --quiet -m "an earlier run left two unsigned items" 2>$null | Out-Null
        } finally { Pop-Location }
        return $repo
    }

    # Kanso's Run 2, 0670172: the Issues Report was regenerated from the run's own knowledge and the
    # five items Run 1 had left unsigned were gone. Nobody noticed until the owner went looking.
    It "stops a run whose iteration drops unsigned items from ISSUES.md" {
        $repo = New-ChecklistRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CLEAR:.harness/ISSUES.md|COMMIT|CONTINUE|regenerated the report", "DONE|never reached")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "3") | Should Be 4
            $log = Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw
            $log | Should Match 'checklist guard: 2 unsigned item\(s\) left \.harness/ISSUES\.md without being ticked'
            $log | Should Match 'Run 1 12 - kill the app'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    # Counting alone passed an iteration that removed one item and added an unrelated one (ADR-037,
    # "Not solved"). An item's id has to survive, open or ticked.
    It "stops a run that swaps an unsigned item for a different one" {
        $repo = New-ChecklistRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REPLACE:.harness/ISSUES.md:Run 1 12 - kill the app=>Run 9 99 - something else entirely|COMMIT|CONTINUE|swapped", "DONE|never reached")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "3") | Should Be 4
            $log = Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw
            $log | Should Match 'checklist guard: 1 unsigned item\(s\)'
            $log | Should Match 'Run 1 12 - kill the app'
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "lets an item be reworded as long as it keeps its id" {
        $repo = New-ChecklistRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REPLACE:.harness/ISSUES.md:kill the app=>not driven: close the app fully|COMMIT|DONE|reworded")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "lets an item leave by being ticked in place" {
        $repo = New-ChecklistRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("TICK:.harness/ISSUES.md|COMMIT|DONE|the person signed both")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "2") | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "has ENGINE.md carry unsigned items over instead of regenerating them away" {
        $engine = Get-Content (Join-Path $RepoRootDir ".harness/loop/ENGINE.md") -Raw
        $engine | Should Match 'Unsigned items are carried over, never regenerated away'
        $engine | Should Not Match 'ISSUES\.md` — regenerated'
    }

    # Kanso's Run 3, 2026-10-07: the machine was shutting the run down, git failed, and the guard
    # logged all 16 baselines as removed while every one was still on disk.
    It "does not report baselines as removed when git cannot list them" {
        $repo = New-TestRepo
        try {
            $dir = Join-Path $repo "app/src/test/screenshots"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "1_home.png") -Value "approved home" -Encoding ASCII
            Push-Location $repo
            try {
                & git add -A 2>$null | Out-Null
                & git -c user.email=t@l -c user.name=t commit --quiet -m "approved baseline" 2>$null | Out-Null
            } finally { Pop-Location }
            # Overwriting the index with text makes `git ls-files` fail (appending a byte does not).
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CLEAR:.git/index|CONTINUE|git is broken now", "DONE|ok")
            Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "3") | Out-Null
            $log = Get-Content (Join-Path $env:TEMP ("loop-run-" + (Split-Path $repo -Leaf) + ".log")) -Raw
            $log | Should Not Match 'baseline guard: removed'
            $log | Should Match 'baseline guard: git could not list the baselines'
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}
