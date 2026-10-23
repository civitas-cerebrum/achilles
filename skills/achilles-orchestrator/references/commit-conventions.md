# Commit conventions

One deliverable per commit, one template per deliverable kind. The git log has to be filterable by journey slug and by kind. The orchestrator commits what authors land; reviewers never commit (their verdicts live in the state file). No AI attribution trailers (`Co-Authored-By: Claude …`, "Generated with …") in any commit or PR body.

| Deliverable | Subject | Notes |
|---|---|---|
| Scaffold | `chore: scaffold e2e suite` | onboard Phase 1 |
| Groundwork docs | `docs: initial app-context and site map` | onboard Phase 2, map-journeys phase 1 |
| Single scenario (author-scenario) | `test(<area>): <scenario>` | one scenario per commit; `test: graduate evidence bundle <slug>-<ts>` when it came from a bundle |
| Happy path (onboard Phase 3) | `test(j-<slug>): happy path` | one journey per commit |
| Journey map | `docs(journey-map): <converged at cycle N \| hard-cap-reached>` | map-journeys author step |
| Compositional pass (1–3) | `test(<j-slug>): <variant>` | one journey, one variant per commit (`happy-path`, `error-states`, `edge-cases`, `mobile`, `negative`, `data-lifecycle`, `visual`) |
| Adversarial pass 4 | `docs(ledger): <j-slug> — N probes, M boundaries, K suspected bugs` | diff is the ledger only |
| Adversarial pass 5 | `test(<j-slug>-regression): lock <N> boundaries` | body lists one `lock <boundary>` line per regression test |
| Per-pass dedup | `docs(ledger): pass <N> test dedup` / `docs(ledger): pass <N> findings dedup` | lands even when nothing merged (empty diff + log line) |
| Cross-pass cleanup | `docs(ledger): dedupe cross-cutting findings` | once after pass 5 |
| App-wide scan | `docs(app-wide): pattern catalogue established (pre-pass-4)` | |
| Standalone bug hunt | `docs(bug-hunt): <j-slug \| phase> — N findings` | findings go to the report, never `fix(…)` |
| Heal | `fix(<j-slug>): <cause> — <heal>` | after the stability bar; one spec per commit |
| Quarantine or release | `docs(quarantine): <test-id> <quarantined \| released>` | |
| Secrets sweep | `chore: extract secrets to .env` | |
| Selector attribute | `feat(selectors): add data-testid='<value>' to <element-key>` | the one frontend file plus the spec that uses it |
| Perf | `chore(perf): scaffold perf suite`, `feat(perf): scenario model — <N> scenarios`, `test(perf): baselines — smoke-green for <N> scenarios`, `test(perf): load-run <pass> — <N> scenarios`, `test(perf): threshold-gate — deliberate-breach proven`, `docs(perf): perf-report — <verdict>` | one phase per commit; load-run per pass |
| Report | `docs(report): qa summary deck` / `docs(report): test catalogue` | |
| Verify-change tests | `test(<ticket>): <AC or defect sentinel>` | only after the commit-or-discard ruling |

Not used: `feat(e2e)`, multi-journey scopes (`test(j-a,j-b)`), `review(…)`, pass numbers in the scope (the `-regression` suffix carries pass 5), `fix(…)` for new tests.
