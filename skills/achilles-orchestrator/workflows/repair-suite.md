# Workflow: repair-suite

Restore a suite to a verified green state. One pipeline, three front doors: a single failing test, an in-session batch repair, and the unattended `npm run test:repair` (`achilles-self-repair`, a standalone CLI that runs the same stages from `bin/self-repair.mjs` for harnesses without an orchestrator; under the orchestrator, repair workers are author dispatches through the Agent tool). The atomic heal-or-classify work is always an author loading [`../../failure-diagnosis/SKILL.md`](../../failure-diagnosis/SKILL.md) with its worker pipeline (`../../failure-diagnosis/references/worker-pipeline.md`).

## Routing inside the workflow

| Signal | Shape |
|---|---|
| One failing test named by the user | one author, `failure-diagnosis` entrypoint L; no baseline runs |
| A pipeline run went red ("CI is red", a run id) | Stage 0b first (pull the run's artifacts), then the shape below by volume |
| ≥5 failures or ≥30% of executed tests, or failures repeat across diagnoses, or a heal broke neighbours | the batch pipeline: cluster-first when one shared cause dominates, per-file fan-out otherwise |
| `npm run test:repair` | per-file fan-out, unattended; the CLI writes `.achilles/self-repair/<run-id>/` |

Compile errors, infrastructure failures (server down, runner OOM, DNS) and a user explicitly scoped to one test are not batch work: report and stop, or stay single-failure.

## Stage 0b: pipeline evidence (pipeline-sourced only)

Author or orchestrator follows `failure-diagnosis` §"Stage 0a" and §"Stage 0b": pin to the run's `headSha` and resolved dependency versions, download the run's artifacts with `gh`. The run's JSON reporter output names the red set; each red file's trace, screenshot and `error-context.md` (naming the attempt they came from) go into that file's brief. A version delta between the run and the local tree is itself a cluster whose heal is a dependency bump. The local baseline still runs: a file red in CI and green locally is a classification, not a pass.

## Stage 1: baseline

Three runs minimum, the floor that separates deterministic from flaky.

- **Focus mode (default):** one discovery run over the full scope with the suite's own timeouts and the JSON reporter (`PLAYWRIGHT_JSON_OUTPUT_NAME=.achilles/self-repair/<run-id>/baseline-1.json npx playwright test --reporter=json`); then reruns 2..N scoped to the red files with `--trace on` and the analysis timeout cap (default 60 s per test). The cap applies to analysis reruns only; discovery and verification use real timeouts.
- **Full mode (`--baseline-mode full`):** every run full scope; required for suites with cross-file state coupling and for flake sweeps.
- Space the reruns (`--rerun-delay`) when a 3/3 red could be a time-boxed app incident.
- Quarantined `@flaky` tests run in the baseline; their outcomes feed the quarantine review.

Record the per-test, per-run matrix in the run directory.

## Stage 2: classify and cluster

Per test: `green` (all pass), `known-defect` (tagged `@known-defect`, red every run; terminal, never clustered), `known-defect-passed` (tagged but passed once; an anomaly that enters the fan-out with a stability-probe brief), `deterministic-fail` (all fail, one signature), `flaky-consistent`, `flaky-chaotic`.

Cluster non-green tests by shared signal: same missing repository entry, same page failing to load, same error class, same predecessor in suite order. Prioritise by unblock count. When no cluster dominates, the unit of work is the red spec file.

Adaptive verification: a crisp pattern goes straight to a targeted batch that would disprove the hypothesis (the cluster alone in isolation; fresh context per test; throttled network; a `repair-<short>` session walking the flow). Ambiguous → two more full runs and re-cluster. Still ambiguous at five runs → `NEEDS_CONTEXT` with the raw pattern data; never force a classification.

## Stage 3: dispatch authors

One author per cluster (representative failure, the hypothesis, the member list so one fix applies once) or per red file. Bounded concurrency (default 2: authors share the app server and `page-repository.json`). Each brief carries:

1. The scope (one cluster or one spec file; nothing else is touched).
2. The baseline evidence: pattern, per-run outcomes, first error line, the trace paths already on disk.
3. The pipeline: `reproduce → evidence-analysis → context-probe → experiment → understand → fix → verify → done`, with the understand gate one-way (no fix before expected-vs-actual and the causal chain are written to the report and appended to `app-context.md`).
4. Per-stage announcements `[self-repair:worker] stage=<name> file=<f> detail=<note>` mirrored into the return's `stage-log[]`.
5. The return contract (`schemas/subagent-returns/repair-worker.schema.json`): every briefed test with an outcome `already-green | known-defect | healed | app-bug | quarantined | operator-pending | unresolved`; no silent drops, no `.skip()`.
6. The bug-evidence standard for `app-bug`: failure screenshot, trace, the failing run's video, and a slow-motion reproduction recording (`slowMo` ≥ 1500 ms per action), copied immediately to `<e2e-root>/bug-evidence/<TEST-ID>/<compact-ISO-UTC>-<label>/` because `test-results/` is reused by the next run.

Bug-versus-heal discipline, binding for every author:

1. A screenshot showing wrong UI is an app bug, not a heal; report with evidence and leave the test.
2. Mechanical heals (selector re-learning, timing hardening, state isolation) apply autonomously; semantic heals (assertion re-baselining, flow-step drift) return `operator-pending` with the proposed change and the understanding attached.
3. No silent skip: a flake that resists two heal strategies is tagged `@flaky` with a `flake-quarantine.md` entry.
4. Every heal meets the stability bar ([SKILL.md](../SKILL.md) §8): 3 consecutive greens, 5 in suite order for a previously flaky test; a heal that destabilises is reverted.
5. A whole-test rewrite (the scenario itself is obsolete) returns `operator-pending`; on approval it goes through `test-composer` and its judge, never silently.
6. A `@known-defect` test that passed: 3/3 targeted + 5/5 suite-order green → drop the tag and name the ticket for closing; any red → retag `@flaky` with a ledger entry. Re-scope a shared tag site onto the individual test first.

## Stage 4: verify in suite order

After a round, rerun the previously red files three times in suite order with the suite's timeouts. Heals that broke neighbours are reverted and re-enter Stage 2 for that test. Tests still red without an explained classification re-enter Stage 3, up to the round cap (default 2); past it they are `unresolved`, never dropped.

Every spec a heal edited gets the Stage 4b compliance sweep before the round closes.

## Stage 5: quarantine review

Runs whenever `tests/e2e/docs/flake-quarantine.md` has `Status: quarantined` entries. Candidates are entries that went 3/3 green in the baseline; confirm with 5 suite-order runs; release by flipping the entry to `unquarantined (<date> — 3/3 baseline + 5/5 suite-order green)` and removing `@flaky`. Entries that failed get a dated observation appended. Entries still quarantined after three sessions are listed for a user decision. Only this workflow releases entries.

## Stage 6: report and review

Write `.achilles/self-repair/<run-id>/report.json` (`schemas/self-repair-report.schema.json`) and `report.md`: scope, runtime, outcome totals, per-file per-test outcomes with root cause and fix, bug reports with evidence paths, quarantine review, observations (authors surfacing the same root cause is a signal to record), artifacts index. Every stage transition is also a line in `events.ndjson`.

A fresh reviewer checks the report against the outcomes: every test in scope ends in one of the eight outcomes, `understand` precedes `fix` in every stage log, app-bug evidence bundles are complete, no test was skipped or deleted. Commit heals one spec per commit (`fix(<j-slug>): <cause> — <heal>`), quarantine changes as `docs(quarantine): …`.

## Hand-back

`DONE` when every test is green or explained; `DONE_WITH_CONCERNS` listing `operator-pending` heals (with the proposed change) and stale quarantine entries; `BLOCKED` for infrastructure. Script-mode exit codes: `0` every test green or explained, `2` unresolved tests remain, `1` driver error.

## Per-flow presets

`achilles-self-repair --init-scripts` derives one `test:repair:<flow>` script per suite-scoped `playwright test` script (preserving env prefixes, path filters, `--project`, `--grep`; skipping `--config`, `--ui`, `--headed`, shell chaining), never overwriting existing presets. The onboard scaffold seeds `test:repair`; run the derivation on the first repair in a project and after new suite scripts land.
