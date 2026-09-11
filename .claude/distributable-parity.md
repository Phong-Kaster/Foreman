# The Distributable Exists Twice and Must Stay Identical

## Objective

Foreman ships the same five artifacts from two locations. They are **byte-identical copies**, and
nothing in the build, the tests, or CI enforces that. Breaking parity produces a repository that
looks correct, passes every test, and installs the wrong runtime into a consumer repo.

This has already happened. A consumer repository was found running a skill copy that differed from
source in **twelve files** and was missing a template outright.

---

# The two locations

| Source of truth | Shipped copy | Consumed by |
|---|---|---|
| `.loop/ENGINE.md` | `skills/engineering/foreman/ENGINE.md` | |
| `.loop/POLICIES.md` | `skills/engineering/foreman/POLICIES.md` | |
| `.loop/capabilities/baseline.json` | `skills/engineering/foreman/capabilities/baseline.json` | |
| `.loop/templates/` | `skills/engineering/foreman/templates/` | |
| `.loop/run.ps1` | `skills/engineering/foreman/scripts/run.ps1` | note the **different filename** |

- `.loop/` is what a **manual install** copies, and what this repository runs against itself.
- `skills/engineering/foreman/` is what **`npx skills@latest add`** installs, and what `/foreman`
  materializes back into a consumer's `.loop/` on every invocation.

Because the skill overwrites the consumer's `.loop/` every run, a stale skill copy silently reverts
a consumer repository to an older runtime — including older permission rules.

---

# The rule

**Edit `.loop/`. Then copy to the skill. Then verify. In the same commit.**

```bash
cp .loop/ENGINE.md                  skills/engineering/foreman/ENGINE.md
cp .loop/POLICIES.md                skills/engineering/foreman/POLICIES.md
cp .loop/capabilities/baseline.json skills/engineering/foreman/capabilities/baseline.json
cp -r .loop/templates/.             skills/engineering/foreman/templates/
cp .loop/run.ps1                    skills/engineering/foreman/scripts/run.ps1
```

## Verify before committing — do not assume the copy worked

```bash
diff -q .loop/ENGINE.md                  skills/engineering/foreman/ENGINE.md
diff -q .loop/POLICIES.md                skills/engineering/foreman/POLICIES.md
diff -q .loop/capabilities/baseline.json skills/engineering/foreman/capabilities/baseline.json
diff -q .loop/run.ps1                    skills/engineering/foreman/scripts/run.ps1
diff -rq .loop/templates                 skills/engineering/foreman/templates
```

Silence from all five is the pass condition. Run it as the last step before `git commit`, every time
one of these files is touched.

---

# What is *not* mirrored

`SKILL.md` exists **only** in `skills/engineering/foreman/`. It is the skill's own instructions and
has no `.loop/` counterpart. Do not create one.

`.loop/` in a **consumer** repository is disposable and regenerated. `.loop/` in **this**
repository is source. Do not reason about them the same way.

---

# Why this is not automated

It could be — a pre-commit hook or a test asserting the five diffs would close it. That has not been
built, so until it is, this file is the enforcement. If you find yourself about to rely on
remembering, build the check instead: a rule enforced by a script is a rule, a rule living only in a
document is a wish (ADR-002).

---

# Related trap: the installed copy in a consumer repo

`.claude/skills/` is gitignored in consumer repositories while `.agents/skills/` is tracked, and the
`.claude` copy is an **absolute-path symlink** that dangles after a branch switch or on another
machine. When diagnosing "the engine behaved like an old version", check the installed copy against
this repository before suspecting the engine.
