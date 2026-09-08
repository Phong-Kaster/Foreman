# Orientation reads a small Resume Block; audit history leaves the read path

Every Iteration is a fresh process that must reconstruct its context from the repository (ADR-002). The cost of that reconstruction was the one cost in the loop that both **grew monotonically** and was **never cacheable** — tool reads sit after the cacheable system-prompt prefix, so they are always paid in full. Measured on a real run, the orientation set grew 2.7x over three Iterations because history is append-only.

Two changes bound it, without touching the memory model:

**The Resume Block.** The engine ends each Iteration by writing one small file containing exactly what the next Iteration needs: current Stage, the next Phase's task ids with their Declared File Scopes, the count of queued decisions, abandoned task ids, and the verified build/test commands. Files that grow monotonically leave the orientation path entirely — iteration history moves to `HISTORY.md`, **successful** task evidence moves into the checkpoint commit message (ADR-003 already establishes `git log` as the execution history), `AMENDMENTS.md` becomes write-only, and the capability ledgers are not read at all, since the Runtime compiles them and a denied action is simply a discovery.

**The Worker Brief.** A Worker receives its own task, its Declared File Scope, the *status* of other tasks — never their content or their story — pointers to interfaces created by earlier Phases, and the conventions it needs. Its handoff back is a **manifest, not a payload**: files written, behavior now working, anything it could not do. The parent reads the diff from `git diff`, never from the Worker's report, so the parent's context stays bounded regardless of how much code was written.

## Considered Options

- **Carry the conversation transcript between Iterations** — rejected. The transcript accumulates every build log, test output, and diff, so it outgrows the state files it would replace within a few Iterations; it degrades reasoning as the window fills; and it removes the mechanical hard stop, since the process no longer exits.
- **Keep reading the full state every Iteration (V1)** — rejected for the two properties above: monotonic growth and zero cacheability.
- **Give each Worker the full state** — rejected: it is the largest avoidable cost in a Phase, because it multiplies by Worker count.
- **Give a Worker the content of earlier Phases' work** — rejected: a pointer costs roughly twenty tokens and the Worker reads from the repository on demand only if it actually needs the interface.
- **Trim `ENGINE.md` itself** — deferred. It is the operating contract, it sits in the cacheable prefix, and shortening a specification to save tokens risks the obedience the whole loop depends on.

## Consequences

- **The Resume Block is a derived cache, never a source of truth.** Where it disagrees with the task files or git, it loses. Anything it does not cover, the engine reads from source, and Recover (a dirty working tree) always goes to ground truth. ADR-002's property is preserved: still a fresh process, still reconstructing from the repository — the memory is simply small and purpose-built instead of a growing journal.
- Orientation cost becomes **flat**: Iteration 40 reads what Iteration 2 read. Estimated from measured file sizes at chars/4, the orientation set falls from roughly 6,800 tokens to roughly 800–1,700 depending on how far the splits go.
- **Within a Phase, Workers are blind to each other by design**, and that is safe precisely because the non-conflict criterion (ADR-008) guarantees they never need to see each other. Across Phases, a Worker sees earlier work as committed code, guided by pointers.
- **Measured, not assumed.** Prompt caching *does* survive across separate `claude -p` processes. Two back-to-back invocations sharing the same `--append-system-prompt-file` prefix (~27,700 tokens: the Claude Code default prompt plus `ENGINE.md`) served **86% of it as `cache_read`** on the second call. So the spec is billed at roughly a tenth of base input, and its size is not the thing to optimize.
- **`--exclude-dynamic-system-prompt-sections` is load-bearing, and worth more than this ADR's own read-path savings.** Measured with a git commit between two invocations — i.e. what every checkpoint does:

  | Second invocation, after repo state changed | `cache_creation` | `cache_read` | hit |
  |---|---|---|---|
  | with the flag | 3,806 | 23,907 | **86.3%** |
  | without it | 9,785 | 18,017 | 64.8% |

  Without the flag, git status sits inside the cached prefix, so **every checkpoint commit invalidates ~6,000 tokens** that must then be re-written at cache-creation rates (~1.25x) instead of read (~0.1x) — a penalty per Iteration larger than the entire orientation read this ADR set out to shrink. The Runtime therefore passes the flag by default, and `-NoStablePrompt` should be understood as opting into that cost.
- A first measurement said the flag made no difference (86.3% vs 87.4%). That test was invalid: both runs were made from a repository whose git state did not change between calls, so the dynamic sections never varied and the flag had nothing to protect. The lesson generalizes — when measuring a cache, the experiment must vary the thing the cache is sensitive to.
- **Failure evidence is the exception, and it must be captured at the moment it happens.** Moving evidence into commit messages works only for work that gets committed; failed work is reverted and enters no commit, so its detail would be lost forever. Each attempt therefore writes the command it ran and the tail of its error output (line-capped) into the task file immediately — three attempts, three entries — and the Issues Report aggregates from there. This is what makes ADR-007's abandonment diagnosable rather than merely recorded.
- A run that ends incomplete never reaches the Cleanup Commit, so `.harness/run/` survives intact on the branch and the failure detail is preserved with no extra mechanism.
- **Measured regression, recorded honestly:** specifying Phases, Workers, the Decision Queue, abandonment, the Resume Block and the Issues Report grew `ENGINE.md` from ~12.9KB to ~20.2KB -- roughly 3,200 to 5,000 tokens of *fixed* per-iteration cost. The orientation read fell by roughly 4-8x in exchange, so the net depends entirely on whether the spec is served from cache: at cache-read rates the growth is negligible, at cache-write rates it costs more than the orientation saving. This makes the cache measurement above the deciding number for the whole design, not a footnote. If the cache does not hit, the first lever is `--exclude-dynamic-system-prompt-sections` (already passed by default, so that per-iteration git status no longer breaks the prefix), and only then trimming the spec.
- Splitting audit out of the read path means audit content must be written *somewhere durable*: `HISTORY.md` in `.harness/run/` (preserved in branch history by the Cleanup Commit) and successful evidence in commit messages, which survive it.
