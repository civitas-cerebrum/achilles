---
name: self-repair
description: >
  Autonomous per-file suite repair. Use this skill when the user says "self repair",
  "self-repair the suite", "run self repair", "autonomous repair", "repair per file",
  "run test:repair", or when the `achilles-self-repair` CLI driver (npm run test:repair)
  invokes the pipeline non-interactively. Baselines the suite, classifies failures
  (deterministic vs flaky), fans out one repair worker per red spec file, verifies heals
  with re-runs, and writes an audit-grade session report — repeating until every test is
  green or carries an explanation (app-bug report, quarantine, operator-pending). Do NOT
  use for a single failing test — that stays with `failure-diagnosis`. Do NOT use when
  the user wants in-session cluster-first batch triage — that is `test-repair`. Do NOT
  use to find new bugs adversarially — that is `bug-discovery`.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.

# Self-Repair — autonomous per-file suite repair

One pipeline, two front doors:

| Mode | Trigger | Workers | Logging surface |
|---|---|---|---|
| **Script** | `npm run test:repair` → `achilles-self-repair` (`bin/self-repair.mjs`) | One `claude -p` subprocess per red spec file | Timestamped `[self-repair]` stage lines on stdout + `driver.log` + `events.ndjson` + per-worker `stream-json` transcripts |
| **Interactive** | User asks for self repair in a Claude Code session | One Agent-tool subagent per red spec file (`repair-worker-<file-slug>:` dispatch) | The orchestrator emits the same `[self-repair]` stage lines in chat; workers report per-stage via `stage-log` in their schema-validated returns |

Both modes follow the same baseline structure (discovery run + focused
failure reruns — see Stage 1) and execute the same stages against the same
worker contract
(`schemas/subagent-returns/repair-worker.schema.json`) and write the same
run-dir artifacts under `.achilles/self-repair/<run-id>/`, ending with
`report.md` + `report.json`
(`schemas/self-repair-report.schema.json`, `mode: script | interactive`).

Relationship to the siblings: `test-repair` is cluster-first — it triages a
rotted suite *inside one session* by grouping failures that share a root
cause. Self-repair is fan-out-first — it gives every red file its own worker
with its own context window, which is what lets it run unattended and in
parallel. Both delegate the atomic heal-or-classify work to
`failure-diagnosis` and both obey the same Bug-vs-Heal discipline
(`skills/test-repair/SKILL.md` §"Bug-vs-Heal Discipline" — normative for
this skill too, not restated here).

---

## Pipeline

### Stage 1 — Baseline: discovery run + focused failure reruns

Detect first, analyse before fixing. N baseline runs total (default 3 —
the minimum floor to distinguish deterministic from flaky), but only the
first covers the full scope:

1. **Discovery run** (1 of N) — full scope, the suite's own timeouts,
   JSON reporter:

   ```bash
   PLAYWRIGHT_JSON_OUTPUT_NAME=.achilles/self-repair/<run-id>/baseline-1.json \
     npx playwright test --reporter=json
   ```

   Its red files define the failure-rerun scope. Discovery green → skip
   the reruns and report.

2. **Failure reruns** (2..N of N) — scoped to the red files only, with
   `--trace on` (workers start from real evidence, not a bare error
   line) and the **analysis timeout cap** (default 60s per test,
   `--timeout-cap`, 0 disables):

   ```bash
   PLAYWRIGHT_JSON_OUTPUT_NAME=.achilles/self-repair/<run-id>/baseline-<i>.json \
     npx playwright test <red-files> --reporter=json --trace on --timeout 60000
   ```

**Why these standards are universal.** A deterministically broken test is
the slowest thing in any suite — it burns every assertion timeout in full
on every run (observed: a broken logout test at 73s vs a 13s suite
median). Scoping reruns to red files makes baseline cost scale with
failure count, not suite size; the timeout cap bounds the burn on any
suite regardless of how generous its production timeouts are. The cap
applies ONLY to analysis reruns — discovery and verification always run
with the suite's own timeouts, because a heal is only proven under real
conditions, and a cap on discovery could misclassify legitimately slow
tests app-wide.

**Incident-shape spacing.** A 3/3-red baseline captured in one tight
window can be a time-varying app incident, not a deterministic failure
(observed live: a logout journey read 3/3 red during a bad window and
passed minutes later). When runs are fast or the failure smells
infrastructural, space the failure reruns with `--rerun-delay <s>`; the
classification only hardens to `deterministic-fail` legitimately when
failures span the spacing. Workers must still attempt an out-of-harness
reproduction before healing (failure-diagnosis discipline).

