# WORKER BRIEF - T-00x

> The complete context handed to one Worker. Deliberately minimal: status of other work, never its
> content or its reasoning. A Worker holds no git, build, or test capability.

## Your task

<!-- Description and acceptance criteria, copied from the task file. -->

- **Attempt:** N of 3
- **Model Tier:** Fast | Capable <!-- assigned at planning; escalates to Capable after a failed Fast attempt -->
- **Previous attempt failed with:** <!-- error tail, when this is a re-dispatch. Your scope has been
     reverted to the last checkpoint, so you are starting clean, not on top of the failed work. -->

## Declared File Scope

You may write **only** these files. Writing outside this list is a violation and your work will be
reverted:

- `src/...`

Files shared with other tasks (navigation tables, route registries, manifests, dependency files) are
deliberately excluded. The Iteration wires those itself after your work is merged. Do not touch them.

## Status of other work

<!-- Status ONLY. Not content, not reasoning. -->
| Task | Status |
|---|---|
| T-00y | complete |
| T-00z | in progress (another Worker, right now - you cannot see its work and must not need to) |

## Pointers

<!-- Interfaces earlier Phases created. A pointer, not the code: read the file if you need it. -->
- T-00y created `SettingsRepository` in `data/SettingsRepository.kt` - read it if you need it.

## Constraints (binding, copied verbatim from knowledge/PROJECT.md)

<!-- EVERY Constraint, always, unfiltered (ADR-016). The Iteration does not choose which traps a
     Worker needs -- that judgement is what shipped an invisible delete icon one commit after the
     trap was written down. If a Constraint conflicts with a literal reading of the acceptance
     criteria, the Constraint wins and the Worker says so in its report. -->

- **Never** ... because ... — evidence: `path/to/File.kt:NN`

## Conventions

<!-- The relevant subset of .harness/knowledge/PROJECT.md. -->

## Report back

A **manifest, not a payload** - the Iteration reads the diff from git itself:

- files you wrote
- what observable behavior now works
- anything you could not do, and why
- anything you learned that belongs in project knowledge
