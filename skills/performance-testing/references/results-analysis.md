# Results Analysis

## Read percentiles, not averages

A mean latency hides the tail. Always report and gate on `p(95)` / `p(99)` for
`http_req_duration`. The `avg` is for color, not for the oracle.

## Source of truth

Read `tests/perf/results/<slug>.json` (written by `lib/summary.js` `handleSummary`), not k6
stdout. The JSON carries per-metric `values` (avg/min/med/p90/p95/p99/max), `http_req_failed`
rate, and `http_reqs` count → throughput.

## SLO-breach → severity ladder (single source for the ledger feed)

When a run breaches an SLO, write a finding to `tests/e2e/docs/adversarial-findings.md` using
the canonical finding format (Finding-ID `<journey-slug>-perf-<nn>`), with severity:

| Condition | Severity |
|---|---|
| Error-rate threshold breach (requests failing under load) | `critical` |
| p95 over latency budget by ≥ 50% | `high` |
| p95 over latency budget by 10–50% | `medium` |
| Throughput shortfall vs target | `medium` |
| Soak-test latency / memory creep over time | `high` |

The `scope` / `expected` / `observed` / `coverage` field mapping follows
`../../element-interactions/references/subagent-return-schema.md`.

## Regression vs baseline

If a committed baseline exists (`tests/perf/<slug>.baseline.json`), compare current p95 against
it: a p95 regression > 20% with thresholds still passing is a `medium` finding (the app got
slower but is still inside budget — worth flagging before it crosses). If no baseline exists,
the first green run establishes one (commit it; ask the user first).

## What a green run proves — and doesn't

Green proves the thresholds held *for this profile, this environment, this data set*. It does
NOT prove the thresholds can bite — that is what the Phase-6 deliberate-breach check exists for.
