# A Worker writes at most six files and reads only what it needs

On 2026-10-13, Kanso Run 7's Iteration 5 dispatched one Opus Worker for T-003, the per-tool screen. T-003's
Declared File Scope held 18 files: six production files and twelve tests. Measured from the session
transcripts, between 14:32 and 14:44:

- In its first 75 seconds the Worker read about 15 whole files, `DoD.md` three times among them. Its
  context reached 150K tokens before it wrote a line.
- It made 49 calls. Each one re-sent the whole context, which grew from 7K to 258K tokens: 7.9M cached tokens
  read, 248K written to cache, and 79K tokens of output.
- It cost $4.41 in API-equivalent terms, 94% of the Iteration's $4.67. The orchestrator, on Sonnet, cost $0.26.
- Over the same 12 minutes the account's five-hour window rose from 2% to 33%. Foreman was about half of
  that; the rest was a review and two interactive sessions on the same account.

The problem is not new to this run. In Iteration 3 the T-001 Worker's context reached 420K tokens, and the
iteration took the five-hour window from 14% to 95% in 30 minutes before stopping on the limit.

Lowering effort did not help, and could not have. Both tiers moved from `xhigh` to `medium` earlier the same
day (ADR-038's note). Effort governs how much the model thinks and writes; here writing was 1% of the tokens.
The cost is reading: total cost is roughly *calls × average context*, and a bigger task raises both at once,
so doubling a Worker's work roughly quadruples its cost.

## The decision

**One Worker writes at most 6 files.** A task whose Declared File Scope is larger is dispatched as sequential
**slices** of at most 6 files, production files before the tests that exercise them, one fresh Worker per
slice. The task stays one task: one set of acceptance criteria, one attempt counter, one build and test after
the last slice, one checkpoint. Only the Worker context is cut. A later slice gets the earlier slices' files as
pointers, the same mechanism a Brief already uses for interfaces earlier Phases created. A failure is
attributed to the slice whose file it names, and that slice is reverted and re-dispatched as one attempt
against the task. The rule lives in `POLICIES.md` (Worker Standards) and `ENGINE.md` §6.5.

**A Worker reads narrowly.** The Brief now quotes the text of every DoD criterion the task cites, so the
Worker has no reason to open `DoD.md`. The Worker's own instructions (`agents/loop-worker.md`, rule 7) tell it
to find a line with Grep before reading, to read a range rather than a whole long file, and never to re-read a
file it has not changed.

Six is the starting value, not a measured optimum: it cuts T-003 into three slices. Estimated from this run,
three slices of about 16 calls each starting near 60–90K would re-read 3–4M tokens instead of 7.9M. That is
arithmetic, not a measurement; the next run that dispatches a sliced task is the measurement.

**Decided by the human, 2026-10-13:** the two changes above, chosen from three. Moving Workers to the Fast
tier was offered and not taken.

**What would change this.** If a sliced task's total Worker cost is not clearly below what one Worker would
have cost, or slices start failing on interfaces an earlier slice was meant to provide, the cap is wrong:
raise it or measure size in a different unit.

## Considered Options

- **Split large tasks at planning time into separate tasks** — rejected, and the closest call. It reuses
  machinery that already exists. But `POLICIES.md` requires each task to be an observable checkpoint, and
  "migrate twelve tests to the new screen" has no observable behaviour of its own. Every extra task also buys
  its own review and checkpoint overhead, which is cost the change exists to remove.
- **Cap by tokens instead of files** — rejected. The engine cannot know a Worker's context before dispatching
  it; it does know the file list, because the plan already records it for Phase grouping. Files are a proxy,
  and a usable one.
- **Run slices concurrently** — rejected. A later slice reads what an earlier one wrote, and concurrent
  Workers spend the usage window faster, which `POLICIES.md` already advises against when quota binds.
- **Lower effort further** — rejected. Output was 1% of the Worker's tokens.
- **Move Workers to the Fast tier** — not chosen by the human. It halves the price per token but leaves the
  growth untouched, and a wrong Fast classification costs an attempt.

## Consequences

- A task like T-003 costs three Brief preambles (Constraints, task text, quoted criteria — a few thousand
  tokens each) instead of one, in exchange for three contexts that each start small.
- The Brief grows by the quoted criteria, and `DoD.md` leaves every Worker's context.
- Slices of one task run one after another, so a sliced task takes longer by wall clock.
- **Not solved:** the file count is a proxy. Six files of 1,000 lines each still make a large context; reading
  ranges is what keeps that case in check, and nothing enforces it beyond the instruction.
- **Not solved:** the orchestrator's own context. Iteration 4's Sonnet orchestrator carried 144K and re-read
  4.4M tokens, and slicing adds a Brief out and a manifest back per slice to it.
- **Not solved:** the account limit itself. On 2026-10-09/10 a full five-hour window held about $100 of API-
  equivalent usage; on 2026-10-13 it held about $25–28 on both accounts used. This ADR reduces what Foreman
  spends; it does not explain that change.
- **Open:** whether 6 is the right number. It should be re-measured on the first run that slices a task.
