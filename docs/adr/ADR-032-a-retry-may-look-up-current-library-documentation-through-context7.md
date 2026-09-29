# A retry on a library failure may look up current documentation through Context7, and only the engine does it

A model's knowledge of a library ends where its training data does. When a task fails on a library
symbol, `POLICIES.md` already forbids retrying the same work and demands new information; until now
the only sources of it were the error text and the repository itself.

**Decided by the human, 2026-09-29:** Foreman integrates [Context7](https://github.com/upstash/context7)
— a widely used index of current, version-specific library documentation — as a skill the engine
uses when it needs knowledge to get past a failure. This ADR records that decision and the shape it
takes. It is a human decision, not a Ratchet lesson: the evidence below says the integration is cheap
and well-aimed, not that its absence has yet cost a run.

**What would change this assessment.** Telemetry (ADR-029) showing library-failure retries that
consulted Context7 succeed no more often than ones that did not, or any query found to have carried
repository code off the machine.

## The evidence, both ways

Against urgency. Every engine commit in Calendar-Note — 67 of them across four goals — was searched for
the signatures of stale library knowledge: `Unresolved reference`, deprecations, "does not exist",
wrong or invented APIs. There were none. The failures that did happen were a pre-existing lint error,
a `NewApi` lint on `minSdk`, a Kotlin empty-lambda compile error, a wrong test assertion, a
`MediaController` lifecycle leak the reviewer caught, OEM device behaviour (a vivo blocking media
notifications, MIUI refusing `pm grant`), and a misplaced capability ledger. Context7 answers none of
the device cases: asked directly whether a `MediaSessionService` notification needs
`POST_NOTIFICATIONS`, it returned the manifest declarations and nothing about the permission.

For the shape. Measured on 2026-09-29: `npx -y ctx7 library …` resolved AndroidX Media3 in 15 seconds
on a cold `npx`, with no API key; `npx -y ctx7 docs … --json` returned 5,122 bytes of structured
snippets, each with its official source URL, in 6 seconds. The snippet it returned for "MediaController
release and reconnect" documents `MediaController.Listener`'s disconnection callback — the exact API
the music-player run's second attempt used to fix the lifecycle leak its reviewer found. And the
capability rule `Bash(CTX7_TELEMETRY_DISABLED=1 npx -y ctx7 library *)` was tested against the real
permission matcher with `claude -p`: the command ran, zero permission denials.

## The decision

**A stack-agnostic opt-in pack**, `skills/knowledge/general/library-docs/`, like the Android packs:
a `SKILL.md` saying when and how, and a `capabilities.snippet.json` with one standing entry the human
reviews and approves at the DoD gate.

**The CLI, not MCP.** `ctx7 library` and `ctx7 docs` run through `Bash`. The runtime has no MCP
plumbing at all — no `--mcp-config`, no `mcp__*` rule in any ledger, no MCP tool in any agent — and
the CLI needs none of it, nor an API key for normal use.

**Only on failure.** `POLICIES.md`'s retry rule gains one line: when a failure names a third-party
library's API and the pack is granted, look the API up before the retry — at most three calls — and
record what was found. Nothing is spent while the work goes well, which matters because quota, not
library knowledge, is what has actually stopped runs.

**Only the engine goes to the network.** Workers keep their tool list (`Read, Write, Edit, Glob,
Grep`) and get the excerpt through a new **Library documentation** section of the Worker Brief. The
engine is the librarian; the Worker stays as contained as it was.

**Only two commands.** The grant covers `library` and `docs`. `setup`, `login` and `remove` write
configuration or run OAuth, and are not granted; telemetry is switched off in the granted form.

## Considered Options

- **The Context7 MCP server** — rejected for now. It needs runtime support for MCP configuration,
  `mcp__context7__*` rules in the compiled permissions, and either MCP tools for Workers (widening
  them) or the same librarian arrangement as the CLI. The CLI delivers the same two operations with
  none of that. This was the closest call: MCP is Context7's primary interface and would avoid the
  `npx` start-up cost.
- **Always consult documentation before writing library code** — rejected: it spends quota on every
  task to prevent a failure no run has shown, and turns an information source into a ritual.
- **Give Workers the CLI directly** — rejected: Workers have no `Bash` by design (ADR-008), and a
  network-capable Worker is a wider blast radius than one engine call whose result is handed over.
- **Leave it to the model's own judgement, with no pack** — rejected by the human; and in practice an
  engine that does not know a documented, granted route exists will not reliably find one.

## Consequences

- Queries leave the machine for a service whose backend is private. The pack forbids repository code,
  paths and non-library names in a query, but that is guidance the engine follows, not a filter the
  Runtime enforces. **Not solved:** nothing mechanically inspects a query before it is sent.
- Context7's content is community-contributed without a guarantee of accuracy or safety. It enters the
  engine's context as data under Invariant 10, and only the build and tests decide whether a fix is
  right — the documentation can make a retry better informed, never make wrong code pass.
- Anonymous use is rate-limited; a human may run `npx ctx7 login` or set `CONTEXT7_API_KEY` in their
  own environment. The engine never holds or writes a key.
- **Open:** no run has used the pack yet. Whether it earns a place in `ENGINE.md`, or is retired, is
  for ADR-029's telemetry to show.
