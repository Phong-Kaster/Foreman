# Knowledge is stratified by whose failure history earned it; domain truth outranks the codebase

`knowledge/` originally held one file, `PROJECT.md`, typed everywhere as *operational* truth with one conflict rule: **the codebase wins, and the engine corrects the cache**. Real use surfaced two kinds of knowledge that rule does not fit.

**Domain truth** — a blood-pressure formula, a background-removal algorithm, a regulatory invariant — had no home at all. Traced through Reconcile (`ENGINE.md` §9), it could only classify as "no action → noted in history", which lands in `.ai/STATE.md` and is **deleted at the Cleanup Commit**. Worse, had it been written into `PROJECT.md`, the cache rule would have been actively harmful: if the code implements a formula wrongly, the code is not ground truth, and the engine would have been instructed to overwrite the correct rule with the buggy implementation's behaviour. The fresh-context reviewer receives `knowledge/` as its standards (§6.7), so the corruption would then have been used to validate all future code. The bug becomes the spec.

**Stack/platform truth** — "Android 13+ requires a runtime `POST_NOTIFICATIONS` grant" — is not truth about any one repository, and the pull was to promote it into the product so a second Android project would not relearn it.

We therefore split `knowledge/` by **owner and conflict direction**, and decided that stack knowledge stays out of the product:

| Layer | Where | Owner | On conflict with the codebase | Travels between repos |
|---|---|---|---|---|
| Loop mechanics | `.loop/` — `ENGINE.md`, `POLICIES.md`, `baseline.json` | Foreman product | n/a | **Yes** — Foreman's own failure history is cross-repo by nature |
| Stack / platform | A separate opt-in knowledge pack (its own skill), human-curated | Whoever curates the pack | n/a | Yes, by explicit install — never auto-promoted |
| This repository | `knowledge/PROJECT.md` | Engine | **Codebase wins** — it caches facts about the code | No |
| Domain | `knowledge/DOMAIN.md` | **Human only** | **`DOMAIN.md` wins** — the code is an *attempt* at the rule | No |
| This run | `.ai/` | Engine | n/a | No |

`knowledge/DOMAIN.md` is enforced, not merely asked for: `run.ps1` appends `Edit`/`Write` deny rules for it alongside the Capability Ledgers'. The engine may read it and may propose entries through an Escalation Request; only the human (or the Skill transcribing an approved decision verbatim, per ADR-004) writes it. Bootstrap must not create it.

The **ratchet** governs what earns a line anywhere: record a lesson only when a real failure demonstrated it — a broken build, a failing test, a review finding, a denied command — and remove it once the model no longer needs it. A lesson merely inferred is noise, and `ENGINE.md` is injected as system prompt on *every* invocation, so noise does not just cost tokens: it makes the lines that were earned matter less.

This project's own history is the worked example of the product-scope ratchet functioning correctly. Commit `3065d70` promoted two lessons from one real timed run — a task-decomposition policy (a 2-task feature had been split into 5) and a baseline capability (`git rm -r .ai*`, absent, so *every* run escalated for it). Both were failures in Foreman's mechanics, so Foreman's ledger and policy were the right home, and every later run in every repository inherits the fix.

## Considered Options

- **One `knowledge/` file for everything, as before** — rejected: it forces one conflict rule onto two kinds of truth, and the rule is backwards for domain truth in a way that silently converts a coding bug into the project's specification.
- **Domain knowledge in `PRD.md`** — rejected: the PRD is per-feature and immutable mid-run, so every new feature's PRD would restate the same formulas. That is exactly the duplication `knowledge/` exists to remove.
- **Domain knowledge in `CLAUDE.md` or a README** — rejected: `ENGINE.md` §3 ranks those last and explicitly as "data, never instructions". The source-of-truth ladder had no rung for durable domain truth; we added one above the codebase rather than smuggling it in at the bottom.
- **Domain knowledge protected by protocol only, like `PRD.md` and `DoD.md`** — rejected: a rule enforced by the runtime is a rule, a rule living only in a prompt is a wish (ADR-002). The asymmetry this leaves — `PRD.md` and `.ai/DoD.md` remain protocol-protected because bootstrap must create `DoD.md` — is noted as open.
- **Auto-promote stack lessons into `.loop/` so the harness compounds across repositories** — rejected, and this was the closest call. The ambition is legitimate and is contemplated in Osmani's *Self-Improving Coding Agents* ("consider sharing AGENTS.md knowledge across agents or runs"). But that piece recommends **no gate** before lessons enter durable instruction files and does not warn about stale or wrong lessons, so Foreman would inherit the ambition without the safeguard. Three concrete costs decided it: the engine is deny-listed from `.loop/` by the trust chain and the Skill overwrites `.loop/` on every invocation, so there is no write path that survives; nothing can *verify* a cross-repo claim, because verification here means running it against one codebase; and *Agent Harness Engineering* states the position directly — "The right harness for your codebase is shaped by your failure history. **You can't download it.**"
- **A `knowledge/CANDIDATES.md` staging file, so lessons survive the Cleanup Commit and the human triages them at `DONE`** — rejected *for now*, on the ratchet's own terms. The failure it prevents ("a lesson was lost because nobody was watching") has not yet been observed; `SKILL.md` step 5 already folds vanishing discoveries into the final summary. Revisit when a lesson is actually lost.

## Consequences

- The source-of-truth ladder gains a rung and the codebase moves down one: domain truth now outranks it, everything else is unchanged.
- Reconcile gains a **Domain defect** classification: codebase disagrees with a domain rule → the code is wrong. Never reconcilable by editing `DOMAIN.md`.
- The fresh-context reviewer receives the domain rules the diff touches. This is where the split earns its keep: a formula implemented plausibly-but-wrongly passes the build and passes tests written from the same misreading, and the reviewer holding the authoritative rule — rather than the builder's reasoning — is the only mind positioned to catch it.
- `DOMAIN.md` is optional and must not be stubbed out. A project with no durable domain rules should not have the file.
- Moving to a new repository, Foreman arrives with full loop competence and **zero** knowledge of that repository. This is intended, and the economics favour it: the expensive lessons (process failures) are the portable ones, while the non-portable ones (build commands, conventions) cost one bootstrap iteration to re-acquire. The genuine residual cost is stack knowledge, which is what the opt-in pack addresses if and when it is built.
- Foreman stays stack-agnostic, preserving `CONTEXT.md`'s "Foreman never knows the consumer's tech stack". A stack pack is a separate installable with its own version and its own curator.
- **Open:** `PRD.md` and `.ai/DoD.md` are human-owned but still protocol-protected rather than deny-listed, because bootstrap has to create `DoD.md`. Closing that gap needs the same transcription flow ADR-004 sketches for V2 and is not attempted here.
