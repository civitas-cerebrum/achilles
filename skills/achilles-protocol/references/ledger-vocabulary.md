# Status vocabulary

Every status word the pipeline and its hooks accept. Schemas under `schemas/` are the source; the hooks enforce the same values. Use these words verbatim; do not coin synonyms.

## Pipeline ledger

`tests/e2e/docs/onboarding-status.json` ([schema](../../../schemas/onboarding-status.schema.json)) and `tests/perf/docs/perf-onboarding-status.json` ([schema](../../../schemas/perf-onboarding-status.schema.json)) share these enums.

| Field | Values |
|---|---|
| top-level `status` | `in-progress`, `blocked`, `complete`, `aborted` |
| `phases[].status`, `phases[].subStages[].status` | `pending`, `in-progress`, `completed`, `blocked`, `skipped` |
| `phases[].reviewerVerdict` | `pending`, `approved`, `rejected`, `escalated-to-user`, `null` |
| `runMode` | `standard`, `depth` |

The pipeline says `complete`; a phase says `completed`. Both are schema-enforced; do not normalise.

Transitions the hooks enforce:

- A phase moves `pending` to `in-progress` to `completed`, in order. `skipped` needs an `approvedDeviations[]` entry with a verbatim `authorizer` quote.
- `approved` needs a non-null `handoverEnvelope` and a registered approver as the writer.
- The third rejection is `escalated-to-user`, never `rejected`.
- `complete` and `aborted` are terminal and also need a registered approver; they retire the session's protocol activation.

Phase names: onboarding is Scaffold, Groundwork, Happy-path, Journey-mapping, Coverage-expansion, Bug-discovery, Secrets-sweep, Report. Perf is Scaffold, Readiness, Scenario-model, Baseline, Load-run, Threshold-gate, Report.

## Subagent returns

`handover.status` is role-specific ([handover schema](../../../schemas/subagent-returns/handover.schema.json)). The `verdict` words belong to the reviewer's return, not the ledger.

| Role | `status` values | Schema |
|---|---|---|
| test-composer, secrets-sweep, database-testing | `new-tests-landed`, `covered-exhaustively`, `blocked`, `skipped` | [composer](../../../schemas/subagent-returns/composer.schema.json) |
| probe (bug-discovery) | `clean`, `findings-emitted`, `blocked` | [probe](../../../schemas/subagent-returns/probe.schema.json) |
| workflow-reviewer, perf-reviewer | `approved`, `rejected`, `escalated-to-user` | [workflow-reviewer](../../../schemas/subagent-returns/workflow-reviewer.schema.json), [perf-reviewer](../../../schemas/subagent-returns/perf-reviewer.schema.json) |
| in-loop reviewer, phase-validator | `greenlight`, `improvements-needed` | [reviewer-inloop](../../../schemas/subagent-returns/reviewer-inloop.schema.json), [phase-validator](../../../schemas/subagent-returns/phase-validator.schema.json) |
| phase-4 prioritise author | `journey-map-authored`, `blocked` | [phase4-prioritise-author](../../../schemas/subagent-returns/phase4-prioritise-author.schema.json) |
| section agent | `section-complete` | [section-agent](../../../schemas/subagent-returns/section-agent.schema.json) |
| repair worker | `completed`, `blocked` | [repair-worker](../../../schemas/subagent-returns/repair-worker.schema.json) |

Reviewer `verdict` maps to the ledger word: `approve` to `approved`, `reject` to `rejected`, `escalate` to `escalated-to-user`.

`covered-exhaustively` needs a per-expectation mapping table; `no-new-tests-by-rationalisation` is not a valid status.

## Other enums

| Field | Values | Schema |
|---|---|---|
| `dispatch-mode` (handover) | `per-journey`, `per-section`, `grouped`, `single-agent-collapsed` | [handover](../../../schemas/subagent-returns/handover.schema.json) |
| `convergence-status` (phase-4 prioritise author) | `converged`, `hard-cap-reached` | [phase4-prioritise-author](../../../schemas/subagent-returns/phase4-prioritise-author.schema.json) |
| `tests.status` (run summary) | `passing`, `failing`, `null` | [run-summary](../../../schemas/run-summary.schema.json) |
| `slo_results[].verdict` (perf summary) | `passing`, `failing`, `null` | [perf-summary](../../../schemas/perf-summary.schema.json) |
| `breaches[].severity` (perf summary) | `critical`, `high`, `medium`, `low`, `info` | [perf-summary](../../../schemas/perf-summary.schema.json) |
| `pass` (perf-reviewer) | `load`, `stress`, `spike`, `soak`, `null` | [perf-reviewer](../../../schemas/subagent-returns/perf-reviewer.schema.json) |
| `files[].status` (self-repair) | `green`, `healed`, `explained`, `unresolved` | [self-repair-report](../../../schemas/self-repair-report.schema.json) |
| `tests[].outcome` (self-repair) | `already-green`, `known-defect`, `healed`, `app-bug`, `quarantined`, `operator-pending`, `unresolved` | [self-repair-report](../../../schemas/self-repair-report.schema.json) |
| `tests[].baseline-pattern` (self-repair) | `green`, `known-defect`, `known-defect-passed`, `deterministic-fail`, `flaky-consistent`, `flaky-chaotic` | [self-repair-report](../../../schemas/self-repair-report.schema.json) |
