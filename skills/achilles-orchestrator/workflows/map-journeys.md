# Workflow: map-journeys

Produce the sentinel-bearing `tests/e2e/docs/journey-map.md` that every coverage workflow consumes. The orchestrator runs the loop; inspectors drive the app per section; a doc-writer authors the map. The expert half (section-agent brief, section vocabulary, author rules, document structure, coverage checkpoint) is [`../../journey-mapping/SKILL.md`](../../journey-mapping/SKILL.md).

## Modes

| `phases` | Does |
|---|---|
| `full` (default) | Phase 1 crawl, the discovery cycles, the author step. The coverage checkpoint runs later with `phase-5-only`. |
| `phase-1-only` | Crawl + test-infrastructure probe; writes a sentinel-bearing skeleton map with the site map and empty headings. |
| `phases-2-4` | Requires the skeleton map and a valid discovery draft; runs the cycles and the author step. |
| `phase-5-only` | Coverage checkpoint against a composed suite; appends `## Coverage Checkpoint` and `## Residual Risk`. |

`cycle-strictness: standard` (default: cycle 1 strict per section, later cycles may be single dispatch) or `depth` (every cycle strict per section). Conflicting `phases` values are a `BLOCKED` hand-back naming the conflict.

## Preflight

- Existing map with the sentinel on line 1: resume from it (reuse the site map, update what changed, keep the sentinel). Existing map without the sentinel: `NEEDS_CONTEXT` ("rename it and start fresh, or point me at another path?"); never parse or overwrite it.
- `phases-2-4` and `full` need `tests/e2e/docs/.discovery-draft.json` with its version key and non-empty `cycle-1-targets` ([state-files.md](../references/state-files.md) §"Discovery draft"). Missing or malformed → `BLOCKED: discovery-draft-missing`; this workflow never synthesises a draft. In `full` mode with no draft, run Phase 1 first and seed cycle 1 from its site map.
- Read `.phase4-cycle-state.json` if present and resume at the first cycle whose `returned-sections` is incomplete.

## Phase 1: crawl and infrastructure probe

Dispatch one **inspector** per entry point (`phase1-<entry>` sessions, parallel) following `../../journey-mapping/references/phases.md` §"Phase 1", plus one inspector for the test-infrastructure probe (`../../journey-mapping/references/test-infrastructure-probe.md`). Collect the site map and the constraint tags; append the tags to `app-context.md` `## Test Infrastructure`. In `phase-1-only` mode, a doc-writer writes the skeleton map and the run ends (`docs: initial app-context and site map`).

## Discovery cycles

State file `tests/e2e/docs/.phase4-cycle-state.json` ([state-files.md](../references/state-files.md) §"Journey-mapping cycle state"). At least 2 cycles, at most 5.

```
for N in 1..5:
  1. Targets and kind:
       N == 1                      → kind=discovery, targets = draft cycle-1-targets
       prior cycle found new sections → kind=discovery, targets = new sections not yet dispatched
       no new sections, no edge-probe yet → kind=edge-probe, targets = every section dispatched so far
  2. Dispatch one inspector per target section (session `phase4-c<N>-s-<id>`, id truncated to ≤16),
     all in one parallel wave, each brief per journey-mapping §"Per-section-agent contract";
     edge-probe briefs ask for permission boundaries, deep links, lifecycle edges, hidden routes,
     role-locked features, error paths.
     Under `standard`, cycles ≥2 may be one inspector covering several sections; under `depth`, never.
  3. Wait for every dispatched section to return before step 4. Record returned-sections,
     new-sections-discovered (normalised to the canonical vocabulary), duplicates-merged.
  4. Review: a fresh reviewer (phase-gate mode) checks dispatched == returned, spill files present,
     new sections classified. Advance on approve.
  5. Converged when: dispatched == returned for the highest cycle, no new sections after dedup,
     an edge-probe cycle has run, cycles contiguous. N == 5 with new sections left → hard-cap-reached.
```

Why the edge probe is mandatory: "cycle 1 found nothing new" is not convergence; the edge probe re-engages every section under a different lens, and a quiet edge probe is confirmed convergence.

Gated routes an inspector cannot self-credential into are returned under `gated-deferred-to-coverage-expansion` and become the map's `## Gated Areas (Not Mapped)`; never bypassed.

## Author step

After convergence or the hard cap, dispatch one **doc-writer** loading `journey-mapping` §"Author step" with every cycle's spill file, the discovery draft and the state file. It applies prioritisation (P0–P3), risk factors, redundancy revision and structural-smell prevention, composes cross-section journeys, and overwrites `journey-map.md` in place with the sentinel on line 1, the `## Section → Journey Map` table, `## Gated Areas (Not Mapped)`, `## Coverage Plan` and the mapping-completeness line. It returns `journey-map-authored` or `blocked` (internal-consistency failure); re-dispatch on `blocked` up to 3 attempts, then `BLOCKED` upward with the last return.

Review: a fresh reviewer checks the sentinel, every returned section present in the table or under Gated Areas, the sub-journey cross-references, and the structural-smell rules. A map that passed the author but fails review is a re-run from cycle 1 after deleting the map and the state file, not a re-author.

Commit `docs(journey-map): <converged at cycle N | hard-cap-reached>`. Then write `journey-map-coverage.md` (doc-writer; every journey → covering spec or `<missing>`).

## Coverage plan hand-back

The map's `## Coverage Plan` (per tier: journey count, planned passes, dispatch and wall-clock estimate, P3 adversarial opt-out candidates with the four criteria pre-evaluated) is the user's decision. Standalone runs hand back `NEEDS_CONTEXT` with the plan and one question: approve as written, name exclusions, or change the mode. Inside the onboard workflow the front-load authorisation already covers it; record `approved-coverage-plan: tests/e2e/docs/journey-map.md` in the resume file and continue.

## Phase 5: coverage checkpoint

`phase-5-only`, invoked by expand-coverage after its cleanup commit. A **reviewer** reads the map and every spec, maps authored `Test expectations:` to covering tests, and returns the coverage matrix and the `## Residual Risk` table (gated areas, adversarial opt-outs, blocked journeys with unresolved must-fix, ambiguous ledger findings, structural-only tests; every row present with `0` and `—` when empty). A doc-writer appends both to the map. A P0 journey under 100% of its authored expectations is a `DONE_WITH_CONCERNS` hand-back naming the gap; the suite is not complete until it closes.

## Hand-back

`DONE` with the map path, counts (pages, flows, priority breakdown, gated areas), convergence cycle, and the coverage plan summary.
