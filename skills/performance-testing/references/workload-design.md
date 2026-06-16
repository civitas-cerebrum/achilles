# Workload Design

## The six profiles

| Profile | Question it answers | Shape |
|---|---|---|
| `smoke` | Does the script work at all? | 1 VU, 30s. Always run first. |
| `load` | Does it hold SLOs at expected peak? | Ramp to expected-peak VUs, hold, ramp down. |
| `stress` | Where does it degrade past expected peak? | Ramp beyond peak in stages. |
| `spike` | Does a sudden surge break it / recover? | Fast ramp to a high target, hold briefly, drop. |
| `soak` | Does it leak / drift over hours? | Moderate VUs held for hours; watch latency/memory creep. |
| `breakpoint` | What is the max throughput before failure? | `ramping-arrival-rate` climbing until thresholds break. |

## Deriving targets from SLOs (never guess)

- **Expected peak VUs / RPS** comes from production traffic data, an SLA, or journey-map priority — not a round number you like. Record the source in the perf report.
- **Latency budget (p95/p99)** comes from the documented SLO. If none exists, stop and ask; do not invent one (Rule 5).
- **Error-rate ceiling** defaults to `rate<0.01` unless the SLA states otherwise.
- Map a journey-map P0/P1 flow → `load` + `stress`; a known-bursty flow (checkout, login storm) → add `spike`; a long-running service → add `soak`.

## Think time & pacing

Use `sleep()` to model realistic user think-time in browser-like flows; omit it for raw API
throughput tests where you want maximum pressure. State which you chose and why in the report.
