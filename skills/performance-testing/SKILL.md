---
name: performance-testing
description: >
  k6 load, stress, spike, soak and breakpoint testing with SLO thresholds as
  the oracle, loaded by an `author` dispatch. Triggers: "load test",
  "performance test", "perf test", "k6", "stress test the endpoint", "check
  p95 under load", "latency under load", "how many concurrent users",
  "throughput", "requests per second", "SLO", "performance budget", and the
  pipeline asks "perf-onboard this project", "set up the performance
  pipeline", "build a perf suite from zero". Read references/k6-reference.md
  before writing any k6; never invent k6 API or threshold syntax. Not for
  adversarial functional probing (bug-discovery, even when phrased "stress
  test the app"), UI correctness, or API shape drift (contract-testing).
---

# Performance testing

k6 scripts verify performance contracts (latency percentiles, error rate under load, throughput) with thresholds as the machine oracle. k6 runs in its own runtime, not Node: scripts cannot import the Steps API; shared code is the set of k6-native helper modules scaffolded under `tests/perf/lib/`.

## Reference index

| Reference | Holds |
|---|---|
| [`references/k6-reference.md`](references/k6-reference.md) | Script anatomy, options and stages, thresholds, `handleSummary`, `__ENV`, the canonical helper-module code |
| [`references/workload-design.md`](references/workload-design.md) | The six profiles, when each applies, deriving VU/RPS targets from SLOs |
| [`references/correlation.md`](references/correlation.md) | Dynamic-value extraction and injection; fragility mitigation |
| [`references/results-analysis.md`](references/results-analysis.md) | Reading output, percentiles versus averages, the SLO-breach severity ladder, regression versus baseline |
| [`references/test-data.md`](references/test-data.md) | Parameterisation, `SharedArray`, data-driven VUs, write-load hygiene |
| [`references/perf-readiness-detector.md`](references/perf-readiness-detector.md) | The derive-versus-bootstrap probe the pipeline runs first |

## Absolute rules

1. Read `references/k6-reference.md` first; never write k6 from memory.
2. Never hard-code a base URL, including `__ENV.X || 'http://localhost'` fallbacks; origins come from `tests/perf/lib/config.js` reading env; scenarios address paths.
3. One scenario per script; one workload intent per run.
4. Thresholds are the oracle. A breach is a finding; never loosen a threshold to go green.
5. SLO targets trace to a documented source (SLA, journey-map priority tier, or a confirmed figure in the brief); never invented.
6. Smoke at 1 VU before ramping; correlate dynamic tokens; never hard-code a captured session id.
7. Credentials from env only.
8. No load against production without the explicit per-run authorisation in the brief and `production.allowed: true` in the config; a 500-VU spike at prod is not "read-only safe".
9. The deliberate-breach check runs before the report: tighten one threshold to an impossible value, confirm `k6 run` exits non-zero, revert. A green run whose thresholds cannot bite is vacuous.

## Prerequisites

`k6` on PATH (`k6 version` exits 0; otherwise return `BLOCKED` with the install path for the platform); a reachable non-production target; the auth mechanism known with credentials in env; an SLO source. A missing item is a `NEEDS_CONTEXT` return.

## Scenario workflow (one scenario or a small set)

1. **Intake** from the brief: targets, environment, auth source, SLO source.
2. **Scenario inventory**: derive from `tests/e2e/docs/journey-map.md` (critical flows → workload mix) and `tests/contracts/` (endpoints, auth, env) when present; otherwise from the brief. Return the inventory and SLO targets as a `NEEDS_CONTEXT` when the brief did not pre-authorise them.
3. **Scaffold helpers** under `tests/perf/lib/` (`config.js`, `profiles.js`, `thresholds.js`, `correlation.js`, `summary.js`) per the k6 reference, when absent.
4. **Workload and SLO design** per scenario (`references/workload-design.md`).
5. **Implement** `tests/perf/scenarios/<slug>.js`, one scenario per script, importing the helpers.
6. **Run and verify**: smoke at 1 VU, then the chosen profile, then the deliberate-breach check.
7. **Report**: `tests/perf/docs/perf-report.md` with `<!-- performance-testing:generated -->` on line 1; SLO breaches and regressions go to `tests/e2e/docs/adversarial-findings.md` as canonical findings with the severity ladder from `references/results-analysis.md`.

## Pipeline mode (zero to a maintained perf suite)

The orchestrator runs this as seven phases with a fresh phase-gate review between each ([`../review/SKILL.md`](../review/SKILL.md)); the ledger is `tests/perf/docs/perf-onboarding-status.json` ([state-files.md](../achilles-orchestrator/references/state-files.md) §"Pipeline ledgers"). Each phase is one author dispatch loading this skill with the phase named; the perf reviewer gates count as the composition judge for k6 scenarios.

Precondition: `k6` available; the target origin reachable (HTTP probe, 3 s); the readiness probe run ([`references/perf-readiness-detector.md`](references/perf-readiness-detector.md)): `derive` when a sentinel-bearing journey map and `tests/perf/captures/manifest.json` both exist, else `bootstrap` (crawl up to 50 URLs, an OpenAPI spec, or an endpoint list from the brief; recommend the e2e onboard workflow for richer coverage, then continue).

| # | Phase | Deliverable | Exit |
|---|---|---|---|
| 1 | Scaffold | `tests/perf/lib/*` (five helpers), `tests/perf/perf-onboarding.config.json` (`targets.default`, `targets.allowlist`, `caps { maxVUs, maxConcurrentScenarios, maxDurationPerRun, maxTotalDuration }`, `production { origin, allowed: false }`), gitignore entries (`tests/perf/results/`, `captures/`, `baselines/`, `*.har`), the ledger initialised | config with a non-empty allowlist and caps; `lib/` non-empty; `k6 version` 0 |
| 2 | Readiness | `tests/perf/docs/readiness.md` from the detector's template: cascade outcome, both axes, targets, SLO source | the six items stated, none inferred |
| 3 | Scenario model | `tests/perf/docs/scenario-model.md` (`<!-- perf-onboarding:scenario-model -->` on line 1): per scenario the name (generic vocabulary), priority, SLO targets (`p95_response_ms`, `error_rate_pct`, `rps_min`), required profiles, script path; and `tests/perf/scenarios/*.js` | sentinel; ≥1 script; every SLO traced to its source |
| 4 | Baseline | `tests/perf/baselines/<scenario>.json` from a 1-VU, 30 s smoke per scenario (p50/p95/p99, error rate, RPS) | every scenario smoke-green at zero error rate; a script error is a `BLOCKED` for that scenario, never a skipped baseline |
| 5 | Load runs | `tests/perf/results/<scenario>-<pass>-<ts>.json` per required pass, in order `load → stress → spike → soak`, each pass reviewed before the next; VU counts tuned within `caps.maxVUs` from baseline signals | every required pass has a result per scenario; no ceiling violation |
| 6 | Threshold gate | `tests/perf/docs/threshold-verdict.json` with `deliberateBreach[]` (≥1 entry: scenario, mutated threshold, non-zero exit code, revert confirmed), `scenarios[]` (`pass | fail | warning` at 20% of the limit, actual versus threshold), `regressions[]` (p95 under load more than 3× the 1-VU baseline) | all three sections; the mutation reverted |
| 7 | Report | `tests/perf/docs/perf-report.md` (`<!-- perf-onboarding:report -->` on line 1): executive summary, scenario inventory, threshold-gate results, regression analysis, SLO-breach findings, recommendations | sentinel; every breach surfaced; figures consistent with the result files |

Safety ceilings are fixed and not configurable (1000 VUs, 3600 s, allowlisted origin, production only with `production.allowed: true`); the Claude Code adapter denies a `k6 run` past them, and the skill never asks for a mid-run exception. Commit subjects per phase: [commit-conventions.md](../achilles-orchestrator/references/commit-conventions.md). Cross-cutting: one commit per phase (per pass in Phase 5); generic scenario vocabulary; the threshold mutation always reverted; the ledger never hand-edited around a failed check.

Resume: the first ledger row that is not `completed` with `reviewerVerdict: approved`; inside Phase 5 the first sub-stage without an approved verdict.

## Project layout

```
tests/perf/
  lib/        config.js  profiles.js  thresholds.js  correlation.js  summary.js
  scenarios/  <slug>.js
  baselines/  <scenario>.json          # gitignored, regenerated on demand
  results/    <scenario>-<pass>-<ts>.json   # gitignored
  docs/       readiness.md  scenario-model.md  threshold-verdict.json  perf-report.md
  perf-onboarding.config.json
```

## Integration

`journey-mapping` supplies critical flows and priority tiers; `contract-testing` supplies endpoints, auth and env conventions; `bug-discovery` is the boundary, not an overlap (load routes here, adversarial probing there); an unexpected k6 script failure (not a threshold breach) goes through `failure-diagnosis`.

## Return

Envelope first, then: scripts written, runs executed (profile, VUs, duration), the deliberate-breach proof (threshold, exit code), report path, findings (canonical blocks), and any `concerns` (a scenario that could not be smoked, a target that could not be reached).
