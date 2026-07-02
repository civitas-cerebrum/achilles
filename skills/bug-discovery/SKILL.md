---
name: bug-discovery
description: >
  Use when asked to "find bugs", "break the app", "bug hunt", "quality audit", "edge case testing",
  "stress test the app", "exploratory testing", "find issues", or "bug discovery". Triggers on any
  request for systematic adversarial testing of a web application after an existing test suite passes.
  Do NOT use for writing initial tests — that is element-interactions Stages 1-4. Do NOT use for
  expanding coverage — one journey's variant set is test-composer; whole-app iteration is
  coverage-expansion. Do NOT use for evidence-first single-task verification — that is companion-mode.
  Do NOT use for load / performance testing — "stress test the app" here means adversarial functional
  probing (malformed input, state corruption, edge cases), not load; throughput /
  latency-under-concurrency / VU-ramp work routes to performance-testing, not this skill.
  Use only when the goal is to actively discover bugs.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Bug Discovery — Adversarial Quality Audit

> **Skill names: see `../element-interactions/references/skill-registry.md`.** Copy skill names from the registry verbatim. Never reconstruct a skill name from memory or recase it.

Systematic, automated bug discovery that runs after all existing test stages are complete. The agent probes the live application for bugs across edge cases, user flows, and cross-feature interactions, then cross-references findings against accumulated context and existing tests to produce a prioritized bug report with reproduction tests.

**Core principle — "First time effect":** Probe the live app BEFORE reading any context. Fresh eyes catch things that familiarity blinds you to. Context is used afterward to filter, classify, and derive additional findings.

**Probing perspective — think like a QA engineer.** This skill is not just for hunting "interesting" bugs in unusual corners. It is the QA-coverage layer of the pipeline: every potential use case a QA engineer would design a test for, including negative cases. When you sit down to probe a page or a journey, your starting question is *"what are all the use cases a QA engineer assigned to this feature would write tests for, including the negative complement of every positive expectation?"* Bug-hunting categories (race conditions, cross-feature, cumulative state) extend above that floor — they do not replace it.

**Role under dual-stage (passes 4–5 of `coverage-expansion`).** When invoked as the per-journey adversarial probe subagent inside `coverage-expansion`, this skill is **Stage A** of a per-journey-per-pass dual-stage pipeline. After your probe-and-ledger work returns, a fresh staff-level-QA reviewer (Stage B, see `skills/coverage-expansion/references/reviewer-subagent-contract.md`) reads your ledger appends, your regression tests (pass 5), and the live app, then either greenlights or returns `improvements-needed`. If the reviewer flags adversarial coverage you missed (e.g., a probe category you skipped that actually lands), `coverage-expansion` re-dispatches you with those findings appended — up to 7 A↔B cycles per journey per pass. Nothing about this skill's contract changes for those invocations; the reviewer never appends to the ledger directly, only points you at gaps. Standalone invocations (outside `coverage-expansion`) are unaffected.

**Pre-empting reviewer must-fix items in adversarial passes.** Skim §"Must-fix calibration" in `reviewer-subagent-contract.md` before probing — the adversarial reviewer will: (a) **cross-reference the negative-case matrix** Stage A was given against the ledger entries; any matrix entry without a corresponding ledger finding is a `matrix-missed` must-fix (this is the deterministic floor), (b) attempt 2–3 probes you didn't try and flag any that land as `adversarial-missed` must-fix, (c) require ledger entries to have well-formed `expected:` / `observed:` / `ledger-only:` / `coverage:` / `evidence:` / `fingerprint:` / `classification:` lines per the canonical schema (`../element-interactions/references/subagent-return-schema.md` §3 as extended), (d) for pass 5, require every verified boundary to have a regression test that actually locks the boundary (not a surrogate assertion). Cover EVERY matrix entry on cycle 1 (the matrix is non-negotiable); use the open-ended probe-category vocabulary breadth (`auth-tamper`, `input-tamper`, `state-skip`, `idor`, etc., per `../element-interactions/references/subagent-return-schema.md` §3.6) to extend above the matrix floor.

---

## Canonical return + ledger schema

Every finding reported by this skill — whether returned directly to the user or appended to the adversarial-findings ledger by a `coverage-expansion` adversarial subagent — MUST conform to the canonical schema documented in [`../element-interactions/references/subagent-return-schema.md`](../element-interactions/references/subagent-return-schema.md).

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
| `status` | One of `clean`, `findings-emitted`, `blocked`. |
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
- `@playwright/cli` is reachable (`npx --no-install playwright-cli --version` exits 0). Since the CLI ships as a hard dependency of `@civitas-cerebrum/element-interactions`, this almost always passes; a non-zero exit means a corrupted install and the fix is `npm install`, not a separate dep add. The browser binary may still need a one-shot fetch — `npx playwright-cli install-browser chromium`.
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
- An elevated-risk journey is never folded into a `[group]` or `[P3-batch]` dispatch — it always probes per-journey so its risk surface gets undivided attention.
- The probe budget (see the Session charter) tilts toward elevated journeys: close their categories on the higher end of the diminishing-returns window, baseline journeys on the lower end.

