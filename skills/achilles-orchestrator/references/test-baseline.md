# Test baseline: the rulebook for test code

The one canonical home of every rule that test code written or edited by Achilles follows: specs, support modules, evidence bundles and k6 scripts. Each rule has a short id (`TB-<family><n>`); other files cite it as `test-baseline.md#tb-<id>` and never restate it. The first sentence of a rule is its normative sentence; Achilles' own documentation checks keep cited ids resolvable and keep normative sentences out of other skills.

**Who checks the rules today.** The author checks every touched test against this file in the Stage 4b sweep ([`stages-protocol.md`](stages-protocol.md)); at a composing exit the composition judge (which re-checks a sample) or the Stage B reviewer reads it again from the code and the scenario ([`test-composition-standards.md`](test-composition-standards.md) §4); an incremental heal gets the author's sweep only. **Mechanical** rules are written so a machine can decide them from the code; **judgment** rules need a reader. The lint `achilles-spec-lint` decides the mechanical rules from the code and reports its findings (three lines each, or `--json`); Achilles itself refuses nothing on them yet. A project that records a compliance baseline binds commits through its own pre-commit hook and CI ([Baseline and ratchet](#baseline-and-ratchet)). The rules it cannot decide yet ([TB-A6](#tb-a6), [TB-G2](#tb-g2)) and every judgment rule are still applied by reading.

## Contents

