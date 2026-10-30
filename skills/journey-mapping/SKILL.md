---
name: journey-mapping
description: >
  The expert half of journey mapping: how an `inspector` drives one app
  section and returns its flows (the per-section brief, the canonical
  section vocabulary, the gated-areas policy, the concurrency log), and how
  a `doc-writer` turns the cycle returns into the sentinel-bearing
  `tests/e2e/docs/journey-map.md` (prioritisation, risk factors, redundancy
  revision, structural-smell prevention, the document structure, the
  coverage checkpoint). The loop that dispatches sections and cycles is the
  orchestrator's map-journeys workflow. Triggers: "map the app", "discover
  user journeys", "map user flows", "understand the app", and every coverage
  ask without a sentinel-bearing map.
---

# Journey mapping

Understand the app like a user before testing it like an engineer. Discovery comes before inspection; journeys before selectors. Every test composed later traces back to a mapped journey.

This skill does not inspect selectors, does not write tests, and does not read existing tests (fresh eyes avoid the blind spot where tests exist but journeys are not mapped).

## Reference index

| Reference | Holds |
|---|---|
| [`references/phases.md`](references/phases.md) | Phase 1 page discovery (the crawl), Phase 2 flow identification, Phase 3 prioritisation with the risk-factor vocabulary, Phase 3.5 redundancy revision |
| [`references/test-infrastructure-probe.md`](references/test-infrastructure-probe.md) | The Phase-1 sub-protocol that detects fixtures, configs, env files, auth state, and returns the constraint tags |

## Invariants

- Discovery is live, through `playwright-cli`; static analysis and URL guessing are not substitutes.
- Every journey is a self-contained `### j-<journey-slug>:` block; a downstream author receives only its block plus referenced `sj-` blocks.
- `<!-- journey-mapping:generated -->` is line 1 of the map; consumers refuse a map without it.
- Priority is load-bearing: it drives dispatch order and grouping eligibility (only P3 may batch). Misclassifying a journey as P3 is a contract violation.
- Risk factors are a second axis, never a priority modifier: `risk: elevated` (2+ factors from the vocabulary in `references/phases.md` §"Defect-likelihood risk factors") orders dispatch within a tier and excludes the journey from grouped dispatches; it never changes the tier or the expectations.
- Cycle 1 is strict per section; at least one discovery cycle and exactly one edge-probe cycle run before the author step; at most five cycles.

## Section agent (inspector brief)

Inputs: the section id (canonical, below), routes already known, routes suggested, role required (`unauthed-visitor | authed-user | authed-<role>`), the credentials policy from the discovery draft, the prior cycle's block for this section (cycles ≥ 2), the session slug `phase4-c<N>-s-<id>`, the schema `schemas/subagent-returns/section-agent.schema.json`, and for edge-probe cycles the edge brief (permission boundaries, deep links, lifecycle edges such as account deletion and expired sessions, hidden routes, role-locked features, error paths).

Behaviour:

1. Open the session; drive every route in the section breadth-first.
2. Click every CTA, dropdown, tab and accordion; identify the flows the section supports.
3. Note state variations per route (empty / loaded / errored / authed / unauthed).
4. Classify every link out of the section with a section guess from the vocabulary; propose a new id with a `rationale:` when nothing fits.
5. Gated routes: self-credential when the draft or an in-app affordance allows it (note the inference under `credentials-inferred`); otherwise record the route under `gated-deferred-to-coverage-expansion` with the reason. Never bypass.
6. Close the session. Return index-level fields inline (`section`, `cycle`, `kind`, `routes-driven`, `flows-identified`, `state-variations-recorded`, `new-sections-discovered`, `gated-deferred-to-coverage-expansion`, `spill`, `summary`) with `status` ∈ `section-complete | section-deferred | blocked`; full flow descriptions and state tables go to the spill file `tests/e2e/docs/.subagent-returns/phase4-cycle-<N>-section-<id>.md`.

### Concurrency log (race-only)

Parallel section agents own their sessions, throwaway users and route subtrees. When an action you took changed a sibling's observable state, a resource collided (409 on signup, a rate-limited login, a listing bought from under you), or you observe state a sibling must have caused, append one JSON line (≤ 4096 bytes) to `tests/e2e/docs/.phase4-concurrency-log.jsonl`:

```json
{"timestamp":"<ISO-8601>","from":"phase4-cycle-<N>-section-<id>","conflict-type":"resource-collision|destructive-side-effect|auth-rate-limit|state-corruption|unexpected-data","resource":"<short>","value":"<short|null>","details":"<one sentence>","action-taken":"retry-with-namespace|abort-and-flag|wait-and-retry|coordinate-with-peer","recommendation":"<one sentence|null>"}
```

Tail the log before a high-risk action and adjust (namespaced identifiers like `cycle-<N>-<rand>@e2e.local`, sequencing a shared reset). No locks, no claims, no pre-emptive broadcasts. The author reads the log for flow-level hazards; the file is transient and discarded with the cycle state.

## Section vocabulary (canonical ids)

A union across app shapes; most apps match a subset. Prefer the more specific id (`marketplace` over `catalog` for P2P listings; `documentation` over `content` for versioned docs; `analytics` over `reports` for live dashboards). Sub-divisions (`catalog/search` versus `catalog/browse`) are flows inside one section. Hyphenated ids are allowed; whitespace is not.

