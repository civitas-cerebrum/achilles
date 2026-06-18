---
name: perf-onboarding
description: >
  Autonomous, enforced performance pipeline that takes a project from zero
  load tests to a maintained perf suite with SLO-gated thresholds. Use this
  skill when: "perf-onboard this project", "performance onboard",
  "set up the performance pipeline", "autonomous perf suite",
  "load-test the whole app end to end", "build a perf suite from zero".
  This is the ORCHESTRATOR (same altitude as `onboarding`), distinct from
  the `performance-testing` COMPANION skill which it dispatches for
  per-scenario authoring work.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.

> **Skill names: see registry.** All skill invocation strings are canonical in [`skill-registry.md`](../element-interactions/references/skill-registry.md). Never reconstruct them from memory.

# Perf-onboarding — seven-phase performance bootstrap

This is the umbrella methodology for taking a project from zero performance
tests to a maintained k6 suite with gated SLOs. Once you invoke it with a
target origin it runs end-to-end without further prompts, surfacing blockers
for human triage only when the pipeline cannot proceed autonomously.

| Mode | When | How |
|---|---|---|
| **Interactive** | You want fine-grained control or are learning the system | Read this skill and follow the phase playbook below |
| **Automated** | You want a hands-off run | Invoke this skill from an external automated CLI driver that dispatches role-scoped subagents per phase |

Both modes execute the same phases against the same gate criteria. The
automated driver dispatches role-scoped subagents per phase; in interactive
mode you follow this skill body directly.

---

## Relationship to other skills

| Skill | Relationship |
|---|---|
| `onboarding` | Functional peer — the e2e bootstrap orchestrator. `perf-onboarding` recommends (but does not require) that `onboarding` has run first so that `tests/e2e/docs/journey-map.md` and `tests/perf/captures/manifest.json` exist. When those artifacts are present the perf pipeline derives scenario models from them (the `derive` path). When absent it bootstraps minimal endpoint discovery. |
| `performance-testing` | Companion — dispatched by Phase 3 (Scenario-model) and Phase 4 (Baseline) for per-scenario k6 script authoring. The orchestrator sets strategy and gating; the companion does scenario-level craftsmanship. |
| `journey-mapping` | Upstream producer of `tests/e2e/docs/journey-map.md`, which the readiness detector (Phase 2) checks and Phase 3 ingests for priority-ordered scenario coverage. |
| `contract-testing` | Optional — Phase 3 scenario modelling may inspect contract fixtures to derive realistic payload shapes for k6 scenarios. |
| `workflow-reviewer` | Gatekeeper — dispatched as `perf-reviewer-phase<N>:` and `perf-reviewer-pass-<kind>:` at every transition. The orchestrator advances a phase only when the reviewer returns `approve`. |

---

## Phase map

| # | Phase | What it produces | Dispatch prefix |
|---|---|---|---|
| 1 | Scaffold | `tests/perf/lib/` k6 helpers, `tests/perf/perf-onboarding.config.json`, `.gitignore` additions, ledger initialisation | `scaffold-perf-*` |
| 2 | Readiness | `tests/perf/docs/readiness.md` (cascade result, derive-vs-bootstrap decision, targets, SLO source) | `readiness-*` |
| 3 | Scenario-model | `tests/perf/docs/scenario-model.md` (sentinel line 1), `tests/perf/scenarios/*.js` | `scenario-model-*` |
| 4 | Baseline | `tests/perf/baselines/*.json` (1-VU smoke per scenario) | `baseline-*` |
| 5 | Load-run | `tests/perf/results/*.json` per pass (load → stress → spike → soak) | `load-run-<pass>-*` |
| 6 | Threshold-gate | `tests/perf/docs/threshold-verdict.json` (deliberate-breach proof + SLO evaluation) | `threshold-gate-*` |
| 7 | Report | `tests/perf/docs/perf-report.md` (sentinel line 1) | `perf-report-*` |

A phase only advances once its **exit criteria** are satisfied AND the
matching `perf-reviewer-*` subagent returns `approve`. Ambiguity blocks the
phase, not the run.

---

## Kickoff

Invoke the skill with a target origin:

```
perf-onboard https://staging.example.com
```

The orchestrator captures the origin, writes it into
`tests/perf/perf-onboarding.config.json`, and runs all seven phases
without further prompts. When a phase is blocked (missing prerequisite,
threshold breach requiring human judgment, production load needing explicit
opt-in) the pipeline surfaces the blocker as a structured handover and
waits for user input before resuming.

