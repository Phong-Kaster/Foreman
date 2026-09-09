# Foreman

**You say what you want. A robot builds it while you go do something else. You check the result at the end.**

That is the whole idea. The rest of this page explains it slowly — small words first, precise words second.

> Human owns intent. The loop owns execution.
> The agent forgets. The repository doesn't.
> The engine requests. The human decides. The runtime enforces.

---

## 1. What is it?

### Explain it like I'm five

Imagine you hire a builder with one very strange problem: **every morning, they forget everything.**

No memory of yesterday. None. Most people would say that builder is useless. This project makes them genuinely good, using three rules.

**Rule 1 — Write everything down.**
Before the builder is allowed to stop, they must write in a notebook that stays on the desk: what I did, what I learned, what's next. Next morning a brand-new builder reads the notebook and carries on. The notebook is the repository. That's why forgetting stops being a problem.

**Rule 2 — *You* decide what "finished" means.**
On day one the builder writes a checklist: *"when this is done, the app will do X, Y and Z — and here is how you can check each one."* **You read that checklist and approve it.** After that the builder may never change it. It's their exam, and nobody gets to rewrite their own exam.

**Rule 3 — The builder is not allowed to say "I'm done."**
When the work looks finished, a *different* builder — one who wrote none of it — walks in, re-tests every item on your checklist from scratch, and only *that* builder may say "done."

And one more, about keys:

**Rule 4 — Keys are borrowed, not owned.**
The builder starts with keys to the safe stuff only (read files, save work locally). If they need a key to something riskier — deleting things, reaching the internet, running your build tools — they must **ask you**, and say why, for what, and for how long. Most keys expire on their own when the job ends. The builder can never cut themselves a new key.

That's Foreman. Rule 1 is why it can run for hours with nobody watching. Rule 2 is why it builds the *right* thing. Rule 3 is why "done" actually means done. Rule 4 is why you can walk away without worrying.

### Now the grown-up version

Foreman is a **portable autonomous execution engine for Claude Code**. You hand it a requirement; it plans, implements, builds, tests, reviews and verifies until the feature is provably finished, stopping only at genuine decision points. It's two pieces:

| Piece | What it is | Where |
|---|---|---|
| **The skill** (`/foreman`) | Your on-ramp. Installs the runtime, saves your requirement as `PRD.md`, launches the engine in the background, streams its work into your chat, and turns every decision point into a normal question. | `skills/engineering/foreman/` |
| **The engine + runtime** | The actual loop. A deliberately dumb PowerShell script (`run.ps1`) that re-runs Claude Code over and over, reads back **one word** each time (`CONTINUE` / `DONE` / `ESCALATE` / `FAILED`), and reacts mechanically. All the thinking lives in `ENGINE.md`, a spec injected as the AI's system prompt — never in the script. | `.loop/` |

Day to day you only touch the skill. It exists precisely so you never have to open `.loop/` yourself.

**What you get at the end:** one local git branch (`loop/<your-feature>`) holding the code, the tests, and a final commit message listing every checklist item with the evidence that proves it. Nothing pushed. Nothing merged. That last step is always yours.

---

## 2. How to use it

### Before you start

Four things need to be true, or the first run fails on the doorstep:

| You need | Why |
|---|---|
| **A git repository** | Every save point is a commit. Start from a clean working tree — the engine treats leftover uncommitted changes as debris from a crash. |
| **Claude Code CLI, logged in** | The loop calls `claude` once per cycle. If `claude` isn't on your `PATH`, nothing happens. |
| **Windows PowerShell** | V1 ships `run.ps1` only. A `run.sh` waits for the first non-Windows user. |
| **Node.js** | Only for the installer (`npx`). The loop itself doesn't need it — unless *your* project does. |

### Install once per repository

```
npx skills@latest add Phong-Kaster/Foreman
```

