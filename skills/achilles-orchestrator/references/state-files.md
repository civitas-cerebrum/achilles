# State files

Every workflow resumes from a file, never from the conversation. The orchestrator reads the relevant file as its first act, writes it after every landed deliverable, and refuses a file that contradicts the tree.

| File | Owner workflow | Committed? |
|---|---|---|
| `.achilles/runs/<run-id>/resume.json` | every run | no |
| `tests/e2e/docs/coverage-expansion-state.json` | expand-coverage | no |
| `tests/e2e/docs/.phase4-cycle-state.json` | map-journeys | no |
| `tests/e2e/docs/.discovery-draft.json` | author-scenario (onboard Phase 3) → map-journeys | yes |
| `tests/e2e/docs/onboarding-status.json` | onboard | no |
| `tests/perf/docs/perf-onboarding-status.json` | performance pipeline | no |
| `tests/e2e/docs/flake-quarantine.md` | repair-suite (authors add, the workflow releases) | yes |
| `.achilles/self-repair/<run-id>/` | repair-suite | no |
| `tests/e2e/docs/.subagent-returns/*.md` | spill files, every workflow | no |
| `.achilles/runs/<run-id>/briefs/<slug>.md` | briefs, every workflow | no |
| `.achilles/runs/<run-id>/reports/<slug>.md` | expert reports, every workflow | no |
| `.achilles/adversarial-verification/<ticket>.json` | verify-change sign-off receipt | no |

## Run resume file

```json
{
  "run-id": "<slug>-<yyyymmdd-hhmmss>",
  "workflow": "expand-coverage",
  "cascade": "None",
  "step": "pass-3",
  "state-file": "tests/e2e/docs/coverage-expansion-state.json",
  "questions": [ { "n": 1, "question": "…", "answer": null } ],
  "rulings": [ "Ruling: … — … — cost if wrong: …" ],
  "commits": [ "<sha> <subject>" ],
  "updatedAt": "<ISO-8601>"
}
```

`questions` holds every open `NEEDS_CONTEXT` question; the main session's re-dispatch fills `answer`. A run whose resume file is missing restarts preflight and says so in its hand-back. The run directory `.achilles/runs/<run-id>/` holds this file, `briefs/` and `reports/`; there is no other run-state file.

## Coverage-expansion state

`tests/e2e/docs/coverage-expansion-state.json`. Read first; if absent or `status == "complete"`, start pass 1; if `currentPass` is set, resume that pass's roster, skipping journeys already recorded for it.

```json
{
  "status": "in-progress",
  "runMode": "standard",
  "currentPass": 3,
  "journeyRoster": ["j-…"],
  "completedJourneys": ["j-…"],
  "inFlightJourneys": ["j-…"],
  "dispatches": [
    { "journey": "j-<slug>", "stage_a_cycles": 2, "stage_b_cycles": 2,
      "review_status": "greenlight", "final_must_fix": [],
      "result": "new-tests-landed", "authorizer": null, "batch_id": null }
  ],
  "adversarialTotals": { "probes": 0, "boundaries": 0, "suspected": { "critical": 0, "high": 0, "medium": 0, "low": 0 }, "regressions": 0 },
  "adversarialSkippedJourneys": [
    { "journey": "j-logout", "rationale": "<specific>", "criteria": ["priority-p3", "page-subset-covered", "zero-prior-findings", "low-surface-shape"] }
  ],
  "passes": {
    "pass-1": { "kind": "compositional", "dispatches": [ ... ] },
    "pass-2": { "kind": "compositional", "dispatches": [ ... ] }
  },
  "deferredJourneys": [ { "journey": "j-…", "reason": "blocked-on-app-bug:<id>", "authorizer": null } ],
  "updatedAt": "<ISO-8601>"
}
```

- `passes`: one record per pass that has run, keyed `"pass-<N>"` (the bare `"<N>"` is accepted). Each is a non-empty object with `kind` (`compositional` | `adversarial`) and the pass's journey entries as `dispatches[]`, or `dispatched-journeys[]` / `returned-journeys[]`, or both. Phase 5 is complete when pass 1 exists (passes 1-5 and the cross-pass `cleanup` in standard and depth mode) and pass 1's journeys plus `deferredJourneys[]` (top level or in the pass-1 record) cover the journey map's roster.