**Precondition check before Phase 1:**

1. `k6` is available (`k6 version` exits 0). If not, document the install
   path for the project's platform and pause for confirmation.
2. The target origin is reachable (HTTP probe, max 3s). If not, surface the
   connectivity blocker before writing any files.
3. Run the perf-readiness probe (see §"Precondition / readiness hybrid"
   below). The probe result determines derive-vs-bootstrap and is written
   into Phase 2's deliverable.

---

## Precondition / readiness (hybrid)

Before scaffolding, run the readiness probe documented in
[`references/perf-readiness-detector.md`](references/perf-readiness-detector.md).
The probe answers two axes:

- **Functional axis** — does a sentinel-bearing `tests/e2e/docs/journey-map.md`
  exist and does `tests/perf/captures/manifest.json` exist?
- **Perf axis** — are scaffold helpers (`tests/perf/lib/`) and baselines
  (`tests/perf/baselines/`) already present?

Outcomes:

| Outcome | Condition | Path |
|---|---|---|
| `derive` | Functional artifacts present (journey-map sentinel + captures manifest) | Rich path: scenario model derives from journey priorities and HAR captures |
| `bootstrap` | Functional artifacts absent | Minimal path: agent discovers endpoints via crawler + OpenAPI/HAR + manual specification; recommend running `onboarding` first for richer scenario coverage |

When the outcome is `bootstrap`, surface a one-line advisory to the user:
`[perf-onboarding] Functional artifacts absent — running bootstrap discovery. For richer scenario models, run the onboarding skill first.`

Then continue automatically. Do not block the pipeline on this advisory.

---

## Status ledger + workflow reviewer (state-machine enforcement)

The pipeline runs on top of a structured status ledger at
`tests/perf/docs/perf-onboarding-status.json` (gitignored). The orchestrator
**MUST** update this ledger after every phase / pass completion. Every
transition (phase N → phase N+1, pass N → pass N+1 inside Phase 5) is gated
by a `perf-reviewer-*` subagent. The reviewer reads the ledger row + the
closing subagent's handover envelope + the canonical methodology section,
returns `verdict: approve | reject | escalate`, and the orchestrator only
advances when the verdict is `approve`.

Every `perf-reviewer-*` dispatching brief MUST cite the reviewer's
return-schema path (`schemas/subagent-returns/perf-reviewer.schema.json`) —
the `subagent-schema-preread-gate.sh` hook denies briefs that omit the
citation.

The contract is harness-enforced:

- `perf-onboarding-ledger-gate.sh` (PreToolUse:Agent, DENY) — denies any
  non-reviewer Agent dispatch at a transition point until the matching
  `perf-reviewer-*` has approved; also denies out-of-order phase / pass
  dispatches (e.g., `scenario-model-*` while `currentPhase=1`).
- `perf-onboarding-ledger-write-gate.sh` (PreToolUse:Write|Edit, DENY) —
  validates every ledger write against
  `schemas/perf-onboarding-status.schema.json` and denies phase-skip
  transitions that lack a `status: skipped` row + an `approvedDeviations[]`
  entry carrying a verbatim `authorizer`.

**Dispatch prefix → phase inference** (enforced by the gate):

| Description prefix | Maps to phase |
|---|---|
| `scaffold-perf-*` | Phase 1 (Scaffold) |
| `readiness-*` | Phase 2 (Readiness) |
| `scenario-model-*` | Phase 3 (Scenario-model) |
| `baseline-*` | Phase 4 (Baseline) |
| `load-run-<pass>-*` | Phase 5 (Load-run) |
| `threshold-gate-*` | Phase 6 (Threshold-gate) |
| `perf-report-*` | Phase 7 (Report) |

**Skip / early-stop authorisation.** A phase can be skipped (or the
pipeline stopped early) **only** when the workflow-reviewer for the prior
phase approves the deviation, with the `authorizer` field on the reviewer
return carrying either a verbatim user quote OR a documented structural
exception. Self-imposed reasons (`session-length`, `budget-cap`,
`auto-mode`, `inferred-pref`) are not authorisation — the harness rejects
ledger writes that lack a proper authorizer.

**3-cycle reject cap.** A `perf-reviewer-*` that rejects three consecutive
times returns `verdict: escalate`, and the orchestrator surfaces all three
returns to the user for manual triage. The ledger row's `status` becomes
`blocked`.

