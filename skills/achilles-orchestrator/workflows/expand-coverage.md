# Workflow: expand-coverage

Grow the suite journey by journey across a mapped application. The orchestrator iterates the map and dispatches; authors compose (`test-composer`) or probe (`bug-discovery`); fresh reviewers judge every unit. The per-pass pipeline is [pass-pipeline.md](../references/pass-pipeline.md); the per-journey author↔reviewer loop is [dual-stage-retry-loop.md](../references/dual-stage-retry-loop.md); the state file is [state-files.md](../references/state-files.md) §"Coverage-expansion state".

## Modes

| Mode | Passes | Dispatch shape |
|---|---|---|
| `standard` (default) | 3 compositional + 2 adversarial + per-pass dedup + cross-pass cleanup | pass 1 strict per journey; passes 2–5 may group (cap 7, priority-pure); adversarial grouping is the default, `strict-adversarial: true` opts back into per-journey |
| `depth` | same five passes | strict per journey on every pass, per-journey reviewers on every cycle; up to ~20× the dispatches, for audits and benchmarks |
| `breadth` | one horizontal sweep per priority tier, no adversarial passes | serial sweep: P0 `happy-path,error-states,edge-cases,mobile`; P1 `happy-path,error-states`; P2 `happy-path`; P3 `smoke` |

## Preflight

1. Read the state file first. Absent or `complete` → pass 1 from scratch; `currentPass` set → resume that pass's remaining roster; verify each pass recorded complete has its commit in history, else treat it as incomplete.
2. `journey-map.md` with the sentinel on line 1 and self-contained `### j-<journey-slug>:` blocks carrying `Pages touched:` and `Test expectations:`. Otherwise run [map-journeys](map-journeys.md) first.
3. Green baseline: `npx playwright test` passes. A red baseline routes to [repair-suite](repair-suite.md) before any pass.
4. Record the mode, `strict-adversarial`, and the authorisation (`full-pipeline`, `approved-coverage-plan: <map path>`, or a verbatim `user-authorised-scope` quote) in the resume file. Without one of the three, the full pipeline runs.

## Two valid exits

All passes + cleanup complete with every journey dispatched in every pass; or commit what landed, write the state file, and hand back `NEEDS_CONTEXT`/`BLOCKED` naming completed passes, the in-flight pass and the pending journeys. The second exit needs at least one dispatch already recorded; a state file with zero dispatches is not an exit.

## Per pass

1. **Index the map**: `(j-id, priority, pages-touched, test-expectations, risk)` only. Order P0→P3; within a tier `risk: elevated` first.
2. **Independence graph**: journeys sharing a non-universal page are dependent and serialise; others run in parallel up to the host maximum (the infrastructure audit tags cap it further).
3. **Scope preview** in the state file: journey count, groups, parallel width, expected wall-clock, the model mix. Informational; no confirmation prompt.
4. **Roster**: frozen now. Passes 4–5 iterate `journeyRoster − adversarialSkippedJourneys`.
5. **Dispatch per journey** through the retry loop (below), compositional passes with an author loading `test-composer` (`composer-<slug>-<pass>-c<N>` session; `mode: re-pass` with the trigger evidence on passes 2–3), adversarial passes with an author loading `bug-discovery` plus the negative-case matrix (`probe-<slug>-<pass>`), each followed by a fresh reviewer.
6. **Collect**: committed paths, `review_status`, cycle counts, `final_must_fix`. Never the spec source or review bodies.
7. **Reconcile**: compositional passes append discovered branches, pages and new `j-`/`sj-` blocks to the map and `app-context.md` (reconciliation commit; new journeys join the next roster). Adversarial passes do not touch the map; aggregate the totals counter.
8. **Commit** per journey ([commit-conventions.md](../references/commit-conventions.md)), then rewrite the state file.
9. **Whole-suite gate** ([`test-optimization.md`](../references/test-optimization.md) §7). Red → stop the pass; resolve via repair-suite; never advance.
10. **Per-pass dedup**: one author dispatch (test dedup on 1–3, findings dedup on 4–5), commit even when empty.
11. **Pass review**: a fresh reviewer (phase-gate mode) confirms every journey dispatched and returned, both stages ran, dedup landed. Advance on approve.

