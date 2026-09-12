---
name: test-data-conventions
description: >
  Use this skill whenever a test's relationship to data is in question — what
  data a scenario needs, where that data comes from, who creates it, and who
  cleans it up. Triggers on: "test data", "test data strategy", "hardcoded
  data", "dynamic test data", "seed data", "data cleanup", "data generation",
  "fixtures", "test fixtures", "relies on current content", "the content
  changed and the test broke", "seed the database for tests", "test accounts",
  "worker isolation", "test data plan". Auto-invoked by the composition
  standards' Stage 4c data-feasibility dimension
  (skills/achilles-protocol/references/test-composition-standards.md §4,
  dimension 4) and whenever a composing skill (achilles-protocol Stages 1-4,
  test-composer, coverage-expansion, bug-discovery Phase 6,
  ticket-driven-testing §7, companion-mode graduation) touches an
  entity-creating flow — signup, record creation, uploads, orders, anything
  that persists tenant or user data. Do NOT use for secrets handling alone —
  credential extraction to .env is owned by achilles-protocol Rule 15 and
  the secrets-sweep skill; this skill owns the data-lifecycle doctrine around
  it.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Test Data Conventions — the data-lifecycle doctrine for composing

> **Skill names: see `../achilles-protocol/references/skill-registry.md`.** Copy skill names from the registry verbatim. Never reconstruct a skill name from memory or recase it.

Every flaky suite autopsy eventually reaches the same organ: data. Tests that pinned yesterday's content, shared one account across parallel workers, created records nothing deleted, or assumed a backend setting that flipped mid-day. This skill is the single source of truth for how tests in this suite relate to data — discovery first, then a two-strategy ladder, then the rules that keep both strategies honest. It is the standard the Stage 4c composition judge's data-feasibility dimension reviews against (see [`../achilles-protocol/references/test-composition-standards.md`](../achilles-protocol/references/test-composition-standards.md) §4).

Evidence lines below are stated generically — each was observed in production suites.

---

## Step 0 — Discovery first: establish how each data dependency is SERVED

**Before choosing any strategy — before a scenario is even written against a data dependency — establish how that dependency is served.** Composing against un-discovered data is how suites end up pinning a search index they cannot seed or seeding a production CMS they should never write to.

For every data dependency of a scenario, identify:

- **(a) The serving source.** App-owned database, third-party search index, CMS, external API, session/client state. The source determines what "seeding" even means and how fast writes become visible (a DB write is immediate; a search-index write may lag behind an indexing pipeline).
- **(b) Whether a WRITE path exists.** A seeding/signup API, DB access via the `database-testing` surface (`steps.sql*`), UI-only creation, or none at all (read-only third-party content).
- **(c) Whether the environment is shared/production or isolated.** A dedicated test environment tolerates writes and wipes; a shared staging tenant tolerates scoped writes with cleanup; production tolerates nothing side-effecting.

**Record the findings in `tests/e2e/docs/app-context.md`'s `## Test Infrastructure` section** — the existing home for this class of fact. The discovery mechanism is the test-infrastructure probe: [`../journey-mapping/references/test-infrastructure-probe.md`](../journey-mapping/references/test-infrastructure-probe.md) already captures the auth model, reset/seed endpoints, mutation endpoints, and stable seed resources; this skill extends the probe's remit to also record, per data dependency, the serving source (a) and environment class (c). Cite the probe — do not re-run or duplicate its protocol here. When a composing session encounters a dependency the section does not cover, it probes just that dependency and appends the finding.

## The strategy decision ladder

Given the discovery, there are **exactly two legitimate strategies** per data dependency. Which one applies is determined by the discovery, not by convenience:

**(a) SEED YOUR OWN DATA — preferred.** When a write path exists (b) and the environment tolerates writes (c): the test generates its own data programmatically, unique per attempt, and cleans it up in hooks. The test owns its data's full lifecycle; nothing about the environment's current content can break it. Rules 1, 5, 6, 7 below govern this strategy.

