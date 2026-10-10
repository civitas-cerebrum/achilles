# Phase 6: Reproduction

Write a failing test for each confirmed bug.

Phase 6 is a **composing exit**: before the Phase 7 report cites any reproduction spec, dispatch the Stage 4c composition judge on the specs written here per [`../achilles-protocol/references/test-composition-standards.md`](../../achilles-protocol/references/test-composition-standards.md) §4 (dimension 1 maps each spec back to its finding; dimension 4 checks its data strategy against `test-data-conventions`). Reproduction tests intentionally fail against the live bug — the judge reviews composition quality, not pass status.

## File Structure

```
tests/
  bug-discovery/
    element-bugs.spec.ts         # from Phase 1a findings
    flow-bugs.spec.ts            # from Phase 1b findings
    context-derived-bugs.spec.ts # from Phase 4 findings
```

## Test Conventions

- Uses Steps API from `./fixtures/base` — same as all other tests
- All selectors in `page-repository.json` — no inline selectors (citation — canon: `../achilles-protocol/references/test-composition-standards.md` §3.1)
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

## Assertion Strategy

Assert the **correct** behavior so the test **fails** against the current buggy state. When the bug is fixed, the test turns green without modification.

**Tag every such test `@known-defect`, and give it a test ID.** A reproduction test is a deliberate red, and nothing downstream can tell a deliberate red from a broken test by looking at it. The tag is what stops `self-repair` / `test-repair` / `failure-diagnosis` from spending reruns, workers, and diagnosis cycles re-deriving a conclusion this pass already reached and filed — and it is what keeps the red out of the `unresolved` bucket that holds a repair run's exit code open. Pair it with the `@finding` reference so the report behind the tag is one grep away, and start the title with a stable ID so the evidence bundle at `bug-evidence/<TEST-ID>/` keeps its name when the title is reworded:

```ts
test('TCBD-000412 · @bug-discovery @known-defect double-click submit creates duplicate', async ({ steps }) => {
  // ...
});
```

Conventions and the full no-rerun contract: [`test-identity.md`](../../achilles-protocol/references/test-identity.md).

**Exit gate — the compliance sweep is not optional.** This mode writes test code, so it runs the Stage-4b compliance sweep over every spec it touched before it returns, and announces it with the documented **API Compliance Review** block. That sweep is where API misuse, tautological assertions, missing test IDs and untagged intentional reds get caught. Harness-enforced at stop time by `hooks/compliance-sweep-exit-gate.sh`; the rule and the per-mode table live in [`stages-protocol.md`](../../achilles-protocol/references/stages-protocol.md) §"Stage 4b is every mode's exit gate".


**If a test fails for unexpected reasons** (not the intended bug reproduction — e.g., wrong selector, navigation error, test code issue): invoke the `failure-diagnosis` protocol to diagnose and fix. The failure-diagnosis pipeline distinguishes between test issues (fix autonomously) and app bugs (report). Only use this for unintended failures — the expected failure from the bug reproduction is not a test issue.

Example: double-click creates duplicates → test double-clicks and asserts `verifyCount('Page', 'records', { exactly: originalCount + 1 })`.

## Visibility Pre-Check in Reproduction Tests

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
