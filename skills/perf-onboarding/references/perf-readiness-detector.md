# Perf-Readiness Detector — Canonical State Probe

**Status:** single source of truth for the perf-onboarding readiness probe
(derive / bootstrap outcomes) and the exact signals that produce each.
Cited by `perf-onboarding` (Phase 2) as its readiness-probe contract.
Callers run the probe as documented here and consume the resulting outcome
— they do NOT re-implement the detection table or infer outcomes from memory.

The detector answers exactly one question: **"are the functional and perf
artifacts present such that the perf pipeline can derive a rich scenario
model, or must it bootstrap from minimal discovery?"** It does NOT answer
"has the perf pipeline already run?" — callers that care about in-flight
pipeline state read the ledger at `tests/perf/docs/perf-onboarding-status.json`
directly, on their own contract.

---

## Detection axes

The probe runs two independent axes. Both must pass for the `derive` outcome;
either missing → `bootstrap`.

### Axis A — Functional artifacts

Checks whether the e2e onboarding pipeline has produced the artifacts the
perf pipeline can consume for a rich scenario model.

| Check | Probe | Signal |
|---|---|---|
| **A1** Sentinel-bearing journey map | Read line 1 of `tests/e2e/docs/journey-map.md`. Must equal `<!-- journey-mapping:generated -->` exactly. | Present and sentinel-correct → pass. File missing or line 1 differs → fail. |
| **A2** Captures manifest | Check that `tests/perf/captures/manifest.json` exists and is a non-empty JSON array. | File exists and `length > 0` → pass. Missing or empty → fail. |

Both A1 and A2 must pass for Axis A to pass.

### Axis B — Perf scaffold axis

Checks whether a prior perf-onboarding run has already left scaffold
artifacts (used to detect a resume scenario, not a fresh run).

| Check | Probe | Signal |
|---|---|---|
| **B1** Lib helpers present | Check that `tests/perf/lib/` exists as a directory and contains ≥1 file. | Non-empty dir → pass. Missing or empty → fail. |
| **B2** Baselines present | Check that `tests/perf/baselines/` contains ≥1 `*.json` file. | ≥1 file → pass. Missing or empty → fail. |

Axis B results are informational for the `derive` / `bootstrap` decision:
they do not change the outcome but are recorded in `readiness.md` so the
reviewer knows whether this is a first-run or a partial-resume.

---

## Detection table

Run Axis A first. Axis B is always evaluated and always recorded.

| Outcome | Axis A result | Meaning |
|---|---|---|
| **`derive`** | Both A1 and A2 pass | Rich path — scenario model is derived from journey-map priority tiers + HAR captures. Functional artifacts are present and sentinel-correct. |
| **`bootstrap`** | Either A1 or A2 fails | Minimal path — agent discovers endpoints via crawler, OpenAPI spec, or manual specification. The `onboarding` skill is recommended but the pipeline continues autonomously. |

There is no third outcome. A detector result outside `derive | bootstrap`
is a detector bug, not a new category for callers to handle.

---

## How to probe — Read/Bash, in order

Use the Read tool for file checks, Bash only for directory existence:

1. **A1 — Journey map sentinel** — Read `tests/e2e/docs/journey-map.md`
   and check line 1. Missing file → A1 fail. Line 1 ≠
   `<!-- journey-mapping:generated -->` → A1 fail.

2. **A2 — Captures manifest** — Read
   `tests/perf/captures/manifest.json`. Missing → A2 fail.
   Parse as JSON; `length === 0` → A2 fail.

3. **Axis A result** — `derive` if both A1 and A2 pass; `bootstrap`
   otherwise. Record which checks failed.

4. **B1 — Lib helpers** — Check `tests/perf/lib/` exists and is
   non-empty (Bash: `find tests/perf/lib -maxdepth 2 -type f | head -1`).

5. **B2 — Baselines** — Check `tests/perf/baselines/*.json` count
   (Bash: `find tests/perf/baselines -maxdepth 1 -name '*.json' | wc -l`).

6. **Record all results** — write into `tests/perf/docs/readiness.md`
   under the standard template (see §"readiness.md template" below).