- [Fields](#fields) · [Severity](#severity) · [Baseline and ratchet](#baseline-and-ratchet) · [Scope](#scope) · [Driver bindings](#driver-bindings)
- [Waivers](#waivers) · [Defect pointers and sentinels](#defect-pointers-and-sentinels) · [Framework gaps and version gaps](#framework-gaps-and-version-gaps)
- Rules: [A framework surface](#family-a-framework-surface) · [F flow control](#family-f-flow-control) · [S structure](#family-s-structure) · [I identity](#family-i-identity) · [R readability and the oracle](#family-r-readability-and-the-oracle) · [D data, types and secrets](#family-d-data-types-and-secrets) · [W timeouts](#family-w-timeouts) · [X support files](#family-x-support-files) · [P platform](#family-p-platform) · [N API and database](#family-n-api-and-database) · [K k6](#family-k-k6) · [G governance](#family-g-governance)

## Fields

Every rule carries these fields:

- **Source**: `W` a written Achilles rule, `R` a pattern of the reference project the baseline is derived from, `N` a new mechanical form.
- **Kind**: `mechanical` (decidable from the code alone) or `judgment` (needs a reader: the author in the sweep, then the judge or reviewer). A rule may have both parts.
- **Severity**: see [Severity](#severity).
- **Applies to**: `spec`, `support`, `bundle`, `k6` (see [Scope](#scope)).
- **Detection**: the code shape that breaks the rule, or the question the reader answers.
- **Exceptions**: the only ways out; anything not listed is a finding.
- **Example**: a non-compliant and a compliant snippet.

## Severity

- **blocking**: the finding must be fixed before the change is accepted: the author fixes it in the sweep, and the judge or reviewer returns it as must-fix. A mechanical rule is blocking only when its definition showed at most 5% false positives on hand-checked live suites, or when its shape is exact or structural by construction (a path, a token, a parse result, an exact import or method name, or an AST shape that is the banned construct itself) with no false positive observed and full recall on a seeded corpus of breaking lines. A rule blocks because its shape is exact, not because it was rare.
- **advisory (unmeasured)**: a clause with no live measurement yet. It is reported and counted, and becomes blocking in this file (one commit) once a live measurement confirms it.
- **advisory**: reported and counted, never must-fix on its own.
- **unwaivable**: no waiver applies (see [Waivers](#waivers)).

Judgment rules block through the judge's or reviewer's verdict. A false positive found later downgrades a rule here (one commit to this file), never per project.

**Only the touched test must be clean.** A blocking finding counts against a change when it sits in a test the change adds or edits, or in a describe-level or file-level construct the change itself touches. Findings in untouched tests of the same file are legacy: recorded and reported, not charged to the change. `achilles-spec-lint --staged` (the index against `HEAD`) or `--base <ref>` (the working tree against the merge-base) marks each finding touched or legacy.

## Baseline and ratchet

An existing suite adopts the rules without fixing every legacy finding first: it records a **compliance baseline**, and from then on the count of blocking findings only goes down. Nothing changes for a project until it records one.

- **The file.** `tests/compliance-baseline.json` (schema `schemas/compliance-baseline.schema.json` in the Achilles package) holds, per file, the blocking findings of the rules its **ruleset** counts, in three buckets: per test (its id, else its title and ordinal), per describe scope outside every test, and the file scope; per-file sums and suite totals; the waived findings per rule; the pinned test-id pattern (`idPattern`, a pattern or `house-default`, see [TB-I1](#tb-i1)); the commit it was recorded from. Advisory findings are not recorded, and neither are [TB-S8](#tb-s8) and [TB-A13](#tb-a13), which are decided per change.
- **Recording it.** `achilles-spec-lint --init-baseline` reads `HEAD` only (uncommitted work is not forgiven), pins the id pattern the titles already use (or records the house default), installs the pre-commit check and writes the file. Commit the baseline and the hook alone as `chore(test): compliance baseline`, then the change. The init is refused when the file exists, or existed in any ancestor commit, and in a shallow clone (where that cannot be checked): a deleted baseline is restored, never recorded again (recording again would forgive every finding it counted). CI fails a change that adds a baseline where an ancestor of the merge-base held one.
- **What a change may do.** New files and the tests, describe scopes and file scopes a change touches have no blocking findings ([Severity](#severity)). Untouched code may not gain any: per file, rule and bucket, and in the totals, the untouched findings stay at or below the baseline. Counts are recomputed from the code every time, so a count lowered by hand fails, and a change to a support module, a fixture or the framework version that adds findings to tests the change did not touch fails too. Renames carry their entry (the pairs `git diff -M` reports; a rename is touched only when its content changed).
- **Which copy counts.** The ratchet compares with the baseline at the merge-base of the change (`--ratchet --base <ref>`), or at `HEAD` for a commit (`--pre-commit`), never with the change's own copy; when that copy is corrupt, the last valid copy before it is the reference, so the change that repairs it can pass. The change's copy may only be lowered, never below what the code has and never above the reference; deleting it, or changing its id pattern or its recorded pre-commit check, fails. It is a protected input ([TB-G2](#tb-g2)).
- **Which rule inputs count.** The checks read the protected inputs of [TB-G2](#tb-g2) (the factory rules' `specs.*` and `secrets.*` rules, the id pattern in a committed `.env`, the framework-gap register, the Playwright configs' `grep`, `grepInvert`, `testIgnore` and `testMatch`) from the reference commit, never from the change: CI from the merge-base, failing a change that weakens one; the pre-commit check from `HEAD`, naming such a change.
- **Lowering it.** `achilles-spec-lint --update-baseline` writes the lower of the recorded and the actual count per bucket and never raises one. A rule that becomes blocking, or whose blocking definition widens, comes in a new ruleset that names it (each one has a line in the Achilles changelog). Until `--update-baseline --ruleset-upgrade` records such a rule, it is held to its count in the reference commit's own code, and the upgrade may record no more than that count: the upgrade is a change of its own that touches only the baseline file, so a regression cannot ride along.
- **Where it binds.** The pre-commit check (`--pre-commit`) checks the commit's real content and blocks only on findings; when the lint cannot run it warns and lets the commit through. It is installed in `.githooks/` with a local `core.hooksPath`, or chained into an existing hooks setup (husky, lefthook, a hooks directory inside the work tree, a local hooks directory that already runs a hook), called first so the existing hook keeps its own result, never overwriting it and never writing outside the repository: a hooks path outside the work tree is left alone, with the line to add by hand, and dormant hooks under `.githooks/` are not switched on unless named with `--activate-hooks`. CI runs `achilles-spec-lint --ci --base origin/<default-branch>`: the touched lint, the ratchet against the merge-base baseline, and the copy check (any increase or deletion fails), with the deleted test ids and the waiver changes listed. Review records are not part of CI. Another clone installs the check once with `--install-hook` (git does not clone `core.hooksPath`).

## Scope

| Kind | Files |
|---|---|
| `spec` | any file a Playwright config would run as a test, plus any code file under the spec roots that calls `test(`, `describe(` or `it(` on a test binding |
| `support` | non-spec code under the spec roots that a spec imports (transitively); everything under `fixtures/`, `flows/`, `data/`, `support/`, `utils/`, `lib/`, `helpers/`; a `*.setup.*` file only when a config uses it as a setup project (any other `*.setup.*` that declares tests is a spec); a `globalSetup` or `globalTeardown` module a config names |
| `k6` | files under `tests/perf/**` |
| `bundle` | a directory under an `evidence/` folder with a `summary.md` sibling that no config's test glob matches |
| excluded | `tests/e2e/inspect/**` (except [TB-S8](#tb-s8)), `node_modules`, reports, `.d.ts`, JSON |

Spec roots and globs come from every `playwright*.config.*` (`testDir`, `testMatch`, `testIgnore`, per-project values), plus Playwright's default `testMatch` and `tests/**`.

## Driver bindings

A **driver binding** is a value of kind page, frame, context, browser, request, locator or element-locator: a fixture parameter (`page`, `fx.page`), a custom fixture whose type or `use(…)` value is one, a variable or parameter initialised or annotated as one (including one assigned later in a hook), a destructured member (`const { keyboard } = page`), the `.locator` of a repository element, and the reach-through forms of [TB-A14](#tb-a14). Calls rooted at `steps`, `repo` or `interactions` are framework calls, never driver calls. Regions: test, hook, describe, module, helper, nested function, browser code (inside `evaluate`), fixtures-module fixture, spec-local fixture (`test.extend` in a spec is checked like a test).

## Waivers

A waiver excuses one statement from one waivable rule. It sits in the comment line directly above the statement:

```ts
// achilles-allow TB-<id> -- <reason of at least 15 characters> [gap: FG-<n>]
```

- The reason names the actual obstacle, not a stock word; `[gap: FG-<n>]` is required when the obstacle is a framework gap. A [TB-A1](#tb-a1) waiver covers only the escape-hatch form ([Framework gaps](#framework-gaps-and-version-gaps)) and always carries `[gap: FG-<n>]` naming a row whose raw methods include `locator (escape hatch)`; no seed row does, so a project that needs the hatch adds such a row, which is a [TB-G2](#tb-g2) rule-input change. A [TB-A2](#tb-a2) waiver applies only to a method with no Steps equivalent in the installed release and always carries `[gap: FG-<n>]` naming a row whose raw methods include that method. On any other waiver of a raw call, a gap token names a row that covers the call's method.
- One raw call per waived statement. A waiver directly above a test whose callback is a single expression excuses the one raw call in that expression and counts toward that test.
- A waiver that excuses no finding is removed.
- **Caps:** at most 2 waivers per test, per hook and per helper function, and per gap row the count recorded in the register, counted over the whole suite. File splits gain nothing.
- A raw call from the no-equivalent table ([TB-A2b](#tb-a2b)) is not waived but cited: `// framework-gap: FG-<n>` directly above it, inside a verb or fixture.
- The author writes a waiver; the judge or reviewer decides whether it stands, never the author. A waiver citing a row marked `fixed-in <version>` is a blocking [TB-G1](#tb-g1) finding.
- **Unwaivable:** [TB-A5](#tb-a5) in durable files, [TB-A13](#tb-a13), [TB-F5](#tb-f5) `waitForTimeout` and `pause` in specs, [TB-F6](#tb-f6) `.only`, [TB-D2](#tb-d2), [TB-S8](#tb-s8), [TB-G0](#tb-g0), [TB-G1](#tb-g1), [TB-G2](#tb-g2).

## Defect pointers and sentinels

**Pointer grammar.** Every `@known-defect` test or describe and every `test.fail` sentinel carries a line `// defect: <ref>` in its own contiguous comment block, directly above its `test(` or `describe(` call. A pointer above a `@known-defect` describe covers the tests inside that describe; a pointer never covers any other test in the file, and one comment at the top of the file covers nothing. `<ref>` is one of:

- a repo-relative path with an optional `#anchor` that exists: a bug report, `tests/e2e/docs/adversarial-findings.md#<finding-id>`, a known-issues register entry;
- a tracker key `<KEY>-<n>`;
- a defect id `<TICKET>-D<n>` (the ticket key plus a defect number, e.g. `SHOP-12-D1`) recorded under `.achilles/defect-confirmations/`.

Anchors follow the GitHub heading slug rule (lower-case, spaces to `-`, punctuation other than `-` and `_` removed), or an explicit `<a id="…">`. Paths and anchors must resolve in the repository; tracker keys are checked for shape only; `<TICKET>-D<n>` ids resolve against `.achilles/defect-confirmations/` where that directory exists and are checked for shape elsewhere (CI, where it is gitignored).

**The two accepted `test.fail` sentinel forms.** Both assert the correct behaviour, carry `@known-defect`, and include the defect's own assertion with a message naming the key, so a sentinel that fails for another reason (a broken selector) is visible to whoever reads the failure.

```ts
// (a) verify-change sentinel: the defect id sits in the title
// defect: SHOP-12-D1
test('TCCK-000310 · [SENTINEL SHOP-12-D1] a cancelled order is not charged @known-defect', async ({ steps }) => {
  test.fail(true, 'SHOP-12-D1: a cancelled order is charged. Delete this sentinel once fixed.');
  await steps.verifyText('chargeStatus', 'OrderPage', 'Not charged');
});

// (b) register sentinel: the key is the first token of the test.fail reason
// defect: tests/e2e/docs/known-issues.md#l3
test('TCST-000120 · the badge count matches the inbox @known-defect', async ({ steps }) => {
  test.fail(true, 'L3: the badge counts archived messages');
  await steps.verifyText('inboxBadge', 'HomePage', '2');
});
```

Form (a) is preferred for new sentinels. Any other use of `test.fail` is a [TB-F6](#tb-f6) finding. The lifecycle (when a sentinel is written, when it is deleted) is verify-change phase 7 ([`verify-change/phase-7-durable-tests.md`](verify-change/phase-7-durable-tests.md)); the no-rerun contract is [`test-identity.md`](test-identity.md) §2.

## Framework gaps and version gaps

**Version gap: upgrade first.** When a raw call's Steps equivalent exists in a newer `@civitas-cerebrum/element-interactions` release than the project's installed one, the remedy is the upgrade ([TB-A13](#tb-a13)), done as the first unit of work the next time a workflow touches the suite. A version gap is never a register row and never a waiver.

**Framework gap.** A capability the framework lacks in every release is recorded in the project's register, `tests/e2e/docs/framework-gaps.md`, one row per capability:

| Row | Missing capability | Raw methods covered | Waiver cap | Status | Upstream issue |
|---|---|---|---|---|---|
| FG-<n> | what a test needs | every raw method the row allows, each in backticks (`context.cookies`, `addCookies`, `page.on('console')`); `locator (escape hatch)` for a row that allows the TB-A1 escape hatch | waivers allowed across the suite | `open` or `fixed-in <version>` | link, when filed |

Register rules:

- A row is valid only when every method it lists is in the no-equivalent table ([TB-A2b](#tb-a2b)), or is the `locator (escape hatch)` token; a row naming a method that has a Steps equivalent is a [TB-G1](#tb-g1) finding. Until rulings have a recorded form the lint can read, a row for a method in neither table stays a [TB-G1](#tb-g1) finding until an Achilles release adds the method to the no-equivalent table; the person's decision is recorded in `resume.json` `rulings[]` as [TB-G2](#tb-g2) describes.
- Adding or changing a row is a [TB-G2](#tb-g2) rule-input change, decided only by the person through the escalation path of [TB-G2](#tb-g2). This holds in particular for a method in neither table.
- The escape hatch for a gap that needs a raw locator keeps the selector in the repository and goes through the framework's interactions: `interactions.interact.<method>(new WebElement(page.locator(repo.getSelector('<element>', '<Page>'))))`, one raw call per waived statement ([`framework-gap.md`](framework-gap.md) has the procedure).

**Seed rows** (a new register starts with these):

| Row | Missing capability | Raw methods covered | Note |
|---|---|---|---|
| FG-1 | cookie management | `context.cookies`, `addCookies`, `clearCookies` | session reset and expiry |
| FG-2 | network mocking | `route`, `unroute`, `unrouteAll` | waits inside route handlers are not [TB-F5](#tb-f5) |
| FG-3 | console, page error and request capture | `page.on('console' \| 'pageerror' \| 'request')` | |
| FG-4 | real keyboard focus | `locator.focus()` | `dispatchEvent('focus')` is synthetic |
| FG-5 | dialog capture on web | `page.on('dialog')` | check `acceptAlert` / `dismissAlert` on web before citing |
| FG-6 | a second signed-in browser context | `browser.newContext`, `newPage`, `close` | a project fixture owns it; check `steps.forPage` first |

## Family A: framework surface

<a id="tb-a1"></a>
#### TB-A1 No raw locators

A spec reaches elements only by repository name through the Steps API, never through a locator method on a driver binding.

- **Source** W, R · **Kind** mechanical · **Severity** blocking · **Applies to** spec; support through [TB-A12](#tb-a12)
- **Detection**: `locator`, `getBy*`, `frameLocator`, `$`, `$$` on a driver binding in any region of a spec, spec-local `test.extend` bodies included. A chain reports once. Repository calls (`repo.get`, `repo.getByText`) are never hits; `repo.driver` is [TB-A14](#tb-a14).
- **Exceptions**: a framework gap in the escape-hatch form ([Framework gaps](#framework-gaps-and-version-gaps)) with a waiver whose `[gap: FG-<n>]` names a register row listing `locator (escape hatch)` ([Waivers](#waivers)).

```ts
// Non-compliant
const text = await page.locator('main').innerText();
// Compliant
await steps.verifyPresence('scheduleSummary', 'DashboardPage');
```

<a id="tb-a2"></a>
#### TB-A2 No raw calls that have a Steps equivalent

A spec makes no member call on a driver binding unless the method appears in the no-equivalent table or is a plain accessor.

- **Source** W · **Kind** mechanical · **Severity** blocking · **Applies to** spec
- **Detection**: any member call on a driver binding except the [TB-A2b](#tb-a2b) table and the accessors `context()`, `mainFrame()`, `frames()`. `waitForEvent('popup' | 'page')` is a hit (`steps.switchToNewTab`); `waitForEvent` with another literal event is an event capture in the [TB-A2b](#tb-a2b) table; `waitForEvent` with a non-literal event is a hit (no known Steps equivalent). A method in neither table is a hit too ("no known Steps equivalent": it needs an entry in the no-equivalent table, which is an Achilles release, or a register row, which is the person's decision). A computed member with a non-literal key (`page[m]()`) is a hit.
- **Equivalents by version**: an equivalent is read from the published package surface of each release (raw method, Steps method, first release that has it), never from documentation alone. An equivalent counts only when it exists in the project's installed release; otherwise the site is [TB-A13](#tb-a13).
- **HTTP**: `get`, `post`, `put`, `patch`, `delete`, `head` on a request binding map to `steps.request*` (browser session) or `steps.api*` (own client, no browser session); `fetch` is unlisted; `dispose` is in the no-equivalent table. Below the release that has `request*`, a `context.request.*` or `page.request.*` call has no equivalent (the strict reading) and is [TB-A13](#tb-a13); reading `api*` as its equivalent is the person's decision (escalated as in [TB-G2](#tb-g2)), because the code alone does not show whether the call carries its own auth header.

```ts
// Non-compliant
await page.goto('/login');
// Compliant
await steps.navigateTo(Routes.LOGIN);
```

<a id="tb-a2b"></a>
#### TB-A2b Raw calls with no Steps equivalent

A raw call that the Steps API cannot replace lives in a verb or a fixture, or carries the framework-gap citation of its register row.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** advisory in specs (mechanical); blocking by judgment · **Applies to** spec; allowed in fixtures and verbs with the citation of its register row (advisory without it)
- **Detection**: the no-equivalent table: `page.on('console' | 'pageerror' | 'request' | 'dialog')`, `route`, `unroute`, `unrouteAll`, `context.cookies`, `addCookies`, `clearCookies`, `browser.newContext`, `newPage`, `close`, `locator.focus()`, `waitForEvent('download' | 'filechooser')`, request `dispose`, and the mutation-hook calls of [TB-X2](#tb-x2), each with its register row; and, with no seed row yet, listeners for other events (`on`, `once`, `off`, `removeListener`, and `waitForEvent` with a literal event other than `popup`, `page`, `download` and `filechooser`), `storageState`, `grantPermissions`, `clearPermissions`, `setOffline`, `setGeolocation`, `setExtraHTTPHeaders`, `context.pages`, `page.isClosed`, `bringToFront` and `video`.
- **Judgment**: in a spec, the call belongs in a verb or fixture, or carries `// framework-gap: FG-<n>` naming the matching row.

```ts
// Non-compliant (in a spec, no citation)
await context.clearCookies();
// Compliant (fixtures module; the spec calls `await clearSessionCookies()`)
clearSessionCookies: async ({ context }, use) => {
  // framework-gap: FG-1
  await use(() => context.clearCookies());
},
```

<a id="tb-a3"></a>
#### TB-A3 No web-first assertions on page, locator or response

Assertions about pages, elements and responses go through `steps.verify*` or `steps.expect`, never through Playwright's web-first matchers.

- **Source** W · **Kind** mechanical · **Severity** blocking; `toBeOK` advisory (unmeasured) · **Applies to** spec
- **Detection**: `expect(x).<matcher>` where the matcher applies only to a Locator, Page or APIResponse: `toBeVisible`, `toBeHidden`, `toBeEnabled`, `toBeDisabled`, `toBeChecked`, `toBeEditable`, `toBeFocused`, `toBeInViewport`, `toBeAttached`, `toBeEmpty`, `toHaveText`, `toHaveValue`, `toHaveValues`, `toHaveCount`, `toHaveAttribute`, `toHaveClass`, `toHaveCSS`, `toHaveId`, `toHaveRole`, `toHaveURL`, `toHaveTitle`, `toHaveScreenshot`, `toHaveAccessibleName`, `toHaveAccessibleDescription`, `toHaveAccessibleErrorMessage`, `toHaveJSProperty`, `toContainText`, `toContainClass`, `toMatchAriaSnapshot`.
- **Not a hit**: `expect(value)` on plain data read through the Steps API.

```ts
// Non-compliant
await expect(page.getByRole('alert')).toBeVisible();
// Compliant
await steps.verifyPresence('errorAlert', 'LoginPage');
expect(unknownAccountMessage?.trim()).toBe(knownAccountMessage?.trim());
```

<a id="tb-a4"></a>
#### TB-A4 No page scripting

A spec never runs script inside the page through a driver binding.

- **Source** W · **Kind** mechanical · **Severity** blocking · **Applies to** spec
- **Detection**: `evaluate`, `evaluateHandle`, `$eval`, `$$eval`, `addInitScript`, `addStyleTag`, `exposeFunction`, `exposeBinding` on a driver binding. A comment saying the Steps method "does not exist" in a project on an older release is a version gap ([TB-A13](#tb-a13)): upgrade, do not waive.
- **Exceptions**: the mutation hooks of [TB-X2](#tb-x2) in the fixtures module.

```ts
// Non-compliant
const theme = await page.evaluate(() => localStorage.getItem('theme'));
// Compliant
const theme = await steps.getLocalStorage('theme');
```

<a id="tb-a5"></a>
#### TB-A5 No inline selectors

Durable test code addresses every element by its page-repository name and never carries a selector string of its own.

- **Source** W, R · **Kind** mechanical · **Severity** blocking, unwaivable in durable files · **Applies to** spec, support; `bundle` exempt
- **Detection**: a string, template or regex literal as the first argument of a [TB-A1](#tb-a1) call, of `waitForSelector`, or of `steps.on(…).findBySelector(…)`; a selector-shaped literal passed as an element or page name to `steps.*` (an argument the installed release names `elementName` or `pageName`). Never hits: URL-taking steps (`navigateTo`, `waitForUrl`, `waitForResponse`, `verifyUrlContains`, `api*`, `request*`, `openDeepLink`, `expectNoRequest`); a literal inside a callback whose only consumer is `expect(cb).toThrow(…)` or `expect(cb).rejects…`, or inside a call whose promise only `expect(…).rejects…` consumes (a refusal test never resolves it). The project's `selectors.no-inline.forbidden` strings are an extra input, advisory (unmeasured).
- **Exceptions**: an evidence bundle may carry bundle-scoped selector proposals; they become repository entries when the scenario graduates to a durable test ([`test-composition-standards.md`](test-composition-standards.md) §3.1).

```ts
// Non-compliant
await steps.on('row', 'CartPage').findBySelector('button.remove').click();
// Compliant
await steps.click('removeItemButton', 'CartPage');
```

<a id="tb-a6"></a>
#### TB-A6 Repository names resolve

Every element and page name a test hands to the framework names an entry of the page repository the fixture loads.

- **Source** W, N · **Kind** mechanical · **Severity** advisory until a mechanical check can resolve the repository exactly as the fixture does (resolved path, generated repository, page names merged across platforms), then blocking; retyping the repository path outside the fixtures module: advisory · **Applies to** spec, support
- **Detection**: every literal or file-constant `(elementName, pageName)` pair passed to `steps.*`, `steps.on`, `steps.expect` or `repo.*`, and every `child: { pageName, elementName }`.

```ts
// Non-compliant (no `submitBtn` on LoginPage in the repository)
await steps.click('submitBtn', 'LoginPage');
// Compliant
await steps.click('submitButton', 'LoginPage');
```

<a id="tb-a7"></a>
#### TB-A7 Imports come from the fixtures module

A spec takes `test` and `expect` from the project's fixtures module and no value import from any Playwright package.

- **Source** W, R · **Kind** mechanical · **Severity** blocking · **Applies to** spec
- **Detection**: a value import or `require()` of `@playwright/test`, `@playwright/test/*`, `playwright` or `playwright-core` in a spec. `import type` is allowed.

```ts
// Non-compliant
import { test, expect } from '@playwright/test';
// Compliant
import { test, expect } from '../fixtures/base';
```

<a id="tb-a8"></a>
#### TB-A8 Signatures and option shapes

Every framework call matches the signature, argument order and option shape of the installed release as the API reference documents it.

- **Source** W · **Kind** judgment, plus `tsc --noEmit` · **Severity** blocking · **Applies to** spec, support
- **Detection**: element name before page name; types (`DropdownSelectType`, `EmailFilterType`, `FillFormValue`) imported from the framework packages, nothing invented; `DropdownSelectType` with its companion field; the email API signatures and filters; wait states `'visible' | 'hidden' | 'attached' | 'detached'`; `verifyCount` with `{ exactly | greaterThan | lessThan }`; a bare `verifyText()` asserts non-empty. The surface is [`api-reference.md`](api-reference.md).

```ts
// Non-compliant
await steps.click('LoginPage', 'submitButton');
// Compliant
await steps.click('submitButton', 'LoginPage');
```

<a id="tb-a9"></a>
#### TB-A9 Fixtures requested

A test callback asks only for the framework's fixtures, the project's own fixtures and Playwright's option fixtures.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** advisory (mechanical); blocking by judgment · **Applies to** spec
- **Detection**: fixtures outside `steps`, `repo`, `interactions`, `contextStore`, `page`, the project's `extend` keys and Playwright's option fixtures (`baseURL`, `locale`, `colorScheme`, `ignoreHTTPSErrors`, `video`, `trace`, `launchOptions`, and the rest of that list).
- **Judgment**: `browser` or `context` in a spec only through a project fixture that owns its teardown, a verb, or a gap citation.

```ts
// Non-compliant
test('TCLG-000130 · a second session sees the change', async ({ browser }) => { const ctx = await browser.newContext(); /* … */ });
// Compliant
test('TCLG-000130 · a second session sees the change', async ({ steps, otherUserSession }) => { /* … */ });
```

<a id="tb-a10"></a>
#### TB-A10 Steps methods and fixtures exist

Every `steps.<method>` a test calls is a public method of the framework release the project has installed.

- **Source** N · **Kind** mechanical · **Severity** blocking (methods); advisory (unmeasured) for undeclared fixture names · **Applies to** spec, support
- **Detection**: compare with the installed surface: `CommonSteps.d.ts` of `@civitas-cerebrum/element-interactions` in the worktree's `node_modules`, else the main checkout's, else the surface shipped with Achilles for the release the project pins. When none resolves, the check cannot be made: say so in the return rather than assume a method exists.

```ts
// Non-compliant (no such method)
await steps.getLocator('submitButton', 'LoginPage');
// Compliant
await steps.verifyState('submitButton', 'LoginPage', 'enabled');
```

<a id="tb-a11"></a>
#### TB-A11 A driver binding does not leave the spec

A spec never hands a page, context, browser, request, frame or locator to a function it calls.

- **Source** N, R · **Kind** mechanical · **Severity** blocking (direct form); advisory (unmeasured) for the extended forms · **Applies to** spec
- **Detection, direct form**: a driver binding, including the [TB-A14](#tb-a14) forms, passed as a call argument to any callee except `new WebElement`, `new ElementInteractions`, `new Steps`, `new ElementRepository`, `steps.forPage`, `expect`, `test.step`, `use`, and `Promise.all` / `race` / `allSettled` over call expressions. A callee rooted at `steps`, `repo` or `interactions` never counts.
- **Extended forms**: the binding inside an object, array or spread argument; a closure returning it; `page.keyboard`, `page.mouse`, `page.touchscreen`; a repository element whose `.locator` the helper reads; `Promise.resolve(page).then(helper)`; returning the binding from a test or hook; storing it on an object, a module variable or `contextStore`.
- **Exceptions**: a gap that needs the page (FG-6) is owned by a project fixture, not passed from the spec.

```ts
// Non-compliant
await clickCss(page, '#pay');
// Compliant
await signIn(steps, user);
```

<a id="tb-a12"></a>
#### TB-A12 Raw calls in support modules only in wiring shapes

Support modules drive the UI through the Steps API, and raw Playwright appears there only in the sanctioned wiring shapes.

- **Source** W, R · **Kind** mechanical · **Severity** blocking for UI-driving raw calls in new or touched support functions; advisory (unmeasured) for HTTP raw calls · **Applies to** support
- **Detection**: the [TB-A1](#tb-a1) to [TB-A4](#tb-a4) and [TB-P1](#tb-p1) shapes in verb, data and helper modules outside the wiring allowlist: (a) fixtures-module `.extend` / `baseFixture` bodies that construct framework objects, or that set up and tear down state without driving the UI (a fixture that hands out a UI-driving function is a verb, [TB-X1](#tb-x1)); (b) route handlers whose enclosing statement cites a gap row; (c) the mutation hooks of [TB-X2](#tb-x2); (d) API back-door helpers ([`test-optimization.md`](test-optimization.md) §4) whose only driver use is a request binding and that drive no UI; (e) [TB-A2b](#tb-a2b) calls with a gap citation.
- **Legacy modules**: a touched spec's imports are followed. Findings in an untouched module it reaches are reported in the return, not charged to the change; the spec side of a wrapper is already [TB-A11](#tb-a11).

```ts
// Non-compliant (flows/checkout-flow.ts)
export async function openCart(steps: Steps, page: Page) { await page.click('#cart'); }
// Compliant
export async function openCart(steps: Steps) { await steps.click('cartButton', 'HeaderPage'); }
```

<a id="tb-a13"></a>
#### TB-A13 The framework is too old for the equivalent

A raw call whose Steps equivalent ships only in a newer framework release is fixed by upgrading the framework, never by keeping or waiving the raw call.

- **Source** N · **Kind** mechanical · **Severity** blocking in new and touched tests, unwaivable; advisory for legacy sites · **Applies to** spec
- **Detection**: a [TB-A2](#tb-a2) or [TB-A4](#tb-a4) hit whose equivalent exists only in a release newer than the installed one, and (strict reading) `context.request.*` / `page.request.*` below the release that has `request*`. Reported once per project ("upgrade `@civitas-cerebrum/element-interactions` to ≥ <version>, then use `<method>`; <n> call sites") and per site.
- **Exceptions**: none. The upgrade is the first unit of work the next time a workflow touches the suite; see [Framework gaps and version gaps](#framework-gaps-and-version-gaps).

```ts
// Non-compliant (installed release predates evaluateScript)
// evaluateScript does not exist in our version
const width = await page.evaluate(() => window.innerWidth);
// Compliant (after the upgrade)
const width = await steps.evaluateScript(() => window.innerWidth);
```

<a id="tb-a14"></a>
#### TB-A14 No reach-through to the driver behind framework objects

Test and support code never reaches the driver through a framework object's fields, reflection or a type escape.

- **Source** N · **Kind** mechanical · **Severity** blocking (exact); advisory (unmeasured) for untyped parameters · **Applies to** spec, support
- **Detection**: `repo.driver`, `repo._driver`, and any member named `page` or `driver` on a `steps`, `repo` or `interactions` binding (including `interactions.<x>.page`) are driver bindings of kind page, so every other A rule applies to them. Any read of a member declared `private` or `protected` in the installed type definitions, or starting with `_`, on those bindings. `Reflect.*`, `Object.values` / `entries` / `keys` / `getOwnPropertyDescriptor(s)` / `getPrototypeOf`, spread and `Object.assign` copies over them, and computed members with a non-literal key on them. `as any`, `as unknown as …`, `@ts-ignore` or `@ts-expect-error` applied to them. Untyped form: in a support module, a member named `page`, `driver`, `browser`, `context` or `_*` read on an `any` or unannotated parameter.
- **Exceptions**: a `repo.driver` read inside the `baseFixture` / `.extend` body that builds the framework objects.

```ts
// Non-compliant
await repo.driver.locator('#pay').click();
await (steps as any).page.goto('/orders');
// Compliant
await steps.click('payButton', 'PayPage');
```

## Family F: flow control

Flow-control rules apply to spec files only. Verbs, fixtures and setup files may branch, retry and poll within [TB-X1](#tb-x1) and [TB-X4](#tb-x4).

<a id="tb-f1"></a>
#### TB-F1 No branching that decides what a test does or checks

No `if`, `switch`, awaited conditional expression or short-circuit in a spec's test or hook body has a branch that performs an action or an assertion.

- **Source** W · **Kind** mechanical · **Severity** blocking · **Applies to** spec
- **Detection**: an `if` or `switch` in a test or hook body (outside browser code and loops) whose branch contains an assertion, a `steps.*` call, a raw call or a verb call, including `if (await steps.isVisible(…))` and `if (await steps.isPresent(…))`. Evasion shapes count the same: an IIFE body is analysed as the test body; a one-pass loop (`for (… of [x])`, `do {} while (false)`, `for (let i = 0; i < 1; …)`) is not a loop; a conditional expression or `&&` / `||` / `??` whose branch or right operand awaits an assertion or a steps, raw or verb call.
- **Not counted**: guard-throws, bookkeeping, loop control, skip guards, value-selecting ternaries that await nothing, a branch inside a loop (a `test.step` body is part of the test, so its loops count as the test's). In a hook a branch counts only when it asserts or drives the UI (a Steps call other than `api*`, `request*` or `sql*`, the repository, interactions, a raw call): conditional teardown through verbs that use the binding they are handed only for API, request or SQL calls, or through those calls directly, is bookkeeping. Constructing a class from `steps`, the repository or a UI driver binding (not `request`) inside a hook branch (`if (id) await new OrderClient(steps).remove(id)`) counts as driving the UI even when the class only makes API calls; the compliant form is an API teardown verb over `steps` (`if (id) await removeOrder(steps, id)`).
- **Exceptions**: the declarative `test.skip(<condition>, '<reason>')`. A test whose data may be in either of two states does not branch on it: a fixture resolves the state, or the test skips by name ([TB-D5](#tb-d5)). Platform differences are [TB-P3](#tb-p3).

```ts
// Non-compliant: the test closes the promo only when it happens to show
if (await steps.isVisible('promoBanner', 'HomePage')) await steps.click('closePromo', 'HomePage');
await steps.click('searchButton', 'HomePage');
// Compliant: a verb in a flow module owns the optional promo; the spec does not branch
await dismissPromo(steps);
await steps.click('searchButton', 'HomePage');
```

<a id="tb-f2"></a>
#### TB-F2 Loops in a test body

A loop inside a test body repeats only what the scenario itself defines, with its count held in a named constant that states the reason.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** advisory (mechanical); blocking by judgment · **Applies to** spec
- **Detection**: loops and async iteration callbacks in a test body; `steps.repeat`. `steps.repeat` is the preferred form. A retry loop in a spec is [TB-F4](#tb-f4).

```ts
// Non-compliant
for (let i = 0; i < 6; i++) await enterPin(steps, wrongPin);
// Compliant
const PIN_TRIES_BEFORE_LOCK = 5; // the card policy locks after five wrong PINs
await steps.repeat(() => enterPin(steps, wrongPin), PIN_TRIES_BEFORE_LOCK);
```

<a id="tb-f3"></a>
#### TB-F3 No swallowed failures

A failure raised inside a test body is never turned into a constant, a value or a pass.

- **Source** W · **Kind** mechanical · **Severity** blocking for `.catch(() => <constant>)`, `.then` with a second function argument and `Promise.allSettled` in a test body; advisory (unmeasured) for a `try` that drives the UI and whose `catch` neither rethrows, asserts nor records into a collection asserted later · **Applies to** spec
- **Not counted**: `try/finally` (advisory: prefer a fixture teardown); catch-record-assert; `.catch` inside route handlers, callbacks, hooks and helpers.

```ts
// Non-compliant
const banner = await steps.getText('statusBanner', 'OrderPage').catch(() => null);
// Compliant
const banner = await steps.getText('statusBanner', 'OrderPage');
```

<a id="tb-f4"></a>
#### TB-F4 Retries live in verbs

A spec never retries an action; a bounded retry belongs to a verb and is followed by a hard check.

- **Source** W · **Kind** mechanical and judgment · **Severity** advisory (mechanical); blocking by judgment · **Applies to** spec
- **Detection**: `steps.retryUntil`, hand-rolled bounded retries (a numeric loop that breaks or returns on success, catch plus continue), `testInfo.retry`. `expect.poll` and `toPass` are allowed.

```ts
// Non-compliant (in a spec)
await steps.retryUntil(async () => { await steps.click('refreshButton', 'InboxPage'); }, async () => { await steps.verifyPresence('newMail', 'InboxPage'); }, 3, 1000);
// Compliant
await waitForNewMail(steps); // flows/inbox-flow.ts: bounded retry, then verifyPresence
```

<a id="tb-f5"></a>
#### TB-F5 No fixed waits

A test waits for a state of the application, never for a fixed span of time.

- **Source** W, R · **Kind** mechanical · **Severity** blocking in specs (`waitForTimeout` and `pause` unwaivable); advisory in support · **Applies to** spec, support
- **Detection**: `*.waitForTimeout(n)`; an awaited `setTimeout` from `timers/promises`; an awaited promise-sleep or a helper built that way (`sleep`, `delay`, `wait`, `pause`); `driver.pause`. Excluded: route handlers; non-awaited timers. `steps.pace` is advisory.

```ts
// Non-compliant
await page.waitForTimeout(2000);
// Compliant
await steps.waitForState('orderConfirmation', 'OrderPage', 'visible');
```

<a id="tb-f6"></a>
#### TB-F6 Focus, silent skips and expected failures

Committed specs carry no `.only`, give every unconditional skip a reason, and call `test.fail` only in one of the two defect-sentinel forms.

- **Source** W, R · **Kind** mechanical · **Severity** blocking for `.only` (unwaivable) and for `test.fail` outside the sentinel forms; advisory for an unconditional `skip` or `fixme` without a reason · **Applies to** spec
- **Detection**: `test.only`, `describe.only`; `test.fail` not in form (a) or (b) of [Defect pointers and sentinels](#defect-pointers-and-sentinels). Set `forbidOnly: !!process.env.CI` in the config.

```ts
// Non-compliant
test.fail('TCCK-000310 · a cancelled order is not charged', async ({ steps }) => { /* … */ });
// Compliant: form (a) or (b), with its `// defect:` pointer
```

<a id="tb-f7"></a>
#### TB-F7 No unasserted optional actions in a spec

An optional action in a spec is followed by a check that fails when the action did not happen.

- **Source** W · **Kind** mechanical and judgment · **Severity** advisory (mechanical); blocking by judgment · **Applies to** spec; allowed in support
- **Detection**: `steps.clickIfPresent`, `steps.on(…).ifVisible()…`, `{ optional: true }` on a steps call. These members are flow control: in a spec the reader asks "does the test pass if the element never appears?", and a yes is must-fix.

```ts
// Non-compliant
await steps.clickIfPresent('acceptCookies', 'HomePage');
await steps.click('signInLink', 'HomePage');
// Compliant (the optional action moves into a verb or fixture that checks its own effect)
await dismissCookieBanner(steps);
```

## Family S: structure

<a id="tb-s1"></a>
#### TB-S1 One scenario per test, no generated tests

Each `test()` declares exactly one scenario, written out by hand, and no loop or factory function declares tests.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** blocking for tests declared inside a loop, an iteration callback or a function called more than once; advisory (unmeasured) for a title with two ids · **Applies to** spec, in every suite
- **Detection**: `test(…)` inside a loop or iteration callback at describe or module level, or inside a function called more than once. A declarative constant table for non-UI suites is not accepted at present: the lint keeps that form behind one factory-rule setting, `specs.constant-table-tests` (`{ "allowed": true }`), which is off, and turning it on is a [TB-G2](#tb-g2) rule-input change.
- **Judgment**: "Does this test check exactly one behaviour, the one its title names?"

```ts
// Non-compliant
for (const size of ['S', 'M', 'L']) test(`size ${size} is selectable`, async ({ steps }) => { /* … */ });
// Compliant
test('TCPD-000210 · size S is selectable', async ({ steps }) => { /* … */ });
test('TCPD-000220 · an unavailable size cannot be added', async ({ steps }) => { /* … */ });
```

<a id="tb-s2"></a>
#### TB-S2 No UI-driving helpers in spec files, except file-local shared ones

A function in a spec file that drives the UI is used by at least two tests of that same file and is never exported.

- **Source** W, R · **Kind** mechanical · **Severity** blocking · **Applies to** spec
- **Detection**: a module- or describe-level function in a spec that references `steps`, a driver binding or a fixture actor, or awaits, and is used by fewer than two tests in the file (counted per test, through in-file helpers); an exported spec helper; any `class`, or `new XxxPage / Screen / Flow()`, in a spec. A helper that declares tests is [TB-S1](#tb-s1).
- **Exceptions**: a helper used by two or more tests of the file, bounded like a verb kept close to its only callers: it takes `steps` (plus data), builds data, composes verbs and returns data. Its body is held to the spec's flow-control rules as if it were the test body ([TB-F1](#tb-f1) to [TB-F5](#tb-f5), [TB-F7](#tb-f7)), and it never holds the scenario's outcome assertion ([TB-R3](#tb-r3); see [TB-S2a](#tb-s2a)). A doc comment says why it stays in the file (advisory). Once another file needs it, it moves to a support module.

```ts
// Non-compliant (one caller)
async function openSettings(steps: Steps) { await steps.click('settingsLink', 'HeaderPage'); }
// Compliant (called by three tests of this file)
/** File-local: only the suspension tests sign in as a suspended account. */
async function signInAsSuspendedAccount(steps: Steps) {
  const account = SuspendedAccount.credentials();
  await signIn(steps, account);
  return account;
}
```

<a id="tb-s2a"></a>
#### TB-S2a Assertion-holding in-spec helper

An in-spec helper that contains assertions is flagged, because the scenario's outcome check belongs in the test body where the reader sees it.

- **Source** R · **Kind** mechanical and judgment · **Severity** advisory (mechanical); blocking by judgment when the helper holds a scenario's outcome assertion · **Applies to** spec
- **Detection**: an in-spec helper allowed by [TB-S2](#tb-s2) whose body contains an assertion. The reader answers [TB-R4](#tb-r4) and [TB-R5](#tb-r5) for each calling test. A check of the helper's own effect may stay (as for a verb, [TB-R3](#tb-r3)); the scenario's outcome assertion moves into the test.

```ts
// Non-compliant: the outcome of every calling test hides in the helper
async function expectNameStillFree(steps: Steps, name: string) { await steps.verifyText('availability', 'SignupPage', `${name} is available`); }
await expectNameStillFree(steps, rejected.username);
// Compliant: the helper builds and returns data; the test asserts
const name = await reserveRejectedName(steps);
await steps.verifyText('availability', 'SignupPage', `${name} is available`);
```

<a id="tb-s3"></a>
#### TB-S3 No page-object layers

No class wraps the Steps API, the repository or a driver binding in page or screen methods.

- **Source** W, R · **Kind** mechanical · **Severity** blocking; advisory (unmeasured) for the constructor-injected field clause · **Applies to** spec, support
- **Detection**: a class whose methods call `steps.*`, `repo.*`, `interactions.*` or a driver binding, or a constructor-injected field of steps or driver type (`this.<field>.<method>`); `new <Name>(page | steps | driver)`; `extends …Page | …Screen`. Constant holders, error classes, classes whose only framework calls are `api*`, `request*` or `sql*`, and API clients whose field is of request kind (`constructor(private request: APIRequestContext)` with `this.request.get(…)`) are not hits. A construction takes its class's severity: advisory when the class drives only through an injected field (calling it, handing it to a verb or returning it from a getter).

```ts
// Non-compliant
class CheckoutPage { constructor(private steps: Steps) {} async pay() { await this.steps.click('payButton', 'CheckoutPage'); } }
// Compliant (a verb in a flow module)
export async function payByCard(steps: Steps, card: Card) { /* … */ }
```

<a id="tb-s4"></a>
#### TB-S4 `test.step` one level deep

A `test.step` is never nested inside another `test.step`, and no step wraps a second scenario.

- **Source** W · **Kind** mechanical · **Severity** blocking for nesting; advisory for any use · **Applies to** spec

```ts
// Non-compliant
await test.step('checkout', async () => { await test.step('pay', async () => { /* … */ }); });
// Compliant
await test.step('pay by card', async () => { await payByCard(steps, card); });
```

<a id="tb-s5"></a>
#### TB-S5 Test length

A test stays within 40 lines from `test(` to its closing brace and within 15 awaited statements.

- **Source** W, R · **Kind** mechanical · **Severity** advisory · **Applies to** spec
- **Detection**: lines of the test callback; awaited statements are top-level statements of the body containing an `await` outside nested functions. The finding asks the reader to answer [TB-S1](#tb-s1) and [TB-R2](#tb-r2): a long test is usually two scenarios or an unshared chore.

```ts
// Flagged: 22 awaited statements covering cart edits and checkout in one test
// Compliant: two tests, the shared chore as a verb
await arriveAtCheckoutWith(steps, basket);
```

<a id="tb-s6"></a>
#### TB-S6 One family per file, describes at most two deep

A spec file holds the scenarios of one family, its name says which, and its describe blocks nest at most two deep.

- **Source** W, R · **Kind** mechanical · **Severity** advisory · **Applies to** spec
- **Detection**: describe depth above two. Contexts (regions, devices, browsers) are config projects, not describes or branches.

```ts
// Non-compliant: tests/e2e/misc.spec.ts holds login, cart and search scenarios
// Compliant: tests/e2e/login/login-negative.spec.ts holds the login negatives
```

<a id="tb-s7"></a>
#### TB-S7 Serial mode is annotated

File-level serial mode carries a `// serial-deliberate: <reason>` line in the contiguous comment block above `test.describe.configure({ mode: 'serial' })`.

- **Source** W · **Kind** mechanical · **Severity** blocking · **Applies to** spec
- When serial mode is required: `../../test-composer/SKILL.md` Step 3; review of it: [`test-optimization.md`](test-optimization.md) §6. The marker carries its reason after the colon. `test.describe.serial` without the marker is advisory for now (unmeasured).

```ts
// Non-compliant
test.describe.configure({ mode: 'serial' });
// Compliant
// serial-deliberate: every test edits the one shared account's address book
test.describe.configure({ mode: 'serial' });
```

<a id="tb-s8"></a>
#### TB-S8 Throwaway scripts are not committed

Nothing under `tests/e2e/inspect/` is ever part of a commit.

- **Source** W · **Kind** mechanical · **Severity** blocking, unwaivable · **Applies to** staged files
- **Detection**: a staged path under `tests/e2e/inspect/**`.

```text
Non-compliant: tests/e2e/inspect/login-probe.spec.ts staged
Compliant: the probe deleted before hand-back; its findings in the report
```

<a id="tb-s9"></a>
#### TB-S9 Hooks arrange, they do not test

Hooks prepare and clean state, while the scenario's actions and outcome checks stay in the test body.

- **Source** W · **Kind** judgment, plus a mechanical hint · **Severity** blocking by judgment; advisory hint for assertions in hooks · **Applies to** spec
- A positive control that the page is alive (a guard) may sit in a hook; the scenario's oracle may not.

```ts
// Non-compliant
test.beforeEach(async ({ steps }) => { await signIn(steps, user); await steps.verifyText('greeting', 'HomePage', 'Welcome back'); });
// Compliant
test.beforeEach(async ({ steps }) => { await steps.navigateTo(Routes.LOGIN); });
```

## Family I: identity

<a id="tb-i1"></a>
#### TB-I1 Every test carries a stable id

The title of every test starts with an id that matches the project's pinned id pattern, then ` · ` and the behaviour.

- **Source** W, R · **Kind** mechanical · **Severity** blocking once a pattern is pinned or the house default is recorded; until then advisory, plus one project-level "pin your pattern" finding. Template-literal titles: advisory. A duplicate id within a file: blocking · **Applies to** spec
- **Detection**: the pattern comes from `CIVITAS_TEST_ID_PATTERN`, else `specs.shape.titleIdPattern`, else the compliance baseline's recorded `idPattern` ([Baseline and ratchet](#baseline-and-ratchet)), else the house default (`TC` plus area letters, a dash and a 4 to 6 digit ordinal; [`test-identity.md`](test-identity.md) §1). The middle dot is the canonical separator.

```ts
// Non-compliant
test('wrong password is rejected', async ({ steps }) => { /* … */ });
// Compliant
test('TCLG-000420 · a wrong password is rejected', async ({ steps }) => { /* … */ });
```

<a id="tb-i2"></a>
#### TB-I2 Ids are unique and indexed

No two tests of a suite share an id, and the suite's id index lists every id in use.

- **Source** W, R · **Kind** mechanical · **Severity** blocking · **Applies to** spec (whole suite)
- **Detection**: ids across files; every id appears in the suite's index (typically `tests/e2e/docs/test-ids.md`), which is the place to look before minting a new id. `achilles-spec-lint --id-index` writes the index and `--id-index --check` fails when an id in use is missing from it or a listed id is no longer used; `achilles-spec-lint --suite` reports an id used in two files.

```ts
// Non-compliant: 'TCLG-000420 · …' in login.spec.ts and in session.spec.ts
// Compliant: a fresh id for the new case, added to the index
```

<a id="tb-i3"></a>
#### TB-I3 Title and tags match the scenario block

In a project with `specs.shape`, a test's id, title and tags are those of its scenario block.

- **Source** W, R · **Kind** mechanical · **Severity** blocking under `specs.shape` · **Applies to** spec
- The `tag` option is preferred; tags in the title are compliant; type tags (`@e2e`, `@smoke`) only where the suite splits on them. Block format: [`scenario-block.md`](scenario-block.md).

```ts
// Non-compliant (block CHK-03 is typed @e2e @checkout)
test('CHK-03 · cancel returns to checkout', async ({ steps }) => { /* … */ });
// Compliant
test('CHK-03 · cancelling the payment modal returns to checkout without an order', { tag: ['@e2e', '@checkout'] }, async ({ steps }) => { /* … */ });
```

<a id="tb-i4"></a>
#### TB-I4 Expected-red tests point at a resolvable defect record

Every `@known-defect` test and every `test.fail` sentinel names its defect record in its own pointer, and the pointer resolves.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** blocking · **Applies to** spec
- **Detection**: the pointer grammar of [Defect pointers and sentinels](#defect-pointers-and-sentinels), per test. A pointer at the top of the file, "see the README" or a finding id in free text is not the grammar.
- **Judgment**: "Does the test assert the correct behaviour, not the bug? Is the failing assertion the defect's own assertion?"

```ts
// Non-compliant
// Known defect, see the README
test('TCSG-000110 · a duplicate email surfaces a conflict @known-defect', async ({ steps }) => { /* … */ });
// Compliant
// defect: tests/e2e/docs/adversarial-findings.md#j-signup-02
test('TCSG-000110 · a duplicate email surfaces a conflict @known-defect', async ({ steps }) => { /* … */ });
```

## Family R: readability and the oracle

<a id="tb-r1"></a>
#### TB-R1 Steps appear in scenario order

A reader finds the scenario's steps in the test in the same order the scenario lists them.

- **Source** W, R · **Kind** judgment · **Severity** blocking · **Applies to** spec

```ts
// Non-compliant: the oracle for step 2 is checked before step 1 runs
// Compliant
await signIn(steps, { ...user, password: wrongPassword });           // step 1
await steps.verifyText('formError', 'LoginPage', 'Wrong email or password'); // step 2
```

<a id="tb-r2"></a>
#### TB-R2 Verbs are shared, or hold what a spec may not

A verb earns its place by being used by two or more scenarios, or by holding a branch, bounded retry or poll that a spec may not contain.

- **Source** W, R · **Kind** judgment, plus an advisory hint · **Severity** blocking by judgment · **Applies to** support
- A verb is an exported function in a support module (a flow module under `flows/`) that takes `steps` first, or a project fixture that hands out such a function (its body is held to the verb-module rules of [TB-X1](#tb-x1)); it is named as an imperative chore with its end state. Use counts include composition through other verbs.

```ts
// Non-compliant: clickSave(steps) wraps one steps.click and is used once
// Compliant
export async function closeWelcomeTour(steps: Steps) { /* branches on an optional dialog, then checks it is gone */ }
```

<a id="tb-r3"></a>
#### TB-R3 Verbs check their own effect, never the scenario's outcome

A verb may confirm that its own chore took effect, and the scenario's outcome assertion stays in the test.

- **Source** W, R · **Kind** judgment · **Severity** blocking · **Applies to** support

```ts
// Non-compliant (flow asserts the scenario's outcome)
export async function placeOrder(steps: Steps) { /* … */ await steps.verifyText('orderStatus', 'OrderPage', 'Placed'); }
// Compliant (flow checks its own step; the test asserts the outcome)
export async function skipTwoFactorSetup(steps: Steps) { await steps.click('skipForNow', 'TwoFactorPage'); await steps.verifyAbsence('twoFactorDialog', 'TwoFactorPage'); }
```

<a id="tb-r4"></a>
#### TB-R4 The oracle is present and tied to the action

Every scenario test asserts the effect of its action at least once, and guard checks may come after that assertion.

- **Source** W, R · **Kind** mechanical hint and judgment · **Severity** advisory (zero assertions in a test); blocking by judgment · **Applies to** spec
- **Detection**: zero assertions, where any `steps…` chain ending in `to*`, `satisfy`, `throws` or `verify*` counts. An absence or URL check is never the only oracle.

```ts
// Non-compliant (only a URL is checked)
await submitSignup(steps, user); await steps.verifyUrlContains('/welcome');
// Compliant
await submitSignup(steps, user); await steps.verifyText('welcomeHeading', 'WelcomePage', `Welcome, ${user.firstName}`);
```

<a id="tb-r5"></a>
#### TB-R5 Causal verification

Each oracle would fail if the action under test had silently done nothing.

- **Source** W, R · **Kind** judgment · **Severity** blocking · **Applies to** spec
- Tautologies to catch: clicking a list item then asserting the list is present; hovering then asserting visibility; filling then asserting the input exists; clicking a button then asserting it is enabled; filtering then asserting the collection exists. Verify the specific effect instead (navigation, a selected-state attribute, the filled value, a dependent element, a modal, the filtered result). An element that exists only after the action counts as visible dependence; an absence-only or URL-only oracle needs a can-fail proof ([`verification-record.md`](verification-record.md)). Only a documented framework-smoke case may end on `verifyState('visible')`, with a comment saying why.

```ts
// Non-compliant
await steps.fill('searchInput', 'SearchPage', 'lamp'); await steps.verifyPresence('searchInput', 'SearchPage');
// Compliant
await steps.fill('searchInput', 'SearchPage', 'lamp'); await steps.verifyInputValue('searchInput', 'SearchPage', 'lamp');
```

<a id="tb-r6"></a>
#### TB-R6 A UI test asserts what the user is shown

A UI test's oracle includes something the user can see, refusals included, and never rests on URLs, absences or API statuses alone.

- **Source** W, R · **Kind** judgment · **Severity** blocking · **Applies to** spec
- A UI test whose user-facing checks are all URLs, absences or API statuses is `proxy-only` and a miss. Detail: `../../test-composer/SKILL.md` §"UI outcome oracle".

```ts
// Non-compliant
await submitSignup(steps, duplicate); await steps.verifyApiStatus(/* … */);
// Compliant
await submitSignup(steps, duplicate); await steps.verifyPresence('duplicateEmailError', 'SignupPage');
```

<a id="tb-r7"></a>
#### TB-R7 Evidence and created identities

Evidence is keyed on test ids, and every identity a test creates is annotated on that test.

- **Source** W, R · **Kind** judgment · **Severity** advisory · **Applies to** spec, support
- Media capture may live in a separate evidence config; a collector keys on ids, never on title slugs.

```ts
// Non-compliant: the collector names folders after the title slug
// Compliant
test.info().annotations.push({ type: 'created-account', description: user.email });
```

<a id="tb-r8"></a>
#### TB-R8 A non-obvious check carries its reason

A check whose purpose is not evident from its names carries a comment saying why it is there.

- **Source** R · **Kind** judgment · **Severity** advisory · **Applies to** spec, support
- Comments say why, never what the next line does.

```ts
// Non-compliant
// click the button
await steps.click('resendCode', 'TwoFactorPage');
// Compliant
// the lockout banner appears only after the server has counted the attempt
await steps.verifyPresence('lockoutBanner', 'LoginPage');
```

## Family D: data, types and secrets

<a id="tb-d1"></a>
#### TB-D1 Type escapes are counted

Non-null assertions, `as any` casts and `@ts-ignore` comments are counted as a code-health metric.

- **Source** W · **Kind** mechanical · **Severity** advisory · **Applies to** spec, support
- The narrow form on framework objects is blocking under [TB-A14](#tb-a14).

```ts
// Counted
const id = order!.id;
// Compliant
if (!order) throw new Error('the order fixture returned no order'); const id = order.id;
```

<a id="tb-d2"></a>
#### TB-D2 No secrets

No real credential, token or key appears as a literal in test or support code.

- **Source** W · **Kind** mechanical hint and judgment · **Severity** blocking by judgment, unwaivable; the mechanical hint is advisory (most literal hits are boundary data) · **Applies to** spec, support
- **Judgment**: "Is any literal a real credential?" Credentials come from env through a fixture or data module ([`../../test-data-conventions/SKILL.md`](../../test-data-conventions/SKILL.md); extraction: [`../../secrets-sweep/SKILL.md`](../../secrets-sweep/SKILL.md)). A project with the `secrets.none` factory rule also has such writes refused by the adapter.

```ts
// Non-compliant
await signIn(steps, { email: 'ops@shop.test', password: 'S3cret-prod-pass!' });
// Compliant
await signIn(steps, StandingAccount.credentials());
```

<a id="tb-d3"></a>
#### TB-D3 Origins and duplicated routes

Tests address paths through named route constants, and neither hard-code an origin nor retype a route that a constant already holds.

- **Source** W, R · **Kind** mechanical · **Severity** advisory · **Applies to** spec, support
- An env fallback to a reserved domain (`example.com`, `.test`) is fine.

```ts
// Non-compliant
await steps.navigateTo('https://staging.shop.test/login');
// Compliant
await steps.navigateTo(Routes.LOGIN);
```

<a id="tb-d4"></a>
#### TB-D4 Per-attempt generation

Data that a test creates is generated per attempt inside the test or a hook, never once at module scope.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** blocking at module scope of specs and data or fixture modules; advisory (unmeasured) in a describe callback outside tests and hooks · **Applies to** spec, support
- **Judgment**: the current content of the environment is never the oracle ([`../../test-data-conventions/SKILL.md`](../../test-data-conventions/SKILL.md) rules 1 and 2).

```ts
// Non-compliant
const user = makeCustomer(); // module scope: a retry reuses the same email
// Compliant
test('TCSG-000120 · a new account can sign in', async ({ steps }) => { const user = makeCustomer(); /* … */ });
```

<a id="tb-d5"></a>
#### TB-D5 Skips name a premise

A data-dependent skip names, by name, the premise it rests on.

- **Source** W · **Kind** judgment · **Severity** blocking · **Applies to** spec
- Only a premise is skippable; the taxonomy is [`../../test-data-conventions/SKILL.md`](../../test-data-conventions/SKILL.md) rule 3.

```ts
// Non-compliant
test.skip(!orders.length);
// Compliant
test.skip(!Premises.hasArchivedOrder(), 'premise: the account has at least one archived order');
```

## Family W: timeouts

<a id="tb-w1"></a>
#### TB-W1 Per-call timeout overrides carry their reason

A per-call or per-test timeout override carries a `// perf:` or `// slow:` comment saying why the default is not enough.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** advisory (mechanical); blocking by judgment for new or changed overrides · **Applies to** spec, support
- **Detection**: an options `timeout` on `steps.*`, `interactions.*`, a raw call, `expect` or `test(…, { timeout })` without the comment. Not hits: constructor options, observation windows (`steps.expect(…).timeout(n)`), fixture-level timeouts and `test.setTimeout()`. An override earns its place when the default demonstrably fails (a timeout-class failure resolved by it, a slow-page note in `app-context.md`).

```ts
// Non-compliant
await steps.waitForState('reportReady', 'ReportsPage', 'visible', { timeout: 90_000 });
// Compliant
// slow: report generation takes up to 60 s on the shared environment
await steps.waitForState('reportReady', 'ReportsPage', 'visible', { timeout: 90_000 });
```

<a id="tb-w2"></a>
#### TB-W2 Budgets

A test that needs more than the default timeout carries its own budget, and no describe block needs a timeout of its own.

- **Source** W, R · **Kind** judgment · **Severity** advisory · **Applies to** spec
- A describe-level timeout that every test overrides is dead configuration.

```ts
// Non-compliant
test.describe.configure({ timeout: 60_000 }); // on every describe, by habit
// Compliant
test.setTimeout(120_000); // perf: the export test waits for a two-minute job
```

## Family X: support files

<a id="tb-x1"></a>
#### TB-X1 What a support file may contain

Each support module plays one role (fixtures, verbs, data, handoff or setup) and holds only what that role allows.

- **Source** W, R · **Kind** judgment · **Severity** blocking · **Applies to** support
- **Fixtures module**: wiring only: the `baseFixture(…)` call, the repository path declared once, options, the `expect` re-export, `.extend` fixtures that construct framework objects or set up and tear down state without driving the UI, a fixture-level `beforeEach` slot whose body only calls verbs and fixtures, the mutation hooks of [TB-X2](#tb-x2). A fixture that exposes a UI-driving function is a verb: the verb-module rules below apply to its body.
- **Verb modules** (`flows/`): functions taking `steps` that drive one chore, with imperative names. Allowed with a reason comment: bounded loops of idempotent or state-aware attempts followed by a hard gate; branches on optional app state followed by a check; parameter options; a per-call timeout. Never: the scenario's outcome assertion, `try/catch`, raw calls outside [TB-A12](#tb-a12)'s allowlist, unbounded waits, hand-rolled sleeps. A new verb's doc comment says where it leaves the browser (advisory).
- **Data modules**: constants with reasons, types, generators, builders with overrides, env getters; no Playwright, no I/O.
- **Handoff modules**: run-state file read and write, with an explanatory throw when the file is missing.
- **Setup files**: may branch on environment; prefer the resolution in a support function.

```ts
// Non-compliant (fixtures/base.ts)
export async function checkout(page: Page) { await page.click('#checkout'); }
// Compliant (fixtures/base.ts)
export const test = baseFixture(base, REPOSITORY_PATH, { timeout: 30_000 });
export { expect };
```

<a id="tb-x2"></a>
#### TB-X2 Sanctioned wiring shapes, and no reimplemented steps

Raw framework wiring in support code takes one of the sanctioned shapes, no verb reimplements a Steps call with raw Playwright, and no spec builds its own repository or Steps object.

- **Source** W, R · **Kind** judgment · **Severity** blocking · **Applies to** spec, support
- The sanctioned shapes are [TB-A12](#tb-a12)'s allowlist, including the verify-change mutation hooks: in the fixtures module's `page` fixture, `page.addInitScript({ content })` and `page.addStyleTag({ content })` gated exactly on `process.env.E2E_MUTATION_INIT` and `process.env.E2E_MUTATION_CSS` ([`verify-change/phase-8b-adversarial-review.md`](verify-change/phase-8b-adversarial-review.md)).
- **Judgment**: "Does a verb reimplement a `steps.*` call with raw Playwright? Does a spec build its own `ElementRepository` or `Steps`?" Use a fixture or `steps.forPage` instead.

```ts
// Non-compliant (in a spec)
const other = new Steps(new ElementRepository(REPOSITORY_PATH, otherPage));
// Compliant (fixtures module, inert unless the mutation driver sets the variable)
if (process.env.E2E_MUTATION_INIT) await page.addInitScript({ content: process.env.E2E_MUTATION_INIT });
```

<a id="tb-x3"></a>
#### TB-X3 No tests in support files

Support modules declare no tests, apart from setup files that a config runs as setup projects.

- **Source** W · **Kind** mechanical · **Severity** blocking · **Applies to** support

```ts
// Non-compliant (flows/login-flow.ts)
test('login works', async ({ steps }) => { /* … */ });
// Compliant: the flow exports verbs; tests live in specs
```

<a id="tb-x4"></a>
#### TB-X4 Retries and branches in verbs are bounded and gated

A loop or retry inside a verb has a deadline or a counter, and a hard check follows it.

- **Source** W, R · **Kind** mechanical and judgment · **Severity** `while (true)`, `for (;;)` or a `for` with no test and no deadline or counter: advisory until the shape has a measured mechanical definition, then blocking; other bound shapes advisory; blocking by judgment ("idempotent or state-aware attempts, followed by a hard gate?") · **Applies to** support

```ts
// Non-compliant
while (true) { if (await steps.isVisible('nextButton', 'WizardPage')) await steps.click('nextButton', 'WizardPage'); else break; }
// Compliant
for (let screen = 0; screen < MAX_WIZARD_SCREENS && await steps.isVisible('nextButton', 'WizardPage'); screen++) await steps.click('nextButton', 'WizardPage');
await steps.verifyPresence('wizardDone', 'WizardPage');
```

## Family P: platform

These rules apply to native-driver specs only (a project whose tests drive a device through a native driver). They never fire on web projects.

<a id="tb-p1"></a>
#### TB-P1 No raw driver calls

A native-driver spec drives the device only through the Steps API, never through the driver object.

- **Source** W · **Kind** mechanical · **Severity** blocking (exact method names) · **Applies to** spec (native)

```ts
// Non-compliant
await driver.$('~loginButton').click();
// Compliant
await steps.click('loginButton', 'LoginScreen');
```

<a id="tb-p2"></a>
#### TB-P2 No capability literals

Device capabilities come from the project's configuration, never from literals in a native-driver spec.

- **Source** W · **Kind** mechanical · **Severity** blocking · **Applies to** spec (native)

```ts
// Non-compliant
const caps = { platformName: 'Android', 'appium:deviceName': 'Pixel 7' };
// Compliant: capabilities live in the config's projects; the spec reads `steps.platform`
```

<a id="tb-p3"></a>
#### TB-P3 Platform divergence is declarative

Where platforms behave differently, the spec declares the difference (a per-platform file, a named skip or per-platform repository entries) instead of branching on it.

- **Source** W · **Kind** mechanical (through [TB-F1](#tb-f1)) · **Severity** blocking · **Applies to** spec (native)

```ts
// Non-compliant
if (steps.platform === 'android') await steps.pressKey('Back');
// Compliant
test.skip(steps.platform !== 'android', 'the hardware back key exists only on Android');
```

## Family N: API and database

<a id="tb-n1"></a>
#### TB-N1 HTTP through the Steps API

Specs send HTTP through the Steps API's `api*` or `request*` methods, never through `fetch` or an HTTP client library.

- **Source** W · **Kind** mechanical · **Severity** blocking in specs; advisory in support (back-door, seeding and health checks are legitimate there) · **Applies to** spec, support
- **Detection**: `fetch`, `axios`, `got`, `undici` imports or calls in a spec, outside browser code.

```ts
// Non-compliant
const res = await fetch(`${process.env.API_URL}/users/42`);
// Compliant
const res = await steps.apiGet<User>('/users/42');
```

<a id="tb-n2"></a>
#### TB-N2 Typed responses

A contract test declares the type of every response body it reads.

- **Source** W · **Kind** mechanical · **Severity** advisory (unmeasured) · **Applies to** spec under `tests/contracts/**`
- Detail: `../../contract-testing/SKILL.md` rule 7.

```ts
// Non-compliant
const res: any = await steps.apiGet('/orders/7');
// Compliant
const res = await steps.apiGet<Order>('/orders/7');
```

<a id="tb-n3"></a>
#### TB-N3 Shape assertions, status and envelope per endpoint

API assertions check the response's shape, and each endpoint's tests assert its status and its error envelope.

- **Source** W · **Kind** judgment · **Severity** blocking · **Applies to** spec
- Detail: `../../contract-testing/SKILL.md` rules 3 and 4.

```ts
// Non-compliant
expect(order.title).toBe('Blue lamp');
// Compliant
expect(order).toEqual(expect.objectContaining({ id: expect.any(Number), title: expect.any(String) }));
```

<a id="tb-n4"></a>
#### TB-N4 Database access through `steps.sql*`

Specs reach a database only through the `steps.sql*` methods and import no database client.

- **Source** W · **Kind** mechanical · **Severity** blocking · **Applies to** spec
- **Detection**: imports of database clients in a spec (`pg`, `mysql2`, `knex`, `typeorm`, `prisma` and similar). Detail: `../../database-testing/SKILL.md`.

```ts
// Non-compliant
import { Client } from 'pg';
// Compliant
const rows = await steps.sqlQuery('select status from orders where id = $1', [orderId]);
```

## Family K: k6

Advisory until measured on a live k6 suite. Home of the full doctrine: `../../performance-testing/SKILL.md` §"Absolute rules".

<a id="tb-k1"></a>
#### TB-K1 Origins from configuration

A k6 script addresses paths and takes its origin from the perf configuration module.

- **Source** W · **Kind** mechanical · **Severity** advisory · **Applies to** k6

```js
// Non-compliant
http.get((__ENV.BASE_URL || 'http://localhost:3000') + '/api/items');
// Compliant
http.get(`${config.baseUrl}/api/items`);
```

<a id="tb-k2"></a>
#### TB-K2 Thresholds are the oracle

Every k6 scenario declares thresholds, and a breach is answered as a finding, never by loosening the threshold.

- **Source** W · **Kind** judgment · **Severity** advisory · **Applies to** k6

```js
// Non-compliant
export const options = { vus: 50, duration: '5m' };
// Compliant
export const options = { vus: 50, duration: '5m', thresholds: { http_req_duration: ['p(95)<800'] } };
```

<a id="tb-k3"></a>
#### TB-K3 One scenario per script

A k6 script holds one scenario with a single workload intent.

- **Source** W · **Kind** judgment · **Severity** advisory · **Applies to** k6

```js
// Non-compliant: browse, checkout and a soak profile in one script
// Compliant: tests/perf/scenarios/checkout-peak.js holds the checkout peak only
```

<a id="tb-k4"></a>
#### TB-K4 Think time is allowed

A `sleep` between iterations of a k6 script models user think time and is not a fixed wait under TB-F5.

- **Source** W · **Kind** mechanical · **Severity** advisory · **Applies to** k6

```js
// Compliant
http.get(`${config.baseUrl}/api/items`);
sleep(randomBetween(1, 3)); // think time between page views
```

## Family G: governance

<a id="tb-g0"></a>
#### TB-G0 The file parses

Every in-scope test or support file parses as valid TypeScript or JavaScript.

- **Source** N · **Kind** mechanical · **Severity** blocking, unwaivable; a note while writing · **Applies to** spec, support

```ts
// Non-compliant
test('TCLG-000430 · …', async ({ steps }) => { await steps.click('submitButton', 'LoginPage') ;; }
// Compliant: the file parses; every brace and parenthesis closes
```

<a id="tb-g1"></a>
#### TB-G1 Waivers and gap citations are well formed

Every waiver and framework-gap citation follows the grammar and caps of this file and names a valid, open register row.

- **Source** N · **Kind** mechanical · **Severity** blocking, unwaivable · **Applies to** spec, support, the register
- **Detection**: the [Waivers](#waivers) grammar and caps; a row naming a method with a Steps equivalent; a citation of a `fixed-in` row; a third waiver in one test; a citation of a row that the person has not decided on (a new register row needs the person's decision, [TB-G2](#tb-g2)).

```ts
// Non-compliant
// achilles-allow TB-A1 -- needed
// Compliant
// achilles-allow TB-A1 -- the repository cannot address this shadow-root chain [gap: FG-<n>]
```

<a id="tb-g2"></a>
#### TB-G2 Rule inputs are not weakened

A change that weakens an input the rules depend on is made only when the person decided it for that input.

- **Source** N · **Kind** mechanical · **Severity** blocking; the judge or reviewer returns an undecided change as must-fix · **Applies to** the protected inputs
- **Protected inputs**: the pinned id pattern (`CIVITAS_TEST_ID_PATTERN` in committed env files, `specs.shape.titleIdPattern`, a recorded baseline `idPattern`); `achilles-factory-rules.json` (any change to a `specs.*` or `secrets.*` rule, or deleting the file); removing entries from `selectors.no-inline.forbidden`; adding or editing a row of `tests/e2e/docs/framework-gaps.md`; raising or deleting counts in the compliance baseline (`tests/compliance-baseline.json`, [Baseline and ratchet](#baseline-and-ratchet)); a Playwright config's `grep`, `grepInvert`, `testIgnore` or `testMatch`; the git hooks directory and its hook files.
- **How to get the decision**: the expert does not make the change on its own judgment; it returns `NEEDS_CONTEXT` naming the input and the change. The orchestrator never answers such a question itself: it escalates it in its own `NEEDS_CONTEXT` hand-back ([`../SKILL.md`](../SKILL.md) §6). The person's answer comes back in the resume brief, is recorded in `resume.json` `rulings[]` ([`state-files.md`](state-files.md)), and the final hand-back cites it.

```text
Non-compliant: a change that widens testIgnore to skip a red spec, made without asking
Compliant: the same change after the person answered the escalated question; the ruling is in resume.json and the hand-back cites it
```
