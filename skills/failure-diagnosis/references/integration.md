# Integration and escalation

# Integration

## Skills that call this one

| Calling Skill | Activation Point | What Happens Next |
|---|---|---|
| `maintenance` | First step when a test failure is reported | After heal + stability → return for compliance review + commit |
| `authoring` | When a newly written test fails in Stage 3 | After heal + stability → return for compliance review + commit |
| `test-composer` | When a test run produces failures | After heal + stability → return for next scenario |
| `bug-discovery` | When adversarial tests fail | After heal + stability OR bug report → return to caller |
| `test-repair` | Per cluster in its Stage 4 (batch repair pipeline) | Diagnose the cluster's representative, apply heal once for the whole cluster, return outcome (Healed / App bug / Operator-pending / Quarantined) |
| `self-repair` | Per red spec file, inside each `repair-worker-*` worker | Same contract as `test-repair`, one worker per file |
| `achilles-protocol` | A pipeline run went red and the user asks why (Entrypoint C) | Dispatch an `fd-ci-<run-id>:` subagent; it runs Stage 0 → Stage 0a → Stage 0b → the full pipeline and returns the diagnosis with run provenance |

After a successful heal + stability confirmation, control returns to the calling skill.

## Escalating up to test-repair

Sometimes single-failure mode isn't the right shape. Hand off to `test-repair` when the failure is not really a single event:

| Condition | Why escalate |
|---|---|
| The current run has ≥5 failures or ≥30% of executed tests failed | Per-failure diagnosis doesn't scale; batch clustering finds the shared root cause faster |
| You have been invoked 3+ times in this session on distinct tests | The pattern across failures is likely worth detecting before healing more in isolation |
| A heal you applied caused previously-passing tests to start failing | Cross-test interaction is invisible from here; `test-repair`'s post-heal verification stage is designed for it |
| Two different heal strategies on the same test have both destabilized | Before trying a third, bump up to batch mode: the test's behavior may be coupled to sibling tests |
| The pipeline run has ≥5 failing tests or ≥2 red spec files (Entrypoint C) | Same volume rule, read off the run's JSON reporter output. **Complete Stage 0a + Stage 0b first** and hand `test-repair` / `self-repair` the *downloaded artifact directory* and the run's `headSha`, not just the run id; otherwise clustering starts from log lines instead of evidence |

**Announce the escalation once** to the operator and start batch mode:

> Detected <reason>: handing off to the `test-repair` batch pipeline so we can cluster root causes before continuing to heal individually. Reply "stay single-failure" to override.

The operator can override back to single-failure mode if they have a reason to keep the narrower scope.

---

# API Reference

Refer to [`../achilles-protocol/references/api-reference.md`](../../achilles-protocol/references/api-reference.md) for all method signatures, argument orders, and types. All Steps methods use `(elementName, pageName)` order.
