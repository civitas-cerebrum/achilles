# element-interactions API design

Architecture, API hard rules and design rules for the `@civitas-cerebrum/element-interactions` package. Contribution workflow and PR rules: [SKILL.md](../SKILL.md).

## 🏛️ Software Architecture

### The two packages

The framework is split across **two packages** for a reason. Understand the split before adding anything.

```
┌──────────────────────────────────────────────────────────────────┐
│ User test file (tests/*.spec.ts)                                  │
│                                                                   │
│   await steps.expect('price', 'ProductPage').text.toBe('$19.99') │
│   await steps.on('btn', 'Page').nth(2).click()                   │
└────────────────────────────┬─────────────────────────────────────┘
                             │ string names only — no selectors,
                             │ no Locators, no driver primitives
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│ @civitas-cerebrum/element-interactions                            │
│                                                                   │
│   Steps  ──┬─► Interactions  (click, fill, hover, ...)           │
│            ├─► Verifications  (verifyText, verifyCount, ...)      │
│            ├─► Extractions    (getText, getAttribute, ...)        │
│            └─► ExpectBuilder  (.text.toBe, .count.toBeGT, ...)    │
│                                                                   │
│   ElementAction  (fluent builder behind steps.on(...))           │
│   BaseFixture    (wires Steps + Repository + Interactions)        │
└────────────────────────────┬─────────────────────────────────────┘
                             │ uses Element abstraction —
                             │ never raw Locator
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│ @civitas-cerebrum/element-repository                              │
│                                                                   │
│   ElementRepository.get('btn', 'Page')  ──► Element              │
│                                                                   │
│   Element  (platform-agnostic interface)                          │
│     ├─► WebElement       (Playwright-backed)                      │
│     └─► PlatformElement  (Appium / WebDriverIO-backed)            │
│                                                                   │
│   page-repository.json  (single source of truth for selectors)   │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
            Playwright Locator   /   WebDriverIO Element
```

### Layer responsibilities

| Layer | Responsibility | Forbidden |
|---|---|---|
| User test | Describe scenarios in domain language | Constructing locators, importing `@playwright/test` directly for assertions, calling `page.locator()` |
| `Steps` | Top-level facade users call | Holding state across calls, exposing `Locator` in return types |
| `ElementAction` | Fluent builder for `steps.on(...)` chains | Long-lived state (only in-flight chain state); exposing raw Playwright |
| `ExpectMatchers` | Chain-style assertion tree | Mocking, side-effects beyond the awaited assertion |
| `Interactions` / `Verifications` / `Extractions` | Internal helpers: accept `Element` only (no Locator). Wrap raw Locators in `new WebElement(locator)` at the seam if you must. | Calling raw `locator.X()` instead of going through `Element` |
| `BaseFixture` | Constructs Steps with the right deps; auto-attaches failure screenshots | Test-specific logic |
| `Element` interface | Cross-platform element abstraction | Concept that doesn't exist on one of the platforms |
| `WebElement` | Playwright impl + web-only methods | Anything that's not a thin Playwright delegation |
| `PlatformElement` | WebDriverIO/Appium impl | Web-only DOM concepts |
| `ElementRepository` | Resolves name → `Element`, owns `page-repository.json` | Wrapping interactions or assertions: that's element-interactions' job |

### Data flow — anatomy of one call

Tracing `await steps.on('submit-button', 'CheckoutPage').text.toBe('Place Order')`:

1. **`steps.on('submit-button', 'CheckoutPage')`**: `Steps` constructs an `ElementAction` with the element/page names and a fresh `ExpectBuilder` context.
2. **`.text`**: getter on `ElementAction` returns a `TextMatcher` carrying the builder's context (timeout, page, name, negation flag).
3. **`.toBe('Place Order')`**: `TextMatcher.toBe` queues a `QueuedAssertion` on the builder's queue and returns the builder. **No work runs yet.** The chain is synchronous up to this point.
4. **`await`**: JavaScript invokes `builder.then(...)` because `ExpectBuilder` implements `PromiseLike<void>`. `then` calls `flush()`.
5. **`flush()`**: drains the queue. For each assertion:
   - Calls `ctx.captureSnapshot()` → `ElementAction.captureSnapshot()` resolves the named element via `ElementRepository.get(...)` (returning an `Element`), then calls `Element.count/textContent/inputValue/getAllAttributes/isVisible/isEnabled` in parallel.
   - Runs the matcher's predicate against the snapshot.
   - On failure, throws with a structured error that includes the snapshot pretty-printed.
6. **`Element.click/textContent/...`** under the hood call into `WebElement` (Playwright `Locator`) or `PlatformElement` (WebDriverIO). User test code never sees these primitives.

The same shape applies to actions: `steps.on('btn', 'Page').click()` flows through `Interactions.click(target)` → `toElement(target)` → `Element.click({ timeout })` → `WebElement.click()` → `Locator.click()`.

### Why this split exists

- **Cross-platform abstraction has to be at the bottom.** If `Element` lived in element-interactions, every package that wanted platform support would have to depend on the entire interaction surface. Keeping `Element` in its own package means future platforms (desktop, smart TV, native macOS) can implement only the Element contract.
- **Element acquisition is a different concern from interaction.** Repository logic (parsing `page-repository.json`, applying selection strategies, formatting selectors per platform) is independent of what you do with the resolved element. Mixing them produces a god-class.
- **The fixture is the wiring layer, not the API.** Tests import from `BaseFixture`; `Steps` itself is constructible standalone for unusual scenarios. The fixture is opinionated; `Steps` is composable.

