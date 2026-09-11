---
name: verify-distributable
description: Run every pre-commit check for the Foreman repository - the five distributable parity diffs, the Pester runtime suite, and the ENGINE.md command-line size ceiling. Use before committing any change to .loop/, skills/engineering/foreman/, or tests/.
---

Three things in this repository can be broken by a change that still looks correct, passes review,
and leaves no trace until it reaches a consumer. Run all three checks before committing. Report
results plainly; do not summarise a failure as a pass.

## 1. Distributable parity — the five copies

`.loop/` is source. `skills/engineering/foreman/` is what `npx skills@latest add` installs, and what
`/foreman` writes back over a consumer's `.loop/` on every invocation. A stale skill copy silently
reverts a consumer repository to an older runtime, including older permission rules. Nothing in the
build or the tests enforces this.

```bash
cd <repo root>
diff -q .loop/ENGINE.md                  skills/engineering/foreman/ENGINE.md
diff -q .loop/POLICIES.md                skills/engineering/foreman/POLICIES.md
diff -q .loop/capabilities/baseline.json skills/engineering/foreman/capabilities/baseline.json
diff -q .loop/run.ps1                    skills/engineering/foreman/scripts/run.ps1
diff -rq .loop/templates                 skills/engineering/foreman/templates
```

Silence from all five is the pass condition. Note the fourth line: the filename differs
(`run.ps1` → `scripts/run.ps1`), so a naive directory diff will not catch it.

On a mismatch, copy `.loop/` → skill (never the reverse — `.loop/` is source), then re-run.
`SKILL.md` exists only on the skill side and has no `.loop/` counterpart; it is not part of this
check.

## 2. Runtime test suite

Required after any change to `.loop/run.ps1` or `tests/fixtures/fake-claude.ps1`. Needs no network,
no API calls and no real `claude` — the `-ClaudeCommand` seam drives a stub.

```powershell
Invoke-Pester -Script @{ Path = 'tests/run.Tests.ps1' } -PassThru
```

Expected: **14 passed, 0 failed**. Two `Write-Error` blocks appear in the output — they are the
prerequisite tests asserting those exact failures, not test failures. Read the `Passed:`/`Failed:`
counts, not the presence of red text.

## 3. `ENGINE.md` size against the command-line ceiling

`run.ps1` passes `ENGINE.md` to the CLI as a single `--append-system-prompt` argument. Windows caps
the whole command line at roughly **32,000 bytes** — measured on this machine: 32,000 accepted,
33,000 rejected with `The filename or extension is too long`.

`ENGINE.md` grows every release, because the Ratchet writes to it. When it crosses, every consumer
repository fails at once.

```bash
B=$(wc -c < .loop/ENGINE.md); echo "$B bytes ($(( B * 100 / 32000 ))% of budget)"
```

- Under 75% — fine, report the number.
- 75–90% — say so explicitly in your report; the next few doctrine additions need to be paid for by
  removing something.
- Over 90% — stop and escalate to the human. The fix is architectural (pass the spec by file or
  stdin rather than argv), not a trim.

The Ratchet cuts both ways here: a line is earned by a real failure **and removed once the model no
longer needs it.** Size pressure is the forcing function for the removal half.

## Reporting

State each check's result and the actual numbers — parity pass/fail, the test counts, the byte count
and percentage. If any check fails, say which, and do not commit.
