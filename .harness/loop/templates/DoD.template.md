# Definition of Done

> Derived from `PRD.md` at bootstrap. Human-owned after approval: the engine may propose changes (Tier 3) but never apply them.
> Every criterion must be verifiable by evidence, and must declare WHO can verify it (ADR-015).

## Status

- [ ] APPROVED — approve via the pending `.harness/run/ESCALATION.md`; edit criteria freely before approving.
      Approval covers the Verification Class of each criterion, not only its wording.

## Acceptance Criteria

<!-- Every criterion is written twice, once for each reader (ADR-035), always in English:

     1. [machine] Tapping a song plays it.
        Proof: `dumpsys media_session` shows the app's session in state PLAYING(3) with the tapped
        song's title, driven from a fresh install with the permission granted.

     The first line is the PERSON's: one plain sentence about what they will see or be able to do,
     readable by someone who has never opened the code - no commands, file paths, class names, ids or
     regexes. It is what the human approves. The indented `Proof:` line is the ENGINE's: everything
     a command or a Verifier needs - commands, files, the state it is driven from, the exact
     expectation. FOREMAN.html shows the sentence and folds the Proof away under it. A Proof that
     checks less than its sentence promises is a defect, not a shorthand.

     Each criterion is tagged with its Verification Class.
     [machine] a command's output or a named file proves it; the Verifier proves it itself.
     [human]   a person must look at the running software; blocks DONE until signed off.

     Business logic, behaviour/flow, and "builds AND starts without crashing" are [machine].
     Appearance, contrast, and whether a control can be SEEN and FOUND are [human].

     A user-facing capability usually needs one of each. "The user can delete a note" is both
     "the record is removed" [machine] and "the delete control is visible and reachable" [human].
     A DoD with user-facing behaviour and NO [human] criteria is a defect: it is measuring a layer
     beneath the one the user experiences. When uncertain, choose [human].

     Group the criteria under the category headings below, in this order, and leave out a heading
     with nothing under it. A criterion that fits two categories goes under the first one. Number
     criteria continuously across the categories - 1, 2, 3 ... never restarting at a heading - because
     the number is the criterion's id everywhere else (STATE.md, ESCALATION.md, the Verify tab). The
     Runtime renders this file into FOREMAN.html for the human, grouped and numbered exactly as written. -->

### Behaviour

<!-- What the user can do and what happens: flows, business logic, state that survives a restart. -->
1. [machine] <what the user can do, in one plain sentence>
   Proof: <the command or file that proves it, and the state it is driven from>
2. [human] <what a person will see when they try it>
   Proof: open …, do …, expect …

### Permissions the user is asked for

<!-- Every runtime permission the app requests: when it is asked, and what happens on allow and on deny. -->
3. [machine] <when the app asks, and what happens if the user says no>
   Proof: …

### Background work and notifications

<!-- What keeps working off screen - services, scheduled work - and the notifications and controls it shows. -->
4. [human] <what keeps working when the app is in the background>
   Proof: …

### Appearance and reachability

<!-- Whether a control can be seen, found and reached: contrast, layout, system bars and gesture areas. -->
5. [human] <what a person can see and reach on screen>
   Proof: …

### Data and storage

<!-- What is saved, where, and what survives a restart, an update or a reinstall. -->
6. [machine] <what is kept, and what survives a restart>
   Proof: …

### Build, start and quality

<!-- It builds, starts without crashing, and the test and lint commands pass. -->
7. [machine] The app builds and opens without crashing.
   Proof: …

## Removals

<!-- What the repository already ships that the PRD makes unnecessary. One [machine] criterion per
     removal, stating ABSENCE, provable by command. The human approves these at the same gate as
     everything else; after approval, leaving any of them in place is a DoD violation.

     Repository class (from PROJECT.md): template | product
     - template: propose removing every demo feature, screen, permission and dependency the PRD does
       not use.
     - product:  propose removing only what the PRD replaces or leaves unreachable; list anything else
       that looks unused under "Questions" below, never as a removal.

     If this section is empty, say why in one line. -->
R1. [machine] <what is gone, in plain words> — e.g. The template's demo Home screen is gone.
    Proof: e.g. `HomeFragment` appears neither in the navigation graph nor in the source tree
R2. [machine] <what is gone, in plain words> — e.g. The app no longer asks for the user's location.
    Proof: e.g. the merged debug manifest declares no `ACCESS_FINE_LOCATION`

Questions (product repositories only): …

## Constraints

<!-- Non-negotiable boundaries from the PRD: architecture rules, compatibility, performance floors. -->
- …

## Verification Evidence Required

<!-- [machine]: the exact command and the output that proves it.
     [human]:   what to open, what to do, what to expect — written so a person can act on it without
                reading any code. "Check the UI looks right" is not evidence, it is an apology for
                not having written a criterion. -->
| Criterion | Class | Evidence / what to look at | Signed off |
|---|---|---|---|
| 1 | machine | `gradlew test` … | n/a |
| 2 | human | open …, do …, expect … | ☐ |
| R1 | machine | `grep -r HomeFragment app/src` finds nothing; navigation graph has no such destination | n/a |
