# Status vocabulary

Status values are defined by the schemas under `schemas/`; this file records only what they cannot express.

- Pipeline ledgers: [onboarding](../../../schemas/onboarding-status.schema.json), [perf](../../../schemas/perf-onboarding-status.schema.json). The pipeline `status` says `complete`; a phase `status` says `completed`. Both are schema-enforced; do not normalise.
- A phase moves `pending`, `in-progress`, `completed`, in order. `skipped` needs an `approvedDeviations[]` entry with a verbatim `authorizer` quote.
- `approved` needs a non-null `handoverEnvelope`. `approved`, `complete` and `aborted` need a registered approver as writer; `complete` and `aborted` retire the session's protocol activation.
- The third rejection is `escalated-to-user`, never `rejected`.

## Subagent returns

`handover.status` is role-specific ([handover](../../../schemas/subagent-returns/handover.schema.json)).

| Role | Schema |
|---|---|
| test-composer, secrets-sweep, database-testing | [composer](../../../schemas/subagent-returns/composer.schema.json) |
| probe | [probe](../../../schemas/subagent-returns/probe.schema.json) |
| workflow-reviewer | [workflow-reviewer](../../../schemas/subagent-returns/workflow-reviewer.schema.json) |
| perf-reviewer | [perf-reviewer](../../../schemas/subagent-returns/perf-reviewer.schema.json) |
| in-loop reviewer | [reviewer-inloop](../../../schemas/subagent-returns/reviewer-inloop.schema.json) |
| phase-validator | [phase-validator](../../../schemas/subagent-returns/phase-validator.schema.json) |

Reviewer `verdict` maps to the ledger word: `approve` to `approved`, `reject` to `rejected`, `escalate` to `escalated-to-user`.

`covered-exhaustively` needs a per-expectation mapping table; `no-new-tests-by-rationalisation` is not a valid status.
