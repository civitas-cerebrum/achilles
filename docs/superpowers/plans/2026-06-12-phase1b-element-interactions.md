# Phase 1B — element-interactions Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Methodology note:** changes to this package go through its own contribution methodology — at execution time, dispatch each task as a `contribution-handover-` subagent whose brief instructs it to load the `contributing-to-element-interactions` skill (subagent-only) and follow its pipeline (tests, docs, handover return per `contribution-handover.schema.json`). The steps below are the technical content of those briefs.

**Goal:** Remove the framework's three integrity traps — waits that can't fail, auto-retries that mask real bugs, and a package that can't be published — plus the README sections that teach removed APIs.

**Architecture:** Behavior changes are confined to `Utils.waitForState`, `Steps.waitForState`, and `Interaction.clickWithInterceptionRetry`, each gaining an explicit option with honest defaults; everything else is docs, typing, and packaging. Breaking change → version 0.4.0.

**Tech Stack:** TypeScript 5, Playwright Test ≥1.59, the package's own dockerized E2E self-test suite (`npm run test:unit` against the vue-test-site app — `docker compose up -d` first; see `docker-compose.yml`).

**Repo:** `/Users/Ay/Github/element-interactions` (work on a new branch `feat/0.4.0-integrity` off its default branch).
**Spec:** `achilles/docs/superpowers/specs/2026-06-12-phase1-harness-integrity-design.md` §B

---

### Task 1: Publish blocker — sql-client registry dependency (B3)

**Files:**
- Modify: `/Users/Ay/Github/element-interactions/package.json` (dependencies)
- External: `/Users/Ay/Github/sql-client` (publish v0.1.0)

Decision already made (verified during planning): `@civitas-cerebrum/sql-client` is imported **eagerly** at module top of `src/steps/CommonSteps.ts:7` and re-exported from `src/index.ts:61-63`, so `optionalDependencies` is not viable without a lazy-loading refactor (out of scope). The fix is to publish sql-client. It is NOT yet on the registry (404 verified 2026-06-12); local copy at `/Users/Ay/Github/sql-client` is v0.1.0.

- [ ] **Step 1: Pre-publish check on sql-client**

```bash
cd /Users/Ay/Github/sql-client && npm pack --dry-run && npm test
```

Verify the tarball contains dist/ and no `file:` deps of its own (`jq '.dependencies' package.json`).

- [ ] **Step 2: Publish (USER ACTION — requires npm auth)**

