# Integration and escalation

## Who dispatches an author with this skill

| Caller | When | After the pipeline |
|---|---|---|
| author-scenario workflow (Stage 3, fix mode) | a new or edited test fails | heal + stability → the 4b sweep → commit |
| `test-composer` Step 4 | a run inside the journey's composition fails | heal + stability → the next variant |
| `bug-discovery` phase 6 | a reproduction test fails for the wrong reason | heal + stability, or the finding stays ledger-only |
| repair-suite workflow | one representative per cluster, or one author per red spec file (the worker pipeline order in [worker-pipeline.md](worker-pipeline.md)) | the outcome per test: `healed`, `app-bug`, `operator-pending`, `quarantined`, `known-defect`, `unresolved` |
| repair-suite workflow, pipeline-sourced | "the nightly failed", "CI is red", a run id (Entrypoint C) | Stage 0 → 0a → 0b → the full pipeline, with run provenance in the return |
| `evidence-capture` follow-up | the orchestrator routes a `FAILED` bundle to diagnosis on the user's answer | the verdict decides between a durable test and a bug ticket |

Control returns to the dispatching workflow with the stability evidence and the sweep announced.

## Escalating to the batch pipeline

Single-failure mode is the wrong shape when the failure is not a single event. Return `BLOCKED` with the reason below instead of continuing, so the orchestrator switches to the repair-suite batch pipeline:

| Condition | Why |
|---|---|
| the current run has ≥5 failures or ≥30% of executed tests failed | per-failure diagnosis stops scaling; clustering finds the shared cause |
| three or more distinct tests diagnosed in one run of work | a pattern across failures is likely |
| a heal made previously passing tests fail | cross-test interaction is invisible from here; the batch pipeline's suite-order verification is built for it |
| two heal strategies on the same test both destabilised | the test is coupled to its siblings |
| a pipeline run with ≥5 failing tests or ≥2 red spec files | the same volume rule read off the run's JSON reporter; finish Stage 0a + 0b first and hand over the downloaded artifact directory and `headSha`, not just the run id |

## API reference

Every Steps method signature, argument order and option shape: [`../../achilles-orchestrator/references/api-reference.md`](../../achilles-orchestrator/references/api-reference.md). All Steps methods use `(elementName, pageName)` order.
