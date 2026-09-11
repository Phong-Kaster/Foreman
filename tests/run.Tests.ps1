<#
.SYNOPSIS
    Unit tests for .loop/run.ps1's mechanics, using a fake `claude` stub so no real API calls,
    no nested-agent invocation, and no dependency on git ever happen.

.DESCRIPTION
    run.ps1 never calls git itself (only the real engine does), so these tests don't need a real
    git repo — just a plain folder with a `.loop/ENGINE.md` file. The fake-claude.ps1 fixture
    (invoked via run.ps1's existing -ClaudeCommand seam) is driven by a queue file so each test can
    script exactly what "the engine" does on each iteration, deterministically.

    run.ps1 is always launched as a genuine child process (powershell -File ...), never dot-sourced
    or called in-process — its internal `exit N` calls would otherwise terminate the test runner
    itself instead of just ending the script.

.NOTES
    Run with: Invoke-Pester -Script @{ Path = 'tests/run.Tests.ps1' }
#>

$RepoRootDir = Split-Path -Parent $PSScriptRoot
$RunPs1 = Join-Path $RepoRootDir ".loop\run.ps1"
$FakeClaude = Join-Path $PSScriptRoot "fixtures\fake-claude.ps1"

function New-TestRepo {
    param([switch]$WithoutEngineSpec)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("foreman-unit-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 12))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if (-not $WithoutEngineSpec) {
        New-Item -ItemType Directory -Path (Join-Path $dir ".loop") -Force | Out-Null
        Set-Content -Path (Join-Path $dir ".loop\ENGINE.md") -Value "# fake engine spec for tests"
    }
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

    It "exits 1 immediately when .loop/ENGINE.md is missing, without invoking the engine" {
        $repo = New-TestRepo -WithoutEngineSpec
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|should never run")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5")
            $exit | Should Be 1
            (Test-Path (Join-Path $repo ".ai\STATUS.md")) | Should Be $false
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
            (Test-Path (Join-Path $repo ".ai\STATUS.md")) | Should Be $false
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

Describe "run.ps1 distinguishes a refusal from a crash" {

    # Regression for the 2026-09-11 incident: a quota refusal consumed all three watchdog retries
    # in five seconds, against a limit that would not reset for three hours, and was then reported
    # to the human as "usually a transient CLI or network problem. Start it again."

    It "exits 4 (FAILED) on a quota refusal instead of burning the watchdog" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REFUSE|You've hit your session limit - resets 2:30pm")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "3", "-CrashBackoffSeconds", "0")
            $exit | Should Be 4
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "does not re-invoke after a refusal" {
        $repo = New-TestRepo
        try {
            # If the refusal were retried, the queued DONE would be consumed and the run would
            # exit 0. Exit 4 with the DONE still unconsumed proves it stopped on the first refusal.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REFUSE|usage limit reached", "DONE|should never be reached")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-CrashBackoffSeconds", "0")

            $exit | Should Be 4
            $remaining = @(Get-Content (Join-Path $repo "queue.txt") | Where-Object { $_.Trim() -ne "" })
            $remaining.Count | Should Be 1
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "exits 4 (FAILED) when the engine binary cannot be started" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("DONE|should never run")
            Push-Location $repo
            try {
                $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RunPs1,
                          "-ClaudeCommand", "claude-does-not-exist-on-this-machine",
                          "-QuietEngine", "-MaxIterations", "5", "-CrashBackoffSeconds", "0")
                & powershell @args | Out-Null
                $exit = $LASTEXITCODE
            } finally { Pop-Location }

            $exit | Should Be 4
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "still treats a mid-work death as a crash (exit 2), not a refusal" {
        $repo = New-TestRepo
        try {
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("CRASH", "CRASH")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "2", "-CrashBackoffSeconds", "0")
            $exit | Should Be 2
        } finally { Remove-TestRepo -TestRepo $repo }
    }

    It "does not treat a transient overload as a refusal" {
        $repo = New-TestRepo
        try {
            # 'overloaded' is deliberately absent from the refusal list: it is what the Watchdog is for.
            Set-FakeClaudeQueue -TestRepo $repo -Directives @("REFUSE|API Error 529 overloaded_error", "DONE|recovered")
            $exit = Invoke-RunPs1 -TestRepo $repo -ExtraArgs @("-MaxIterations", "5", "-MaxConsecutiveCrashes", "3", "-CrashBackoffSeconds", "0")
            $exit | Should Be 0
        } finally { Remove-TestRepo -TestRepo $repo }
    }
}