Ask the user to run: `cd /Users/Ay/Github/sql-client && npm publish --access public`. **Blocked until done.** (publishConfig provenance may require `--provenance=false` outside CI — user's call.)

- [ ] **Step 3: Switch the dependency**

In element-interactions `package.json`: `"@civitas-cerebrum/sql-client": "file:../sql-client"` → `"@civitas-cerebrum/sql-client": "^0.1.0"`, then `npm install` (lockfile updates).

- [ ] **Step 4: Guard against regression**

Add to element-interactions `package.json` scripts:

```json
"check:publishable": "node -e \"const d={...require('./package.json').dependencies,...require('./package.json').devDependencies}; const bad=Object.entries(d).filter(([,v])=>/^(file|link):/.test(v)); if(bad.length){console.error('Unpublishable deps:',bad);process.exit(1)}\"",
"prepublishOnly": "npm run check:publishable && npm run build"
```

- [ ] **Step 5: Verify + commit**

```bash
npm run check:publishable && npm pack --dry-run | head -20 && npm run build
git add package.json package-lock.json
git commit -m "fix(deps): sql-client from registry — package is publishable again"
```

---

### Task 2: waitForState honesty (B1, breaking)

**Files:**
- Modify: `src/utils/ElementUtilities.ts` (waitForState, ~lines 20-55), `src/steps/CommonSteps.ts` (Steps.waitForState ~1234-1247, plus the `waitAndClick` caller just below), `src/enum/Options.ts` (StepOptions)
- Test: Create `tests/wait-honesty.spec.ts`

- [ ] **Step 1: Write the failing tests**

Create `tests/wait-honesty.spec.ts` (fixture/app-URL conventions: copy the header of `tests/negative.spec.ts` — same `baseFixture` import and test-site URL):

```ts
import { test, expect } from './fixtures'; // ← match the import path used by negative.spec.ts
test.describe('waitForState honesty', () => {
    test('waitForState rejects when the element never reaches the state', async ({ steps, page }) => {
        await steps.navigateTo('/');
        await expect(
            steps.waitForState('nonexistentElement', 'HomePage', 'visible', { timeout: 1500 } as any)
        ).rejects.toThrow(/did not reach state 'visible'/);
    });
    test('waitForState with optional:true resolves false instead of throwing', async ({ steps }) => {
        await steps.navigateTo('/');
        const reached = await steps.waitForState('nonexistentElement', 'HomePage', 'visible', { optional: true, timeout: 1500 } as any);
        expect(reached).toBe(false);
    });
    test('waitForState resolves true for a present element', async ({ steps }) => {
        await steps.navigateTo('/');
        const reached = await steps.waitForState('heading', 'HomePage', 'visible', { optional: true });
        expect(reached).toBe(true);
    });
});
```

(`'nonexistentElement'`/`'heading'`: pick real repo entries — `nonexistent` patterns exist in `tests/negative.spec.ts`; reuse its element/page names. Drop the `as any` once Step 3 adds the options.)

Run: `npx playwright test tests/wait-honesty.spec.ts` → FAILS (no rejection today; returns void).

- [ ] **Step 2: Extend StepOptions**

In `src/enum/Options.ts`, `StepOptions` (line 322), add:

```ts
    /**
     * Per-call timeout override in milliseconds. Applies to the wait/action
     * this options bag is passed to. Falls back to the instance timeout.
     */
    timeout?: number;
    /**
     * For waitForState: do not throw on timeout — resolve `false` instead.
     * Default `false` (timeouts throw as of 0.4.0).
     */
    optional?: boolean;
```

- [ ] **Step 3: Make Utils.waitForState throw by default**

Replace the body in `src/utils/ElementUtilities.ts` (keep the JSDoc, updating the "Does not fail the test" line):

```ts
    /**
     * Standardized wait logic for element states.
     * Throws on timeout as of 0.4.0; pass `optional: true` to get the
     * pre-0.4 soft behavior (resolves false, logs a warning).
     * If the resolver yields multiple elements (strict mode violation),
     * the wait retries on the first matched element and logs loudly.
     */
    async waitForState(
        element: WebElement,
        state: 'visible' | 'attached' | 'hidden' | 'detached' = 'visible',
        timeout?: number,
        optional: boolean = false,
    ): Promise<boolean> {
        const effectiveTimeout = timeout ?? this.timeout;
        try {
            await element.waitFor({ state, timeout: effectiveTimeout });
            return true;
        } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            if (message.includes('strict mode violation')) {
                log.warn(`Locator resolved to multiple elements (strict mode violation) — waiting on the FIRST match. Narrow the repository selector to silence this.`);
                try {
                    await element.first().waitFor({ state, timeout: effectiveTimeout });
                    return true;
                } catch (innerError) {
                    return this.handleWaitTimeout(state, effectiveTimeout, optional, innerError);
                }
            }
            return this.handleWaitTimeout(state, effectiveTimeout, optional, error);
        }
    }

    private handleWaitTimeout(state: string, timeout: number, optional: boolean, cause: unknown): boolean {
        if (optional) {
            log.warn(`Element did not reach state '${state}' within ${timeout}ms (optional wait — continuing).`);
            return false;
        }
        const causeMsg = cause instanceof Error ? cause.message : String(cause);
        throw new Error(`Element did not reach state '${state}' within ${timeout}ms. ${causeMsg}`);
    }
```

**Ripple check (critical):** `grep -n "waitForState" src/ -r` — every internal caller (e.g. `Interaction.click` pre-waits via `this.utils.waitForState(element, 'visible', timeout)`) now throws on timeout instead of falling through to the click call's own (clearer-context) failure. That is the spec's intent ("failing tests fail earlier and clearer") — but each internal call site must be reviewed: for `ifPresent`/gated paths that intentionally probe, pass `optional: true` explicitly. Known sites to set `optional: true`: none in `click` (it should throw); `VisibleChain`-style probes if they route through Utils (check `src/steps/` for `isPresent`/`ifPresent` paths — `isVisible()` calls don't route through waitForState, but verify with the grep).

- [ ] **Step 4: Update Steps.waitForState**

In `src/steps/CommonSteps.ts` (~line 1234), replace the try/catch body:

```ts
    async waitForState(
        elementName: string,
        pageName: string,
        state: 'visible' | 'attached' | 'hidden' | 'detached' = 'visible',
        options?: StepOptions
    ): Promise<boolean> {
        log.wait('Waiting for "%s" in "%s" to be "%s"', elementName, pageName, state);
        const element = await this.getWebElement(elementName, pageName, options);
        const timeout = options?.timeout ?? this.timeout;
        try {
            await element.waitFor({ state, timeout });
            return true;
        } catch (error) {
            if (options?.optional) {
                log.wait("Element '%s.%s' did not reach state '%s' within %dms (optional wait — continuing)", pageName, elementName, state, timeout);
                return false;
            }
            const causeMsg = error instanceof Error ? error.message : String(error);
            throw new Error(`waitForState: '${pageName}.${elementName}' did not reach state '${state}' within ${timeout}ms. ${causeMsg}`);
        }
    }
```

Return type `Promise<void>` → `Promise<boolean>` is non-breaking for awaiting callers. Check `waitAndClick` directly below: it should NOT pass `optional` through implicitly — a `waitAndClick` on a missing element must throw (that's the honest default).

- [ ] **Step 5: Run the suite**

```bash
docker compose up -d && npx playwright test tests/wait-honesty.spec.ts && npm run test:unit
```

Expected: wait-honesty green. Pre-existing specs that *relied* on the swallow (a wait on a never-appearing element followed by unrelated assertions) will now fail — fix each by either adding `{ optional: true }` (when the probe is intentional) or fixing the test's real bug (when the wait was a disguised broken assertion). List every such change in the commit body — they are evidence of the trap.

- [ ] **Step 6: Commit**

```bash
git add src/utils/ElementUtilities.ts src/steps/CommonSteps.ts src/enum/Options.ts tests/wait-honesty.spec.ts tests/<any-fixed-specs>
git commit -m "feat(waits)!: waitForState throws on timeout; { optional: true } restores the soft probe

BREAKING CHANGE: steps.waitForState / Utils.waitForState reject on timeout
instead of logging a warning. Pass { optional: true } for the old behavior."
```

---

### Task 3: Interception-retry signal + opt-out (B2)

**Files:**
- Modify: `src/interactions/Interaction.ts` (~40-101), `src/fixture/BaseFixture.ts` (BaseFixtureOptions + ElementInteractions construction, ~16-41 and ~123-125), the `ElementInteractions` constructor that passes the timeout through (find via `grep -n "new Interaction" src/ -r`), `src/enum/Options.ts` if config types live there
- Test: Create `tests/interception-retry.spec.ts`

- [ ] **Step 1: Write the failing tests**

`tests/interception-retry.spec.ts` needs an overlay scenario. Check the vue-test-site for an existing overlay/cookie-banner page (`grep -ri "intercept\|overlay" tests/ src/` for prior art — the overlay-retry path is currently untested, per the audit). If the test app has no overlay element, add the scenario with `page.evaluate` injecting a covering div:

```ts
import { test, expect } from './fixtures';

async function coverWithOverlay(page) {
    await page.evaluate(() => {
        const o = document.createElement('div');
        o.id = 'test-overlay';
        o.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.01)';
        document.body.appendChild(o);
    });
}

test('fallback fires, annotates the test, and clicks through (default-on)', async ({ steps, page }, testInfo) => {
    await steps.navigateTo('/');
    await coverWithOverlay(page);
    await steps.click('someButton', 'HomePage');   // succeeds via dispatchEvent fallback
    const note = testInfo.annotations.find(a => a.type === 'interception-fallback');
    expect(note?.description).toContain('HomePage');
});
```

And a second spec file (fixture options are per-`baseFixture()` call) `tests/interception-retry-off.spec.ts` constructing the fixture with `interceptionRetry: false`, asserting the same click **rejects** with `intercepts pointer events`. (Look at how other option-variant specs instantiate a second fixture — `grep -rn "baseFixture(" tests/ | head` — and copy that pattern.)

Run → FAILS (no annotation; no config option).

- [ ] **Step 2: Add the config option + plumbing**

`BaseFixtureOptions` (src/fixture/BaseFixture.ts:16):

```ts
    /**
     * When a click is intercepted by an overlaying element, retry it as a
     * dispatched DOM click event. Default `true` (compat). Set `false` so
     * genuine overlay bugs (stuck modals, cookie walls) fail the click —
     * recommended for adversarial/bug-discovery suites.
     */
    interceptionRetry?: boolean;
```

Thread it: `BaseFixture` → `ElementInteractions` options → `Interaction` constructor (`constructor(private page: Page, timeout = 30000, private interceptionRetry = true)`). Follow exactly how `timeout` flows today (grep `new ElementInteractions` and `new Interaction`).

- [ ] **Step 3: Annotate + honor the flag in the retry**

Replace `clickWithInterceptionRetry` (src/interactions/Interaction.ts:89-101):

```ts
    private async clickWithInterceptionRetry(element: WebElement, timeout: number): Promise<void> {
        try {
            await element.click({ timeout: Math.min(timeout, 5000) });
        } catch (error: unknown) {
            const message = error instanceof Error ? error.message : String(error);
            if (message.includes('intercepts pointer events')) {
                if (!this.interceptionRetry) throw error;
                const detail = `click intercepted by another element — fell back to dispatchEvent('click'). ${message.split('\n')[0]}`;
                log.warn(detail);
                this.annotate('interception-fallback', detail);
                await element.dispatchEvent('click');
            } else {
                await element.click({ timeout });
            }
        }
    }

    /** Push a report-visible annotation when running inside a Playwright test. */
    private annotate(type: string, description: string): void {
        try {
            // Lazy import: Interaction is also usable outside test context.
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            const { test } = require('@playwright/test');
            test.info().annotations.push({ type, description });
        } catch {
            /* not in a test context — log line above is the only signal */
        }
    }
```

The element name isn't known at `Interaction` level — enrich `detail` with whatever context exists. If `ElementAction`/`Steps` is where `pageName.elementName` is known (it is — the Steps layer logs it), prefer adding the annotation at the Steps/ElementAction call site instead and keep `Interaction` emitting only the log: check `src/steps/` for where `click` catches/wraps, and put `annotate` at the layer that knows the names. **The test asserts the description contains the page name — implement at whichever layer makes that true.**

- [ ] **Step 4: Honest docs for force/withoutScrolling**

In `src/enum/Options.ts` ClickOptions/StepOptions JSDoc for `force` (line 337-338) and `withoutScrolling` (333-334), replace with:

```ts
    /** Dispatches a DOM 'click' event directly (no pointer simulation, no
     *  actionability checks). NOT Playwright's `force: true` — no scrolling,
     *  no hover, no pointer coordinates. Rename pending in a future major. */
    force?: boolean;
    /** Alias semantics of `force`: dispatches a DOM 'click' event without
     *  scrolling the element into view. */
    withoutScrolling?: boolean;
```

Mirror the same wording in the README's options table (`grep -n "force" README.md`).

- [ ] **Step 5: Run, commit**

```bash
npx playwright test tests/interception-retry.spec.ts tests/interception-retry-off.spec.ts && npm run test:unit
git add src/ tests/ README.md
git commit -m "feat(click): interception fallback is report-visible and opt-outable (interceptionRetry: false)"
```

---

### Task 4: Docs drift + test typechecking (B4)

**Files:**
- Modify: `README.md` (§Advanced Raw Interactions ~630-648, getText ~444, verifyCount ~455, matcher list ~232), `tsconfig.json` or new `tsconfig.tests.json`, `package.json` scripts, `tests/negative.spec.ts`, `test-coverage-report.txt` header (or the script that generates it)

- [ ] **Step 1: Add test typechecking (it will fail — that's the point)**

Create `tsconfig.tests.json`:

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": { "noEmit": true, "rootDir": "." },
  "include": ["src/**/*", "tests/**/*"]
}
```

package.json: `"typecheck:tests": "tsc -p tsconfig.tests.json"`, and prepend it to `test:unit`: `"test:unit": "npm run typecheck:tests && npx playwright test --grep-invert 'Email Integration Tests'"`.

Run `npm run typecheck:tests` → expect errors in `tests/negative.spec.ts` (raw `Locator` passed to WebElement-only APIs) and possibly others. That error list is the work inventory for Step 2.

- [ ] **Step 2: Fix the fallout**

For each raw-Locator usage in `tests/negative.spec.ts` (e.g. `fast.interact.click(missing)` at ~line 21): replace the raw `page.locator(...)` with a repository-resolved element that is *absent* (the file already has the "missing element" pattern — use the repo entry it defines for that purpose, or `repo.get('nonexistentElement', 'HomePage')`). The tests must still assert rejection — now for the right reason (absent element) rather than a type-confusion crash. Re-run each fixed test individually to confirm it still fails-then-passes for the documented reason.

- [ ] **Step 3: README truth pass**

- §"Advanced: Raw Interactions API" (lines ~630-648): rewrite to the WebElement-only reality — methods accept `WebElement` from `repo.get(...)`; the sanctioned escape hatches are `(element as WebElement).locator` for element-level raw access and the `page` fixture for page-level APIs the facade doesn't cover (dialogs, downloads). Delete the "accept both Locator and Element" sentence and the `customLocator` example.
- getText (~line 444): "Returns `null` when the element has no text" (matches `Extraction.ts:25-29`).
- verifyCount (~line 455): document the `greaterThanOrEqual` / `lessThanOrEqual` variants from `CountVerifyOptions`.
- Matcher list (~line 232): add `html`, `outerHtml`.
- waitForState example (~line 325): now truthful post-Task 2 — update the snippet to show both modes:

```ts
await steps.waitForState('confirmationModal', 'CheckoutPage', 'visible');      // throws on timeout (0.4.0+)
const open = await steps.waitForState('promoBanner', 'HomePage', 'visible', { optional: true }); // probe
```

- [ ] **Step 4: Relabel the coverage claim**

Find what writes `test-coverage-report.txt` (`@civitas-cerebrum/test-coverage`, script `test:with-coverage`). If the header text is package-controlled, add a README line where the report is referenced: "this is **API (method-invocation) coverage** — every public method exercised at least once — not line/branch coverage." If the file is committed, edit its header line `OVERALL: 281/281 (100.0%)` context to say `API coverage (method invocation)`.

- [ ] **Step 5: Run everything, commit**

```bash
npm run test:unit
git add README.md tsconfig.tests.json package.json tests/negative.spec.ts test-coverage-report.txt
git commit -m "docs+test: README matches the real API; tests are typechecked (raw-Locator drift eliminated)"
```

---

### Task 5: Version 0.4.0, CHANGELOG, release PR

- [ ] **Step 1: CHANGELOG**

Create/append `CHANGELOG.md`:

```markdown
## 0.4.0 — 2026-06-XX

### Breaking
- `steps.waitForState` / `Utils.waitForState` now THROW on timeout. Pass
  `{ optional: true }` to probe without failing (returns boolean).

### Added
- `StepOptions.timeout` — per-call timeout override on waitForState.
- `BaseFixtureOptions.interceptionRetry` (default `true`) — set `false` to
  make intercepted clicks fail instead of falling back to dispatchEvent.
- Interception fallback now pushes a `interception-fallback` test
  annotation (visible in HTML reports) whenever it fires.
- `typecheck:tests` — the test suite is now typechecked.

### Fixed
- `@civitas-cerebrum/sql-client` resolved from the registry (`file:` dep
  made the package unpublishable).
- README: removed the raw-Locator API section (removed in 0.2.6),
  corrected `getText` null contract, documented verifyCount gte/lte
  variants and the html/outerHtml matchers.
```

- [ ] **Step 2: Bump + verify**

```bash
npm version 0.4.0 --no-git-tag-version
npm run check:publishable && npm run build && npm run test:unit && npm pack --dry-run | head
git add package.json package-lock.json CHANGELOG.md
git commit -m "chore(release): 0.4.0"
```

- [ ] **Step 3: PR**

```bash
git push -u origin feat/0.4.0-integrity
gh pr create --title "0.4.0: waits that can fail, visible interception fallback, publishable package" --body "<task summaries; link to achilles spec; BREAKING note>"
```

Publishing 0.4.0 to npm and bumping achilles' dependency (`"@civitas-cerebrum/element-interactions": "^0.3.6"` → `^0.4.0`) happens after merge — user-gated, same as Task 1 Step 2.

---

## Self-review notes (already applied)

- Spec §B1-B4 → Tasks 2,3,1,4; release mechanics in Task 5. No spec item unplaced.
- B1 ripple risk (internal pre-wait callers) is called out with the exact grep; B2 annotation layer ambiguity is resolved by the test's assertion (page name must appear), letting the implementer pick the layer that knows the name.
- B3's optional-dependency branch was eliminated during planning by verifying the eager import (CommonSteps.ts:7) — decision recorded in Task 1 preamble.
- Both user-gated npm publishes (sql-client, 0.4.0) are explicit blocking steps, not assumptions.