**(b) CONTENT-RESILIENT HANDLING.** When the dependency is read-only, third-party, or shared/prod (no write path, or writes intolerable): the test **declares content REQUIREMENTS** ("a product with ≥2 variants", "a category with ≥1 item"), **resolves them at runtime against the same source the app renders from**, and the resolved facts become the oracle. Rules 2, 3, 4 below govern this strategy.

**Hardcoding current content is never a strategy.** A literal copied from today's rendering ("the third item is «Widget Pro»") is not strategy (a) — the test didn't create it — and not strategy (b) — nothing re-resolves it. It is a snapshot of an environment that will drift, and its failure mode is a false alarm that erodes trust in the suite.

This ladder is what the Stage 4c judge's dimension 4 checks each spec against: every data dependency sits on rung (a) or rung (b), or the scenario is blocked per Rule 12.

---

## The twelve rules

### 1. Tests generate their own data — programmatic, unique PER ATTEMPT

Under strategy (a), generation happens **inside the test body**, per attempt: `` `user-${Date.now()}-${crypto.randomUUID().slice(0, 8)}@example.test` ``. **Module-scope generation is banned** — a retry re-runs the test body but NOT the module scope, so the retried attempt reuses the first attempt's identity and collides with the half-created state it left behind. Observed in production suites: retry-only failures that vanish under `--retries=0`, caused entirely by module-scope `const email = ...`.

Env-sourced **durable identities** (accounts that exist by design — an admin, a seeded catalog user) are the fixture carve-out: they live in `tests/fixtures/test-data.ts` loaded from `process.env`, per `../achilles-protocol/SKILL.md` Rule 15. The line is creation: if the test creates it, the test generates it per-attempt; if it exists by design, it comes from env via the fixture.

### 2. Never rely on current content — declare requirements, resolve at runtime

