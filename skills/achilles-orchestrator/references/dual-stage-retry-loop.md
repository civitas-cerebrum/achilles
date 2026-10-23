# Dual-stage retry loop

Every journey in every coverage pass runs as two stages: **Stage A** (an author loading `test-composer` on passes 1–3, `bug-discovery` on passes 4–5) and **Stage B** (a fresh reviewer loading [`../../review/SKILL.md`](../../review/SKILL.md) in Stage B mode, with its own context and its own `playwright-cli` session). A single agent that does the work and certifies it misses what an independent reader catches; Stage B exists to catch what Stage A missed. The reviewer never writes tests, never appends to the ledger, never modifies files.

## Loop (orchestrator, per journey per pass)

```
stage_a_input = base_brief
history = []

for cycle in 1..7:
  a = dispatch author(stage_a_input)                 # fresh brief each cycle
  on dispatch failure (transport, timeout, malformed shape):
      re-dispatch once with the same brief; a second failure → review_status = blocked-dispatch-failure; break
  b = dispatch reviewer(a)                            # fresh reviewer, fresh session, prior must-fix lists in compressed form
  if b.status == greenlight: review_status = greenlight; break
  must_fix = b.findings                               # every reviewer finding is must-fix
  if must_fix is empty:                               # malformed improvements-needed
      re-dispatch the reviewer once with a stricter brief; same shape again → coerce greenlight; break
  identical_run = 1 + count of trailing history entries whose must_fix == must_fix
  if b.stalled == true or identical_run >= 3: review_status = blocked-cycle-stalled; break
  history.append({cycle, must_fix})
  stage_a_input = base_brief + must_fix (verbatim, never summarised)

if cycle == 7 and review_status unset: review_status = blocked-cycle-exhausted
record review_status, cycle counts, final_must_fix in the state file
```

Stall needs three identical lists in a row (current, prior, prior-before-that): a cycle-N+1 reviewer may legitimately catch something cycle N missed, so a single match is progress, not stagnation. Stalled wins over exhausted when both apply at cycle 7; they send different signals downstream.

## Termination

| Condition | `review_status` | Action |
|---|---|---|
| reviewer `greenlight` | `greenlight` | accept; commit this journey's work for the pass |
| `improvements-needed` with empty findings, twice | `greenlight` (coerced) | no changes were needed; the status was malformed |
| must-fix identical for three consecutive cycles, or `stalled: true` | `blocked-cycle-stalled` | commit what landed; record the unresolved list; carry it to the next pass's author brief |
| cycle 7 without greenlight | `blocked-cycle-exhausted` | same |
| author dispatch failed twice | `blocked-dispatch-failure` | commit nothing for this journey this pass; carry the failure note forward |

The three blocked statuses are valid terminals and visible deferrals, never relabelled `greenlight`. Seven cycles leave room for a first review to catch the obvious gaps, a second the subtler ones, and a third what the first reader missed, while keeping exhaustion the exception.

## Invariants

- Both stages, every journey, every pass. A `review_status` written without a reviewer dispatch is fabricated state.
- A fresh reviewer per cycle; a reviewer that carries state starts agreeing with the author.
- Findings flow to the next author brief verbatim; compression loses the specificity the fix needs.
- Each cycle's reviewer is taken as-is; divergence between cycles is handled by the stall and exhaustion checks, never by picking the lenient one.
- Cycle-1 reviews of individually dispatched journeys in compositional passes may use one batch reviewer per pass; cycle 2+, grouped dispatches, adversarial passes and `depth` mode are per-journey.
