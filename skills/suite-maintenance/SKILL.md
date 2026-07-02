---
name: suite-maintenance
description: >
  Proactive maintenance loop for an already-onboarded e2e suite: detect where
  the application has drifted from the suite, scope the affected journeys, and
  route each drift class to the right existing skill — journey-mapping to
  refresh the map, coverage-expansion to re-compose changed/new journeys,
  test-repair / failure-diagnosis to heal what broke. Use when the app changed
  and the suite needs to catch up ("the app changed, update the tests", "sync
  the suite with the app", "maintenance pass", "we shipped a feature, add
  coverage", "the suite is drifting"). NOT for zero-to-suite (that is
  onboarding) and NOT for a suite that is merely red with no app change (that
  is test-repair directly).
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Suite Maintenance — keep the suite in sync with the app

> **Skill names: see `../element-interactions/references/skill-registry.md`.** Copy skill names from the registry verbatim. Never reconstruct a skill name from memory or recase it.

This is the missing loop between "build the suite" (`onboarding`) and "the
suite broke" (`test-repair` / `failure-diagnosis`). Onboarding is
zero-to-suite; test-repair is reactive (a run is already red). Neither answers
the day-to-day question an engineer actually has: *"the app moved — what does
the suite need so it still means something?"* This skill owns that question.

It is an **orchestrator**, not a new authoring engine: it detects drift, scopes
it, and dispatches the existing skills. It never re-implements
journey-mapping, composing, or repair — it routes to them with a narrowed
scope so a maintenance pass touches only what changed, not the whole app.

**Context discipline:** this skill holds only the drift index (changed
areas → affected journeys → drift class → target skill) and the pass counter.
All per-journey reasoning happens inside the dispatched skills' subagents.

---

## Preconditions

1. **The project is already onboarded.** A sentinel-bearing
   `tests/e2e/docs/journey-map.md`, `tests/e2e/docs/journey-map-coverage.md`,
   and at least one spec under `tests/e2e/` exist. If they do not, this is not
   maintenance — run the onboarding cascade detector
   (`../element-interactions/references/cascade-detector.md`) and route to
   `onboarding` instead.
2. **A reachable target of a known environment class.** Reuse the
   `targetEnvironment` classification rule from `onboarding` (precondition 4):
   drift re-crawl and any adversarial re-pass are destructive and follow the
   same production-safety gate — `local`/`staging` freely, `production` only
   under explicit per-run authorization.
3. **A drift reference point.** Either a git ref (the commit the suite was last
   known-good against — default: the most recent commit that touched
   `tests/e2e/`), a changelog/PR the user names, or "re-crawl and diff" when no
   ref is available.

---

## Phase 1 — Detect drift

Build the drift set from as many of these signals as are available. Do not stop
at the first; they catch different classes.