That drops the `foreman` skill into `.claude/skills/foreman/` (and `.agents/skills/foreman/`) and records it in `skills-lock.json` — the same way you'd install any shared Claude Code skill. Nothing else to copy by hand.

> **Don't want the installer?** `.loop/` is a self-contained folder. Copy it into any repo's root and run `powershell .loop/run.ps1` from a terminal. Full instructions: [docs/consumer-guide.md](./docs/consumer-guide.md).

### Then start a run

```
/foreman <describe what you want, in plain text>
/foreman <path to a requirements document>
/foreman
```

- **Plain text** — `/foreman add a dark mode toggle to Settings that persists via DataStore`. Your words are saved into `PRD.md` **exactly as you typed them**. Nothing rewritten, nothing summarized.
- **A file path** — `/foreman C:\reqs\dark-mode.md`. That document becomes the requirement instead.
- **Nothing at all** — continues with whatever `PRD.md` is already there. (First run in a fresh repo? It'll ask you for one.)

### What happens next

1. **It looks around.** Reads your requirement, inspects the repo (language, build tool, conventions), creates a branch, and writes down what it worked out.
2. **It asks you the one important question.** *"Here's my checklist of what 'done' means — approve it? And may I have permission to run your build and test commands?"* This is the **only** stop that always happens. Read the checklist properly. Five minutes here is the highest-value five minutes of the whole run — it's what stops the robot from confidently building the wrong thing for three hours.
3. **It works, and you watch — or don't.** Every line the engine writes streams into your chat: which files it's touching, which commands it's running, whether tests passed. Go make coffee. It never ties up your terminal.
4. **It interrupts you only for real reasons.** Anything above its pay grade — change the architecture? the requirement is ambiguous? needs a risky key? — arrives as a normal chat question, with the engine's own suggested options as your choices. You answer in chat; it records your answer and carries on. You never open a file to reply.
5. **It proves it's finished.** A fresh run that wrote none of the code re-tests every checklist item, wipes its scratch notes off the branch tip, and reports `DONE`.
6. **You get a summary of every branch** — not just this one. What's mergeable, what's still going, what's stuck waiting on you.
7. **You merge.** Always you. The engine never pushes, never merges, never touches your default branch.

### Watching it work

The chat is the live view, but everything also lands in a log file on disk. `run.ps1` prints the exact path when it starts — it's `%TEMP%\loop-run-<your-repo-folder-name>.log`. Follow it from any other terminal:

```powershell
Get-Content "$env:TEMP\loop-run-<your-repo-folder-name>.log" -Wait -Tail 20
```

What you'll see — one line per action, each stamped with a stopwatch showing how deep into the current cycle it is:

```
=== Iteration 2 / 50 === 2026-09-09T20:35:30.4821637+07:00
[20:35:41 +00:00:10] engine> Read .ai\STATE.md
[20:36:02 +00:00:31] engine> Bash ./gradlew.bat assembleDebug
[20:39:14 +00:03:43] engine: Build succeeded. Running the test suite next.
[20:44:58 +00:09:27] engine invocation finished (success)
=== Status: CONTINUE === 2026-09-09T20:44:58.9930412+07:00
```

New lines appearing = it's alive. The console it was launched from shows the same feed with friendlier headers — `started 20:35:30 | total elapsed 00:04:44` in place of the raw timestamps — and there's a `.raw.jsonl` beside the log holding the unfiltered event stream, for when something is genuinely weird.

**You can kill it at any time.** Close the terminal, stop the skill, reboot — it's safe. Every cycle ends at a commit, so the next run picks up from the last one. If it died *mid*-cycle, the next run notices the dirty working tree and either salvages the work or throws it away — it never builds on top of unverified debris.

**Only one loop per repository.** A second one refuses to start while the first holds the lock. Two engines committing to the same branch would corrupt the run.

### When it stops — and what to do

Five ways a run ends. Only the first two need anything from you:

| It stopped with | Meaning | What you do |
|---|---|---|
| `ESCALATE` (3) | A decision above its authority: approve the checklist, resolve an ambiguous requirement, grant a permission, or approve an architecture change. | Answer the question. That's it — the skill records your answer and restarts it. |
| `FAILED` (4) | Execution itself is broken: build tool missing, disk full, repo corrupted. Not "the task was hard". | Fix the environment, then start it again. It resumes from the last commit. |
| `DONE` (0) | A fresh verifier re-proved every checklist item. | Review and merge (below). |
| Watchdog (2) | The AI died without reporting, 3 times in a row. | Usually a transient CLI or network problem. Start it again. |
| Budget (5) | Hit the 50-cycle ceiling. | Not a verdict on the work — a deterministic stop. Check `.ai/STATE.md` to see where it got to, then continue. |

**What makes a good answer when it asks:** you may always **narrow** a request — tighten a vague checklist item, cut the permission down to a single command, say "console output, not a desktop notification". You can't accidentally widen anything; the engine can only ever get less than it asked for. And say *why* — your reason gets recorded in the audit trail alongside the decision, which is what makes the branch readable in three months.

### Reviewing and merging

When it reports `DONE`, the branch tip holds the code, the tests, updated `knowledge/`, and **no scratch notes** — those were stripped in the final commit, whose message is the completion summary.

```powershell
git branch --list 'loop/*'              # every run this repo has ever done
git log --oneline loop/<prd-slug>       # the execution history, cycle by cycle
git log -1 loop/<prd-slug>              # the completion summary: criteria -> evidence
git diff main...loop/<prd-slug>         # everything it changed, as one review
git merge loop/<prd-slug>               # your call, your hands
```

- **Next feature:** `/foreman <the next requirement>` in the same repo. A new branch and new scratch notes get created, but `knowledge/` carries over — the build commands and environment quirks it learned the hard way are paid for once, not once per feature.
- **Abandoning a run:** delete `.ai/` and delete the branch. Nothing else to clean up, and your default branch was never touched.

Full operating manual — every `run.ps1` parameter, the manual (non-skill) path, and the engine's hard limits: [docs/consumer-guide.md](./docs/consumer-guide.md).

### A real run (not a hypothetical)

`/foreman write a hello world notification`, in an empty scratch repo:

- **It set up:** confirmed Node was installed, created the branch `loop/hello-world-notification`, wrote its plan and its checklist.
- **It asked two questions.** First: *"approve this checklist — and by 'notification' did you mean printing to the console (my recommendation, no dependencies) or a real desktop pop-up (needs a new permission)? Also, may I run `node`?"* Answered in chat. Later: *"final checks passed. May I have a one-time permission to delete my scratch folder for the cleanup commit?"* Granted — and it expired the moment it was used.
- **It built:** `src/notify.js`, `test/notify.test.js`, updated README. Build and tests green. A separate reviewer sub-agent — given only the diff, the task and the checklist, *never* the reasoning behind the code — raised two minor notes and nothing serious.
- **Result:** one merge-ready branch, 6 commits, two questions asked, zero files opened by hand.

### When *not* to use it

The cost per cycle is roughly fixed; the benefit grows with the size of the job. So:

| Your task | Use |
|---|---|
| A small fix, one file, something you'd finish in one sitting | A normal chat session — the loop's overhead will just feel slow |
| A real feature you'd otherwise babysit prompt-by-prompt for hours | **The loop** — the overhead disappears into the size of the job |
| Anything you want running overnight, or while you do other work | **The loop** — that's exactly what it's for |

Don't judge it by a hello-world. Judge it by whether it got a real feature right while you weren't looking.

---

## 3. How this repo applies loop engineering

**Loop engineering** (a concept from Addy Osmani) is a change in *your* job. Normally you sit beside the AI and poke it: "now do this… no, not like that… okay now run the tests." In loop engineering you stop being the poker. You write down what you want once, and you design the *loop* that drives the AI. You own **intent**; the loop owns **execution**.

This repo builds that idea out of five moving parts. Small words first, real name second.

### a) The forgetful builder with a notebook

*Every cycle is a brand-new AI process with zero memory. It learns everything from files in the repo, and must write everything it learns back into them.*

Here's the clever bit: because *every* cycle starts from scratch, the question "could this survive a crash and resume?" gets **tested every few minutes** instead of merely hoped for. If the notebook were missing something, cycle 2 breaks loudly and immediately — not months later at the worst possible moment.
→ *stateless iterations* ([ADR-002](./docs/adr/ADR-002-stateless-iteration-dumb-runtime.md))

### b) A timer that knows four words

*The script running the loop is deliberately stupid. It doesn't understand code, plans, or progress. It runs the AI once, reads back one word, and reacts:*

| Word | Meaning | What the script does |
|---|---|---|
| `CONTINUE` | progress saved, more to do | run it again |
| `DONE` | verified finished | stop — success |
| `ESCALATE` | I need a human decision | stop — ask you |
| `FAILED` | something is genuinely broken | stop — ask you to repair it |
| *(silence)* | the AI died mid-sentence | try again, up to 3 times, then stop |

Why keep it stupid? Because a rule enforced by a script **is** a rule, while a rule living only inside a prompt is a *wish*. "Stop and ask before changing the architecture" is enforced here by the process genuinely exiting — not by the AI remembering to behave.
→ *the dumb runtime and the status contract*

### c) The exam you write, and they can't touch

*Your requirement (`PRD.md`) is yours forever — the AI may propose changes but never make them. From it, the AI drafts a checklist of testable criteria, and you approve it. Then that's locked too.*

Notice what you *don't* approve: the plan. How to get there is the machine's business. What "done" means is yours.
→ *PRD + Definition of Done, and tiered mutability* ([ADR-001](./docs/adr/ADR-001-prd-and-dod-source-of-truth.md))

### d) Three different minds

*One AI builds it. A second AI checks it — and is shown only the diff, the task and the checklist, **never** the first one's reasoning. A third AI, which wrote nothing at all, decides whether the whole thing is finished.*

Why hide the reasoning? Because the usual way self-review fails isn't sloppiness — it's a **shared wrong assumption**. The mind that made the mistake is the worst possible mind to catch it. So the checker never gets to read the story that contained the mistake.
→ *fresh-context review + the DONE-candidate rule* ([ADR-005](./docs/adr/ADR-005-fresh-context-review-done-candidate.md))

### e) A keyring where every key has a note on it

*Every permission carries four things: why, which command, where, and for how long. Most expire by themselves when the job ends. You can always narrow a request — the AI can never widen one.*

The chain only runs one way: **you → the keyring file → the script that compiles it → the AI.** The AI cannot edit the keyring, cannot edit the script, and cannot write its own permissions file. If it could, asking permission would be theater.

Stated honestly: this is a guardrail against **accidents and drift**, not a wall against a genuinely hostile AI. Matching on command text will always be a little leaky. If you need real containment, run the whole thing in a VM.
→ *capability-based permissions and the trust chain* ([ADR-004](./docs/adr/ADR-004-capability-permission-and-trust-chain.md))

### And everything leaves a paper trail

Each cycle is one git commit holding the code *and* the notes together, so the two can never disagree. Every plan change is logged with its reason. Every decision you make is stored with your rationale. `git log` on the branch **is** the story of how the feature got built.

### Word swaps

| I said | The docs say |
|---|---|
| what you want | PRD |
| the checklist | Definition of Done (DoD) |
| the notebook | `.ai/` (this run) and `knowledge/` (worth keeping forever) |
| the house rules only you can change | `knowledge/DOMAIN.md` — Domain Knowledge |
| "a rule has to be earned by a real mistake" | the Ratchet |
| one cycle | an Iteration |
| a save point | a Stable Checkpoint (one git commit) |
| "I need to ask you something" | an Escalation Request → `ESCALATE` |
| a key with a note on it | a Capability |
| the stupid timer script | the Runtime (`run.ps1`) |
| the AI doing the work | the Execution Engine (`ENGINE.md`) |

Full glossary: [CONTEXT.md](./CONTEXT.md). Full design: [docs/architecture.md](./docs/architecture.md). The reasoning behind each hard-to-undo choice: [docs/adr/](./docs/adr/).

---

## What's in this repo

```
Foreman/
├── skills/engineering/foreman/       ← THE SKILL — what the installer installs
│   ├── SKILL.md                      the skill's own instructions
│   ├── ENGINE.md                     the AI's operating contract
│   ├── POLICIES.md                   engineering policy (retries, reviews, evidence)
│   ├── capabilities/baseline.json    the starter keyring — safe stuff only
│   ├── templates/                    blueprints for .ai/ and knowledge/
│   └── scripts/run.ps1               the loop script
│
├── .loop/                            ← THE SAME THING, standalone — for manual installs
├── tests/                            ← Pester tests for run.ps1, driven by a fake `claude` stub
├── docs/
│   ├── architecture.md               the complete design
│   ├── consumer-guide.md             manual-install operating manual
│   └── adr/                          why each big decision was made
├── CONTEXT.md                        the glossary
└── README.md                         this file
```

### What appears in *your* repo when you use it

```
your-repo/
├── .claude/skills/foreman/   ← the installed skill
├── .loop/                    ← the runtime, refreshed on every /foreman
├── PRD.md                    ← yours. what you want.
├── .ai/                      ← the robot's working notes for this run. Disposable —
│                               removed from the branch tip when it finishes.
└── knowledge/                ← survives every run. Three files, three rules:
    ├── PROJECT.md            ← what it learned about your repo (build commands,
    │                           quirks, conventions). CONFORM to it; code wins.
    ├── ISSUES.md             ← what it knows is still broken and didn't fix.
    │                           AVOID it. Deleted per entry once fixed.
    └── DOMAIN.md             ← your domain rules and formulas. Optional. Only YOU
                                write it. IMPLEMENT it; it beats the code.
```

---

## Status

**V1 works on real projects, validated twice:**

- **A real consumer project** (Android Jetpack Compose, 2026-07-08, manual install). Every contract fired correctly — including the engine refusing to declare its own work finished and deferring to a clean verifier, unprompted.
- **Skill packaging, end to end** (scratch repo, 2026-07-15). Install → run → live streaming → two real questions answered in chat → `DONE` → summary, without opening a single file by hand. Found and fixed one real bug on the way: the skill needed `disable-model-invocation: true`, or a nested engine run in the same repo could trigger the launcher on itself.

**Known rough edges, being worked on:**

- Compound shell commands can be denied even when the base command is approved (e.g. `cd X && node …`). The engine worked around it both times it happened, but it costs a retry — the permission format needs tightening.
- Plan granularity doesn't scale down for small requirements yet: a 2-task feature got split into 5, paying full overhead five times.
- **Fixed:** a log file-lock once killed an entire run. Log writes are now shared-mode and fail-silent, and only one loop may run per repository. Observability must never be able to kill execution.
- Cosmetic: the engine's and the script's cycle counters disagree; UTF-8 punctuation shows as mojibake on default Windows code pages.
- Portability to other AI CLIs (Codex, Gemini) is confined to a single adapter surface inside `run.ps1` — see [ADR-006](./docs/adr/ADR-006-engine-adapter-boundary.md).

This repo stays deliberately small. New structure has to earn its place through real use, not anticipated complexity. Everything deliberately postponed — and what would make us revisit it — is listed in [docs/architecture.md §12](./docs/architecture.md).
