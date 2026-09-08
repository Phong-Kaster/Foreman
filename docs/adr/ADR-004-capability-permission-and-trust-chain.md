# Capability-based permissions enforced through a three-plane trust chain

Unattended execution requires pre-granted permissions, but a static command allowlist accumulates silent, context-free power over time (permission creep). We chose **Capabilities**: scoped grants carrying intent, command, resource scope, and lifetime — **goal-scoped by default**, expiring automatically with `.harness/run/`. Permanent grants (baseline read/git-local in `.harness/loop/`, per-repo toolchain in `.harness/knowledge/`) require separate explicit approval. Enforcement follows the trust chain:

> Human → Capability Ledger → Runtime Compiler → Permission Settings → Engine

The engine **requests** (structured proposals via Escalation Request), the human **decides** (may reduce scope or lifetime, never the engine expanding it), the Runtime **enforces** (mechanically compiles the approved ledgers into fresh permission settings before every invocation — a build artifact, never a source artifact — always appending deny rules protecting `.harness/loop/`, the ledgers, and the generated settings).

## Considered Options

- **`--dangerously-skip-permissions` as the default** — rejected: it trusts prompt-level obedience, which this architecture rejects everywhere else. Remains available as a documented, consenting-adult flag for sandboxed/VM runs.
- **Static allowlist** — rejected: permission creep; a `Remove-Item` granted to clean build artifacts stays available forever in unrelated contexts.
- **Engine compiles its own settings** — rejected: a process that writes its own permission file has all permissions; escalation becomes theater.
- **Sandbox/container as the packaging** — rejected for V1: fights "copy `.harness/loop/` and run" portability. Documented as the hard-security path.

## Consequences

- V1: the human physically writes approved entries into the ledger (the approval boundary made visible). V2: a structured approval flow where the Runtime transcribes the exact approved block verbatim — authority placement unchanged.
- The `/loop-runtime` Skill is one instance of this V2-style transcription: the human still decides (now via conversation instead of a hand-edited file), and the Skill writes the exact approved entry into the named ledger — standing or goal-scoped, whichever the decision specified — verbatim, never expanding or editorializing it. The boundary the human crosses is identical; only its presentation changed.
- The ledger stores the exact permission rule strings the human approved; the Runtime concatenates, never translates — it cannot interpret or expand intent.
- **Documented limitation:** this is a guardrail against accidents and drift, not a security boundary against an adversarial engine. Hard containment is the VM path.