| Group | Ids and typical routes |
|---|---|
| Authentication and identity | `auth` (/login, /signup, /logout, /forgot-password, /reset, /verify-email, /mfa) · `profile` (/profile, /account, /me) · `admin` (/admin/*) |
| Commerce | `catalog` (/, /products, /categories, /search) · `detail` (/products/:id, /items/:slug) · `cart` (/cart, /checkout) · `order` (/orders, /orders/:id, /receipts) · `billing` (/billing, /invoices, /subscriptions, /plans) · `marketplace` (/marketplace, /listings, /sell) |
| Content and documentation | `content` (/blog, /about, /faq, /terms, /privacy) · `documentation` (/docs/*, /api, /reference, /changelog) |
| SaaS surfaces | `dashboard` (/dashboard, /home, /overview) · `settings` (/settings/*, /preferences) · `integrations` (/integrations, /connections, /webhooks, /api-keys) |
| Communication and support | `notifications` (/notifications, /alerts) · `inbox` (/inbox, /messages, /chat) · `support` (/help, /support, /contact, /tickets) |
| Reporting and analytics | `reports` (/reports, /exports) · `analytics` (/analytics, /insights, /metrics, /audit-log) |
| Errors and fallbacks | `error` (/404, /500, /maintenance) |

## Author step (doc-writer brief)

Inputs: every cycle's spill file, the discovery draft (for `credentials-discovered`), the cycle state file (`convergence-status`, `unvalidated-sections-flagged`), the concurrency log, the schema `schemas/subagent-returns/phase4-prioritise-author.schema.json`. The author drives no browser; its job is synthesis.

1. Apply Phase 3 prioritisation (P0–P3, `references/phases.md` §"Priority Framework") and the risk-factor field.
2. Apply Phase 3.5 redundancy revision; log every sub-journey extraction, variant collapse and decomposition under `## Phase 3.5 Revision Log`.
3. Compose cross-section journeys by following `links-out` across sections; multi-section conversion flows are the norm, not the exception.
4. Prevent structural smells: a journey that differs only by viewport is a `Mobile:` expectation on the parent; an empty-state journey is a `State variations:` entry; fewer than three actions on a non-navigating toggle is a smoke test in `tests/e2e/smoke.spec.ts`, not a journey; a strict step subset plus a state modifier folds into the larger journey. Ask: distinct user goal needing its own priority and depth, or a variation of an existing journey?
5. Internal consistency: every `Sub-journey refs:` matches a `Used by:` and vice versa; no orphan sub-journeys; no undefined `sj-` references. A failed check returns `blocked` so the orchestrator can re-dispatch.
6. Write `tests/e2e/docs/journey-map.md` in place, sentinel preserved, with the structure below, the `## Section → Journey Map` table (every returned section, novel ids annotated `(novel)` with a rationale), `## Gated Areas (Not Mapped)` from every `gated-deferred-to-coverage-expansion` entry, `## Coverage Plan` (per tier: journey count, planned passes, estimated dispatch count and wall-clock, P3 adversarial opt-out candidates with the four criteria pre-evaluated), and the `**Mapping completeness:**` line (`converged at cycle <N>` or `hard-cap-reached at cycle <N>`).
7. Return `journey-map-authored` with `cycles-consumed`, `convergence-status`, the `journey-map` block (path, pages, flows, priority breakdown), `gated-areas-not-mapped`, and a `summary`.

### Document structure

```markdown
<!-- journey-mapping:generated -->
# Journey Map — [App Name]

**Generated by:** journey-mapping skill
**Date:** YYYY-MM-DD
**App:** [URL]
**Pages discovered:** X
**Flows identified:** X
**Priority breakdown:** X P0, X P1, X P2, X P3
**Mapping completeness:** converged at cycle <N> | hard-cap-reached at cycle <N>

## Site Map
[flat URL list]

## Sub-journeys (reusable segments)
### sj-<journey-slug>: <name>
- **Pages:** [list]
- **Steps:** 1. …
- **Used by:** [j-slug, …]

## Journeys
### j-<journey-slug>: <name>
**Priority:** P0 | P1 | P2 | P3
**Risk factors:** [factors from the canonical vocabulary, or none]
**Category:** Conversion | Core experience | Content | Account | Error recovery | Return visitor
**Entry:** /path
**Pages touched:** [URLs or page names from the site map]
**Sub-journey refs:** [sj-slug, …]
**Steps:** 1. [action] → [page] …
**Branches:** [alternative paths]
**State variations:** [empty, loading, errored, with data]
**Exit:** [outcome]
**Test expectations:** [exactly the tier's set per references/phases.md §"Priority Framework"]
**UI-covers:** [canonical flow names this journey exercises through the UI]

## Section → Journey Map
| Section ID (canonical) | Journeys covering it | Notes |

## Gated Areas (Not Mapped)
## Coverage Plan
## Coverage Checkpoint Template
```

Formatting rules: stable kebab-case ids (`j-` ≤ 16 chars where possible, for the session-slug budget); `Pages touched:` as concrete paths matching the site map (the independence graph is built from it); `UI-covers:` as per-project flow names (`<verb>` or `<verb>-<resource>`) that make a flow eligible for API shortcuts in other journeys; blocks in priority order; every cross-reference by full id.

## Coverage checkpoint (reviewer brief, after composition)

Verify the sentinel; map every journey's authored `Test expectations:` to covering tests (coverage of authored expectations, so "complete" means 100% at every tier); build the matrix (`Journey | Priority | Expectations authored | Expectations covered | Coverage | Status`); flag every journey under 100% as a gap, P0 gaps as blocking; append `## Residual Risk` with the five rows (gated areas, adversarial opt-outs, blocked journeys with unresolved must-fix, ambiguous ledger findings, structural-only tests), each present with `0` and `—` when empty.

## Consumers

`test-composer` reads one journey block: what to implement (expectations lacking a test), the depth the tier demands, and when to stop (every authored expectation covered). `bug-discovery` reads the block for flow probing and risk ordering. `qa-reporting` reads the map for the catalogue axes and the coverage figures.