- `runMode` ∈ `standard | depth`; omitted for breadth. Written on the first write of the run from the mode the brief named.
- Per dispatch: `stage_a_cycles`, `stage_b_cycles` (1..7), `review_status` ∈ `greenlight | blocked-cycle-stalled | blocked-cycle-exhausted | blocked-dispatch-failure`, `final_must_fix` (finding ids, carried to the next pass's author brief), `result` ∈ `new-tests-landed | covered-exhaustively | blocked | skipped`, `authorizer` non-null only for `skipped`, `batch_id` shared by the members of one grouped dispatch (null once a journey breaks out at cycle 2).
- Gated-skip entry (passes 2 and 3 only): `{ "journey", "gated_skip": true, "result": "covered-exhaustively", "review_status": "greenlight", "triggers_checked": { "map_delta": false, "sibling_ledger_update": false, "must_fix_carry_over": false } }`. All three booleans must be false; any `true` means the journey should have been dispatched.
- `deferredJourneys[]`: `reason` starts with `blocked-on-app-bug:<id>`, `test-data-prerequisite:<thing>` or `user-authorised:<quote>`, or the entry carries a non-empty `authorizer` quote. `budget-cap`, `session-length`, `auto-mode`, `inferred-pref` are invalid without one.
- `adversarialSkippedJourneys[]` entries land only at a user-authorised commit before pass 4 and need all four criteria strings.
- The roster is frozen at the start of a pass; journeys discovered mid-pass join the next pass's roster at the reconciliation commit.
- Lifecycle: rewritten after every per-pass commit; recorded complete (all five passes + cleanup) at the cross-pass cleanup commit; deleted only after the phase-5 review approves, as the final act.
- Corrupt: a dispatched journey without `stage_a_cycles`/`stage_b_cycles`/`review_status`; a journey not in the map; `completedJourneys` larger than `journeyRoster`; a pass marked complete whose commit is absent from history. Stop with `BLOCKED`; never self-repair.

## Journey-mapping cycle state

`tests/e2e/docs/.phase4-cycle-state.json`.

```json
{
  "phase4-cycle-state-version": 1,
  "started-at": "<ISO-8601>",
  "cycleStrictness": "standard",
  "draft-path": "tests/e2e/docs/.discovery-draft.json",
  "cycles": {
    "1": { "kind": "discovery", "dispatched-sections": ["catalog", "auth"], "returned-sections": ["catalog", "auth"],
           "new-sections-discovered": ["cart"], "duplicates-merged": [], "completed-at": "<ISO-8601>" },
    "2": { "kind": "edge-probe", "…": "…" }
  },
  "convergence-status": "converged",
  "author-dispatched": false,
  "author-attempts": 0,
  "unvalidated-sections-flagged": []
}
```

Cycles are contiguous `1..N`, at most 5, at least one `discovery` and exactly one `edge-probe`. `author-attempts` caps at 3. Deleted after the journey-map review approves. The concurrency log `tests/e2e/docs/.phase4-concurrency-log.jsonl` is transient and discarded with it.

## Discovery draft

`tests/e2e/docs/.discovery-draft.json`, written by the author at the end of a happy-path scenario (onboard Phase 3) and consumed by map-journeys cycle 1. First key `"discovery-draft-version": 1`; then `generated-at`, `app-url`, `visited-routes[]` (`url`, `role-as`, `kind-guess`, `interactive-elements[]`, `links-out[]`), `unvisited-but-linked[]` (`url`, `seen-from`, `section-guess`), `sections-inferred[]` (`id`, `routes-visited[]`, `routes-suggested[]`, `role-required`, `seed-data-needed`), `handover-to-phase4` (`cycle-1-targets[]`, `credentials-discovered { signup-open, signup-endpoint, demo-credentials, admin-path }`). An author that cannot infer at least one section returns `blocked: discovery-draft-empty` rather than writing an empty draft. Section ids come from the vocabulary in [`../../journey-mapping/SKILL.md`](../../journey-mapping/SKILL.md) §"Section vocabulary".

## Pipeline ledgers

`tests/e2e/docs/onboarding-status.json` and `tests/perf/docs/perf-onboarding-status.json` follow `schemas/onboarding-status.schema.json` and `schemas/perf-onboarding-status.schema.json`. One row per phase with `status` (`pending → in-progress → completed`, or `skipped` with an `approvedDeviations[]` entry whose `authorizer` is a verbatim quote), `reviewerVerdict` (`pending | approved | rejected | escalated-to-user`), `reviewerCycles` (0..3), `handoverEnvelope` (the closing expert's envelope, required for `approved`), and `runMode` with its `modeAuthorizer`. The pipeline `status` says `complete`; a phase says `completed`. The third rejection is `escalated-to-user` and the pipeline `status` becomes `blocked`.

## Quarantine ledger

`tests/e2e/docs/flake-quarantine.md`: one entry per `@flaky` test with `Status: quarantined | unquarantined (<date> — <evidence>)`, the heal strategies already tried, and dated `Observations:` lines that are appended, never rewritten. Authors add entries; only the repair-suite workflow's quarantine review releases them.