**Risk tags reach a probe via its dispatch brief (the journey block), never by reading `journey-map.md` during Phase 1a — the zero-context rule stands.** A standalone run with no journey map treats every page as `baseline` and orders by observed surface complexity instead.

**App-wide bug-discovery is a parent-only orchestrator.** Dispatching this skill as a subagent at app-wide scope (Phase 1a / Phase 1b across multiple journeys, "standalone bug-discovery", "fan out probes") hits the recursive-dispatch wall — subagents cannot fan out their own children. The parent must iterate journeys itself and dispatch one `probe-j-<slug>:` Agent call per journey directly. The journey-scoped invocation (called by `coverage-expansion` as a Pass-4/5 leaf) is leaf-shape and remains valid. **Methodology rule** — app-wide / multi-journey dispatches via orchestrator-role language are forbidden, regardless of whether the literal "skill"/"SKILL.md" word appears; per-journey single-scope dispatches with `probe-j-<slug>:` description prefix are the only valid form. (The harness-enforcement hook for this rule was retired in the 0.3.6 cleanup.)

### Relevance grouping for probe dispatch (Phases 1a/1b; onboarding Phase 6)

Per-journey dispatch is the default for element and flow probing — one `probe-j-<slug>:` Agent call per journey. When the app has many journeys and many of them share a section (auth, cart, marketplace, etc.), the parent MAY group same-section journeys into one dispatch under the `[group]` marker, mirroring the relevance-group path that `coverage-expansion` uses for compositional passes. (This skill's probe passes are *bug-discovery* Phase 1a / 1b; when `onboarding` runs bug-discovery as its Phase 6, the onboarding orchestrator applies the same grouping to the journeys it hands down — the "Phase 6" label there is onboarding's, not a phase of this skill.)

**Trigger.** A probe pass (Phase 1a element-probing or Phase 1b flow-probing) has more than 5 journeys to cover. Below that threshold, per-journey dispatch is the rule.

**Composition rules** (same as the compositional `[group]` path — see `coverage-expansion/references/depth-mode-pipeline.md` §"Relevance grouping for compositional passes"):
- **Priority-pure.** Never mix priorities in one group. If a probe pass (Phase 1a element-probing or Phase 1b flow-probing) spans multiple priority tiers, build separate groups per tier.
- **Same section / shared `Pages touched`.** Group by relevance — auth-section journeys together, cart-section journeys together, etc. Section sharing is what makes the per-journey context overhead amortise.
- **Cap 7.** Maximum 7 journeys per group. If a relevance cluster has 9 journeys, split into 7+2.
- **No journeys carrying flagged remediation work.** If a journey is being re-probed because a prior pass surfaced a gap that needs targeted attention, dispatch it per-journey, not in a group.
- **No elevated-risk journeys.** A journey whose dispatch brief tags it `elevated` (2+ defect-likelihood factors) never goes inside a `[group]` — its risk surface needs undivided probe attention. Group only `baseline` journeys; elevated ones dispatch per-journey (and first, per "Risk-weighted probe ordering").