### Module / file conventions

- `src/steps/`: user-facing `Steps`, `ElementAction`, `ExpectMatchers`. The chain-style API lives here.
- `src/interactions/`: internal `Interactions`, `Verifications`, `Extractions`, plus the `facade/ElementInteractions` aggregator.
- `src/utils/`: shared helpers (`ElementUtilities` for waiting, `DateUtilities` for date formatting). Pure functions only.
- `src/enum/`: public enum types (`DropdownSelectType`, `EmailFilterType`, etc.).
- `src/fixture/`: `BaseFixture` and related fixture helpers.
- `src/config/`: environment / credentials parsing.
- `src/logger/`: debug logger for verify/interact/email categories.
- `tests/`: Playwright tests, all hitting the real Vue test app.
- `tests/fixture/`: test fixture wiring + shared helper functions (e.g. `pageHelpers.ts`).
- `tests/data/`: `page-repository.json` and any fixture data.
- `skills/contributing-to-achilles-protocol/`: the contributing skill (top-level so the harness auto-discovers it). Agent-facing skill files for the broader suite live under sibling directories at `skills/<skill-name>/SKILL.md`.

When you add a new file:
- New public API entrypoint? `src/steps/`.
- New internal helper (called only by the package itself)? `src/utils/` or co-located in the file that uses it.
- New enum or public type? `src/enum/Options.ts` (or a new file in the same dir for large groups).
- Never create a top-level "misc" folder.

---

## 🚦 Decision tree: where does my new API go?

When you want to add something, walk this in order:

1. **Is it a raw element capability** (e.g. "read CSS variable", "drag with custom timing")?
   → Add to `Element` interface in element-repository (and/or `WebElement` if web-only). Bump element-repository version. Then expose it through element-interactions.

2. **Is it a verification/assertion** (e.g. "assert element has class X", "assert N items in this list")?
   → Add a matcher to `ExpectMatchers.ts`. Either extend an existing matcher class (`TextMatcher`, `CountMatcher`, etc.) or add a new field matcher under `ExpectBuilder`.

3. **Is it a composite workflow** (e.g. "fill an entire form from an object", "retry an action until verification passes")?
   → Add a method to `Steps` in `CommonSteps.ts`. Use existing primitives (`steps.fill`, `steps.verifyText`, `steps.on(...)`): never call `page.locator()` from inside the new method.

4. **Is it a strategy selector or filter** (e.g. "select first matching by aria-label")?
   → Add to `ElementAction` as a chainable strategy method. It should mutate `resolutionOptions` and return `this`.

5. **Is it a fixture-level concern** (e.g. "auto-clean cookies between tests")?
   → Extend `BaseFixture` or compose via `test.extend<T>()`; don't pollute Steps with global cross-cutting setup.

If none of the above fit, **stop and discuss** before writing code. There's probably a deeper design issue.

---

## API hard rules

### No raw `locator.*()` in element-interactions src/

Every `locator.click()`, `locator.fill()`, `locator.evaluate()`, etc. that creeps into `src/` is a regression. If you need a primitive Playwright doesn't expose through `Element`, **add it to the Element interface in element-repository first**.

The one exception: the `WebElement` constructor itself (`new WebElement(locator)`) is the boundary where a raw Locator legitimately enters. Everywhere else uses `Element`.

To audit:

```bash
grep -rn "locator\.\(click\|fill\|textContent\|inputValue\|getAttribute\|count\|evaluate\|isVisible\|isEnabled\|waitFor\|scrollIntoView\|hover\|check\|uncheck\|selectOption\|dispatchEvent\|boundingBox\|press\|setInputFiles\|screenshot\|dragTo\|clear\)" src/ --include="*.ts" | grep -v "dist/"
```

Should return **zero results** in user-facing call sites. The only allowed calls are in `Element` implementations themselves (which live in element-repository).

### Action methods presence-detect

Every action on `Element` (`click`, `fill`, `dragTo`, ...) calls `ensureAttached(timeout)` first. When you add a new action to element-repository, follow the same pattern:

```ts
async myNewAction(options?: ElementActionOptions): Promise<Element> {
    await this.ensureAttached(options?.timeout);  // <-- mandatory
    await this.locator.myUnderlyingCall({ timeout: options?.timeout });
    return this;
}
```

This is what gives the framework predictable failure modes ("element never attached" instead of opaque driver errors) and makes Appium actions stable without depending on auto-wait.

### Web-only methods only get cast at the call site, not aliased

If element-interactions needs `selectOption` (which is `WebElement`-only), the call site does the narrowing:

```ts
const element = toElement(target) as WebElement;
await element.selectOption(...);
```

Don't smuggle web-only methods onto `Element` with throw-stubs on `PlatformElement`. The cast makes the web-only intent explicit and keeps the cross-platform contract accurate.

### Maintain 100% API coverage

The CI gate requires **100% API coverage**: every public method on `Steps`, `ElementAction`, `Verifications`, `Interactions`, `Extractions`, and the matcher classes must have at least one test that exercises it. The coverage tool (`@civitas-cerebrum/test-coverage`) introspects the public surface and fails the build if anything is uncovered.