**Focus-mode trade-off (explicit).** A flaky test that happens to pass
the single discovery run escapes the failure reruns and is classified
green this session — focus mode optimises for detecting and analysing
*observed* failures cheaply, not for exhaustive flake hunting. Two
recovery paths exist by construction: the suite-order verification runs
re-expose late flake in red files, and any test that fails a future
discovery run enters that session's reruns. When the goal is a thorough
flake sweep rather than repair of known failures, use
`--baseline-mode full`.

**Escape hatch.** Suites with cross-file state coupling (a red file's
failure depends on state left by earlier green files) also need
`--baseline-mode full`: every run covers the full scope with suite
timeouts — the original 3× behaviour. `fullyParallel` suites with
isolated files (the framework's own scaffold default) are safe in
`focus` mode.

Announce each run: `[self-repair] stage=baseline run <i>/<N> done: <T> tests, <F> failing` (the discovery run and each failure rerun get one line; delays are announced).

### Stage 2 — Classify

Per test, from the per-run outcome matrix (same taxonomy as `test-repair`
Stage 2): **green** (all pass) / **deterministic-fail** (all fail, same
signature) / **flaky-consistent** (mixed, one signature) / **flaky-chaotic**
(mixed, several signatures). Aggregate non-green tests into the **red-file
set**. Log one `[self-repair] stage=classify` line with the totals and one
per red file.

If the red-file set is empty: write the report (everything
`already-green`) and stop.

### Stage 3 — Fan-out (one worker per red file)

Dispatch one worker per red file, bounded concurrency (default 2 — workers
share the app server and `page-repository.json`; higher values increase
shared-file race risk).

**Interactive dispatch contract.** Description MUST use the
`repair-worker-<file-slug>:` prefix, and the brief MUST cite the return
schema path `schemas/subagent-returns/repair-worker.schema.json` — the
`subagent-schema-preread-gate.sh` hook denies briefs for schema-validated
prefixes that omit the citation. The brief carries:

1. The single spec file in scope (the worker must not touch other spec files).
2. The per-test baseline evidence: pattern + per-run outcomes + first error
   line — plus, in focus mode, the failure-rerun traces already on disk
   (`test-results/<test-slug>/trace.zip`), so analysis starts from recorded
   evidence instead of a fresh reproduction run.
3. The pipeline contract: follow the staged worker pipeline in
   [`references/worker-pipeline.md`](references/worker-pipeline.md) —
   `reproduce → evidence-analysis → context-probe → experiment →
   understand → fix → verify → done`, with the **understand gate**
   one-way: no fix attempt before expected-vs-actual behaviour and the
   causal chain are established and written (report + knowledge
   write-back to `app-context.md`). `failure-diagnosis` (loaded via the
   Skill tool) supplies the techniques inside the stages; the pipeline
   supplies the order and the gates. Bug-vs-heal discipline applies
   unchanged: app bugs exit with evidence and an unmodified test;
   semantic changes exit operator-pending; irreducible flake is
   quarantined.
4. The per-stage reporting contract: emit
   `[self-repair:worker] stage=<reproduce|evidence-analysis|context-probe|experiment|understand|fix|verify|done> file=<f> detail=<note>`
   at every stage transition, and mirror those transitions into the
   `stage-log` array of the return.
5. The return contract: every briefed test appears in `tests[]` with an
   outcome of `already-green | healed | app-bug | quarantined |
   operator-pending | unresolved` — no silent drops, no `.skip()`.
6. The bug-evidence contract (below): app-bug outcomes require the full
   evidence bundle — including a slow-motion screen recording of a
   reproduction — copied to `bug-evidence/` before the worker returns.

**Bug-evidence standard (app-bug outcomes).** An app bug leaves the repair
session as a report other people act on — its evidence must be complete,
watchable, and findable long after run dirs rotate:

- **Bundle contents:** failure screenshot, error context / trace, the
  failing run's video, AND a **slow-motion screen recording of a
  reproduction run**. The slow-down happens at the source — the
  browser's `launchOptions.slowMo` paces the actions themselves, so the
  native real-time recording is watchable with no post-processing.
  Standard: **`slowMo` ≥ 1500ms per action**; if individual actions
  still blur together for the flow under test, raise it until they
  don't. Prefer the consumer's existing hook when one exists (e.g. an
  `E2E_SLOWMO=<ms>` env var). 500ms proved too fast to track individual
  actions in review. For action-by-action stepping beyond any video,
  the captured `trace.zip` opened with `npx playwright show-trace` is
  the engineer's artifact; the recording is for humans and bug tickets.
- **Canonical location:** `<e2e-root>/bug-evidence/<TEST-ID>/<compact-ISO-UTC>-<label>/`
  — timestamp as `20260805T133000Z`, since colons are illegal in Windows paths.
  Copy evidence there IMMEDIATELY on capture: Playwright reuses per-test
  `test-results/` directories, so a later rerun silently overwrites
  failure artifacts, and run dirs under `.achilles/` rotate per session.
  `bug-report.evidence` paths in the worker return MUST point at the
  `bug-evidence/` copies, never at `test-results/`. The scaffold
  gitignores `bug-evidence/` alongside `test-results/` (binary media);
  teams that want evidence in VCS remove the ignore deliberately.
  Harness backstop: `hooks/playwright-artifact-archiver.sh` copies every
  run's artifacts to `.achilles/runs/<runId>/`, so evidence you forgot to
  copy stays recoverable for the last few runs. Safety net, not a
  substitute — those run dirs rotate, `bug-evidence/` does not.
- **Intermittent bugs:** reproduce in a loop (bounded attempts — default
  12 — announced per attempt) until the recording is captured. If the
  window stays healthy, record the attempt count + window in the report
  and either schedule a recording monitor or hand the loop command to
  the operator; the app-bug classification stands on the already-captured
  evidence, but say explicitly that the slow-mo recording is pending.

In script mode the CLI driver builds the equivalent brief and the worker
writes the same shape to
`.achilles/self-repair/<run-id>/workers/<slug>.report.json`; the driver
validates it against the schema and flags violations in the session report.

The orchestrator relays each worker's stage lines as they arrive and logs
worker start/finish: `[self-repair] stage=fan-out worker finished file=<f> …`.

### Stage 4 — Verify

After a round's workers finish, re-run the previously-red files ×3 in suite
order (catches heals that break neighbours and heal-introduced flake — same
rationale as `test-repair` Stage 5). Tests still failing **without** an
explained classification (`app-bug` / `quarantined` / `operator-pending`)
re-enter Stage 3 for another round, up to the round cap (default 2). Tests
still red at the cap are reported `unresolved` — never silently dropped.

### Stage 5 — Report

Write `.achilles/self-repair/<run-id>/report.json` (conforming to
`schemas/self-repair-report.schema.json`) and its human rendering
`report.md`: outcome totals, per-file per-test outcomes with root causes and
fixes, bug reports with evidence paths (tests NOT modified), observations,
and an artifacts index. Present the totals in chat and link the report.

Script-mode exit codes: `0` = every test green or explained, `2` =
unresolved tests remain, `1` = driver error.

---

## Logging contract (both modes)

- Every stage transition emits exactly one
  `[self-repair] <ISO-timestamp> stage=<stage> <message>` line — stdout in
  script mode, chat in interactive mode.
- Every event is also appended as NDJSON to
  `.achilles/self-repair/<run-id>/events.ndjson`.
- Workers announce every stage with `[self-repair:worker]` lines (relayed by
  the driver/orchestrator as they arrive) and mirror them in `stage-log`.
- Script mode additionally keeps `driver.log`, per-run Playwright output
  logs, and each worker's full `stream-json` transcript under `workers/`.
- Nothing is summarised away: the report links the artifacts, and the
  artifacts reconstruct the whole session.

---

## Scope boundaries (YAGNI)

- **Single failing test** → `failure-diagnosis` directly. Fan-out is overkill
  for one data point.
- **In-session cluster-first triage** → `test-repair`. Prefer it when
  failures obviously share one root cause (one missing page-repo entry
  breaking 20 files) — self-repair's per-file workers would each rediscover
  the shared cause; cross-file duplication of one fix is the known cost of
  fan-out. Workers surfacing the same root cause is itself a signal the
  session report must call out under observations.
- **Compile/type errors, infra failures** (server down, OOM, DNS) — report
  and stop; nothing to fan out.
- **No test deletion, no `.skip()`, no adversarial probing, no new test
  authoring** — same boundaries as `test-repair`.
- The quarantine ledger (`tests/e2e/docs/flake-quarantine.md`) is the only
  cross-session state, written per `failure-diagnosis` heal (f). Ledger
  review/release remains `test-repair` Stage 5.5's job — self-repair
  workers may add entries, never release them.

---

## Universal applicability (assumptions inventory)

Achilles targets any Playwright-tested UI application. Self-repair's only
assumptions, kept deliberately minimal:

- **A Playwright project in cwd** — `npx playwright test` resolves the
  locally installed runner regardless of package manager (npm, pnpm, yarn);
  the JSON reporter is forced per-run via `PLAYWRIGHT_JSON_OUTPUT_NAME`, so
  the suite's own reporter config never matters.
- **The default config** — flows using `--config=…` (perf configs, custom
  harnesses) are out of scope for repair and excluded by preset derivation.
- **Run artifacts under `.achilles/`** — outside Playwright's `outputDir`
  (which Playwright wipes at run start) and gitignored by the scaffold.
  Each run's `outputDir` + report output is archived to
  `.achilles/runs/<runId>/` by `hooks/playwright-artifact-archiver.sh`
  (newest 5 kept; `ACHILLES_ARTIFACT_RETAIN` / `ACHILLES_ARTIFACT_MAX_MB`
  tune retention), so a later baseline run cannot destroy an earlier
  failure's evidence before a worker is dispatched to diagnose it.
- **File-isolated specs for focus mode** — the scaffold's `fullyParallel`
  default guarantees this; suites with cross-file state coupling use
  `--baseline-mode full` (documented escape hatch, Stage 1).
- **No app-specific knowledge** — selectors come from the project's own
  page repository; timeouts, projects, and viewports come from the
  project's own config; the repair standards (timeout cap, failure-rerun
  scoping, incident spacing) are ratios and structure, not app constants.

