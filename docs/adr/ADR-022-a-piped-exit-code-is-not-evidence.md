# A piped exit code is not evidence; `set -o pipefail` is a baseline capability

`POLICIES.md` requires that task completion rest on recorded evidence — command plus observed output — and `ENGINE.md` §10 makes a passing build one of the conditions for completing a task. Neither said anything about *how* the passing build is observed. On Windows, through Git Bash, that gap has a specific shape.

The engine keeps build output small by piping it, which is what every instruction it reads encourages. But:

```
$ false | tail -1 ; echo $?
0
```

The exit status of a pipeline belongs to its **last** command. `./gradlew build 2>&1 | tail -20` exits `0` when the build failed. The engine discovered this itself, in a real run, and wrote it into that repository's `knowledge/PROJECT.md`:

> `./gradlew … 2>&1 | tail -20` exits **0 even when the build failed**, because the exit status belongs to `tail`. This is not theoretical: it is how a `BUILD FAILED` in this repository was first mistaken for a pass.

## Why this ranks above the runtime defects fixed in ADR-021

The failure direction is the opposite one, and that is the whole argument.

| | Failure mode |
|---|---|
| ADR-021 (quota refusal, launch failure) | **Fail-safe.** The run stops. Wasteful, confusing, but nothing false ships. |
| This | **Fail-unsafe.** The run *continues* on a false premise. |

Everything Foreman builds around completion — the Fresh-Context Review (ADR-005), the DONE-Candidate rule, the evidence requirements — is scaffolding around the claim that `DONE` means done. A masked build failure walks through all of it, because every one of those checks is downstream of "the build passed" and none of them re-asks the question. It is the one defect class that produces a confidently wrong result rather than a stopped run.

## The engine could not fix this by itself, and that is the real finding

The engine's note ended by saying both standard remedies were refused by the permission layer. That claim was tested rather than trusted (2026-09-11, `allow: ["Bash(echo*)"]`, permission layer active):

| Command | Result |
|---|---|
| `echo alpha` | ALLOWED |
| `set -o pipefail; echo bravo` | **DENIED** |
| `echo charlie \| tail -1` | ALLOWED |
| `echo delta; echo ${PIPESTATUS[0]}` | **DENIED** |
| `echo bravo > out1.txt` | **DENIED** |
| `echo beta \| node -e "…"` | DENIED |

So the permission matcher **allowed the form that masks the failure and refused every form that exposes it.** The engine was not being careless; it was writing the only command it was permitted to write. Telling it to "read the text instead of the exit code" — the fix first proposed for this — would have been a rule it could follow only by remembering to, which ADR-002 names exactly: *a rule enforced by a script is a rule; a rule living only in a prompt is a wish.*

Two further results shaped the fix:

- **Redirection is refused too**, so "write to a file and grep it" is not the escape hatch it looks like.
- **A pipeline is not a permission bypass.** `node` was denied inside a pipe while `tail`, `head`, `wc` and `cat` passed — the matcher checks the pipeline and lets read-only filters through. Worth recording because the first reading of the `| tail -1` result looked like a hole, and it is not one.

With `Bash(set -o pipefail)` added to the allowlist, `set -o pipefail; echo alpha | tail -1` becomes ALLOWED. The denial was never about `set` being dangerous; it was about a compound statement whose first half nothing had granted.

## The decision

1. **`Bash(set -o pipefail)` joins the baseline Capability Ledger.** It is the rare grant that *reduces* risk: the option executes nothing, reads nothing, writes nothing, and its only effect is to make a pipeline return the first non-zero status in it rather than hiding it. Withholding it does not make the engine safer — it makes the engine's evidence untrustworthy.
2. **`POLICIES.md` § Evidence Requirements gains an explicit rule**: never accept a piped command's exit code as evidence; either prefix the pipeline with `set -o pipefail`, or run it unpiped and record the tool's own verdict line (`BUILD SUCCESSFUL` / `BUILD FAILED`) as the evidence. `${PIPESTATUS[0]}` and `> file` are named as unavailable, with the date they were verified, so the next reader does not re-derive it.

The capability is the load-bearing half. The policy tells the engine what to do; the capability is what makes doing it possible.

## Considered Options

- **POLICIES rule only ("read the text, not the exit code")** — rejected as the whole fix. It is achievable — the engine did exactly this unaided, and a later iteration was observed announcing *"Running the full verification set in one command (no pipe, foreground)"* — but it depends on the engine remembering, every time, in a file read as guidance rather than enforced. It is retained as the second acceptable form, not as the primary.
- **Grant `${PIPESTATUS[0]}`** — rejected: refused as a shell expansion, and expansions are exactly what a static command matcher cannot reason about. Fighting that is fighting the enforcement layer's one real safeguard.
- **Grant redirection (`Bash(* > *)`) and grep the file** — rejected: a far broader grant than the problem needs, since it makes every command able to write anywhere, to solve a problem one shell option solves.
- **A runtime affordance — `run.ps1` executes build commands on the engine's behalf and reports a true exit code** — rejected for now, and it was the closest call. It is the purest enforcement-plane answer, and ADR-004's logic points at it: evidence would stop depending on the engine's shell hygiene entirely. But it would put command execution into the Runtime, which ADR-002 keeps deliberately free of engineering decisions, and it would need the Runtime to know which commands are builds — that is consumer-specific knowledge the Runtime is designed never to hold. Revisit if a second evidence-integrity defect appears that a capability grant cannot close.
- **Forbid pipes in build commands outright** — rejected: unenforceable, and it would force unbounded build output into the engine's context, trading a correctness risk for a context-exhaustion one.

## Consequences

- The baseline ledger now contains an entry whose justification is *correctness of evidence* rather than *access to a resource*. That is a new category for the ledger and worth noticing: capabilities have until now been about what the engine may reach, not about whether what it observes is true.
- `knowledge/PROJECT.md` in the Calendar-Note repository holds a now-partially-obsolete version of this lesson, recorded when `pipefail` was unavailable. It is not wrong — reading the verdict line still works — but it names a constraint that no longer holds. Nothing propagates the correction, which is ADR-019's stack-knowledge problem and the `CANDIDATES.md` gap (ADR-019, deferred) meeting in one place: this lesson was portable, was recorded in a per-repo file because that was the only writable home, and is now stale there.
- **Not solved:** nothing verifies that recorded evidence was *gathered* correctly. This closes the one mechanism known to produce false evidence; it does not make the evidence chain self-checking. A build command that silently skipped a module, a test task that matched no tests, a lint run scoped to the wrong variant would all still record as green. The general problem — evidence that is true about the wrong thing — remains open.
