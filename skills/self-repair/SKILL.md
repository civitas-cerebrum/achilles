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

Both modes execute the same stages against the same worker contract
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

### Stage 1 — Baseline

Run the suite N× (default 3 — the minimum floor to distinguish
deterministic from flaky) with a JSON reporter per run:

```bash
PLAYWRIGHT_JSON_OUTPUT_NAME=.achilles/self-repair/<run-id>/baseline-<i>.json \
  npx playwright test --reporter=json
```

Announce each run: `[self-repair] stage=baseline run <i>/<N> done: <T> tests, <F> failing`.

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
2. The per-test baseline evidence: pattern + per-run outcomes + first error line.
3. The methodology instruction: load `failure-diagnosis` via the Skill tool
   for each failing test; heal test-side causes (selector drift, waits,
   state isolation); prove every heal with 5 consecutive passing runs of the
   file; classify wrong-UI evidence as **app-bug with evidence, test
   unmodified**; quarantine irreducible flake; return semantic changes
   (assertion re-baselining, flow drift) as **operator-pending**, unapplied.
4. The per-stage reporting contract: emit
   `[self-repair:worker] stage=<diagnosing|fixing|verifying|classifying|done> file=<f> detail=<note>`
   at every stage transition, and mirror those transitions into the
   `stage-log` array of the return.
5. The return contract: every briefed test appears in `tests[]` with an
   outcome of `already-green | healed | app-bug | quarantined |
   operator-pending | unresolved` — no silent drops, no `.skip()`.

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
| `onboarding` | Phase 1 scaffold wires `"test:repair": "achilles-self-repair"` into the consumer's `package.json`. |
| `work-summary-deck` | May consume `report.json` as input data for a stakeholder deck. |

---

## Success criteria

A self-repair session is complete when:

1. Every test in scope is `already-green`, `healed` (verified in suite
   order), `app-bug` (with evidence, test unmodified), `quarantined` (with
   ledger entry), `operator-pending` (with the proposed change described),
   or `unresolved` (explicitly counted — never silent).
2. `report.md` + `report.json` exist under
   `.achilles/self-repair/<run-id>/` and the JSON validates against
   `schemas/self-repair-report.schema.json`.
3. The stage log is complete: every stage transition and every worker
   lifecycle event appears in `events.ndjson`.
4. Zero tests were skipped, deleted, or healed around an app bug.
