# Loop Runtime

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

That's Loop Runtime. Rule 1 is why it can run for hours with nobody watching. Rule 2 is why it builds the *right* thing. Rule 3 is why "done" actually means done. Rule 4 is why you can walk away without worrying.

### Now the grown-up version

Loop Runtime is a **portable autonomous execution engine for Claude Code**. You hand it a requirement; it plans, implements, builds, tests, reviews and verifies until the feature is provably finished, stopping only at genuine decision points. It's two pieces:

| Piece | What it is | Where |
|---|---|---|
| **The skill** (`/loop-runtime`) | Your on-ramp. Installs the runtime, saves your requirement as `PRD.md`, launches the engine in the background, streams its work into your chat, and turns every decision point into a normal question. | `skills/engineering/loop-runtime/` |
| **The engine + runtime** | The actual loop. A deliberately dumb PowerShell script (`run.ps1`) that re-runs Claude Code over and over, reads back **one word** each time (`CONTINUE` / `DONE` / `ESCALATE` / `FAILED`), and reacts mechanically. All the thinking lives in `ENGINE.md`, a spec injected as the AI's system prompt — never in the script. | `.loop/` |

Day to day you only touch the skill. It exists precisely so you never have to open `.loop/` yourself.

**What you get at the end:** one local git branch (`loop/<your-feature>`) holding the code, the tests, and a final commit message listing every checklist item with the evidence that proves it. Nothing pushed. Nothing merged. That last step is always yours.

---

## 2. How to use it

### Install once per repository

```
npx skills@latest add Phong-Kaster/Foreman
```

That drops the `loop-runtime` skill into `.claude/skills/loop-runtime/` (and `.agents/skills/loop-runtime/`) and records it in `skills-lock.json` — the same way you'd install any shared Claude Code skill. Nothing else to copy by hand.

> **Don't want the installer?** `.loop/` is a self-contained folder. Copy it into any repo's root and run `powershell .loop/run.ps1` from a terminal. Full instructions: [docs/consumer-guide.md](./docs/consumer-guide.md).

### Then start a run

```
/loop-runtime <describe what you want, in plain text>
/loop-runtime <path to a requirements document>
/loop-runtime
```

- **Plain text** — `/loop-runtime add a dark mode toggle to Settings that persists via DataStore`. Your words are saved into `PRD.md` **exactly as you typed them**. Nothing rewritten, nothing summarized.
- **A file path** — `/loop-runtime C:\reqs\dark-mode.md`. That document becomes the requirement instead.
- **Nothing at all** — continues with whatever `PRD.md` is already there. (First run in a fresh repo? It'll ask you for one.)

### What happens next

1. **It looks around.** Reads your requirement, inspects the repo (language, build tool, conventions), creates a branch, and writes down what it worked out.
2. **It asks you the one important question.** *"Here's my checklist of what 'done' means — approve it? And may I have permission to run your build and test commands?"* This is the **only** stop that always happens. Read the checklist properly. Five minutes here is the highest-value five minutes of the whole run — it's what stops the robot from confidently building the wrong thing for three hours.
3. **It works, and you watch — or don't.** Every line the engine writes streams into your chat: which files it's touching, which commands it's running, whether tests passed. Go make coffee. It never ties up your terminal.
4. **It interrupts you only for real reasons.** Anything above its pay grade — change the architecture? the requirement is ambiguous? needs a risky key? — arrives as a normal chat question, with the engine's own suggested options as your choices. You answer in chat; it records your answer and carries on. You never open a file to reply.
5. **It proves it's finished.** A fresh run that wrote none of the code re-tests every checklist item, wipes its scratch notes off the branch tip, and reports `DONE`.
6. **You get a summary of every branch** — not just this one. What's mergeable, what's still going, what's stuck waiting on you.
7. **You merge.** Always you. The engine never pushes, never merges, never touches your default branch.

### A real run (not a hypothetical)

`/loop-runtime write a hello world notification`, in an empty scratch repo:

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
├── skills/engineering/loop-runtime/   ← THE SKILL — what the installer installs
│   ├── SKILL.md                        the skill's own instructions
│   ├── ENGINE.md                       the AI's operating contract
│   ├── POLICIES.md                     engineering policy (retries, reviews, evidence)
│   ├── capabilities/baseline.json      the starter keyring — safe stuff only
│   ├── templates/                      blueprints for .ai/ and knowledge/
│   └── scripts/run.ps1                 the loop script
│
├── .loop/                             ← THE SAME THING, standalone — for manual installs
├── tests/                             ← Pester tests for run.ps1, driven by a fake `claude`
│                                        stub — no API calls, no cost
├── docs/  ├── architecture.md          the complete design
│          ├── consumer-guide.md        manual-install operating manual
│          └── adr/                     why each big decision was made
├── CONTEXT.md                          the glossary
└── README.md                           this file
```

### What appears in *your* repo when you use it

```
your-repo/
├── .claude/skills/loop-runtime/   ← the installed skill
├── .loop/                         ← the runtime, refreshed on every /loop-runtime
├── PRD.md                         ← yours. what you want.
├── .ai/                           ← the robot's working notes for this run. Disposable —
│                                    removed from the branch tip when it finishes.
└── knowledge/                     ← what it learned about your repo (build commands,
                                     quirks, conventions). Survives every run. Edit freely.
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
