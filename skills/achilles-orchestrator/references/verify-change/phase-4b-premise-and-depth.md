# 4b. Premise and depth: decide what the run is before it is run

The diff review costs a twentieth of a full run and already knows two things the rest of the run
depends on: whether the change the ticket describes is still what the environment runs, and how
much is at stake if it is wrong. Decide both here, in writing, before step 5.

This exists because it was skipped and it cost something real. A ticket asked for a field type to
be changeable; a later commit had removed that field type. The diff review said so in its first
finding. The run went on through the walk, four reproducers, the tests, the mutation set and the
probes, and ended with the question the diff review could have asked: is the ticket closed by the
later change? Fourteen parts of the cost bought nothing the first part had not.

## The premise check

The premise holds when the behaviour the criteria describe is what the environment under test is
meant to do today. It is gone when any of these is true:

- **Superseded**: a later change to the same code removed or replaced the behaviour
  (`git log <merge>..<deployed> -- <changed files>`, read by the inspector in step 4).
- **Reverted**: the change is no longer an ancestor of the deployed build, or its hunks are gone.
- **Untestable as written**: the criteria contradict each other, or name a state the product can
  no longer reach.

A premise that is gone from the source is an inference until it is seen. The same inspector
confirms it with one look at the live screen the criteria describe (one screenshot, one sentence),
inside the diff-review dispatch.

**Premise gone: stop.** Nothing after step 4 runs. The hand-back is `NEEDS_CONTEXT` with the
evidence (the superseding commit, the screenshot) and the one question that decides the ticket:
verify against the new intent, wait, or close. No criterion gets a verdict, and the hand-back says
so. The answer resumes the run at step 5 with the intake and the diff review kept.

A change that is merely not deployed yet is not a gone premise: it is `BLOCKED` on the environment,
as before.

## The depth

Every run that goes on states its depth and the reason, in `docs/evidence/<ticket>/brief.md` and in
the hand-back. The delegation may fix the depth; otherwise:

**Full** when any of these holds: the change touches money, permissions or access; it changes what
is stored or what leaves the product; it sits on a journey the journey map ranks P0 or P1; it edits
code that other features share; or the diff review has a critical or high finding. Full is steps
5–9 as written.

**Light** otherwise (copy, layout, one component's behaviour with nothing stored). Light keeps
everything that makes a verdict mean something and drops the breadth:

| Step | Light |
|---|---|
| 6 | the walk covers the criteria and what the diff review ranked; 6d is limited to what the walk passes through |
| 7a | as written: a suspicion still needs its confirmation |
| 7 | one test per criterion, a sentinel per confirmed bug; no extra edge-case cover |
| 8 | the negative control, as written |
| 8b | one mutant per criterion; one reviewer takes the five code missions as a single pass that reports only `[must-fix]` findings, one section per mission; `probe-visual` as written; one fix cycle |
| 8c, 8e | as written: the score and its floor do not change with depth |
| 9 | as written |

Light is never a way to skip the negative control, the confirmation of a defect or the score. A
light run that turns up a critical or high finding becomes full from that point, and says so.