**Role-prefix.** Dispatch description: `[group] probe-j-<a>,probe-j-<b>,...:`. Items must all be `probe-j-` slugs (priority-pure, no mixing with `composer-j-`). Cap-7 rule, enforced by methodology (the comma count in the description tells you whether you're at the cap). The dispatch-guard hook that previously enforced this was retired in the 0.3.6 cleanup; the rule still applies. The parent-only-orchestrator methodology rule treats `[group]` dispatches the same way it treats `[P3-batch]` — both are valid leaf-shape forms.

**Schema validation and `[group]` dispatches.** Grouped dispatches are intentionally **not** schema-validated by `subagent-return-schema-guard.sh` or `subagent-schema-preread-gate.sh`. The wrapper return contains per-item returns which the parent splits and validates individually. The schema-guards only fire on individual `composer-`/`probe-`/`reviewer-`/`phase-validator-` prefixed dispatches.

**Returns.** Per-journey concatenated under one Agent return — each journey's findings appended to the report file under its own section heading (`### j-<slug> (probe-j-<slug>-<phase>, YYYY-MM-DD)`), exactly as if it had been dispatched per-journey. The grouped probe writes findings INCREMENTALLY (after each confirmed finding) so partial work survives if the dispatch is interrupted.

**Quality safeguard — same as compositional `[group]`.** If multiple journeys in one grouped probe return shallow/under-covered findings (the attention-rationing failure mode), the parent stops grouping for the rest of that pass and falls back to per-journey dispatch.

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

## Phase 1a: Element Probing

Visit every page via `playwright-cli` (open a `-s=bd-<journey-slug>` session per [`../element-interactions/references/playwright-cli-protocol.md`](../element-interactions/references/playwright-cli-protocol.md) §3) with **zero context** — do NOT read `app-context.md`, existing tests, or scenario docs. Pure adversarial exploration.

### Probing Categories

Apply to every interactive element found on every page:

| Category | Actions |
|---|---|
| **Boundary inputs** | Empty submit, special chars (`<script>`, `'"; DROP`), max-length strings, zero/negative numbers, unicode, whitespace-only |
| **State transitions** | Browser back after submit, refresh mid-flow, double-click buttons, re-submit completed forms, navigate away and return |
| **Race conditions** | Rapid repeated clicks, interact during loading spinners, submit while animations play, type during autocomplete debounce |
| **Permission/access** | Direct URL access without auth, manipulate URL params, expired session behavior, access other users' resources |
| **Data edge cases** | Empty lists, single item lists, pagination last page, long text overflow, missing/broken images, zero-result search |
| **Cross-feature** | Edit in one tab and check another, apply filters then navigate back, change language mid-flow, resize viewport during interaction |

### Process per Page

1. Navigate via `playwright-cli` (`-s=bd-<journey-slug> goto <URL>`)
2. Take a snapshot (`-s=bd-<journey-slug> snapshot`)
3. Identify all interactive elements
4. **Visibility gate:** For each element, check `getBoundingClientRect()` — if width and height are both 0, or if any ancestor has `display: none`, `visibility: hidden`, or zero height, mark the element as **DOM-only**. Continue probing both visible and DOM-only elements, but tag all findings accordingly.
5. Systematically try each probing category on each element
6. **Screenshot verification:** For every anomaly found, take a screenshot that shows the issue as a user would see it. If the anomaly is not visible in the screenshot (element is hidden, zero-sized, or off-screen), classify it as **DOM-only** — not a user-facing bug.
7. Log every anomaly with: page, action taken, observed result, screenshot, and **visibility classification** (user-visible or DOM-only)

### Evidence paths (convention)

Screenshots and captured artifacts are named and located so a report link, a ledger `evidence:` line, and the on-disk file always agree:

- **Pre-classification anomaly shots** (Phase 1a/1b, before a finding has an ID): `<page-slug>-<probe-category>-<nn>.png`.
- **At Phase 5 classification**, rename each kept shot to its canonical FINDING-ID:
  - Standalone bug-discovery: `docs/e2e/screenshots/<FINDING-ID>.png`
  - Journey-scoped (dispatched by `coverage-expansion`): `tests/e2e/docs/screenshots/<FINDING-ID>.png` (sibling of the ledger)
- Non-screenshot evidence for API/security/privacy findings (saved response body, header dump, console capture, DOM/source excerpt) is saved alongside under the same `<FINDING-ID>` stem.
- Report links and ledger `evidence:` lines carry exactly these repo-relative paths.

### Output

A raw findings list. Each entry: page, action taken, observed result, screenshot, visibility classification (user-visible / DOM-only).

---

## Phase 1b: Flow Probing

Construct and test **adversarial user journeys** — complete flows designed to break assumptions. Uses the page map built during Phase 1a.

### Flow Categories

| Category | Example Flows |
|---|---|
| **Interrupted flows** | Start checkout, close tab, reopen — is cart still there? Start wizard, back at step 3 — does state corrupt? |
| **Out-of-order operations** | Skip wizard steps via URL, delete item being edited elsewhere, submit form for just-deleted record |
| **Concurrent state** | Same form in two tabs — edit both, submit both. Cart in tab A, checkout in tab B — what happens in A? |
| **Data lifecycle** | Create, edit, delete — can you undo? Create, navigate away, return — is draft saved? Bulk delete, check pagination |
| **Role/session transitions** | Log out mid-flow, log back in — where do you land? Switch roles — do stale permissions persist? |
| **Upstream dependency failures** | List references deleted item? Filter value no longer exists? Linked resource returns 404? |
| **Cumulative state** | Repeat action 20 times — memory leak, stacked toasts, DOM growth? Apply/clear filters repeatedly — clean reset? |

### Process

1. Read the app's route structure to identify all multi-step flows
2. For each flow, design 2-3 adversarial variations from the categories above
3. Execute each variation via `playwright-cli`
4. Log anomalies with full flow description, screenshots at each step, and expected vs actual outcome

---

## Phase 2: Context Cross-Reference

Shift from discovery to analysis. NOW read the accumulated context.

### Steps

1. Read `app-context.md` — check "Known issues" for each page.
2. Read the **prior bug-discovery report / ledger** (if one exists) and load its triage state, keyed by canonical FINDING-ID (see §"Triage lifecycle"). Findings already at `deferred` or `wontfix` are filtered exactly like documented known issues — they do NOT re-emit as new. Findings at `fix-in-progress` or `fix-verified` are regression re-check candidates for Phase 3 (their reproduction tests get re-run there).
3. Filter out findings already documented as known quirks or accepted behavior.
4. Flag findings that **contradict** documented behavior — these escalate, they do NOT get filtered out. A finding that a prior run set to `wontfix` but which now reproduces at a **higher severity** than when it was deferred escalates: re-surface it (it is no longer covered by the operator's wontfix instruction at the old severity).
5. Note any discrepancies between documented state and observed state for Phase 4.

### Output

Filtered findings with known issues and operator-deferred/wontfix items removed; prior findings tagged for regression re-check; discrepancies and severity-escalated wontfix items flagged for Phase 4.

---

## Phase 3: Test Cross-Reference

Scan existing test coverage against remaining findings.

### Steps

1. Read all spec files in the test directory
2. Read scenario docs (`tests/e2e/docs/test-scenarios.md`) if they exist
3. Filter out findings already covered by a passing test
4. Flag findings that contradict what an existing test asserts in a different context — these are **regression candidates**

### Output

Classified findings with already-tested items removed, regression candidates flagged.

---

## Phase 4: Context-Derived Analysis

Use `app-context.md` as a **source** of new findings — not just a filter. Cross-reference what context documents against what probing actually observed.

### Discrepancy Patterns

| Pattern | Example |
|---|---|
| **Documented state never appeared** | app-context says page has empty state, probing never triggered it — is empty state broken? |
| **Documented flow doesn't match reality** | app-context says "Links to Settings", but link goes to 404 or different page |
| **Known workaround masks deeper issue** | Tests use `waitForState` for slow load — is slow load itself a performance bug? |
| **Inconsistent behavior across pages** | Similar components behave differently (date formats, validation rules, error messages) |
| **Missing error handling** | app-context documents actions but no error states — probing confirms errors unhandled |

### Output

New findings derived from discrepancies, classified the same as probing findings.

---

## Phase 5: Classification & Prioritization

Merge all findings from Phases 2, 3, and 4 into a single prioritized list.

### Classifications

| Classification | Meaning | Action |
|---|---|---|
| **New bug** | Not documented, not tested, clearly wrong | Phase 6 (reproduce) |
| **Regression candidate** | Contradicts existing test in different context | Phase 6 (reproduce with context note) |
| **Undocumented quirk** | Weird but possibly intentional | Flag in report, ask user |
| **Known but untested** | In app-context but no test guards it | Phase 6 (write guard test) |

### Severity

Severity uses the **single canonical five-value enum** — `critical | high | medium | low | info` — defined once in [`../element-interactions/references/subagent-return-schema.md`](../element-interactions/references/subagent-return-schema.md) §1. This skill does not restate the enum; the table below is **report-facing decision guidance** that maps observed findings onto those canonical values. The report-facing label **"No impact (DOM-only)"** is this skill's presentation name for canonical `info`.

| Canonical severity | Report-facing guidance | Decision criteria | Examples |
|---|---|---|---|
| `critical` (**Critical**) | Security vulnerabilities, privacy violations, leaked sensitive data, broken authentication, credential/key exposure, legal-or-compliance risk, or complete failure of a primary user journey. | Ask: "Could this cause a data breach, privilege escalation, auth bypass, legal liability, or prevent all users from achieving the app's core purpose?" If yes → critical. | XSS/injection, exposed API keys or credentials in client-side code, auth bypass, IDOR/cross-user data access, SSL errors, GDPR/CCPA violations, broken payment flow, complete app crash on load |
| `high` (**High**) | A state the app must prevent, or material user impact — the user cannot complete an intended action without a non-obvious workaround; a core feature is broken. | Ask: "Is a user stuck? Can they not complete what they came to do?" If yes → high. Simple workaround + non-core feature → medium. | Form submission silently fails, primary navigation leads to error/blank page, core feature throws unhandled exception, search returns no results when results exist, login/signup broken |
| `medium` (**Medium**) | Degraded UX or data-correctness issue. The user notices something is wrong but can continue. | Ask: "Does the user notice something is wrong, but can still use the app?" If yes → medium. If the broken content is critical to the app's purpose (e.g. pricing on e-commerce), escalate to high. | Dead outbound links, expired listings, 404 on linked pages, stale references, broken images on content pages, incorrect contact details |
| `low` (**Low**) | Minor inconsistency, cosmetic defect, UX nit. Still accessible, just slightly inconvenient; a typical user would not notice. | Ask: "Would a normal user even notice this? Does it prevent them from doing anything?" If no to both → low. | `href="#"` instead of `tel:`, external links missing `target="_blank"`, minor nav/footer naming inconsistencies, slightly truncated tooltip |
| `info` (**No impact (DOM-only)**) | Found only by inspecting HTML/DOM; invisible to users. Hidden elements, zero-height containers, unused template content, metadata issues. Code hygiene, not bugs. | Ask: "Is there captured evidence appropriate to the finding's oracle?" (See the evidence rule.) If a user-experience finding has no screenshot → info. | Lorem ipsum in `display:none` sections, broken anchors in hidden navs, unused zero-dimension FAQ sections, missing H1 in hidden blocks, generic `<title>` tags |

### Evidence rule (replaces the absolute screenshot cap)

This operationalises the unified evidence rule in `subagent-return-schema.md` §1; it is the authority other skills inherit.

**Every finding above `info` MUST cite captured evidence appropriate to its oracle** — a screenshot for visual/UX findings; a saved response body, header dump, console capture, DOM/source excerpt, or static-inference rationale (`inferred: true`) for API/security/privacy findings. Findings with no captured evidence cap at `info`.

- **User-experience findings** (visual/functional/UX) **MUST be screenshot-verified.** If you cannot see the issue in a screenshot — element hidden, zero-sized, off-screen, `display:none`, collapsed container — it caps at `info` (the "No impact (DOM-only)" label). A hidden broken link is unused HTML, not a broken link.
- **Security-class findings MUST be artifact-verified**, and are **severity-rated on impact regardless of screenshot visibility.** A security/privacy finding (anything meeting the `critical`-row criteria in §1 — auth bypass, IDOR/cross-user access, credential/key exposure, injection, data exfiltration, privilege escalation, compliance risk) is rated on its impact even when nothing visible appears in a screenshot, *provided* it is backed by an artifact: a DOM/source excerpt, a saved response body, a header dump, or a static-inference rationale (`inferred: true`). The artifact is the evidence the screenshot would otherwise be — the carve-out is *which* evidence, not *whether* evidence.

**Verification process — for every finding:**
1. Navigate to the page where the finding occurs.
2. Capture the evidence appropriate to the oracle — a screenshot for a UX finding; a response body / header dump / DOM excerpt / console capture (or a static-inference rationale) for a security/API/privacy finding.
3. **UX finding, visible in the screenshot** → assign severity on user impact via the table above. **Not visible** → `info`.
4. **Security-class finding, artifact captured** → rate on impact per §1's critical-row criteria, even if invisible on screen. **No artifact captured** → caps at `info`.
5. **When in doubt** for a UX finding, scroll to the element and take a full-page screenshot — CSS transforms, overflow, z-index, and scroll-reveal can hide an in-DOM element. Do not rely on DOM inspection alone to judge *user* visibility.

### Priority derivation

**Priority** is distinct from severity: severity = "how bad is the defect", priority = "how soon to fix", and it is a fixed function of `f(severity, journey tier)`. Record a `Priority:` next to `Severity:` in the Phase 7 block and pass it to `bug-report` as the pre-filled suggestion (the user confirms).

| Severity \ Journey tier | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| `critical` | Highest | Highest | High | High |
| `high` | Highest | High | High | Medium |
| `medium` | High | Medium | Medium | Low |
| `low` | Low | Low | Low | Low |
| `info` | Low | Low | Low | Low |

When no journey map is available (standalone runs without tiers), default the journey tier to **P2**.

**Vocabulary mapping** (one surface, three labels):

| Canonical severity (§1) | bug-discovery report label | bug-report Jira label |
|---|---|---|
| `critical` | Critical | Critical |
| `high` | High | High |
| `medium` | Medium | Medium |
| `low` | Low | Low |
| `info` | No impact (DOM-only) | _(not ticketed)_ |

### Also in this phase

Update `app-context.md` with any newly discovered pages, state variations, or quirks found during probing.

---

## Phase 6: Reproduction

Write a failing test for each confirmed bug.

### File Structure

```
tests/
  bug-discovery/
    element-bugs.spec.ts         # from Phase 1a findings
    flow-bugs.spec.ts            # from Phase 1b findings
    context-derived-bugs.spec.ts # from Phase 4 findings
```

### Test Conventions

- Uses Steps API from `./fixtures/base` — same as all other tests
- All selectors in `page-repository.json` — no inline selectors
- Test names describe the bug: `test('@bug-discovery double-click submit creates duplicate record')`
- Tests grouped in `test.describe('Bug Discovery — [category]')` blocks
- Each test has a JSDoc comment:

```ts
/**
 * @finding <journey-slug>-<nn>   // standalone; coverage-expansion uses <journey-slug>-<pass>-<nn>
 * @severity critical
 * @phase 1b
 * @steps
 * 1. Navigate to /checkout
 * 2. Click submit twice rapidly
 * 3. Check order count
 */
test('@bug-discovery double-click submit creates duplicate', async ({ steps }) => {
  // ...
});
```

The `@finding` tag carries the canonical FINDING-ID (`<journey-slug>-<nn>` standalone, `<journey-slug>-<pass>-<nn>` when dispatched by `coverage-expansion`). `@severity` is one of the canonical lowercase values (`critical | high | medium | low | info`). No `BUG-NNN` scheme — it is banned by §4.1 of the canonical schema.

- All tests tagged `@bug-discovery` for filtering: `npx playwright test --grep @bug-discovery`

### Assertion Strategy

Assert the **correct** behavior so the test **fails** against the current buggy state. When the bug is fixed, the test turns green without modification.

**If a test fails for unexpected reasons** (not the intended bug reproduction — e.g., wrong selector, navigation error, test code issue): invoke the `failure-diagnosis` protocol to diagnose and fix. The failure-diagnosis pipeline distinguishes between test issues (fix autonomously) and app bugs (report). Only use this for unintended failures — the expected failure from the bug reproduction is not a test issue.

Example: double-click creates duplicates → test double-clicks and asserts `verifyCount('Page', 'records', { exactly: originalCount + 1 })`.

### Visibility Pre-Check in Reproduction Tests

Every reproduction test for a user-visible bug MUST include a visibility assertion before testing the bug behavior. This confirms the element is actually visible to users and prevents false flags from hidden DOM content.

```ts
// User-visible bug — verify element is visible first, then assert correct behavior
test('@bug-discovery expired job listing links to live posting', async ({ steps }) => {
  await steps.navigateTo('/careers');
  await steps.verifyPresence('viewListingButton', 'CareersPage'); // visibility pre-check
  // ... then assert the bug
});
```

For DOM-only findings, tag tests with `@dom-only` instead of `@bug-discovery`, and include `@visibility: dom-only` in the JSDoc:

```ts
/**
 * @finding <journey-slug>-04
 * @severity info
 * @visibility dom-only
 */
test('@dom-only missing H1 on blog page', async ({ steps, page }) => {
  // DOM inspection — no visibility pre-check needed
});
```

Run user-visible bugs: `npx playwright test --grep @bug-discovery`
Run DOM-only issues: `npx playwright test --grep @dom-only`

---

## Phase 7: Report & Triage

### Output by invocation scope (read this first)

This skill produces **different deliverables depending on how it was invoked** —
getting this wrong strands the caller's completion gate:

| Invocation | Required deliverable | Prose report |
|---|---|---|
| **Standalone** ("find bugs", "bug hunt") | — | `docs/e2e/bug-discovery-report.md` (the template below) |
| **onboarding Phase 6** | `tests/e2e/docs/adversarial-findings.md` (the §3 ledger — the file `onboarding-ledger-write-gate.sh` requires before Phase 6 → completed) | optional |
| **coverage-expansion Pass 4/5 leaf** | append to `tests/e2e/docs/adversarial-findings.md` (§3 ledger) | none |

When invoked by onboarding or coverage-expansion, the **ledger at
`tests/e2e/docs/adversarial-findings.md` is the gated artifact** — write it,
not (or in addition to) the standalone prose report. Every `findings-emitted`
probe must land either a regression spec or an explicit `@bug` + `app-bug`
flag; the orchestrator cannot silently discard findings (onboarding Phase 6
exit criteria). Emitting only `docs/e2e/bug-discovery-report.md` in these
scopes leaves the gate unsatisfied and the phase blocked.

### Report Location (standalone scope)

`docs/e2e/bug-discovery-report.md`

### Report Template

```markdown
# Bug Discovery Report
**Date:** YYYY-MM-DD
**App:** [baseURL from playwright config]
**Total findings:** X
**User-visible bugs:** X | **DOM-only issues:** X | **Undocumented quirks:** X

## Summary by Severity
| Severity | Count | Categories |
|----------|-------|------------|
| **User-Visible** | | |
| Critical | X     | ...        |
| High     | X     | ...        |
| Medium   | X     | ...        |
| Low      | X     | ...        |
| **DOM-Only** | | |
| No impact | X    | ...        |

## User-Visible Bugs (Confirmed)

### <FINDING-ID> [<severity>] — Title
- scope: <one sentence — page / endpoint / element / flow step under probe>
- expected: <one sentence — correct behaviour>
- observed: <one sentence — actual behaviour>
- coverage: <spec file › test name, or none>

**Severity:** critical | high | medium | low | info
**Priority:** Highest | High | Medium | Low   _(from the Priority-derivation matrix; bug-report pre-fill)_
**Triage:** new | acknowledged | fix-in-progress | fix-verified | deferred | wontfix
**Visibility:** User-visible (screenshot) | Security-class (artifact-verified)
**Category:** Boundary input | State transition | Race condition | ...
**Phase discovered:** 1a | 1b | 4
**Page:** PageName — `/route`
**Reproduction test:** `tests/bug-discovery/element-bugs.spec.ts:L42`
**Screenshot:** ![](screenshots/<FINDING-ID>.png)
**Steps:**
1. Navigate to /page
2. Do X
3. Observe Y

---

## DOM-Only Issues (Lowest Priority)
Issues found by inspecting the HTML/DOM that are not visible to users.
These are cleanup items, not user-facing bugs.

## Undocumented Quirks (User Decision Required)
Items that could not be definitively classified as bugs.
Each entry asks: "Is this intentional?"

## Previously Reported (Triage Carry-Forward)
Counts by triage status for findings carried forward from prior runs (keyed by FINDING-ID):
| Status | Count |
|---|---|
| new | X |
| acknowledged | X |
| fix-in-progress | X |
| fix-verified | X |
| deferred | X |
| wontfix | X |
_(Regressions: list any fix-verified entry whose reproduction test failed this run and flipped to `acknowledged (regressed YYYY-MM-DD)`.)_

## Coverage Notes
- Pages probed: X/Y
- Flows tested: X
- Categories covered: [list]
- Charter vs actuals: budgeted <B> probes, consumed <C>; <closed>/<total> categories closed by diminishing-returns stop rule
- Areas not probed (and why): [derived from budget-closed items in the session charter]
```

### Triage lifecycle

Findings carry a triage status across runs. This is a **methodology convention (model-compliance), not harness-enforced** — no hook gates the report or ledger. State is keyed on the canonical FINDING-ID and survives between runs.

| Status | Meaning |
|---|---|
| `new` | First reported this run; not yet acknowledged by an operator. |
| `acknowledged` | An operator has seen it; fix not yet started. |
| `fix-in-progress` | A fix is being worked. |
| `fix-verified` | The reproduction test now passes — the bug is fixed, **evidence-revocable** (see Rules). |
| `deferred` | Operator chose to defer; verbatim instruction recorded. Filtered like a known issue. |
| `wontfix` | Operator chose not to fix; verbatim instruction recorded. Filtered like a known issue. |

**Rules:**

1. **Stable identity.** Triage state is keyed by the canonical FINDING-ID (`<journey-slug>-<pass>-<nn>` / `<journey-slug>-<nn>` per the canonical schema §1). Every entry carries the ID in its heading. **IDs are never renumbered or reused** across runs — a re-found bug keeps its original ID; a genuinely new bug gets a fresh one.
2. **Operator-only deferral.** Only an operator may set `deferred` or `wontfix`, and the verbatim instruction is recorded with the entry. **Severity is frozen during triage** — triage status changes, severity does not.
3. **Evidence-revocable fix-verified.** `fix-verified` is not terminal. A `fix-verified` entry whose reproduction test **fails again** flips to `acknowledged` with a dated `regressed YYYY-MM-DD` note — severity unchanged. (Mere failure-to-reproduce of an *inferred* static finding is `live-unconfirmed`, not a regression — see static-mode epistemics.)

**Re-run reconciliation.** On every run, Phase 3 re-runs the reproduction tests of **every prior finding not at `deferred`/`wontfix`** (`fix-verified` is NOT exempt — that is what makes it revocable). A passing repro on a `new`/`reported`/`acknowledged`/`fix-in-progress` finding advances it to `fix-verified(YYYY-MM-DD)`; a failing repro on a `fix-verified` finding flips it to `acknowledged (regressed YYYY-MM-DD)`. Reconciliation carries every prior entry forward by FINDING-ID; no finding is silently dropped.

The ledger mirrors this via its §3 `status:` line (`new | reported(<issue-url>) | fix-verified(YYYY-MM-DD) | closed-wontfix | recurring`) — the report's six-state `**Triage:**` field is the operator-facing lifecycle; the ledger `status:` line is its machine-facing projection.

### Post-Report

After generating the report, ask:

> "Bug discovery report written to `docs/e2e/bug-discovery-report.md`. Would you also like me to file tickets for the confirmed bugs?"

If the user agrees, **route ticket creation through the `bug-report` skill** — one ticket per confirmed bug, with the FINDING-ID, journey, build/commit, reproduction-test pointer, and the matrix-derived Priority handed over as `bug-report`'s Traceability and pre-fill fields. When a GitHub issue (or Jira ticket) is created, write its URL back into the finding's ledger `status:` line as `status: reported(<url>)` and reflect it in the report's `**Triage:**` carry-forward. Do not hand-roll the ticket body here — `bug-report` owns the ticket shape.

---

## Commit-message conventions

Every adversarial pass this skill produces MUST use the following template when the pass output is committed (whether committed by this skill directly or by the `coverage-expansion` orchestrator):

```
docs(bug-hunt): <journey-or-phase> — N findings
```

- `<journey-or-phase>` identifies the scope: a journey slug (`j-<slug>`) when invoked per-journey from `coverage-expansion`, or a phase label (`phase-1a`, `phase-1b`, `full`) when invoked standalone.
- `N` is the total count of findings written to the report/ledger in this pass.

Examples:
- `docs(bug-hunt): j-book-demo — 7 findings`
- `docs(bug-hunt): phase-1a — 23 findings`
- `docs(bug-hunt): full — 48 findings`

When this skill is invoked from `coverage-expansion` adversarial passes 4 or 5, the orchestrator may use the pass-specific templates from `coverage-expansion/SKILL.md` (`docs(ledger): <j-slug> — N probes, M boundaries, K suspected bugs` for pass 4; `test(<j-slug>-regression): lock <boundary-description>` for pass-5 regression tests). The `docs(bug-hunt): …` template applies to standalone invocations.

Do NOT use `fix(…): …` or `bug(…): …` for bug-hunt output — findings go to the report/ledger, not the code. Use `fix(…): …` only for test-code or app-code changes made to close out a finding.

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

## Static mode — first-class adversarial probing

`mode: static` is a **first-class probing mode**, not a degraded fallback for when live probing fails. In environments where `@playwright/cli` is unavailable — CI runners without a browser, restricted sandboxes, read-only review checkouts — static mode is the default. Static findings stand on their own merit; they are simply a different class of evidence than live findings, and they are labelled as such.

### What the subagent reads

In static mode the subagent does not navigate the app. It reads, in order:

1. Spec files in the test directory — to understand what is currently asserted and what boundaries existing tests already guard.
2. `page-repository.json` — the authoritative selector inventory and element-attribute context (input types, max-length attributes, role hints).
3. `tests/e2e/docs/app-context.md` — documented pages, flows, and known quirks.
4. Sibling-journey ledger sections in `tests/e2e/docs/adversarial-findings.md` (or equivalent) — adversarial findings logged against related journeys often transfer to the journey under analysis.

### How bugs are inferred

Static mode infers likely bugs from pattern matches against the code and repository snapshot. Every inferred finding is recorded with `inferred: true` in its structured body. Examples of inference patterns:

1. **Missing `maxlength` on a free-text input** → likely HTTP 500 on long input (server-side length unguarded). Infer a boundary bug for payloads above the typical DB column cap (255, 4000, etc.).
2. **Missing `type="email"` / no client validation on an email field** → likely XSS or malformed-input vector; downstream rendering probably reflects user-supplied content unescaped.
3. **No `autocomplete="off"` on a password-reset or MFA entry field** → likely credential-leak surface via browser autofill in shared-device contexts.
4. **No CSRF token reference in a form handler that issues a mutating POST** → likely CSRF vulnerability, especially if the session cookie lacks `SameSite=Lax|Strict`.
5. **Numeric input without `min` / `max` / `step` attributes** → likely negative-number or floating-point edge-case bug (e.g., quantity=-1 bypassing validation, price=0.0001 rounding to 0).

These five are illustrative — the subagent applies the same inference pattern to any similar structural gap it observes. Each finding body states the evidence (which file, which element, which missing attribute), the inferred failure mode, and carries the `inferred: true` flag.

### What static mode must never claim

- **No verified-bug claims.** Static mode never asserts that a bug was reproduced. Findings are inferences from structural evidence. If the caller later re-runs in `mode: live`, the inference can be confirmed or refuted — but until then, the finding is documented as inferred only.
- **No reproduction test.** Phase 6 writes reproduction tests; static mode does not. A static finding can be handed to a later live pass for reproduction, but the static subagent itself stops at evidence + inference.

### Why this is first-class, not a fallback

Several environments are static-only by construction: CI runners without a browser, regulated sandboxes that block outbound network, code-review contexts, and offline audits. Running bug-discovery in those contexts is a legitimate use case, not a degraded one. Framing static mode as a first-class probing mode removes the "apology" framing that produces weaker findings and standardises the structured-return shape so the orchestrator can merge static and live findings on the same footing (with the `inferred: true` flag retaining the epistemic distinction).

### Orchestrator-side: no silent deprioritisation

Being first-class is not only framing — it is a constraint on how orchestrators (`coverage-expansion`, `onboarding`, Phase-7 deck generation) handle the findings:

- **Ranking.** Static findings rank by **severity**, not by evidence class. A `severity: high` inferred finding outranks a `severity: low` live-verified finding in any ordered list.
- **Inclusion in reports and decks.** Static findings appear in the onboarding-report and the summary deck on the same footing as live findings. The `inferred: true` flag is shown explicitly so readers can judge epistemic weight, but the finding is not buried or collapsed.
- **Follow-up suggestion.** When static findings landed in an earlier run and `@playwright/cli` later becomes available, the orchestrator SHOULD suggest re-running the affected journeys in `mode: live` to confirm or refute each `inferred: true` finding. "Suggest" means a one-line progress note to the caller, not an autonomous re-run.

**Rationalizations to reject:**

| Excuse | Reality |
|--------|---------|
| "Inferred findings are weaker so I'll bucket them separately in the deck" | Bucketing by evidence class rather than severity buries high-impact static findings. The flag carries the epistemic weight — ranking stays severity-first. |
| "Static-mode findings are probably false positives, so I'll drop the low-severity ones" | Every finding's severity is the subagent's judgement; filtering on evidence class on top of severity is double-discounting. |
| "Live mode ran fine so I can ignore any earlier static findings" | A live pass that failed to reproduce an inferred finding does not refute it — it demotes evidence, but the finding stays in the report unless the live pass reached the specific pattern. The orchestrator marks the inference as `live-unconfirmed`, not deleted. |
| "`@playwright/cli` is available so there's no reason to run static mode" | Correct for that one run. Static mode is not opportunistic redundancy — it is for environments where live is unavailable. Do not run static mode in parallel with live unless the caller specifically requested a code-audit pass. |
