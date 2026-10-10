# Phases 1a to 4: probing, cross-reference, analysis

# Phase 1a: Element Probing

Visit every page via `playwright-cli` (open a `-s=bd-<journey-slug>` session per [`../achilles-protocol/references/playwright-cli-protocol.md`](../../achilles-protocol/references/playwright-cli-protocol.md) §3) with **zero context** — do NOT read `app-context.md`, existing tests, or scenario docs. Pure adversarial exploration.

## Probing Categories

Apply to every interactive element found on every page:

| Category | Actions |
|---|---|
| **Boundary inputs** | Empty submit, special chars (`<script>`, `'"; DROP`), max-length strings, zero/negative numbers, unicode, whitespace-only |
| **State transitions** | Browser back after submit, refresh mid-flow, double-click buttons, re-submit completed forms, navigate away and return |
| **Race conditions** | Rapid repeated clicks, interact during loading spinners, submit while animations play, type during autocomplete debounce |
| **Permission/access** | Direct URL access without auth, manipulate URL params, expired session behavior, access other users' resources |
| **Data edge cases** | Empty lists, single item lists, pagination last page, long text overflow, missing/broken images, zero-result search |
| **Cross-feature** | Edit in one tab and check another, apply filters then navigate back, change language mid-flow, resize viewport during interaction |

## Process per Page

1. Navigate via `playwright-cli` (`-s=bd-<journey-slug> goto <URL>`)
2. Take a snapshot (`-s=bd-<journey-slug> snapshot`)
3. Identify all interactive elements
4. **Visibility gate:** For each element, check `getBoundingClientRect()` — if width and height are both 0, or if any ancestor has `display: none`, `visibility: hidden`, or zero height, mark the element as **DOM-only**. Continue probing both visible and DOM-only elements, but tag all findings accordingly.
5. Systematically try each probing category on each element
6. **Screenshot verification:** For every anomaly found, take a screenshot that shows the issue as a user would see it. If the anomaly is not visible in the screenshot (element is hidden, zero-sized, or off-screen), classify it as **DOM-only** — not a user-facing bug.
7. Log every anomaly with: page, action taken, observed result, screenshot, and **visibility classification** (user-visible or DOM-only)

## Evidence paths (convention)

Screenshots and captured artifacts are named and located so a report link, a ledger `evidence:` line, and the on-disk file always agree:

- **Pre-classification anomaly shots** (Phase 1a/1b, before a finding has an ID): `<page-slug>-<probe-category>-<nn>.png`.
- **At Phase 5 classification**, rename each kept shot to its canonical FINDING-ID:
  - Standalone bug-discovery: `docs/e2e/screenshots/<FINDING-ID>.png`
  - Journey-scoped (dispatched by `coverage-expansion`): `tests/e2e/docs/screenshots/<FINDING-ID>.png` (sibling of the ledger)
- Non-screenshot evidence for API/security/privacy findings (saved response body, header dump, console capture, DOM/source excerpt) is saved alongside under the same `<FINDING-ID>` stem.
- Report links and ledger `evidence:` lines carry exactly these repo-relative paths.

## Output

A raw findings list. Each entry: page, action taken, observed result, screenshot, visibility classification (user-visible / DOM-only).

---

# Phase 1b: Flow Probing

Construct and test **adversarial user journeys** — complete flows designed to break assumptions. Uses the page map built during Phase 1a.

## Flow Categories

| Category | Example Flows |
|---|---|
| **Interrupted flows** | Start checkout, close tab, reopen — is cart still there? Start wizard, back at step 3 — does state corrupt? |
| **Out-of-order operations** | Skip wizard steps via URL, delete item being edited elsewhere, submit form for just-deleted record |
| **Concurrent state** | Same form in two tabs — edit both, submit both. Cart in tab A, checkout in tab B — what happens in A? |
| **Data lifecycle** | Create, edit, delete — can you undo? Create, navigate away, return — is draft saved? Bulk delete, check pagination |
| **Role/session transitions** | Log out mid-flow, log back in — where do you land? Switch roles — do stale permissions persist? |
| **Upstream dependency failures** | List references deleted item? Filter value no longer exists? Linked resource returns 404? |
| **Cumulative state** | Repeat action 20 times — memory leak, stacked toasts, DOM growth? Apply/clear filters repeatedly — clean reset? |

## Process

1. Read the app's route structure to identify all multi-step flows
2. For each flow, design 2-3 adversarial variations from the categories above
3. Execute each variation via `playwright-cli`
4. Log anomalies with full flow description, screenshots at each step, and expected vs actual outcome

---

# Phase 2: Context Cross-Reference

Shift from discovery to analysis. NOW read the accumulated context.

## Steps

1. Read `app-context.md` — check "Known issues" for each page.
2. Read the **prior bug-discovery report / ledger** (if one exists) and load its triage state, keyed by canonical FINDING-ID (see §"Triage lifecycle"). Findings already at `deferred` or `wontfix` are filtered exactly like documented known issues — they do NOT re-emit as new. Findings at `fix-in-progress` or `fix-verified` are regression re-check candidates for Phase 3 (their reproduction tests get re-run there).
3. Filter out findings already documented as known quirks or accepted behavior.
4. Flag findings that **contradict** documented behavior — these escalate, they do NOT get filtered out. A finding that a prior run set to `wontfix` but which now reproduces at a **higher severity** than when it was deferred escalates: re-surface it (it is no longer covered by the operator's wontfix instruction at the old severity).
5. Note any discrepancies between documented state and observed state for Phase 4.

## Output

Filtered findings with known issues and operator-deferred/wontfix items removed; prior findings tagged for regression re-check; discrepancies and severity-escalated wontfix items flagged for Phase 4.

---

# Phase 3: Test Cross-Reference

Scan existing test coverage against remaining findings.

## Steps

1. Read all spec files in the test directory
2. Read scenario docs (`docs/e2e-test-scenarios.md`) if they exist
3. Filter out findings already covered by a passing test
4. Flag findings that contradict what an existing test asserts in a different context — these are **regression candidates**

## Output

Classified findings with already-tested items removed, regression candidates flagged.

---

# Phase 4: Context-Derived Analysis

Use `app-context.md` as a **source** of new findings — not just a filter. Cross-reference what context documents against what probing actually observed.

## Discrepancy Patterns

| Pattern | Example |
|---|---|
| **Documented state never appeared** | app-context says page has empty state, probing never triggered it — is empty state broken? |
| **Documented flow doesn't match reality** | app-context says "Links to Settings", but link goes to 404 or different page |
| **Known workaround masks deeper issue** | Tests use `waitForState` for slow load — is slow load itself a performance bug? |
| **Inconsistent behavior across pages** | Similar components behave differently (date formats, validation rules, error messages) |
| **Missing error handling** | app-context documents actions but no error states — probing confirms errors unhandled |

## Output

New findings derived from discrepancies, classified the same as probing findings.