Under strategy (b): state what the scenario *requires*, resolve the requirement at runtime against the same source the app renders from (the app's own listing API, the rendered collection, a search endpoint), and assert against the **resolved** facts — the resolved entity's name, price, and count are the oracle, not a frozen literal.

Two sub-cases:

- **Pinned entities** (the scenario is *about* a specific entity — a named plan, a flagship item): **verify-or-fail.** If the pinned entity is absent, that is a premise failure (Rule 3), never a silent substitution — substituting changes what the test proves without changing its name.
- **Interchangeable entities** (any member of a class will do): **may substitute WITH an annotation** (`testInfo.annotations.push({ type: 'data-substituted', description: ... })`) so a reader of the report can see the test ran against a different representative than last run.

### 3. Three-class dependency-error taxonomy

When a data dependency cannot be satisfied at runtime, classify before reacting:

| Class | Meaning | Response |
|---|---|---|
| **premise** | The content cannot satisfy the declared requirement (no product with ≥2 variants exists today) | The ONLY skippable class. Skip **by name**: `test.skip(true, 'premise: no product with >=2 variants in <source>')` — a named premise, not a bare skip |
| **app-state** | The route exists and responds, but rendered broken (empty grid with an error toast, 500 in the payload) | **Fail.** This is what the suite exists to catch |
| **infra** | Transport-level (DNS, timeout, 502 from the proxy) | **Fail** — after bounded transport retries at the data-access helper (retry the fetch 2-3×, not the test) |

Misclassification is the damage: a premise treated as app-state produces false alarms; an app-state failure treated as premise silently skips a real regression.

### 4. Configuration is a premise too

A backend setting can legitimately flip behaviour mid-day. Observed: registration switching between auto-sign-in and email-confirmation within 30 minutes; tests assuming auto-sign-in reported an unrelated element timeout 60 seconds later — the true cause invisible in the failure. The rule: **detect the alternate state's own marker** (the "check your email" view is a positive signal, not a missing-element timeout), skip by name, and annotate **which setting restores cover** (`premise: registration=email-confirmation; auto-sign-in coverage restored when <setting> reverts`). A configuration-premise skip that names the setting is actionable; a 60s timeout is a mystery.

### 5. Generation + cleanup live in hooks

`before*` hooks create; `after*` hooks remove — **even on failure** (afterEach/afterAll run on failure; put cleanup there, never at the end of the test body), and **idempotently** (cleaning up an entity the failed test never created must not itself throw). Setup failures must read as setup failures — throw with a `setup:`-prefixed message rather than letting the first step's element timeout masquerade as the failure.

The cleanup contract is canonical in `../test-composer/SKILL.md` §"Tenant cleanup hooks are non-negotiable" — `cleanupViaApiBackdoor`, the `CleanupBackdoorUnavailableError` stub, the `cleanup-blocked` annotation, and the `cleanup: done | blocked | not-needed` enum in the composer return. Cite it; do not fork it.

### 6. API-first state setup for derivatives

The doctrine: a test's *prerequisites* reach their target state through the fastest safe non-UI channel; only the test's *subject* runs through the UI. The mechanism is canonical in [`../achilles-protocol/references/test-optimization.md`](../achilles-protocol/references/test-optimization.md) §4 — the two-of-two gate (UI-covered elsewhere + API equivalent discovered) decides when a UI prerequisite is replaced with a helper.

### 7. Auth via session/cookie injection with worker-scoped account pools

Derivative tests inject session state (`setAuthCookie`-style helpers per test-optimization §4) instead of walking the login UI. **Parallel workers never share an account**: pool accounts per worker (`accounts[test.info().workerIndex % accounts.length]` over a pool ≥ worker count, or a per-worker `freshUser`). Observed: a shared account throttled valid credentials mid-suite — worker A's login storm tripped rate limiting that failed workers B-D on correct passwords.

### 8. Smoke-vs-e2e depth

Which tests may inject state at all is the depth doctrine — canonical in [`../achilles-protocol/references/test-composition-standards.md`](../achilles-protocol/references/test-composition-standards.md) §5: the journey's one e2e walk stays UI-end-to-end; derivatives shortcut; auth is injected everywhere except the tests whose subject is login.

### 9. No prod pollution

Side-effecting data operations — real emails, registrations, orders, anything that reaches third parties or humans — are **gated on a test environment**. On environments not declared test-safe (Step 0 discovery, item c), the side-effecting scenario is excluded **with a named annotation** (`test.skip(true, 'excluded: order placement is side-effecting and <env> is not a test environment')`), never run "just once to check". Load tests instantiate this rule via `performance-testing/references/test-data.md` §"Write-load data hygiene".

### 10. Hydration-safe data entry: fill → correct-ALL → verify-ALL

On framework-rendered forms, a client-side mount can reset controlled inputs after the test starts typing. Observed: a controlled-form mount reset deterministically wipes the FIRST field filled; the symptom is a short submit + validation timeout — never a visibly empty field in the screenshot, because the wipe happens before capture. The discipline: fill all fields; then **correct every field before verifying any** (re-assert each field's value and refill the ones the reset wiped); only then verify all and submit. Correcting field-by-field interleaved with verification lets a mid-pass reset wipe an already-verified field behind the test's back.

### 11. Volatile-value assertion discipline

Round-trip, delta, and shape oracles for values the app legitimately changes between runs are canonical in [`../achilles-protocol/references/test-optimization.md`](../achilles-protocol/references/test-optimization.md) §3b (the oracle audit). Under strategy (b), the round-trip oracle's "value the test itself produced" becomes "value the test itself *resolved*" — same form, resolved instead of generated.

### 12. DATA FEASIBILITY IS A COMPOSING GATE

Before a scenario is written, answer: can its data be generated programmatically (or resolved per strategy (b)), isolated per worker, and cleaned up? **If not, the scenario is blocked/flagged per the cleanup-blocked pattern (Rule 5) — never written against "whatever is live."** A test composed against unfeasible data is a flake with a delivery date. This is dimension 4 of the Stage 4c composition judge (`test-composition-standards.md` §4): the judge checks each spec against the strategy decision ladder and this gate, and checks the test data plan below reflects the specs under review.

---

## The test data plan — a per-project living document

Every project using this suite maintains **`tests/e2e/docs/test-data-plan.md`** (alongside `journey-map.md` and `e2e-test-scenarios.md`). It is the durable record of where each data dependency stands and what the ideal test environment would unblock. **Creation owner:** `onboarding`’s Phase-1 scaffold seeds it from the template below; on a project that predates that scaffold, **the first composing session creates it from the template if absent** — so the Stage 4c judge’s dimension 4 always has a file to check, and never fails a fresh project on a file no step creates. **Composing sessions UPDATE this document when they hit a gap** — a missing seeding endpoint, a shared account, a prod-only side effect — in the same session that hit it. The Stage 4c judge's dimension 4 checks the plan exists and reflects the specs under review.

Three sections per data dependency / journey:

- **CURRENT** — the strategy in force: `seeded` (strategy a), `resolved` (strategy b), or `blocked` — with blocked entries carrying their `cleanup-blocked` or excluded-by-name pointer (Rule 5 / Rule 9).
- **GAPS** — what prevents the preferred strategy: missing seeding endpoints, missing cleanup backdoors, shared accounts, prod-only side effects, index-lag on a third-party search source.
- **ROADMAP** — the concrete path to the ideal test environment, each item with **what it unblocks**: dedicated test environment, seeding/cleanup APIs, test-traffic header filtering, per-worker account pools, email sandbox.

### Template

```markdown
<!-- test-data-conventions:plan -->
# Test Data Plan — <app name>

**Updated:** YYYY-MM-DD by <session / skill>

## Dependencies

### <dependency or journey — e.g. j-signup: user accounts>
- **Serving source:** <app DB | search index | CMS | external API | client state>
- **Write path:** <seeding API <endpoint> | DB (database-testing) | UI-only | none>
- **Environment:** <isolated test env | shared staging | production-like>
- **CURRENT:** <seeded | resolved | blocked — pointer: <cleanup-blocked user:<id> | excluded: <named annotation>>>
- **GAPS:** <none | missing cleanup backdoor for <entity> | shared admin account | ...>

## Roadmap to the ideal test environment
| Item | Unblocks |
|---|---|
| <e.g. seeding API for <entity>> | <e.g. strategy (a) for j-<slug>; removes 3 premise-skips> |
| <e.g. per-worker account pool (N >= workers)> | <e.g. parallel auth without throttling> |
```

---

## Layering — when UI, API, and DB clients are all available

**Generation preference: API > DB seed > UI.** The API exercises the app's own validation and stays honest to what a client can create; a DB seed (via the `database-testing` surface) is faster but bypasses validation — use it when the API path doesn't exist; the UI is the last resort for generation (slow, flaky, and already covered by the journey's own e2e walk). **Cleanup mirrors generation** — clean through the same layer that created, or lower. When a DB oracle exists, **DB-verified cleanup** closes the loop: after the cleanup call, a `steps.sql*` read confirms the row is gone, so silent cleanup failures cannot accumulate.

---

## Rationalizations to reject

| Excuse | Reality |
|---|---|
| "The fixture already has a user I can reuse" | Fixture identities are for accounts that exist *by design*. Reusing one for a creation flow couples every worker and every retry to one account's mutable state — the shared-account throttling failure (Rule 7) is this excuse in production. |
| "Cleanup can be a follow-up" | A follow-up nobody owns. Rule 5: cleanup lands in the same spec as generation, or the spec returns `cleanup: blocked` so the gap is on the record. Pollution compounds per variant × per pass × per run. |
| "The content rarely changes" | "Rarely" is a delivery date for a false alarm. Strategy (b) costs one runtime resolution; a pinned literal costs a triage session the week the content team ships. |
| "I'll pin today's top item — it's obviously stable" | Ranking, seasonality, and CMS edits all reorder "obviously stable" lists. Declare the requirement ("first item in <collection>"), resolve it, assert the resolved fact. |
| "Retry will regenerate anyway" | Only if generation is in the test body. Module-scope generation is exactly what retries do NOT re-run (Rule 1) — this excuse ships the retry-collision bug. |
| "No seeding API, so I'll just use whatever data is live" | That is composing against unfeasible data. Rule 12: block/flag the scenario, record the gap in the test data plan, and let the roadmap carry the seeding-API request — don't hide the gap inside a fragile spec. |