**Canonical references:**
- `schemas/perf-onboarding-status.schema.json` — ledger shape (v1)
- `schemas/subagent-returns/perf-reviewer.schema.json` — reviewer return shape
- `skills/workflow-reviewer/SKILL.md` — reviewer methodology (§"Perf-onboarding pipeline reviewer")

---

## Safety model

The safety model is layered: the orchestrator's config provides adjustable
defaults; the gate at the Bash boundary enforces hard ceilings the agent
cannot edit past.

### `tests/perf/perf-onboarding.config.json`

Created in Phase 1. Shape:

```json
{
  "targets": {
    "default": "<staging-origin>",
    "allowlist": ["<origins>"]
  },
  "caps": {
    "maxVUs": 200,
    "maxConcurrentScenarios": 1,
    "maxDurationPerRun": "10m",
    "maxTotalDuration": "1h"
  },
  "production": {
    "origin": "<prod-origin-or-omit>",
    "allowed": false
  }
}
```

The `caps` values are **adjustable defaults** the agent tunes to meet SLOs
across phases. The orchestrator may raise `maxVUs` up to the gate ceiling
as it learns the target's capacity from baseline and load-run results.

### Hard ceilings (gate-enforced, not configurable)

`perf-load-safety-gate.sh` (PreToolUse:Bash) intercepts every `k6 run`
invocation and enforces:

1. **Hard VU ceiling: 1000** — requests exceeding this are denied regardless
   of config values. Baked into the gate, not read from config.
2. **Hard duration ceiling: 3600 s / 1 h** — same constraint, same source.
3. **Allowlist enforcement** — only origins listed in `targets.allowlist` may
   be load-tested. Origin is extracted from the `-e PERF_BASE_URL=<url>`
   flag or the first `http(s)://` URL in the command.
4. **Production guard** — the configured `production.origin` cannot be
   load-tested unless `production.allowed: true` is set in the config
   (deliberate opt-in, not a runtime prompt).

When the gate is absent (e.g., the config has not been written yet) it
denies the `k6 run` with a scaffold-first hint, so Phase 1 completion is a
prerequisite for any load command.

**Production load** requires two explicit steps by a human operator:
(a) add the prod origin to `targets.allowlist`, and
(b) set `production.allowed: true`. The pipeline does not prompt for these;
it surfaces the gate denial as a structured blocker.

---

## The seven-phase contract

### Phase 1 — Scaffold

**Goal.** Land the shared k6 infrastructure and config so every subsequent
phase has a consistent foundation.

**Method.**

1. Write `tests/perf/lib/` with the shared k6 helper modules:
   - `tests/perf/lib/config.js` — exports `BASE_URL`, `PERF_CAPS`, and
     the stage profiles (ramp-up, steady, tear-down templates).
   - `tests/perf/lib/profiles.js` — named load profiles: `smoke`,
     `load`, `stress`, `spike`, `soak` (VU counts + duration defaults
     within safe caps).
   - `tests/perf/lib/thresholds.js` — shared threshold factory: exports
     `defaultThresholds(sloConfig)` that builds an SLO-aware threshold
     object for k6's `options.thresholds`.
   - `tests/perf/lib/correlation.js` — token-extraction helpers: captures
     dynamic values (CSRF tokens, session IDs, redirect targets) from
     responses and injects them into subsequent requests.
   - `tests/perf/lib/summary.js` — custom summary handler: extends k6's
     `handleSummary` to write `tests/perf/results/<scenario>-<timestamp>.json`.