Sentinel strings are case-sensitive — copy them verbatim from
[`skill-registry.md`](../../element-interactions/references/skill-registry.md)
§"Non-skill sentinel strings".

---

## `readiness.md` template

The Phase 2 subagent writes `tests/perf/docs/readiness.md` using this
structure. Every field must be filled; no `TBD` entries are permitted.

```markdown
# Perf-Onboarding Readiness Report

**Cascade outcome:** derive | bootstrap
**Date:** <ISO-8601 date>
**Target origin:** <https://...>

## Axis A — Functional artifacts

| Check | Result | Detail |
|---|---|---|
| A1 — journey-map sentinel | PASS / FAIL | <line-1 value or "file missing"> |
| A2 — captures manifest | PASS / FAIL | <entry count or "file missing"> |

**Axis A:** PASS / FAIL → **<derive|bootstrap>** path selected.

## Axis B — Perf scaffold (informational)

| Check | Result | Detail |
|---|---|---|
| B1 — lib helpers | PRESENT / ABSENT | <file count> |
| B2 — baselines | PRESENT / ABSENT | <file count> |

**Scaffold status:** <first-run | partial-resume | fully-scaffolded>

## Decision

**Path:** <derive | bootstrap>

<derive: "Scenario model will be derived from journey-map priority tiers and HAR captures in tests/perf/captures/manifest.json.">
<bootstrap: "Functional artifacts absent — bootstrapping minimal endpoint discovery. Recommendation: run the onboarding skill for richer scenario models.">

## SLO source

<derive: "SLO targets derived from journey-map priority tiers: P0 → p95 ≤ 500ms, error_rate ≤ 1%; P1 → p95 ≤ 1000ms, error_rate ≤ 2%; P2/P3 → p95 ≤ 2000ms, error_rate ≤ 5%. Overrides accepted from user config.">
<bootstrap: "Minimal SLO defaults applied: p95 ≤ 2000ms, error_rate ≤ 5%. Tighten per endpoint after baseline data is collected.">

## Targets

| Origin | Role | Allowlisted |
|---|---|---|
| <origin> | default | yes |
```

---

## Per-caller response

### `perf-onboarding` (Phase 2 — readiness decision)

| Outcome | Response |
|---|---|
| **`derive`** | Proceed to Phase 3 with the journey-map priority tiers + captures manifest as primary scenario sources. Log `[perf-onboarding] Readiness: derive — scenario model will derive from journey-map + HAR captures.` |
| **`bootstrap`** | Proceed to Phase 3 with crawler / OpenAPI / manual spec as primary sources. Log `[perf-onboarding] Readiness: bootstrap — functional artifacts absent. Recommendation: run the onboarding skill for richer scenario coverage.` Emit the advisory once; do not block the pipeline. |

### Phase 2 reviewer (`perf-reviewer-phase2`)

The reviewer checks that `readiness.md` is present and contains:
- A clearly stated outcome (`derive` or `bootstrap`).
- Explicit A1 and A2 check results (not inferred).
- SLO source documentation.
- At least one target origin listed under "Targets."

---

## Relationship to `cascade-detector.md`

The `cascade-detector.md` (in `skills/element-interactions/references/`)
answers whether the functional e2e suite is onboarded. The
perf-readiness-detector is a complementary probe that answers whether the
perf pipeline has the functional artifacts it can consume. They share the
journey-map sentinel check (A1 mirrors the cascade detector's Level C check)
but serve different callers and different decisions.

| Reference | Scope |
|---|---|
| [`cascade-detector.md`](../../element-interactions/references/cascade-detector.md) | Functional e2e onboarding state (Levels A/B/C/None). Callers: `element-interactions`, `onboarding`, `companion-mode`. |
| [`perf-readiness-detector.md`](perf-readiness-detector.md) (this file) | Perf pipeline readiness (derive / bootstrap). Caller: `perf-onboarding` Phase 2. |
| [`skill-registry.md`](../../element-interactions/references/skill-registry.md) | Canonical skill names, invocation strings, sentinel strings. |
