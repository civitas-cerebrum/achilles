---
name: bug-discovery
description: >
  Use when asked to "find bugs", "break the app", "bug hunt", "quality audit", "edge case testing",
  "stress test the app", "exploratory testing", "find issues", or "bug discovery". Triggers on any
  request for systematic adversarial testing of a web application after an existing test suite passes.
  Do NOT use for writing initial tests — that is achilles-protocol Stages 1-4. Do NOT use for
  expanding coverage — one journey's variant set is test-composer; whole-app iteration is
  coverage-expansion. Do NOT use for evidence-first single-task verification — that is companion-mode.
  Do NOT use for load / performance testing — "stress test the app" here means adversarial functional
  probing (malformed input, state corruption, edge cases), not load; throughput /
  latency-under-concurrency / VU-ramp work routes to performance-testing, not this skill.
  Use only when the goal is to actively discover bugs.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Bug Discovery — Adversarial Quality Audit

> **Skill names: see `../achilles-protocol/references/skill-registry.md`.** Copy skill names from the registry verbatim. Never reconstruct a skill name from memory or recase it.

Systematic, automated bug discovery that runs after all existing test stages are complete. The agent probes the live application for bugs across edge cases, user flows, and cross-feature interactions, then cross-references findings against accumulated context and existing tests to produce a prioritized bug report with reproduction tests.

**Core principle — "First time effect":** Probe the live app BEFORE reading any context. Fresh eyes catch things that familiarity blinds you to. Context is used afterward to filter, classify, and derive additional findings.

**Probing perspective — think like a QA engineer.** This skill is not just for hunting "interesting" bugs in unusual corners. It is the QA-coverage layer of the pipeline: every potential use case a QA engineer would design a test for, including negative cases. When you sit down to probe a page or a journey, your starting question is *"what are all the use cases a QA engineer assigned to this feature would write tests for, including the negative complement of every positive expectation?"* Bug-hunting categories (race conditions, cross-feature, cumulative state) extend above that floor — they do not replace it.

**Role under dual-stage (passes 4–5 of `coverage-expansion`).** When invoked as the per-journey adversarial probe subagent inside `coverage-expansion`, this skill is **Stage A** of a per-journey-per-pass dual-stage pipeline. After your probe-and-ledger work returns, a fresh staff-level-QA reviewer (Stage B, see `skills/coverage-expansion/references/reviewer-subagent-contract.md`) reads your ledger appends, your regression tests (pass 5), and the live app, then either greenlights or returns `improvements-needed`. If the reviewer flags adversarial coverage you missed (e.g., a probe category you skipped that actually lands), `coverage-expansion` re-dispatches you with those findings appended — up to 7 A↔B cycles per journey per pass. Nothing about this skill's contract changes for those invocations; the reviewer never appends to the ledger directly, only points you at gaps. Standalone invocations (outside `coverage-expansion`) are unaffected.

**Pre-empting reviewer must-fix items in adversarial passes.** Skim §"Must-fix calibration" in `reviewer-subagent-contract.md` before probing — the adversarial reviewer will: (a) **cross-reference the negative-case matrix** Stage A was given against the ledger entries; any matrix entry without a corresponding ledger finding is a `matrix-missed` must-fix (this is the deterministic floor), (b) attempt 2–3 probes you didn't try and flag any that land as `adversarial-missed` must-fix, (c) require ledger entries to have well-formed `expected:` / `observed:` / `ledger-only:` / `coverage:` / `evidence:` / `fingerprint:` / `classification:` lines per the canonical schema (`../achilles-protocol/references/subagent-return-schema.md` §3 as extended), (d) for pass 5, require every verified boundary to have a regression test that actually locks the boundary (not a surrogate assertion). Cover EVERY matrix entry on cycle 1 (the matrix is mandatory); use the open-ended probe-category vocabulary breadth (`auth-tamper`, `input-tamper`, `state-skip`, `idor`, etc., per `../achilles-protocol/references/subagent-return-schema.md` §3.6) to extend above the matrix floor.

---

## Canonical return + ledger schema

Every finding reported by this skill — whether returned directly to the user or appended to the adversarial-findings ledger by a `coverage-expansion` adversarial subagent — MUST conform to the canonical schema documented in [`../achilles-protocol/references/subagent-return-schema.md`](../achilles-protocol/references/subagent-return-schema.md).