When you add a new method:
1. Add a passing test for it (even a one-liner against the Vue test app).
2. Run `npx test-coverage --format=github-plain` locally to confirm 100%.
3. The CI coverage job will fail otherwise.

### In-package smoke tests must still verify — and the verification must be causally meaningful

100% API coverage is a floor, not a ceiling. The coverage tool only checks that every public method is *called* from at least one test; it doesn't check that the test *asserts* anything after calling it, let alone that the assertion proves the action did something.

Two levels of failure to avoid:

**Level 1: no assertion at all.** A test like

```ts
test('hover()', async ({ steps }) => {
  await steps.on('primaryButton', 'ButtonsPage').hover();   // ❌ no assertion
});
```

satisfies coverage but is indistinguishable from a no-op; it only catches thrown exceptions.

**Level 2: tautological assertion.** Worse than no assertion, because it looks like coverage:

```ts
test('clickListedElement with regex alternation', async ({ steps }) => {
  await steps.clickListedElement('rows', 'TablePage', { text: { regex: 'A|B|C' } });
  await steps.verifyPresence('rows', 'TablePage');  // ❌ list was there before the click
});

test('hover', async ({ steps }) => {
  await steps.on('btn', 'Page').hover();
  await steps.on('btn', 'Page').verifyState('visible');  // ❌ it was visible to be hovered
});

test('fill', async ({ steps }) => {
  await steps.fill('input', 'Page', 'hello');
  await steps.verifyPresence('input', 'Page');  // ❌ inputs don't disappear when filled
});
```

These pass even if the action silently does nothing.

**Rule:** every test in `tests/` must end with an assertion that would *fail under a no-op*. Ask yourself: **"If the exercised method had been replaced with an empty function body, would this test still pass?"** If yes, the assertion is tautological: rewrite it.

Acceptable verification forms (ordered by strength):

1. **Direct effect on a feedback element**: the action updates a `resultText`, `status`, `stateSummary`, `selectedCount`, etc. Verify that specific element's text/attribute.
2. **Navigation**: click a listed element that navigates; `verifyUrlContains(...)` or `verifyAbsence(...)` on an element only present before the click.
3. **Extraction + assertion**: `expect(await steps.getInputValue(...)).toBe('filled')` for `fill`; `expect(cellText).toMatch(/pattern/)` for regex filters.
4. **State-change verification**: `verifyState('checked')` after `check()`, `verifyState('disabled')` after a submit that disables the button, etc.
5. **Fallback**: `verifyState('visible')` or `verifyPresence(...)` on the target is acceptable ONLY when (a) the method has no observable side-effect at any layer, and (b) a one-line comment explains why. Framework-only smoke cases qualify; feature tests do not.

When reviewing a PR:

1. `grep` the diff for `await steps.*\.\(click|fill|drag|hover|check|uncheck|type|upload|setSliderValue|scrollIntoView|rightClick|doubleClick|clickListedElement)\(` as the *last* line of a test body: every hit is a missing assertion (Level 1).
2. For every `verifyPresence` / `verifyState('visible')` / `verifyState('enabled')` added in the diff, ask whether the element was in that state *before* the action. If yes, it's a tautology (Level 2). The fix is usually to reach for a feedback element (`resultText`, `status`, etc.) instead.

### No mocked unit tests

Every test in this repo runs against the **real Vue test app** at `https://civitas-cerebrum.github.io/vue-test-app/` via Playwright. We do **not** use mocked locators / mock Steps / spy fixtures.

Reason: the framework is a Playwright facade. Mocked tests would only verify that we wire up Playwright "correctly", but Playwright's actual behavior is what users care about. End-to-end tests catch real regressions; mocks don't.

When adding tests, place them in `tests/` and use the existing `StepFixture` import pattern:

```ts
import { test, expect } from './fixture/StepFixture';

test('new feature', async ({ steps }) => {
    await steps.navigateTo('/');
    // ... real interactions against the live app
});
```

---

## 📐 Design rules — invariants that must stay consistent

These are the contracts that hold the framework together. Every change must respect them. If a change requires breaking one, that's a major-version-bump conversation, not a casual PR.

### 1. Argument order — `(elementName, pageName, ...rest)` everywhere

Every method that targets a named element starts with `elementName, pageName`. No exceptions, no historical accidents.

```ts
steps.click('submit-button', 'CheckoutPage');
steps.verifyText('summary', 'CartPage', 'Total: $42');
steps.expect('price', 'ProductPage').text.toBe('$19');
steps.on('row', 'TablePage').nth(2).text.toBe('Active');
repo.get('submit-button', 'CheckoutPage');
repo.getByText('option', 'DropdownPage', 'United States');
```

Adding a method that flips this (e.g. `(pageName, elementName)`) is a hard rejection in review.

### 2. Async-everywhere

Every public method that reaches the DOM/driver is `async`. No synchronous element accessors. If you find yourself wanting a sync getter, you're doing something wrong (the only sync exception is `repo.getSelector()` which returns a string, not an element).

### 3. Chain-style for assertions, flat for actions

- **Assertions** extend the matcher tree (`steps.expect(el, page).field.matcher(value)`). New assertions add to `ExpectMatchers.ts`, not new flat `verifyX` on `Steps`.
- **Actions** stay flat on `Steps` (`steps.click`, `steps.fill`, `steps.dragAndDrop`). Composite workflows (`steps.fillForm`, `steps.retryUntil`) stay flat too.