1. **Suite-run drift (what's already broken).** Run the suite
   (`npx playwright test`, or a scoped subset for large suites). Every failing
   spec is a candidate — but a red spec is a *symptom*; Phase 2 classifies
   whether the cause is app drift (test needs updating) or an app bug (finding,
   not a fix). Do NOT auto-edit specs here.
2. **Source drift (what changed in the app).** `git diff --stat <ref>..HEAD`
   over the app's source (routes/pages/components, API handlers, DB schema).
   Map changed source paths to the journeys that touch them via
   `journey-map.md`'s `Pages touched` / `Section → Journey Map` table. Changed
   source with no covering journey is a **coverage gap**, not a repair.
3. **Structural drift (what the map no longer describes).** Re-crawl the live
   app (dispatch a scoped `journey-mapping` discovery cycle, or a lightweight
   route walk) and diff the discovered routes/flows against `journey-map.md`.
   New routes → new journeys to map. Vanished routes → journeys to retire.
4. **Selector drift.** Failures whose root cause is a stale
   `page-repository.json` entry route to `selector-development` /
   `failure-diagnosis`, not a spec rewrite.

Write the drift index to `tests/e2e/docs/maintenance-drift.md` — one row per
affected unit with its drift class and target skill (see the table below). This
is the worklist the rest of the pass consumes; it is a maintenance artifact,
not a durable suite doc.

---

## Phase 2 — Classify and route

Every drift-index row gets exactly one class and one target skill:

| Drift class | Signal | Route to | Scope handed over |
|---|---|---|---|
| **Broken-by-app-change** | spec red; live app shows the flow changed (selector moved, step added, copy changed) but still works | `failure-diagnosis` (single) → `test-repair` (many, clustered) | the failing spec(s) + the journey block |
| **Broken-by-app-bug** | spec red; live app is genuinely wrong | `bug-discovery` triage / file via `bug-report`; do NOT "fix" the test to pass a bug | the finding + evidence |
| **Changed journey** | journey still exists but its flow/expectations moved | `coverage-expansion` scoped re-pass on that journey (`mode: standard`) via `test-composer` | the changed journey block only |
| **New journey / feature** | live route or flow with no journey in the map | `journey-mapping` (resume-from-sentinel, scoped to the new area) → `coverage-expansion` for the new journeys | the new section/routes |
| **Retired journey** | journey in the map whose route/flow no longer exists | mark the spec `test.fixme()` + a `retired:` note in the coverage matrix; surface to the user before deleting a spec | the journey ID |
| **Selector drift** | failure root-caused to a stale repo entry | `selector-development` / `failure-diagnosis` selector re-learn | the element + page |

**Do not widen scope.** A maintenance pass on three changed journeys dispatches
three scoped units — it does not re-run the whole coverage pipeline. If the
drift set turns out to be most of the app (a rewrite, a framework migration), say
so and recommend a fresh `onboarding`-style pass rather than silently expanding
a "maintenance" run into a full re-onboard.

**Retiring a spec is a surface-to-user action, not an autonomous one.** Deleting
coverage is destructive to the suite's meaning; propose it with the evidence
(the route is gone) and let the user confirm.

---

## Phase 3 — Reconcile and verify

1. Dispatched skills land their changes (repaired specs, new/updated specs,
   findings). Commit per landed deliverable, same as onboarding.
2. **Update the coverage matrix.** Every journey the pass touched updates its
   row in `tests/e2e/docs/journey-map-coverage.md` (spec path + `covered` /
   `missing` / `retired`). New journeys get rows; retired journeys are marked.
3. **Re-run the affected specs** (and a broader smoke run if the change was
   cross-cutting). The pass is done when the affected set is green (or every
   remaining red is a filed `app-bug`, not an unaddressed drift).
4. **Findings, not fudges.** A maintenance pass never edits a spec to make a
   real app bug pass. If a red spec is a genuine bug, it stays red (or becomes
   `test.fixme()` + `@bug`) and is filed — closing it is the app team's job.

---

## Exit criteria

- `tests/e2e/docs/maintenance-drift.md` exists and every row reached a terminal
  route (repaired / re-composed / mapped / filed / retired-with-user-assent).
- `tests/e2e/docs/journey-map-coverage.md` reflects the current app (no
  `<missing>` row for a journey this pass was scoped to close; new journeys
  present; retired journeys marked).
- The affected specs pass, or every remaining failure is a filed `app-bug`.
- No spec was edited to mask a real defect.

---

## Relationship to the other modes

- **`onboarding`** builds the suite from zero. Maintenance assumes it already
  ran. If preconditions fail, route to onboarding.
- **`coverage-expansion`** grows coverage across the whole map. Maintenance
  invokes it *scoped to changed/new journeys only*.
- **`journey-mapping`** discovers and prioritises. Maintenance invokes its
  resume-from-sentinel path to refresh only the drifted area.
- **`test-repair`** heals a red suite in bulk. Maintenance routes
  broken-by-app-change clusters to it, but only after Phase 2 has separated
  app-change from app-bug — repair assumes the tests are wrong, and maintenance
  is where that assumption is checked.
- **`failure-diagnosis`** is the single-failure triage repair escalates from.
- **`companion-mode`** verifies one flow with evidence; a maintenance pass may
  hand a single ambiguous drift to it for an evidence bundle before deciding
  the class.