## Retry loop per journey per pass

The author↔reviewer loop, its termination statuses (`greenlight`, `blocked-cycle-stalled`, `blocked-cycle-exhausted`, `blocked-dispatch-failure`) and its invariants are [dual-stage-retry-loop.md](../references/dual-stage-retry-loop.md); run it as written. Both stages, every journey, every pass; blocked statuses are valid terminals carried to the next pass's author brief, never relabelled greenlight. Reviewer mode selection (batch on cycle 1 of compositional passes for individually dispatched journeys; per-journey otherwise) is [`../../review/SKILL.md`](../../review/SKILL.md) §"Mode 2: Stage B (coverage passes)".

## Trigger-gated re-pass (passes 2 and 3)

Before dispatching a journey, check three triggers: map delta since the pass-1 reconciliation commit, a sibling finding in the ledger naming this journey, a `final_must_fix` carry-over. All three false → write a gated-skip entry with `triggers_checked` and do not dispatch. Any true → dispatch with the evidence in the brief; the author's return must carry the four-trigger check and the per-expectation mapping table or it is re-dispatched.

## Adversarial passes

- **Pass-4 prelude**: one author (`probe-app-wide` session) establishes `tests/e2e/docs/app-wide-patterns.md` per `../../bug-discovery/references/app-wide-scan.md`; commit before any per-journey probe. The file's presence with its sentinel is the resume signal. Not run in breadth mode.
- **P3 opt-out**: evaluate the four criteria (`priority-p3`, `page-subset-covered`, `zero-prior-findings`, `low-surface-shape`) for baseline-risk P3 journeys; the candidate table is part of the coverage plan the user approved, or a `NEEDS_CONTEXT` hand-back before the prelude. Approved entries land in `adversarialSkippedJourneys[]` in their own commit.
- **Pass 4**: per journey, the author probes every matrix entry plus open-ended categories, classifies (`boundary-verified | suspected-bug | ambiguous`), appends to the ledger under the lockfile, writes no tests. Elevated-risk journeys are never grouped.
- **Pass 5**: the author reads its journey's pass-4 section (the one bounded exception to your context rule), re-probes ambiguous entries, runs compound probes, and writes passing regression tests for every verified boundary into `j-<slug>-regression.spec.ts`; suspected bugs stay ledger-only; never `test.fail()`. Each pass-5 return carries the added suite runtime.
- Grouping falls back to per-journey for the rest of the pass when ≥3 of 7 reviews in one group return `improvements-needed`.

## Cleanup and checkpoint

After pass 5's dedup: one author dispatch consolidates cross-cutting findings (`docs(ledger): dedupe cross-cutting findings`); the state file records all five passes + cleanup; the phase review approves; then delete the state file and run [map-journeys](map-journeys.md) `phase-5-only` for the coverage checkpoint and residual-risk table.

## Progress and hand-back

One line per event in the resume file: pass start (journey count, shape), per-journey terminal `review_status` with cycle count, pass complete with counts, pass-5 added runtime, cleanup. The hand-back is `DONE` with totals (tests added, regression tests, suite runtime delta, ledger path) and the mandatory residual-risk block: gated areas not mapped, adversarial opt-outs, blocked journeys with unresolved must-fix (ids), ambiguous ledger findings, structural-only tests; each with a count, `0` and `—` when empty.

## Not this workflow

Mapping journeys (map-journeys); one journey on request (an author loading `test-composer` directly, then a judge review); app-wide adversarial sweeps outside the map (hunt-bugs); locking suspected bugs into passing tests, ever.
