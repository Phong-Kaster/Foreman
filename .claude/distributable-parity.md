# The Distributable Exists Twice and Must Stay Identical

## Objective

Foreman ships the same distributable from two locations. They are **byte-identical copies**, and
nothing in the build, the tests, or CI enforces that. Breaking parity produces a repository that
looks correct, passes every test, and installs the wrong runtime into a consumer repo.

This has already happened. A consumer repository was found running a skill copy that differed from
source in **twelve files** and was missing a template outright.

---

# The two locations

| Source of truth | Shipped copy | Note |
|---|---|---|
| `.harness/loop/ENGINE.md` | `skills/engineering/foreman/ENGINE.md` | |
| `.harness/loop/POLICIES.md` | `skills/engineering/foreman/POLICIES.md` | |
| `.harness/loop/models.json` | `skills/engineering/foreman/models.json` | |
| `.harness/loop/capabilities/baseline.json` | `skills/engineering/foreman/capabilities/baseline.json` | includes the Autonomous Deny List |
| `.harness/loop/templates/` | `skills/engineering/foreman/templates/` | |
| `.harness/loop/agents/` | `skills/engineering/foreman/agents/` | |
| `.harness/loop/bin/` | `skills/engineering/foreman/bin/` | the Recovery Wrappers (ADR-027) |
| `.harness/loop/run.ps1` | `skills/engineering/foreman/scripts/run.ps1` | note the **different filename** |

- `.harness/loop/` is what a **manual install** copies, and what this repository runs against itself.
- `skills/engineering/foreman/` is what **`npx skills@latest add`** installs, and what `/foreman`
  materializes back into a consumer's `.harness/loop/` on every invocation (SKILL.md step 2 lists the
  directories it copies — a new directory here must be added there too, as `bin/` was).

Because the skill overwrites the consumer's `.harness/loop/` every run, a stale skill copy silently
reverts a consumer repository to an older runtime — including older permission rules.

---

# The rule

**Edit `.harness/loop/`. Then copy to the skill. Then verify. In the same commit.**

```bash
L=.harness/loop; K=skills/engineering/foreman
cp $L/ENGINE.md $L/POLICIES.md $L/models.json $K/
cp $L/capabilities/baseline.json $K/capabilities/
cp -r $L/templates/. $K/templates/
cp -r $L/agents/.    $K/agents/
cp -r $L/bin/.       $K/bin/
cp $L/run.ps1        $K/scripts/run.ps1
```

## Verify before committing — do not assume the copy worked

Run `.claude/skills/verify-distributable`. It compares git blob hashes rather than bytes, because
Git's line-ending normalisation makes a plain `diff` report false mismatches on Windows.

---

# What is *not* mirrored

`SKILL.md` exists **only** in `skills/engineering/foreman/`. It is the skill's own instructions and
has no `.harness/loop/` counterpart. Do not create one.

`.harness/loop/` in a **consumer** repository is disposable and regenerated. `.harness/loop/` in
**this** repository is source. Do not reason about them the same way.

---

# Why this is not automated

It could be — a pre-commit hook or a test asserting the parity hashes would close it. That has not been
built, so until it is, this file is the enforcement. If you find yourself about to rely on
remembering, build the check instead: a rule enforced by a script is a rule, a rule living only in a
document is a wish (ADR-002).

---

# Related trap: the installed copy in a consumer repo

`.claude/skills/` is gitignored in consumer repositories while `.agents/skills/` is tracked, and the
`.claude` copy is an **absolute-path symlink** that dangles after a branch switch or on another
machine. When diagnosing "the engine behaved like an old version", check the installed copy against
this repository before suspecting the engine.