Anything beyond this list is a methodology bug — report it against the
package rather than special-casing a project.

---

## Per-flow repair presets (`test:repair:<flow>`)

Consumers scope their suites through `package.json` run scripts
(`test:e2e:regression`, `test:e2e:smoke:desktop`, …). Self-repair mirrors
that surface autonomously: every suite-scoped Playwright run script gets a
matching repair preset, so repairing one flow is
`npm run test:repair:<flow>` — no hand-written scoping.

**Derivation rules** (implemented by `achilles-self-repair --init-scripts`;
the interactive orchestrator applies the same rules with Write/Edit):

1. A script qualifies when it invokes `playwright test` with the default
   config, non-interactively. Scripts using `--config=…`, `--ui`,
   `--headed`, shell chaining (`&&`, `||`), or command substitution are
   skipped — perf configs and interactive runners are not repair targets.
2. The preset preserves the script's scope verbatim: leading `VAR=VALUE`
   env prefixes (including `${VAR:-default}` shell expansions), positional
   path filters, `--project`, `--grep`, `--grep-invert`. Any other flag
   disqualifies the script (skipping beats mistranslating).
3. Naming strips the runner prefix: `test:e2e:regression:desktop` →
   `test:repair:regression:desktop`; a bare runner script (`test:e2e`) →
   `test:repair`.
