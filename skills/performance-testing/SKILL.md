---
name: performance-testing
description: >
  Use this skill whenever the user wants to load-test, stress-test, or measure the performance of a
  backend or web app with k6. Triggers on: "load test", "performance test", "perf test", "k6",
  "@civitas-cerebrum performance", "stress test the endpoint", "spike test", "soak test",
  "breakpoint test", "check p95 under load", "latency under load", "how many concurrent users",
  "throughput test", "requests per second", "SLO", "performance budget". Also triggers when a test
  needs k6 thresholds, workload profiles (smoke/load/stress/spike/soak/breakpoint), or a perf report.
  Always consult this skill before writing any k6 script — do not invent k6 API, options, or
  threshold syntax from memory; read references/k6-reference.md first. This skill owns the
  performance entrypoint; it is a sibling of contract-testing and database-testing and runs inline.
  Not for: adversarial functional edge-case probing (that is bug-discovery, even when phrased as
  "stress test the app"); UI-flow correctness (element-interactions); API shape/contract drift
  (contract-testing). Load / throughput / latency-under-concurrency routes here; everything else routes
  to its own skill.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents are exempt.

> **Skill names: see `../element-interactions/references/skill-registry.md`.** Copy skill names verbatim.

# Performance Testing — k6 Load & SLO Verification

A structured protocol for writing **k6** performance tests against HTTP backends. These tests
verify *performance contracts* — latency percentiles, error rate under load, throughput — using
k6 thresholds as the machine oracle. They do not test UI flows, API shape, or business logic.

> **Why k6 and not the Steps API.** k6 runs in its own JavaScript runtime (goja), **not Node**. A k6
> script cannot import the Node-side `@civitas-cerebrum/element-interactions` Steps API. The shared
> code that scenarios reuse is a set of **k6-native ESM helper modules** scaffolded into the repo
> (`tests/perf/lib/`), not the Steps API.

## Reference index

| Reference file | What's in it |
|---|---|
| [`references/k6-reference.md`](references/k6-reference.md) | k6 script anatomy, options/stages, thresholds syntax, `handleSummary`, `__ENV`, and the **canonical helper-module code** the skill scaffolds. Read before writing any k6. |
| [`references/workload-design.md`](references/workload-design.md) | The six workload profiles, when each applies, deriving VU/RPS targets from documented SLOs. |
| [`references/correlation.md`](references/correlation.md) | Dynamic-value extraction/injection (tokens, CSRF, session ids) and fragility mitigation. |
| [`references/results-analysis.md`](references/results-analysis.md) | Reading k6 output, percentiles vs averages, the **SLO-breach → severity ladder**, regression-vs-baseline. |
| [`references/test-data.md`](references/test-data.md) | Parameterization, `SharedArray`, data-driven VUs, cache-skew avoidance. |

## Router carve-out (vs `bug-discovery`)

`bug-discovery` claims "stress test the app" as a trigger, but means *adversarial functional*
probing, not load. The boundary:

- Load / throughput / latency-under-concurrency / VU-ramp → **this skill**.
- Adversarial edge-case / malformed-input / state-corruption probing → `bug-discovery`.

## 🚨 Absolute Rules

1. **Read `references/k6-reference.md` first.** Never invent k6 API / threshold syntax from memory.
2. **Never hardcode a base URL** — including `__ENV.X || 'http://localhost'` fallbacks. Origins come from `tests/perf/lib/config.js` reading env vars; scenarios address paths.
3. **One scenario per script; one workload intent per run.**
4. **Thresholds are the oracle.** On breach, never loosen the threshold to go green — a breach is a finding (escalate), exactly like contract drift.
5. **SLO targets must trace to a documented source** (SLA, journey-map priority, or user-confirmed). Never invent latency budgets.
6. **Smoke at 1 VU before ramping.** Correlate dynamic tokens; never hardcode a captured session id.
7. **Credentials from env vars only.**
8. **Never run a load profile against production without explicit per-run ack.** A 500-VU spike at prod is not "read-only safe."
9. **Deliberate-breach check is mandatory before the report step** (Workflow step 6).

## Prerequisites

Verify all before starting; if any is missing, stop and ask the user.

- k6 is installed (`k6 version` succeeds on PATH). If not, stop: *"Performance tests need k6. Install it — `brew install k6` (macOS), `choco install k6` (Windows), or see grafana.com/docs/k6. Then re-run."*
- A reachable target — staging / sandbox / local. **Never production without explicit per-run ack.**
- Auth mechanism known; credentials in env vars, not source.
- SLO targets exist or can be sourced (SLA doc, journey-map priority, or user confirmation).

## Workflow

1. **Intake.** Confirm target(s), environment (staging default; prod gated), auth source, k6 availability, and SLO source.
2. **Scenario inventory.** *Derive when present, else ask.* Read `tests/e2e/docs/journey-map.md` (critical flows → workload mix) and `tests/contracts/` (endpoints, auth, env config) to draft scenarios + SLO targets; fall back to intake conversation when absent. **Gate on user approval.**
3. **Scaffold helpers.** Write `tests/perf/lib/` (config, profiles, thresholds, correlation, summary) per `references/k6-reference.md`.
4. **Workload & SLO design.** Pick profile(s) per scenario; set thresholds from documented SLOs (`references/workload-design.md`). **Gate on user approval.**
5. **Implementation.** Generate `tests/perf/scenarios/*.js` importing the helpers — one scenario per script.
6. **Run & verify.** Smoke at 1 VU (`k6 run` with the `smoke` profile) to catch script/correlation errors cheaply, then run the chosen profile. **Deliberate-breach check (HARD GATE):** tighten one threshold to an impossible value, confirm `k6 run` exits non-zero and reports the breach, then revert. A green run whose thresholds cannot bite is vacuous.
7. **Report + ledger.** Write `tests/perf/docs/perf-report.md`; feed SLO breaches/regressions into `tests/e2e/docs/adversarial-findings.md` using the canonical finding format and the severity ladder in `references/results-analysis.md`.

## Project layout

```
tests/perf/
  lib/        config.js  profiles.js  thresholds.js  correlation.js  summary.js
  scenarios/  <journey-slug>.js   # one k6 script per scenario, imports ../lib
  results/    <slug>.json         # gitignored — raw k6 summaries
  docs/       perf-report.md      # durable artifact (sentinel-headed)
```

## Integration with other skills

| Skill | When it applies |
|---|---|
| `element-interactions` | Parent orchestrator; routes here on perf intent. |
| `journey-mapping` | Source of critical flows → workload mix (Phase 2). |
| `contract-testing` | Source of endpoints / auth / env config (Phase 2); reuse its `baseFixture` env conventions. |
| `bug-discovery` | Boundary, not overlap — see the router carve-out above. |
| `failure-diagnosis` | Invoke on an unexpected k6 script failure (not on a threshold breach — a breach is a real finding). |