Every element-scoped `verify*` is exposed in **two forms that share one implementation**:

1. **Fluent form on `ElementAction`**: `steps.on(el, page).verifyX(...)`. This is the canonical implementation. Each method is either a thin wrapper over the matcher tree (for `verifyPresence`, `verifyText`, `verifyTextContains`, `verifyCount`, `verifyAttribute`, `verifyInputValue`, `verifyCssProperty`) or a direct call into `Verifications` where a specialized fast path is needed (`verifyAbsence` via `toBeHidden`, `verifyState`, `verifyImages`, `verifyOrder`, `verifyListOrder`).
2. **Standalone form on `Steps`**: `steps.verifyX(el, page, ...)`. This is a thin delegate that constructs the fluent builder via `actionWithStrategy(...)` and calls the matching `ElementAction.verifyX(...)`. One implementation, two entry points.

This is the invariant to preserve when adding a new verification:
- Add the method on `ElementAction` (or grow `Verifications` first if the underlying primitive doesn't exist).
- Add the matching standalone method on `Steps` that delegates via `this.actionWithStrategy(elementName, pageName, options).verifyX(...)`. Keep the logging on the Steps side so `tester:verify` output stays consistent.

A handful of verifications only make sense as page-level or filter-then-match shapes and only exist on `Steps`:
- **`verifyUrlContains`, `verifyTabCount`**: page-level, not element-scoped; the tree starts at an element.
- **`verifyListedElement`**: filter-then-match; the fluent tree operates on a single resolved element.

The matcher tree (`.text.toBe`, `.count.toBeGreaterThan`, etc.) remains the place to grow **new** assertion shapes: chainable negation, regex, substring, custom predicates, etc. When a matcher-tree shape lands that subsumes an existing `verify*` form, don't deprecate the `verify*`; the two coexist as equally valid entry points.

### 3a. Implementation lives in the `Interactions` / `Verifications` / `Extractions` layer. Everything else is a facade.

The single source of truth for assertion behavior (retry mechanics, web-first polling, error formatting, negation, timeout handling) is the `Verifications` class. For actions, it's `Interactions`. For reads, `Extractions`.

All user-facing layers are **dispatch-only** and must ultimately call into the appropriate interaction class:

```
Steps.verifyText(el, page, ...)            ──┐
Steps.expect(el, page).text.toBe(...)        │
ElementAction.verifyText(...)                ├─► Verifications.text(target, expected, options)
ElementAction.text.toBe(...)                 │   ↑ one implementation, one codepath
interactions.verify.text(locator, ...)     ──┘
```

**The rule for new assertions:**
1. If `Verifications` can do what you need, add a matcher in `ExpectMatchers.ts` that delegates to it (2–3 lines: e.g. `return this.ctx.verify.X(target, ..., opts)`).
2. If `Verifications` can't do what you need, **add a method to `Verifications` first**. Implementation goes there. Then add the matcher that delegates.
3. Never reimplement assertion logic in the matcher tree (snapshot-capture + predicate polling + custom retry). The exception is `.satisfy(predicate)`; the predicate escape hatch legitimately needs a snapshot-based poll because user lambdas run against plain data, not against a live element.

**The rule for new actions:**
- Same shape: `Steps.X` and `ElementAction.X` both delegate into `Interactions.X`. Never write click/fill/hover logic directly on `Steps`.

**Why this matters:**
- One bug fix propagates everywhere. Fix Playwright's web-first assertion handling in one place, every entry point benefits.
- Error messages stay consistent because `describeFailure`-style messages are threaded as `errorMessage` into the single implementation, which embeds them via Playwright's `expect(locator, message)` overload.
- The raw `interactions.verify.X` / `interactions.interact.X` public API (documented as the escape hatch for users with custom locators) is never out of sync with the matcher-tree / Steps behavior.
- Adding a new matcher is cheap: write a one-liner in the tree, add one method to Verifications (which is itself a thin Playwright wrapper).

**Helper pattern the matcher tree uses:**

```ts
// Matcher method — 2-line dispatch
toBe(expected: string): ExpectBuilder {
    return this.builder.enqueue(this.ctx, (entry) =>
        runWithElement(entry.ctx,
            el => entry.ctx.verify.text(el, expected, this.msgOpts(entry.ctx, 'text', 'to be', expected)),
            entry.messageOverride));
}
```

`runWithElement` handles the `ifVisible` gate + resolves the Element. `this.msgOpts` builds the `{ negated, timeout, errorMessage }` shape every Verifications method accepts. Verifications does the actual work.

**Audit grep:** if you find yourself writing retry loops, snapshot capture, or Playwright `expect(locator)...` calls outside of `Verifications` / `Interactions` / `Extractions`, stop. It probably belongs in one of those classes instead.

### 4. One-shot semantics for `.not`

`.not` flips the **next matcher only**, then resets. Don't introduce sticky-negation modes or multi-matcher negation scopes; it confuses reading. Both `steps.expect('el', 'Page').not.text.toBe('x')` and `steps.expect('el', 'Page').text.not.toBe('x')` produce the same single-call negation.

### 5. One timeout, uniform mutation

A single chain-level `timeout` var is the source of truth across the whole chain:

```
Steps.timeout (fixture) → ElementAction._timeout → ExpectContext.timeout → VerifyOptions.timeout (threaded into Verifications)
```

`.timeout(ms)` **mutates** at every layer it appears: no cloning, no divergent semantics:

- `ElementAction.timeout(ms)` mutates `_timeout`; `.text`, `.count`, etc. getters rebuild the ExpectContext with the new value.
- `ExpectBuilder.timeout(ms)` mutates `ctx.timeout` and retroactively patches the last queued assertion (so `.satisfy(pred).timeout(500)` applies 500ms to that predicate).
- Matcher `.timeout(ms)` (e.g. `.text.timeout(500)`) mutates its own ctx AND propagates to the builder for subsequent matchers, but does NOT retroactively patch a prior matcher's queued entry.

**Scope: what `.timeout(ms)` affects:**
1. Every verification/matcher (`.text.toBe`, `.count.toBeGreaterThan`, `.satisfy(pred)`, `.verifyText`, `.verifyCount`, etc.).
2. Element-routed actions that go through `element.action(this._timeout).X()` on `ElementAction`: `hover`, `fill`, `check`, `uncheck`, `doubleClick`, `typeSequentially`, `clearInput`, `scrollIntoView`, `getText`, `getAttribute`, `getCount`, `getInputValue`.
3. Interactions-routed actions: `click`, `clickIfPresent`, `rightClick`, `uploadFile`, `dragAndDrop`, `selectDropdown`, `setSliderValue`, `selectMultiple`. `ElementAction` passes `this._timeout` through the option bag of each `interactions.interact.*` call, which then uses it for both the pre-action `Utils.waitForState(...)` and the Playwright primitive (`element.click({ timeout })`, etc.).

When adding a new Interactions-routed action, extend its option bag with `timeout?: number` (or accept an `ActionTimeoutOptions` parameter for modifier-free methods) and plumb it to the same two places: pre-wait and primitive. The `ElementAction` call site passes `{ timeout: this._timeout }` into the bag.

**Repo resolution has its own timeout.** `repo.get(...)` pays `ElementRepository.defaultTimeout` (configured by `repoTimeout` on the fixture, 15000ms default) waiting for the element to reach `attached`. This is upstream of `ElementAction._timeout`: the chain-level `.timeout(ms)` only governs action + verification, not resolution. If you need to bound resolution too, use `repo.setDefaultTimeout(ms)` on the fixture or in a `beforeEach`.

**Visibility probe/gate is another deliberate exception.** `isVisible(options?)` (the unified replacement for the old `ifVisible()` / boolean `isVisible()` pair) and its older aliases use a short `visibilityTimeout` (default 2000ms) because their whole purpose is fast-skip: a hidden element should abort the action in ~2s, not 30s. Do not unify it into the main timeout.

`isVisible(options?)` returns a `VisibleChain` that is both awaitable (`Promise<boolean>`) and chainable (`.click()`, `.text.toBe(...)`, etc.). The probe constructs a `WebElement` directly from `repo.getSelector(...)` rather than going through `repo.get(...)`; otherwise the 15s repository-resolution wait would swallow the caller's short timeout. Every probe and gate decision is logged under `tester:visible` with a `[probe]` or `[gate]` tag.

Other builder state (queue, pendingNot) also mutates, but stays scoped: each `.expect()` / `.on()` call returns a fresh builder, so mutation doesn't leak across chains. `.not` is one-shot: it flips the next matcher only, then resets.

### 6. Snapshot-based predicates

The predicate escape hatch (`steps.expect(el, page).satisfy(predicate)`) takes a function that receives an `ElementSnapshot`: plain data, no async access. This keeps custom assertions readable and predictable.

```ts
// ✓
await steps.expect('price', 'Page').satisfy(el => parseFloat(el.text.slice(1)) > 10);

// ✗ Never change to this — users would need to await inside the predicate
await steps.expect('price', 'Page').satisfy(async el => (await el.getText()) === '$10');
```

### 7. Naming conventions

| Prefix | Returns | Behavior on failure |
|---|---|---|
| `verify*` | `Promise<void>` | Throws |
| `expect(...)...` (matcher tree) | thenable that throws on failure | Throws on failure |
| `is*` | `Promise<boolean>` | Returns `false` (never throws) |
| `get*` | `Promise<value>` | Throws if element not found |
| `wait*` | `Promise<void>` | Throws on timeout |
| `click*` / `fill*` / `hover*` etc. | `Promise<void>` (or `Promise<boolean>` for the `IfPresent` variants) | Throws on failure |

If your new method doesn't fit one of these, reconsider the shape; the naming is the API contract.

### 8. Public API stability

`steps.click`, `steps.verifyText`, `steps.on(...).fill`, the matcher tree shape (all the entry points users have written tests against) stay stable across patch and minor versions. Internal refactors are fine; signature changes on user-facing methods need a major bump and a clear migration note in the PR description.

The public `Target` type on `Interactions`, `Verifications`, `Extractions`, and `Utils` is `Element` (no Locator union). Consumers with custom Playwright locators wrap them via `new WebElement(locator)` at the seam: that's the single documented bridging point.

### 9. Action methods presence-detect

Every action on `Element` (`click`, `fill`, `hover`, `dragTo`, ...) calls `ensureAttached(timeout)` first. New action methods MUST do the same. This is what gives the framework predictable failure modes ("element not attached" instead of opaque driver errors) and stable Appium behavior.

```ts
async myNewAction(options?: ElementActionOptions): Promise<Element> {
    await this.ensureAttached(options?.timeout);  // mandatory
    await this.locator.myUnderlyingCall({ timeout: options?.timeout });
    return this;
}
```

### 10. No raw `locator.*()` in element-interactions src/

Every `locator.click()`, `locator.fill()`, `locator.evaluate()`, etc. that creeps into `src/` is a regression. If you need a primitive Playwright doesn't expose through `Element`, **add it to the Element interface in element-repository first**.

The one exception: the `WebElement` constructor itself (`new WebElement(locator)`) is the boundary where a raw Locator legitimately enters. Everywhere else uses `Element`.

To audit:

```bash
grep -rn "locator\.\(click\|fill\|textContent\|inputValue\|getAttribute\|count\|evaluate\|isVisible\|isEnabled\|waitFor\|scrollIntoView\|hover\|check\|uncheck\|selectOption\|dispatchEvent\|boundingBox\|press\|setInputFiles\|screenshot\|dragTo\|clear\)" src/ --include="*.ts" | grep -v "dist/"
```

Should return **zero** results in user-facing call sites.

### 11. Web-only methods only get cast at the call site

If element-interactions needs `selectOption` (which is `WebElement`-only), the call site does the narrowing:

```ts
const element = toElement(target) as WebElement;
await element.selectOption(...);
```

Don't smuggle web-only methods onto `Element` with throw-stubs on `PlatformElement`. The cast makes the web-only intent explicit at the call site and keeps the cross-platform contract accurate.

### 12. Error message format

User-facing assertion failures follow a consistent header format:

```
expected <PageName>.<elementName> <field> [not ]<verb> <expected>
```

Examples:
- `expected ProductPage.price text to be "$19.99"`
- `expected CheckoutPage.submitBtn count not to be 5`

The actual value comes from Playwright's built-in "Expected / Received" diff block appended below the header: we pass the header string as the `message` argument to `expect(locator, message).<matcher>()`, and Playwright prepends it to its own assertion output. Don't hand-roll the `got <actual>` suffix; it'll duplicate what Playwright already emits.

Use the `BaseMatcher.msgOpts(ctx, field, verb, expected)` helper in `ExpectMatchers.ts`; it builds `{ negated, timeout, errorMessage }` in the exact shape every Verifications method accepts. Don't hand-roll error strings.

For predicate failures (`satisfy(pred)`), the path is different; we poll a snapshot manually, so there's no Playwright diff block. The message includes the full `ElementSnapshot` JSON pretty-printed under the header. Don't truncate or summarize the snapshot: users debug from it.

### 13. Logging

Every public method on `Steps` logs at one of: `tester:navigate`, `tester:interact`, `tester:verify`, `tester:extract`, `tester:wait`, `tester:email`. The category mirrors the operation kind. Use the existing `log.X(...)` helpers in `CommonSteps.ts` rather than `console.log`.

### 14. TypeScript discipline

- **No `any`** in `src/`. Test fixtures are exempted (the Playwright fixture types are awkward to spell exactly).
- **Prefer interfaces over type aliases** for public surfaces. `ExpectContext`, `ElementSnapshot`, `QueuedAssertion` are interfaces.
- **Use `readonly`** on snapshot/data interface fields. Mutable internal state is fine on classes; data passing between layers should be readonly.
- **Use `as const`** for matcher verb strings and similar string literals when they need narrow types.
- **Avoid `as unknown as X` double-casts.** If you need one, the type model is wrong somewhere: refactor.

### 15. No version bumps without explicit authorisation

**Don't run `npm version <X>`. Don't edit `package.json`'s `version` field. Don't push a tag.** Versioning is release-time, not per-PR. The user controls when bumps happen.

A contributor (or an agent acting for one) may bump only when **the user has explicitly authorised that specific bump in the conversation**. The authorisation must be visible in the conversation thread: auditable in context, copy-pasteable from the user's authorising message.

```bash
npm version patch --no-git-tag-version
npm version 0.3.8
```

**Why.** Per-PR bumping causes version-number collisions when PRs merge out of order, reviewer cognitive cost from a version line in every diff, and rebase churn that has nothing to do with the actual change. Release-time bumping collapses every PR diff to "the actual change" and keeps release control with the maintainer.

**Why bump against npm-latest, not `package.json`:**

When multiple PRs are open in parallel, every branch bumping `current+1` from its own diverged base produces version collisions on merge: two branches off the same base both bump to the same next version, the second to merge clobbers or duplicates the first's published version. Bumping against npm-latest collapses every open branch to a known monotonic ceiling: the first PR to merge sets the new published version, and subsequent PRs rebase + re-bump against the new ceiling. No collisions, no manual reconciliation in CI.

**Edge case: `npm view` fails (no network, package not yet published).** Fall back to bumping against the current `package.json` value (the old recipe) and call out the deviation in the PR description so the reviewer can spot-check for collision against any other open PR. Fall back to bumping against the current `package.json` value and call out the deviation in the PR description so the reviewer can spot-check for collision against any other open PR.

For minor/major bumps, same rule: bump once, at the start, against `(npm-latest + 1 minor/major)`.

### 16. Tests hit the real Vue test app

No mocks, no spies, no fake locators. Every test in `tests/` runs against `https://civitas-cerebrum.github.io/vue-test-app/` via Playwright. The framework's value is its Playwright wiring; mocks would only verify wiring against itself.

### 17. 100% API coverage is a CI gate

Every public method on `Steps`, `ElementAction`, `Verifications`, `Interactions`, `Extractions`, and the matcher classes must have at least one test that exercises it. The coverage tool (`@civitas-cerebrum/test-coverage`) introspects the public surface and fails the build if anything is uncovered. New methods need new tests.

### 18. Keep `Steps` lightweight — fewer methods, more flexibility

`Steps` is the user-facing facade. It is a dispatch surface, not an implementation surface. The implementation layers (`Interactions`, `Verifications`, `Extractions`) *should* grow many small specialized methods (`localStorage`, `localStorageContains`, `localStorageMatches`, `localStoragePresent`). `Steps` should grow as few methods as possible, each accepting a flexible options shape that selects between the underlying variants.

**Why this split exists:**

- **Grep-ability for users.** A user reads a test and asks "what assertions exist for X?": finding one `verifyX(key, options)` plus typed options is faster than scanning five sibling methods.
- **Discoverability via TypeScript.** A discriminated-union options type (e.g. `StorageVerifyOptions`) gives autocomplete the matcher names without forcing the user to recall five method suffixes.
- **Refactor blast radius.** Adding a new matcher variant means adding one method to `Verifications` and one branch to a Steps dispatcher, not a full new public method on `Steps` (with logging, doc block, coverage test, surface-area churn).
- **Cognitive load on the API surface.** Every method on `Steps` is a thing a user can call. The API budget is finite; spend it on distinct *resources* (an element, the URL, page HTML, browser storage), not on every variant of how to assert against them.

**The rule:**

When you add a new family of related verifications/extractions on `Steps`, the default shape is **one method per resource**, accepting a discriminated-union options type that picks the matcher.

✓ DO:

```ts
// One Steps method, four matchers selected via discriminated union.
type StorageVerifyOptions =
    | { equals: string; contains?: never; matches?: never; present?: never; ... }
    | { equals?: never; contains: string; matches?: never; present?: never; ... }
    | { equals?: never; contains?: never; matches: RegExp; present?: never; ... }
    | { equals?: never; contains?: never; matches?: never; present: boolean; ... };

async verifyLocalStorage(key: string, options: StorageVerifyOptions): Promise<void> {
    // Dispatch to verify.localStorage / localStorageContains / localStorageMatches / localStoragePresent.
}
```

✗ DON'T:

```ts
// Four separate Steps methods — bloats the surface, splits docs, splits log lines.
async verifyLocalStorage(key, expected, options?) { ... }
async verifyLocalStorageContains(key, substring, options?) { ... }
async verifyLocalStorageMatches(key, regex, options?) { ... }
async verifyLocalStoragePresent(key, options?) { ... }
```

**Variety still belongs on `Interactions` / `Verifications` / `Extractions`.** Those classes are the implementation. They take *concrete* arguments and have *concrete* shapes: one method per matcher is the right granularity there because each method maps to a single Playwright primitive (e.g. `expect.toHaveText` vs `expect.toContainText` vs `expect.toMatch`). Don't try to merge `Verifications.localStorage` and `Verifications.localStorageContains` into one; the implementation layer benefits from specialization.

**Existing technical debt.** Several legacy families on `Steps` *do* have multiple methods per resource (`verifyText` / `verifyTextContains` / `verifyTextMatches`, `verifyHtml` / `verifyHtmlContains` / etc.). These predate this rule. Don't refactor them in the same PR that adds new work: that's a separate cleanup. But every *new* family must follow this rule. When in doubt: one Steps method, dispatch via options.

**Exception: matcher tree.** The matcher tree (`steps.expect(el, page).text.toBe(...)`) is *itself* the flexible-shape API: the chained matchers play the role that an options-union plays for flat methods. So `.text.toBe` / `.text.toContain` / `.text.toMatch` are correct on the matcher tree. The rule applies to flat `verifyX` methods on `Steps`, not to the chain.

### 19. Doc updates are mandatory for new public API

Any PR that adds a new public method to `Steps`, `ElementAction`, the matcher tree, or a new public matcher class **must** update both of:

1. `README.md`: under the relevant `🛠️ API Reference: Steps` subsection (Interaction / Verification / Data Extraction / Visibility / Listed Elements / etc.). One bullet per new method, plus an inline code example block when the API has a non-obvious option shape (e.g. discriminated unions, multi-form matchers).
2. `skills/achilles-protocol/references/api-reference.md`: under the matching section. The api-reference is the canonical documentation consumed by other skills (test-composer, coverage-expansion, bug-discovery), so missing entries here cause downstream agents to write tests that drop out of the framework.

**No "headline-worthy" exception.** The previous version of this rule allowed README updates only for headline-worthy features and produced silent doc drift: the HTML extraction surface (commit `d2f200e`) shipped without a README entry. If the change adds a method a user can call from a test, both files get an entry. The PR description should quote the new bullets verbatim so reviewers can grep them.

**Internal-only changes don't trigger this rule.** Adding a method to `Verifications`, `Interactions`, or `Extractions` *without* a corresponding `Steps` / `ElementAction` / matcher-tree entry point is internal: it's reachable only from the raw escape hatch (`interactions.verify.X`). The README docs the recommended surface; raw escape-hatch methods are documented inline via JSDoc on the class.

**Skill files updates** (`skills/achilles-protocol/SKILL.md`, `skills/contributing-to-achilles-protocol/SKILL.md`, etc.) are required only when the change affects a workflow stage, the contribution rules, or a hard rule. A new `verify*` method does not normally require a SKILL.md change.

---

### 20. Universality — no client references

Achilles is a **universal** quality-assurance medium serving many clients for UI, API, and DB test automation. Nothing in this repository (skills, references, hooks, schemas, fixtures, examples, commit messages, PR bodies) may reference a specific client's software, brand, product names, domain copy, selectors/test IDs, ticket prefixes, or engagement details.

**Findings from client work are welcome ONLY after genericisation.** Describe the MECHANISM, never the instance:

- ✓ "a controlled form resets its inputs on mount, deterministically wiping the first field filled"
- ✗ "«client»'s signup form on /«brand-page» wipes the email field": names the client, the page, the engagement

Use the suite's `«placeholder»` convention for every example value (`«BASE_URL»`, `j-<slug>`, `<resource-001>`, `PageName`/`elementName`), and state evidence generically ("observed in a production suite"). Ticket keys in examples use neutral shapes (`<TICKET>`, `ABC-450`): never a real client tracker prefix.

This applies to **every contributor and every contribution**. Reviewers MUST reject violations: there is no "it's just one product name in an example" carve-out (see `../coverage-expansion/references/anti-rationalizations.md` §"Pattern: Client-reference leakage"). A violation that reaches `main` is a leak of engagement details into a repo other clients consume; the fix is a history-scrubbing chore nobody wants.

**Harness backstop:** `hooks/client-term-guard.sh` (`PreToolUse:Write|Edit`, DENY) scans writes into this repo against an **operator-local** denylist at `<repo-root>/.achilles/client-terms.local.txt` (one term per line; gitignored: the terms themselves ARE client references, so the list must never live in the repo). Each operator maintains the list for their own engagements; with no denylist file the hook is a silent no-op and the rule is reviewer-enforced. Generic leakage beyond the operator's listed vocabulary is not mechanically detectable; that residual surface is tagged in the anti-rationalizations registry entry above.

---

## 🧰 Workflow: adding a new API

### A. Adding to element-repository (the underlying capability)

```bash
cd /path/to/element-repository
git checkout main && git pull
git checkout -b feat/your-feature

# 1. Update src/types/Element.ts (interface)
# 2. Implement in src/types/WebElement.ts
# 3. Implement in src/types/PlatformElement.ts (or stub if web-only — but prefer cross-platform)
# 4. Add live test in tests/live-element-location.spec.ts using the Vue test app
# 5. Verify
npm run build
npx playwright test tests/live-element-location.spec.ts
npx test-coverage --format=github-plain     # must show 100%

# 6. Bump version against npm-latest (Rule 15 — collision-safe across parallel PRs)
npm version "$(npm view @civitas-cerebrum/element-repository version | awk -F. '{print $1"."$2"."$3+1}')" --no-git-tag-version

# 7. Commit + push + open PR
git add -A
git commit -m "feat: add Element.<method> for <use case>"
git push -u origin feat/your-feature
gh pr create --base main --title "feat: ..." --body "..."
```

After this PR merges, element-repository auto-publishes to npm. Then update element-interactions to use the new version.

### B. Adding to element-interactions (the user-facing API)

```bash
cd /path/to/element-interactions
git checkout main && git pull
git checkout -b feat/your-feature

# 1. Add the API to the right layer:
#    - New matcher → src/steps/ExpectMatchers.ts
#    - New step / composite → src/steps/CommonSteps.ts
#    - New strategy → src/steps/ElementAction.ts
#    - Internal helper → src/interactions/{Interaction,Verification,Extraction}.ts

# 2. Add tests in tests/ — must hit the real Vue test app
# 3. Run full suite + coverage
npm run build
npm run test                                 # all tests must pass
npx test-coverage --format=github-plain     # must show 100%

# 4. Update docs (Rule 19 — both files mandatory for any new public API):
#    - skills/achilles-protocol/references/api-reference.md (the canonical source)
#    - README.md (the user-facing reference under "🛠️ API Reference: Steps")
#    - skills/achilles-protocol/SKILL.md (only if the change affects workflow stages)

# 5. Bump version once, against npm-latest (Rule 15 — collision-safe across parallel PRs)
npm version "$(npm view @civitas-cerebrum/element-interactions version | awk -F. '{print $1"."$2"."$3+1}')" --no-git-tag-version

# 6. Populate the contribution handover
cp .contribution-handover.template.json .contribution-handover.json
# fill in every boolean; pair every false / "n/a" with a *Reason field

# 7. Commit + push + open PR
#    (Methodology rule: do not push or open a PR until the
#    `.contribution-handover.json` is valid.)
git add -A
git commit -m "feat: add steps.<method> for <use case>"
git push -u origin feat/your-feature
gh pr create --base main --title "feat: ..." --body "..."
```

### C. Cross-package change (new Element capability + matching Steps API)

Open both PRs in parallel. Element-repository PR ships first; element-interactions PR depends on it:

1. Push element-repository PR.
2. Locally, point element-interactions at `file:../element-repository` so you can develop both sides simultaneously.
3. Once element-repository PR merges and the new version publishes, flip element-interactions back to `^X.Y.Z`.
4. Push the version-flip commit; CI goes green; merge.