4. **Idempotent, never destructive:** existing `test:repair*` scripts are
   never overwritten; re-running only adds what's missing and reports
   what it skipped.

**When presets are (re)generated:**

- **Onboarding Phase 1 scaffold** — seeds `test:repair` (the suite may not
  have per-flow scripts yet).
- **First self-repair activation in a project** (either mode) — run the
  derivation before Stage 1 and announce additions with a
  `[self-repair] stage=init-scripts added: <name>` line per preset.
- **On demand** — `npx achilles-self-repair --init-scripts` after new suite
  scripts are added.

---

## Prerequisites

- The project is scaffolded (Playwright config + specs exist). If not,
  report and stop — onboarding is a different entrypoint.
- The app under test is reachable: either the Playwright config's
  `webServer` handles it (with `reuseExistingServer`) or the operator
  started the app and set the base URL. Parallel workers share one app
  instance by design — the driver does not start one server per worker.
- Script mode runs workers with `--dangerously-skip-permissions` by default
  (unattended operation); `--keep-permissions` opts out for allowlisted
  environments.

---

## Integration with other skills

| Skill | Relationship |
|---|---|
| `failure-diagnosis` | Loaded by every worker for the atomic heal-or-classify work. Its contract is unchanged. |
| `test-repair` | Sibling entrypoint (cluster-first, in-session). Its Bug-vs-Heal Discipline is normative here. Prefer it when one shared root cause dominates. |
| `bug-discovery` | Separate concern — self-repair reports bugs it encounters, it does not probe for new ones. |
| `element-interactions` | Workers use the Steps API + page repository when healing selectors. |
| `onboarding` | Phase 1 scaffold wires `"test:repair": "achilles-self-repair"` into the consumer's `package.json`; per-flow presets are derived from suite scripts via `--init-scripts` (see "Per-flow repair presets"). |
| `work-summary-deck` | May consume `report.json` as input data for a stakeholder deck. |

---

## Success criteria

A self-repair session is complete when:

1. Every test in scope is `already-green`, `healed` (verified in suite
   order), `app-bug` (HIGH confidence — expected behaviour, actual
   behaviour, and causal mechanism stated; evidence complete; test
   unmodified), `quarantined` (with ledger entry), `operator-pending`
   (with the proposed change and its stage-5 understanding attached), or
   `unresolved` (probe budget exhausted, exclusion list recorded — never
   silent).
1a. Every non-green test's `stage-log` shows the pipeline order held —
   in particular, an `understand` entry precedes any `fix` entry, and
   behavioural discoveries were written back to `app-context.md`.
2. `report.md` + `report.json` exist under
   `.achilles/self-repair/<run-id>/` and the JSON validates against
   `schemas/self-repair-report.schema.json`.
3. The stage log is complete: every stage transition and every worker
   lifecycle event appears in `events.ndjson`.
4. Zero tests were skipped, deleted, or healed around an app bug.
