---
name: verify-distributable
description: Run every pre-commit check for the Foreman repository - the five distributable parity diffs, the Pester runtime suite, and the ENGINE.md command-line size ceiling. Use before committing any change to .harness/loop/, skills/engineering/foreman/, or tests/.
---

Three things in this repository can be broken by a change that still looks correct, passes review,
and leaves no trace until it reaches a consumer. Run all three checks before committing. Report
results plainly; do not summarise a failure as a pass.

## 1. Distributable parity — the five copies

`.harness/loop/` is source. `skills/engineering/foreman/` is what `npx skills@latest add` installs, and what
`/foreman` writes back over a consumer's `.harness/loop/` on every invocation. A stale skill copy silently
reverts a consumer repository to an older runtime, including older permission rules. Nothing in the
build or the tests enforces this.

Compare **git blob hashes, not working-tree bytes.** Git normalises line endings on checkout, so
on Windows a plain `diff` reports a mismatch on files that are byte-identical as far as the
repository — and therefore the installer — is concerned. That false positive has already happened.

```bash
cd <repo root>
for p in "ENGINE.md:ENGINE.md"          "POLICIES.md:POLICIES.md"          "capabilities/baseline.json:capabilities/baseline.json"          "run.ps1:scripts/run.ps1"          "models.json:models.json"; do
  h1=$(git hash-object ".harness/loop/${p%%:*}")
  h2=$(git hash-object "skills/engineering/foreman/${p##*:}")
  [ "$h1" = "$h2" ] || echo "MISMATCH ${p%%:*}"
done
for f in .harness/loop/templates/* .harness/loop/agents/*; do
  t="skills/engineering/foreman/${f#.harness/loop/}"
  [ -f "$t" ] && [ "$(git hash-object "$f")" = "$(git hash-object "$t")" ] || echo "MISMATCH $f"
done
```

Silence is the pass condition. Note `run.ps1` → `scripts/run.ps1`: the filename differs, so a naive
directory diff will not catch it.

On a mismatch, copy `.harness/loop/` → skill (never the reverse — `.harness/loop/` is source), then re-run.
`SKILL.md` exists only on the skill side and has no `.harness/loop/` counterpart; it is not part of this
check.

## 2. Runtime test suite

Required after any change to `.harness/loop/run.ps1` or `tests/fixtures/fake-claude.ps1`. Needs no network,
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
B=$(wc -c < .harness/loop/ENGINE.md); echo "$B bytes ($(( B * 100 / 32000 ))% of budget)"
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