- **Finding-return format** — every finding uses `- **<FINDING-ID>** [<severity>] — <title>` with `scope`, `expected`, `observed`, `coverage` sub-bullets.
- **FINDING-ID** — `<journey-slug>-<pass>-<nn>` when invoked by `coverage-expansion` as a Pass-4 or Pass-5 subagent; `<journey-slug>-<nn>` for standalone invocations. No `AF-*`, `BUG-*`, `P4-*-BUG-NN`, or other legacy schemes.
- **Severity** — one of `critical`, `high`, `medium`, `low`, `info`. No other values. The "No impact (DOM-only)" classification in this skill's Phase 5 rubric maps to `info` when emitted in the canonical return shape.
- **Return states** — `covered-exhaustively` requires evidence (per-expectation mapping); `no-new-tests-by-rationalisation` is **not a valid return** from any adversarial pass.
- **Ledger schema** — when an adversarial subagent appends to `tests/e2e/docs/adversarial-findings.md`, the append MUST validate against the schema in §3 of the reference file (header, `### j-<slug>`, `**Pass <N> — <kind> (YYYY-MM-DD, build <short-sha-or-unknown>)**`, `Scope:`, `#### <FINDING-ID>` blocks with `expected` / `observed` / `ledger-only` / `coverage` / `classification` / `evidence` / `repro` / `fingerprint` / `status` lines per §3's requiredness rules, and a `**Pass <N> summary:**` footer). Validate in-memory before releasing the lock.
- **Probe-category vocabulary** — the naming surface for `fingerprint:` and dedup lives in §3.6 of the reference file (web/API + AI-safety categories). Do not invent a parallel scheme.

Do not re-paste the schema when dispatching sub-flows of this skill — point at the reference file instead.

### Return shape (probe)

Full schema: `schemas/subagent-returns/probe.schema.json`.

Every probe return **MUST** open with a `handover` envelope as its first key. The envelope has exactly four required fields:

| Field | Rule |
|---|---|
| `role` | `probe` (standalone) or `probe-j-<slug>` (when dispatched per-journey by coverage-expansion). |
| `cycle` | Integer ≥ 1. |
| `status` | Status words: [ledger-vocabulary.md](../achilles-protocol/references/ledger-vocabulary.md) §"Subagent returns". |
| `next-action` | One-line directive for the orchestrator. |

`summary` is a **top-level** field — it MUST NOT appear inside `handover`. Forbidden inside the envelope: `phase`, `from`, `to`.

JSON is preferred over YAML. YAML's compact-mapping form silently breaks when a value contains `:`.

**Worked example — `findings-emitted`:**

```json
{
  "handover": {
    "role": "probe",
    "cycle": 1,
    "status": "findings-emitted",
    "next-action": "orchestrator to review adversarial-findings.md and continue to next pass"
  },
  "journey": "j-login-flow",
  "findings-emitted": 2,
  "tests-added": 2,
  "summary": "Discovered CSRF bypass and session-fixation edge cases; two regression tests added."
}
```

---

## Prerequisites

Before starting, verify ALL of these:

- A passing test suite exists (Stages 1-4 complete, optionally Stage 5 / Test Composer)
- `page-repository.json` has selectors for the app's pages
- `@playwright/cli` is reachable (`npx --no-install playwright-cli --version` exits 0). Since the CLI ships as a hard dependency of `@civitas-cerebrum/achilles`, this almost always passes; a non-zero exit means a corrupted install and the fix is `npm install`, not a separate dep add. The browser binary may still need a one-shot fetch — `npx playwright-cli install-browser chromium`.
- `app-context.md` exists (used in cross-reference phases; probing can proceed without it but phases 2 and 4 will be limited)

If the test suite is not passing, stop: *"Bug discovery requires a green test suite as baseline. Please fix failing tests first."*

---

## Phase Structure

```
Phase 1a: Element Probing        ─┐
Phase 1b: Flow Probing            ├─ Live app, no context
                                  ─┘
Phase 2:  Context Cross-Reference ─── filter known issues
Phase 3:  Test Cross-Reference    ─┐
Phase 4:  Context-Derived Analysis ├─ can run in parallel
                                  ─┘
Phase 5:  Classification          ─── merge & prioritize
Phase 6:  Reproduction            ─── write failing tests
Phase 7:  Report & Triage         ─── generate report
```

**Hard gates:**
- 1b requires 1a (needs page map)
- 2 requires 1a + 1b complete
- 3 and 4 require 2 complete (can run in parallel with each other)
- 5 requires 2, 3, and 4 complete
- 6 requires 5 complete
- 7 requires 6 complete

You MUST create a task for each phase and complete them in order.

---

## Invocation scope — standalone vs journey-scoped

This skill runs in two scopes. The probing categories below apply to both, but the journey-scoped invocation has an additional deterministic input.

- **Standalone** — user asked to bug-hunt the whole app. Probe every page using the open-ended categories in Phase 1a / 1b.
- **Journey-scoped** (dispatched by `coverage-expansion` as a Pass-4 or Pass-5 adversarial subagent) — the dispatch brief includes the journey's map block, page-repo slice, AND a **negative-case matrix** derived per the contract in [`../coverage-expansion/references/adversarial-subagent-contract.md`](../coverage-expansion/references/adversarial-subagent-contract.md) §"Negative-case matrix — full QA scope". Every matrix entry MUST be probed; the open-ended categories below extend above that floor. A journey-scoped invocation that probes only the open-ended categories without covering the matrix is a contract violation — re-dispatch with the matrix and probe again.

When standalone, derive an analogous per-page negative-case list on the fly: for every primary positive flow you observe on a page (the "QA happy-path" interpretation), enumerate at least one negative complement (missing required field, malformed input, unauthorised access, replay / idempotency, session boundary) before moving on. The matrix concept does not vanish in standalone mode — it is built ad-hoc from observation rather than supplied in a brief.

### Risk-weighted probe ordering

When a journey carries a **risk tier** — `elevated` (2+ defect-likelihood factors observed at journey-mapping) or `baseline` — probe the elevated journeys first within a given probe pass, and spend the larger share of the probe budget on them. Risk never changes a finding's severity or a journey's P-tier; it only orders *when* and *how hard* you probe.

- Within a probe pass, dispatch elevated-risk journeys before baseline ones (same P-tier).
- An elevated-risk journey is never folded into a grouped dispatch — it always probes per-journey so its risk surface gets undivided attention.
- The probe budget (see the Session charter) tilts toward elevated journeys: close their categories on the higher end of the diminishing-returns window, baseline journeys on the lower end.

**Risk tags reach a probe via its dispatch brief (the journey block), never by reading `journey-map.md` during Phase 1a — the zero-context rule stands.** A standalone run with no journey map treats every page as `baseline` and orders by observed surface complexity instead.

**App-wide bug-discovery is a parent-only orchestrator.** Dispatching this skill as a subagent at app-wide scope (Phase 1a / Phase 1b across multiple journeys, "standalone bug-discovery", "fan out probes") hits the recursive-dispatch wall — subagents cannot fan out their own children. The parent must iterate journeys itself and dispatch one `probe-j-<slug>:` Agent call per journey directly. The journey-scoped invocation (called by `coverage-expansion` as a Pass-4/5 leaf) is leaf-shape and remains valid. **Methodology rule** — app-wide / multi-journey dispatches via orchestrator-role language are forbidden, regardless of whether the literal "skill"/"SKILL.md" word appears; per-journey single-scope dispatches with `probe-j-<slug>:` description prefix are the only valid form.

### Relevance grouping for probe dispatch (Phases 1a/1b; onboarding Phase 6)

Per-journey dispatch is the default for element and flow probing — one `probe-j-<slug>:` Agent call per journey. When the app has many journeys and many of them share a section (auth, cart, marketplace, etc.), the parent MAY group same-section journeys into one `probe-group-<id>:` dispatch, mirroring the relevance-group path that `coverage-expansion` uses for compositional passes. (This skill's probe passes are *bug-discovery* Phase 1a / 1b; when `onboarding` runs bug-discovery as its Phase 6, the onboarding orchestrator applies the same grouping to the journeys it hands down — the "Phase 6" label there is onboarding's, not a phase of this skill.)

**Trigger.** A probe pass (Phase 1a element-probing or Phase 1b flow-probing) has more than 5 journeys to cover. Below that threshold, per-journey dispatch is the rule.

**Composition rules** (same as the compositional group path — see `coverage-expansion/references/depth-mode-pipeline.md` §"Relevance grouping for compositional passes"):
- **Priority-pure.** Never mix priorities in one group. If a probe pass (Phase 1a element-probing or Phase 1b flow-probing) spans multiple priority tiers, build separate groups per tier.
- **Same section / shared `Pages touched`.** Group by relevance — auth-section journeys together, cart-section journeys together, etc. Section sharing is what makes the per-journey context overhead amortise.
- **Cap 7.** Maximum 7 journeys per group. If a relevance cluster has 9 journeys, split into 7+2.
- **No journeys carrying flagged remediation work.** If a journey is being re-probed because a prior pass surfaced a gap that needs targeted attention, dispatch it per-journey, not in a group.
- **No elevated-risk journeys.** A journey whose dispatch brief tags it `elevated` (2+ defect-likelihood factors) never goes inside a group — its risk surface needs undivided probe attention. Group only `baseline` journeys; elevated ones dispatch per-journey (and first, per "Risk-weighted probe ordering").

**Role-prefix.** `probe-group-<id>: j-a, j-b, …`; spelling and binding in `../coverage-expansion/SKILL.md` §"Grouped dispatch". Members are all probe journeys (priority-pure, no mixing with composer groups). Cap-7 is enforced by methodology (count the members after the colon). Grouped dispatches are valid leaf-shape forms for the parent-only-orchestrator rule.

**Returns.** Per-journey concatenated under one Agent return — each journey's findings appended to the report file under its own section heading (`### j-<slug> (probe-j-<slug>-<phase>, YYYY-MM-DD)`), exactly as if it had been dispatched per-journey. The grouped probe writes findings INCREMENTALLY (after each confirmed finding) so partial work survives if the dispatch is interrupted.

**Quality safeguard — same as compositional groups.** If multiple journeys in one grouped probe return shallow/under-covered findings (the attention-rationing failure mode), the parent stops grouping for the rest of that pass and falls back to per-journey dispatch.

**When to keep per-journey dispatch even with > 5 journeys.** Cross-tab and concurrent-state probes (Phase 1b) often need their own dedicated `playwright-cli` session pool; if the journey's flow involves multiple authenticated browser contexts simultaneously, per-journey is safer. Element-probing (Phase 1a) groups more cleanly — most a11y / catalogue checks are per-page, not per-flow.

---

## Session charter (mandatory)

Before any probing, write a **session charter** into your working notes. It bounds the run so probing terminates on diminishing returns instead of wandering, and so Phase 7 can report what was *not* probed and why.

```
Mission:       app-wide | journey: j-<slug> | page-set: <page, page, …>
Probe budget:  default 30 probes, OR 8 elements × all categories per page,
               3 flow variations per flow (a dispatch brief MAY override these numbers)
Stop rules:
  - Close a category on a page after 8 consecutive probes with no new anomaly.
  - Close a page when every category is closed OR the page's budget is hit.
  - Close the session when every in-mission page is closed OR the overall budget is hit.
```

- **Mission** is the scope handed in (or inferred standalone): the whole app, one journey, or a named page set.
- **Probe budget** is the default ceiling. Elevated-risk journeys (see "Risk-weighted probe ordering") spend toward the high end of each diminishing-returns window; baseline journeys toward the low end.
- **Stop rules** are the diminishing-returns discipline — they are what make a budget-bounded run *complete* rather than *abandoned*. A category/page/session closed by a stop rule is recorded, not silently dropped.

Phase 7's Coverage Notes report **charter vs actuals** (budgeted vs consumed) and derive "Areas not probed (and why)" from the budget-closed items. Each probe return carries a one-line `budget consumed: <n>/<budget> probes, <closed>/<total> categories closed` field.

---

## Phases 1a to 7

| Phase | Read |
|---|---|
| 1a Element probing, 1b Flow probing, 2 Context cross-reference, 3 Test cross-reference, 4 Context-derived analysis | [phases-1-4-probing-and-analysis.md](references/phases-1-4-probing-and-analysis.md) |
| 5 Classification and prioritisation (classes, severity, evidence rule, priority derivation) | [phase-5-classification.md](references/phase-5-classification.md) |
| 6 Reproduction tests | [phase-6-reproduction.md](references/phase-6-reproduction.md) |
| 7 Report, triage lifecycle | [phase-7-report-and-triage.md](references/phase-7-report-and-triage.md) |
| Static mode (`mode: static`) | [static-mode.md](references/static-mode.md) |

### Assertion Strategy

Assert the **correct** behaviour so the test fails against the current buggy state and turns green, unmodified, once the bug is fixed. The full strategy, including the visibility pre-check: [phase-6-reproduction.md](references/phase-6-reproduction.md).


## Commit-message conventions

Commit subjects: [depth-mode-pipeline.md](../coverage-expansion/references/depth-mode-pipeline.md) §"Commit-message conventions". Standalone hunts use the `docs(bug-hunt)` row; passes 4 and 5 use their pass rows.

---

## Invocation options

bug-discovery accepts two independent parameters via `args`: a `phase` selector and a `mode` selector.

### `phase`

| Phase | Behaviour |
|---|---|
| `phase: 'full'` (default) | Run Phase 1a (Element Probing), Phase 1b (Flow Probing), and everything downstream as documented above. |
| `phase: '1a-element-probing'` | Run Phase 1a only. Write findings to `onboarding-report.md` (or the default bug report file). Do not run Phase 1b. |
| `phase: '1b-flow-probing'` | Run Phase 1b only. Require that Phase 1a has already been run in a prior session (findings file exists). Use those findings to prioritise flow probes. |

Parameter parsing: recognise the literal substrings `1a-element-probing`, `1b-flow-probing`, or `full` in `args`. Default to `full`.

### `mode`

| Mode | Behaviour |
|---|---|
| `mode: 'live'` (default) | Probe the running application through `@playwright/cli` as documented in Phases 1a–1b. Requires the CLI to be installed. |
| `mode: 'static'` | First-class static-only adversarial probing. No live navigation. See below. |
