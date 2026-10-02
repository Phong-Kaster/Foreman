# A DoD criterion is written twice: once for the person who approves it, once for the engine that proves it

The Definition of Done is the one gate a person always sees, and the one they are told to read
properly. On Calendar-Note `loop/music-player-v3` (bootstrap `b5f678a`, 2026-09-29) its 32 criteria
were written for a command to read. Criterion 8, in full, began:

> Driven from 6: tap the first song row (uiautomator). `adb shell dumpsys media_session` lists a
> session for `$PKG` with `state=PlaybackState {state=3` or `state=PLAYING(3)` (regex ...

The human approved the DoD verbatim ("duyệt DoD nguyên văn") and the run went on. On 2026-10-02,
reading the same criteria on the page built for them, they said they were hard to understand. A gate
the person cannot read is not a gate: approving it is a stamp, and the one decision Foreman reserves
for the human is made without being made.

The criteria were not wrong. Their precision is what lets a Verifier re-prove them from a checkpoint,
and it is why criterion 4 names the state it is driven from (ADR-030). The fault was that one text had
two readers who need opposite things.

**Decided by the human, 2026-10-02:** write each criterion so the person can understand it, and write
what the engine needs separately; **always in English**.

**What would change this assessment.** A run whose Verifier proved a criterion's Proof while the
sentence above it was false - the two halves drifting apart - would argue for checking the pairing
mechanically, or for going back to one text.

## The decision

Every criterion is two lines in `DoD.md`, under one number:

```
8. [machine] Tapping a song plays it.
   Proof: `dumpsys media_session` shows the app's session in state PLAYING(3) with the tapped
   song's title, driven from a fresh install with the permission granted.
```

The first line is the **person's**: one plain sentence about what they will see or be able to do, with
no commands, paths, class names, ids or regexes. It is what they approve. The indented `Proof:` line is
the **engine's**: everything a command or the Verifier needs, including the state it is driven from. A
Proof that checks less than its sentence promises is a defect, not a shorthand.

`FOREMAN.html` shows the sentence and folds the Proof away under it ("How the engine checks it").
`ENGINE.md` §5 carries the rule with its evidence; the DoD template shows the shape on every example
criterion, Removals included. When the `/foreman` skill summarises a DoD in chat it uses the sentences,
never the Proofs.

The renderer also reads the shape an earlier DoD had already found for itself: Calendar-Note's Alarms
DoD (2026-09-13) wrote `**1. [machine] The whole app, including every new screen, compiles.**` with the
technical detail after the bold sentence. A bold sentence is read as the sentence and the rest of the
line as its Proof. That run had found the split without being asked; this ADR makes it the rule.

## Considered Options

- **Two files, a plain `DoD.md` for the person and a technical one for the engine** - the closest
  call, and the literal reading of the request. Rejected: the human approves one file while the engine
  is graded against the other, and nothing pairs them. A Proof could quietly prove less than the
  sentence it stands for, in a file the person never opens. Two lines under one number cannot be
  separated, and the page still shows the person only their half.
- **Write the sentence in the PRD's language** - offered, and declined by the human: always English,
  like everything else the engine writes. The page's chrome stays bilingual.
- **Keep one text and let the page simplify it** - rejected: simplifying a criterion is judgement, and
  the Runtime makes none (ADR-002). The engine writes both halves; the Runtime only lays them out.
- **Drop the technical detail from the DoD and keep it in the task files** - rejected: the DoD is
  immutable after approval and the task files are not, so the proof of a criterion would become
  something the engine can quietly weaken.

## Consequences

- A DoD grows by roughly one line per criterion. The person reads less of it, not more: the page shows
  32 sentences where it showed 32 paragraphs.
- Every earlier DoD still renders. Without a `Proof:` line a criterion shows as it always did, and a
  bold sentence is split as above.
- **Not solved:** nothing checks that a Proof covers its sentence. The Reviewer and the Verifier read
  both, and the rule says a weaker Proof is a defect, but it is a rule in prose.
- **Not solved:** a sentence can still be written badly - plain words that say nothing a person can
  check. The template's examples and the person at the gate are the only defence.