2. Write `tests/perf/perf-onboarding.config.json` with the target origin
   as `targets.default`, the origin in `targets.allowlist`, and conservative
   defaults for `caps` (`maxVUs: 10` initially; the agent tunes these upward
   as the pipeline learns the target's capacity).
3. Add gitignore entries: `tests/perf/results/`, `tests/perf/captures/`,
   `tests/perf/baselines/` (baselines are re-generated on demand, not
   committed), `*.har` (HAR captures from the readiness probe).
4. Confirm `k6 version` exits 0.
5. Write the ledger at `tests/perf/docs/perf-onboarding-status.json`
   (schema `perf-onboarding-status`, `schemaVersion: 1`) with
   `currentPhase: 1`, `status: "in-progress"`, and all seven phase rows
   in `phases[]` at `status: "pending"` (phase 1 set to `"in-progress"`).

**Deliverables:**
- `tests/perf/lib/config.js`
- `tests/perf/lib/profiles.js`
- `tests/perf/lib/thresholds.js`
- `tests/perf/lib/correlation.js`
- `tests/perf/lib/summary.js`
- `tests/perf/perf-onboarding.config.json`
- `tests/perf/docs/perf-onboarding-status.json` (initialized)

**Exit criteria.**
- `tests/perf/perf-onboarding.config.json` exists with a non-empty
  `targets.allowlist` and a `caps` object.
- `tests/perf/lib/` is non-empty (the write-gate checks this at the
  phase-1 → completed transition).
- `k6 version` exits 0.
- Ledger initialized with all 7 phases present.

**Dispatch prefix:** `scaffold-perf-*`

**Reviewer dispatch:** `perf-reviewer-phase1:` with the ledger path,
the Phase 1 methodology section from this skill, and the deliverables list.
Cite `schemas/subagent-returns/perf-reviewer.schema.json`. Advance to Phase
2 only on `approve`.

**Commit:** `chore(perf): scaffold perf suite — lib helpers + config + ledger`

---

### Phase 2 — Readiness

**Goal.** Run the readiness probe, make the derive-vs-bootstrap decision,
and document it so all downstream phases operate from explicit,
human-auditable assumptions.

**Method.**

1. Execute the perf-readiness probe (see
   [`references/perf-readiness-detector.md`](references/perf-readiness-detector.md)):
   - **Functional axis** — check for sentinel-bearing journey-map at
     `tests/e2e/docs/journey-map.md` (line 1 = `<!-- journey-mapping:generated -->`)
     and for `tests/perf/captures/manifest.json`.
   - **Perf axis** — check whether `tests/perf/lib/` is populated and
     `tests/perf/baselines/` contains any `.json` files.
2. Derive the cascade outcome: `derive` (both functional artifacts present)
   or `bootstrap` (either absent).
3. Write `tests/perf/docs/readiness.md` covering:
   - Cascade result (`derive` | `bootstrap`) and the signals that produced it.
   - Whether a sentinel-bearing `journey-map.md` is present.
   - Whether `tests/perf/captures/manifest.json` is present.
   - The selected load target(s) and origin(s).
   - SLO source (journey-map priority tiers → default SLOs, or user-specified,
     or minimal defaults when bootstrapping).
   - Recommendation if `bootstrap`: "run the `onboarding` skill for richer
     scenario coverage."

**Deliverables:**
- `tests/perf/docs/readiness.md`

**Exit criteria.**
- `tests/perf/docs/readiness.md` exists (write-gate enforces this at the
  phase-2 → completed transition).
- The document states the cascade outcome and documents the SLO source.

**Dispatch prefix:** `readiness-*`

**Reviewer dispatch:** `perf-reviewer-phase2:` with the readiness.md
contents and the ledger. Cite `schemas/subagent-returns/perf-reviewer.schema.json`.

**Commit:** `docs(perf): readiness probe result — <derive|bootstrap>`

---

### Phase 3 — Scenario-model

**Goal.** Build the canonical scenario inventory: a priority-ordered list
of what to load-test, at what profiles, with what SLOs, and which load-run
passes each scenario requires.

**Method.**

1. **Derive path** (when `readiness.md` shows `derive`):
   - Read `tests/e2e/docs/journey-map.md` and extract P0/P1/P2/P3
     journeys (priority order).
   - Read `tests/perf/captures/manifest.json` for HAR captures; map
     each capture to a journey by URL pattern.
   - Dispatch `performance-testing` for per-scenario k6 script authoring
     (one dispatch per priority group, or per scenario for P0). The
     companion skill converts HAR captures into k6 `http.get/post` chains
     with correlation hooks and threshold declarations.
   - Add contract fixture payloads from `tests/perf/captures/` when
     present (optional — enriches request bodies but is not required).

2. **Bootstrap path** (when `readiness.md` shows `bootstrap`):
   - Crawl the target origin (up to 50 URLs) or parse an OpenAPI spec
     if present, or accept a user-provided endpoint list.
   - Cluster endpoints into logical scenarios (auth, browse, transact,
     account, mutate, errors — no project-specific vocabulary in shared
     docs).
   - Dispatch `performance-testing` for script authoring from the
     discovered endpoint clusters.

3. **Scenario record per scenario:**
   - Scenario name (generic web-UI vocabulary)
   - Priority (P0/P1/P2/P3, derived from journey-map or bootstrapped
     from endpoint criticality)
   - SLO targets: `p95_response_ms`, `error_rate_pct`, `rps_min`
   - Load profiles required: which of `load | stress | spike | soak`
     must run for this scenario
   - Script path: `tests/perf/scenarios/<scenario>.js`

4. Write `tests/perf/docs/scenario-model.md` with line 1 exactly:
   `<!-- perf-onboarding:scenario-model -->`
   Then the scenario inventory table + per-scenario SLO + required
   load passes.

5. Write `tests/perf/scenarios/<scenario>.js` for each scenario
   (produced by the `performance-testing` companion dispatcher).

**Deliverables:**
- `tests/perf/docs/scenario-model.md` (line 1 sentinel required)
- `tests/perf/scenarios/<scenario>.js` (≥1 file)

**Exit criteria.**
- `tests/perf/docs/scenario-model.md` exists with `<!-- perf-onboarding:scenario-model -->` on line 1.
- At least one `tests/perf/scenarios/*.js` exists.
- (Write-gate enforces both checks at phase-3 → completed transition.)

**Dispatch prefix:** `scenario-model-*`

**Reviewer dispatch:** `perf-reviewer-phase3:` with the scenario-model.md
contents, the scenario file list, and the ledger. Cite
`schemas/subagent-returns/perf-reviewer.schema.json`.

**Commit:** `feat(perf): scenario model — <N> scenarios (<derive|bootstrap>)`

---

### Phase 4 — Baseline

**Goal.** Run each scenario at 1 VU to confirm the script works and record
a clean single-user baseline for later regression comparison.

**Method.**

1. For each scenario in `tests/perf/docs/scenario-model.md`:
   - Run `k6 run --vus 1 --duration 30s -e PERF_BASE_URL=<target> tests/perf/scenarios/<scenario>.js`.
   - The safety gate allows this (1 VU is within the 1000-VU ceiling;
     30s is within the 3600s ceiling; target must be in the allowlist).
   - Collect the summary JSON via the `tests/perf/lib/summary.js` handler.
   - Write `tests/perf/baselines/<scenario>.json` with the smoke results
     (p50, p95, p99 response times; error rate; RPS).
2. If a scenario fails at 1 VU (non-zero k6 exit), surface the script
   error as a structured blocker. Do not mark the baseline complete for
   that scenario until the script error is resolved. The `performance-testing`
   companion can be re-dispatched for script repair.
3. All scenarios must be smoke-green before Phase 4 can complete.

**Deliverables:**
- `tests/perf/baselines/<scenario>.json` (one per scenario, ≥1 total)

**Exit criteria.**
- Every scenario in the scenario-model has a corresponding baseline JSON
  with a zero error-rate smoke run.
- At least one `tests/perf/baselines/*.json` exists (write-gate enforces
  this at phase-4 → completed transition).

**Dispatch prefix:** `baseline-*`

**Reviewer dispatch:** `perf-reviewer-phase4:` with the baseline file list,
smoke results summary, and the ledger. Cite
`schemas/subagent-returns/perf-reviewer.schema.json`.

**Commit:** `test(perf): baselines — smoke-green for <N> scenarios`

---

### Phase 5 — Load-run

**Goal.** Run each required load-profile pass for each scenario. Each pass
is gated by its own `perf-reviewer-pass-<kind>:` reviewer before the next
pass begins.

**Sub-stage order (enforced by the gate):** `pass-load` → `pass-stress` → `pass-spike` → `pass-soak`

The gate (`perf-onboarding-ledger-gate.sh`) denies a later-pass dispatch
until the prior pass's `reviewerVerdict` is `approved`.

**Per-pass method:**

For each pass (load / stress / spike / soak — only run passes declared as
required in the scenario-model):

1. For each scenario that requires this pass:
   - Look up the pass profile from `tests/perf/lib/profiles.js` (VU count,
     ramp-up shape, steady-state duration, tear-down). The orchestrator
     tunes VU counts within the `caps.maxVUs` ceiling based on baseline
     capacity signals.
   - Run: `k6 run --vus <N> --duration <D> --stage ... -e PERF_BASE_URL=<target> tests/perf/scenarios/<scenario>.js`
   - The safety gate intercepts: VU ≤ 1000, duration ≤ 3600s, target in
     allowlist, production guard.
   - Write `tests/perf/results/<scenario>-<pass>-<timestamp>.json` via
     the summary handler.
2. Correlate dynamic tokens between scenarios when session state must flow
   across load stages (use `tests/perf/lib/correlation.js`).
3. Update the ledger sub-stage row for the pass:
   `currentSubStage: "pass-<kind>"`, substage `status: "in-progress"`.
4. On pass completion, update the substage to `status: "completed"` and
   include the results summary in the handover envelope.

**Deliverables:**
- `tests/perf/results/<scenario>-<pass>-<timestamp>.json` (≥1 total)

**Exit criteria (per pass):**
- All required-for-pass scenarios have a result JSON.
- No hard-ceiling violation occurred (gate would have blocked it).

**Exit criteria (Phase 5):**
- All required passes across all scenarios are complete.
- At least one `tests/perf/results/*.json` exists (write-gate enforces
  this at phase-5 → completed transition).

**Dispatch prefix:** `load-run-<pass>-*` (e.g., `load-run-load-auth-scenario`)

**Reviewer dispatch (per pass):** `perf-reviewer-pass-<kind>:` after each
pass completes, before the next pass starts. Include: substage handover
envelope, results summary, ledger. Cite
`schemas/subagent-returns/perf-reviewer.schema.json`. The gate enforces this
sequencing — a `load-run-stress-*` dispatch is denied until `pass-load`
has `reviewerVerdict: "approved"`.

**Commit (per pass):** `test(perf): load-run <pass> — <N> scenarios complete`

---

### Phase 6 — Threshold-gate

**Goal.** Prove that the SLO thresholds actually enforce — demonstrate that
k6 exits non-zero when a threshold is breached — and then evaluate each
scenario's load-run results against those thresholds.

**Method.**

1. **Deliberate-breach proof** (mandatory, cannot be skipped):
   - Pick one scenario (preferably P0).
   - Temporarily mutate one threshold in `tests/perf/lib/thresholds.js`
     to an impossible value (e.g., `p95 < 1` — 1ms response time).
   - Run `k6 run --vus 1 --duration 10s -e PERF_BASE_URL=<target> tests/perf/scenarios/<scenario>.js`.
   - Confirm k6 exits with a non-zero exit code.
   - Revert the threshold mutation.
   - Record the proof in `tests/perf/docs/threshold-verdict.json` under
     `deliberateBreach[]` with: scenario name, mutated threshold, observed
     k6 exit code, revert confirmed.
   - The write-gate denies `threshold-verdict.json` writes where
     `deliberateBreach` is empty — this proof step cannot be stubbed.

2. **SLO evaluation** — for each scenario:
   - Compare the load-run results in `tests/perf/results/` against the
     SLO targets declared in the scenario-model.
   - Classify as `pass | fail | warning` (warning = within SLO but within
     20% of the limit).
   - Record in `threshold-verdict.json` under `scenarios[]` with:
     scenario name, pass/fail/warning, p95 actual vs. threshold,
     error rate actual vs. threshold.

3. **Regression-vs-baseline** — compare load-run results to baselines:
   - Flag any scenario where p95 under load has regressed more than 3×
     the baseline p95 at 1 VU.
   - Record regressions in `threshold-verdict.json` under `regressions[]`.

4. Write `tests/perf/docs/threshold-verdict.json` with all three sections:
   `deliberateBreach[]` (≥1 entry required), `scenarios[]`, `regressions[]`.

**Deliverables:**
- `tests/perf/docs/threshold-verdict.json` (with non-empty `deliberateBreach[]`)

**Exit criteria.**
- `tests/perf/docs/threshold-verdict.json` exists.
- `deliberateBreach[]` has ≥1 entry with a non-zero k6 exit code recorded.
- (Write-gate enforces both checks at phase-6 → completed transition.)

**Dispatch prefix:** `threshold-gate-*`

**Reviewer dispatch:** `perf-reviewer-phase6:` with the threshold-verdict.json
contents and the ledger. Cite `schemas/subagent-returns/perf-reviewer.schema.json`.

**Commit:** `test(perf): threshold-gate — deliberate-breach proven, <N> scenarios evaluated`

---

### Phase 7 — Report

**Goal.** Author a human-readable performance report so a stakeholder can
understand what the suite covers, what passed, what failed, and what to
watch, without reading every result JSON.

**Method.**

1. Write `tests/perf/docs/perf-report.md` with **line 1 exactly**:
   `<!-- perf-onboarding:report -->`
2. Report sections:
   - **Executive summary** — number of scenarios, passes run, overall
     SLO verdict (`all-pass | partial | fail`), date.
   - **Scenario inventory** — one row per scenario: name, priority,
     profiles run, SLO verdict (pass/fail/warning), p95 actual.
   - **Threshold-gate results** — deliberate-breach proof record +
     per-scenario verdict table from `threshold-verdict.json`.
   - **Regression analysis** — any baselines-vs-load regressions noted
     in `threshold-verdict.json`.
   - **SLO breach findings** — if any scenario failed SLO, list as a
     structured finding (scenario, metric, actual value, threshold,
     recommended action). Feed these into the ledger's `approvedDeviations`
     or surface to the user as open findings.
   - **Recommendations** — load targets to raise/lower VUs, SLO
     thresholds to tighten, scenarios to add on the next pass.
3. (Tranche 5 will add a `tests/perf/docs/perf-summary.json` machine-
   readable emit; Phase 7 in this version only writes the markdown report.)

**Deliverables:**
- `tests/perf/docs/perf-report.md` (line 1 sentinel required)

**Exit criteria.**
- `tests/perf/docs/perf-report.md` exists with `<!-- perf-onboarding:report -->` on line 1.
- (Write-gate enforces this at phase-7 → completed transition.)

**Dispatch prefix:** `perf-report-*`

**Reviewer dispatch:** `perf-reviewer-phase7:` with the report contents and
the ledger. Cite `schemas/subagent-returns/perf-reviewer.schema.json`.

**Commit:** `docs(perf): perf-report — <overall-verdict> across <N> scenarios`

---

## Integration details

- **`performance-testing` companion** — dispatched in Phase 3 (script
  authoring) and Phase 4 (baseline script repair). Pass the scenario name,
  HAR capture path (if `derive`), SLO targets, and target origin. The
  companion returns a path to the authored `.js` file.
- **Journey-map consumption** — Phase 3 reads `tests/e2e/docs/journey-map.md`
  directly (no re-parse of a different format). The journey map's P0/P1/P2/P3
  priority tiers map 1:1 to scenario priority in the scenario-model.
- **HAR captures** — sourced from `tests/perf/captures/manifest.json` (a
  JSON array of `{ "journey": "<name>", "harPath": "tests/perf/captures/<file>.har" }`
  entries). The scenario-model derive pass iterates this manifest.
- **`tests/perf/lib/` helpers** — shared across all scenario scripts. Scripts
  `import { defaultThresholds } from '../lib/thresholds.js'`, etc.
- **Ledger lifecycle** — initialized in Phase 1, updated after every phase
  and sub-stage. The ledger is gitignored; the commit history is the durable
  record. On resume, the pipeline reads the ledger to determine the
  `currentPhase` and `currentSubStage` and picks up from there.

---

## Resuming a partial run

If the pipeline was interrupted, read `tests/perf/docs/perf-onboarding-status.json`
to find the last phase with `status: "completed"` and the `currentPhase`. Resume
from the next phase. Each phase is independently runnable as long as its
predecessor's deliverables exist on disk.

For Phase 5 mid-run resume: read `currentSubStage` from the ledger, and also
check each sub-stage's `reviewerVerdict` in `phases[4].subStages[]` to find the
first non-approved pass; resume from there.

---

## Cross-cutting rules

These rules apply to every phase. Violating them is a phase failure even
when the exit criteria are technically met.

- **No production load without explicit opt-in.** The `perf-load-safety-gate.sh`
  enforces this at the Bash boundary. The orchestrator does not prompt for
  production opt-in mid-run — this is a deliberate config change.
- **One commit per phase deliverable.** Phases commit per-phase (not per-scenario),
  except Phase 5 which commits per-pass, so a partial run can be safely resumed.
- **No project-specific vocabulary in shared docs.** Scenario names use generic
  web-UI clustering vocabulary (browse / transact / account / mutate / errors /
  auth), not domain-specific tokens.
- **Return-shape conformance.** Every `perf-reviewer-*` subagent dispatch must
  return a schema-conformant envelope (see `schemas/subagent-returns/perf-reviewer.schema.json`).
- **Threshold mutation is always reverted.** The deliberate-breach proof in Phase 6
  mutates then reverts. A Phase 6 run that does not revert is a phase failure.
- **Ledger integrity.** The write-gate validates every ledger write; the agent
  must never bypass it by writing a partial or hand-crafted JSON.
