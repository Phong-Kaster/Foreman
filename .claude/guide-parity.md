# The Interactive Guide Tracks README.md

## Objective

`README.md` is the file GitHub renders on the repository's home page, and it stays the source of
truth for what Foreman is and how to use it. `docs/index.html` is a second, parallel presentation of
the same content — bilingual (English/Vietnamese), a fresh visual design distinct from the
`foreman-field-report.html` / `SUGGESTIONS.template.html` report style, published via GitHub Pages
(`/docs` on `main`) for a friendlier, animated reading experience. It does not replace README, does
not change README's role, and is not linked to from it as an authority — it is a nicer way to read
the same thing.

A copy that isn't the source of truth drifts the moment nobody remembers to update it. The rule here
is the same one `distributable-parity.md` states for the runtime's two copies: **the human decided to
keep two presentations of one truth in sync, and nothing except discipline enforces that.**

---

# The rule

**Whenever `README.md` changes, update `docs/index.html` in the same commit.**

This is a full re-port, not a patch-and-hope: `docs/index.html` mirrors README's content 1:1 (Q3 of
the design session that created it — full port, not a curated subset), so a section added, removed,
or reworded in README must be reflected in both the English and Vietnamese copy inside
`docs/index.html`, in the matching sidebar-navigable section (`id="..."` anchors matching README's
heading structure).

What does **not** need to track README line-for-line:

- The visual presentation itself (animations, card layout, color tokens) — that is `docs/index.html`'s
  own design, independent of README's Markdown formatting.
- Content that exists only in `docs/architecture.md`, `docs/consumer-guide.md`, or the ADRs — the
  guide links out to those the same way README does, and does not inline them.

---

# Why this is not (yet) mechanically enforced

This repository's own doctrine (`.harness/loop/POLICIES.md`, the Ratchet, ADR-019) holds that a rule
enforced by a script is a rule, and a rule living only in a document is a wish — and prefers the
former. This file is deliberately the latter, for now: `docs/index.html` is a human-facing marketing
page, not doctrine injected into the engine's system prompt, and nothing has yet been lost to drift
that would earn a pre-commit check (a CI diff comparing README's heading list against
`docs/index.html`'s anchor ids, for instance). If a future edit to README is merged without the
matching guide update going stale and unnoticed, that is the failure that earns the mechanical check —
follow `distributable-parity.md`'s own reasoning for the precedent.

---

# Related, not identical: `distributable-parity.md`

`ENGINE.md`, `POLICIES.md`, `baseline.json`, `run.ps1`, `models.json`, and the `templates/`/`agents/`
directories are byte-identical copies verified by `git hash-object` — an exact mechanical parity.
`docs/index.html` is not a copy of README.md; it is a re-authored, bilingual, differently-designed
presentation of the same content. "In sync" here means *no section of README is unrepresented*, not
*byte-identical* — there is no automated diff to run, only a human read-through.
