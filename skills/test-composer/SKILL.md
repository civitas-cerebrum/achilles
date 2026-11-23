---
name: test-composer
description: >
  Compose the full test portfolio for one user journey (happy path, error
  states, edge cases, mobile, negative flows, data-lifecycle and visual
  variants), stabilise it, review it, verify coverage is exhaustive, and
  return. Loaded by an `author` dispatch whose brief names `journey=<j-id>`
  from a sentinel-bearing `tests/e2e/docs/journey-map.md`: once per journey
  per compositional pass inside coverage expansion, per primary journey in
  onboarding Phase 3, or on request ("write all tests for the login
  journey", "compose tests for journey X"). Not for iterating across an app
  (the expand-coverage workflow) or one ad-hoc scenario (author-scenario).
---

# Test composer

One journey per invocation. Every step, branch and applicable state variation in the journey's block has a test before you return; the orchestrator trusts this and does not re-check per-journey coverage.

**Inside a coverage pass** you are Stage A. A fresh reviewer (Stage B, [`../review/references/stage-b-contract.md`](../review/references/stage-b-contract.md)) reads your output and the live app and returns `greenlight` or `improvements-needed`; the orchestrator re-dispatches you with the must-fix list per [`dual-stage-retry-loop.md`](../achilles-orchestrator/references/dual-stage-retry-loop.md). Meet the bar in cycle 1 by knowing what the reviewer checks: every `Test expectations:` item covered; Steps API with repository selectors; file-level serial on tenant-mutating specs; a mobile variant on P0/P1; assertions that match the live DOM; a UI outcome oracle on every UI test (§"UI outcome oracle"); a data strategy on the `test-data-conventions` ladder.

## Mandatory stages

1. **Compose** (Steps 1–3).
2. **Stabilise** (Step 4) to 3 consecutive greens.
3. **Optimise** (Step 6a) with [`test-optimization.md`](../achilles-orchestrator/references/test-optimization.md).
4. **API compliance** (Step 6b): the Stage 4b review.
5. **Judge** (Step 6c): skipped inside a coverage pass, where the Stage B reviewer is the judge.
6. **Coverage verification + whole-suite gate** (Step 7).

## Step 1: load the journey

1. Verify `journey-map.md` exists with `<!-- journey-mapping:generated -->` on line 1; otherwise return `blocked: journey-map-missing` naming the map-journeys workflow.
2. Load **only** the `### j-<journey-slug>:` block plus the `sj-` blocks it references. Never the whole map; never cross-app gap analysis (the orchestrator's job).
3. Read `Priority`, `Pages touched:`, `Test expectations:`. Variants by tier: **P0** happy path + error states + edge cases + mobile + negative flows + the listed data-lifecycle variants; **P1** happy path + error states + edge cases + mobile; **P2** happy path + one error state + one data verification; **P3** smoke (loads, key elements present). Depth per variant follows the smoke-versus-e2e doctrine ([`test-composition-standards.md`](../achilles-orchestrator/references/test-composition-standards.md) §5): the UI walk is the subject of exactly one e2e test; derivatives shortcut prerequisites and assert their own surface.
4. List existing tests that already cover steps of this journey (`npx playwright test --list`); add variants, do not duplicate.

## Step 2: discover

Open `npx playwright-cli -s=<slug from the brief> open --browser=chromium <URL>`, snapshot each uncovered page, note every interactive element (`[ref=eN]`), headings and labels, click into dropdowns, modals and menus, close the session ([`playwright-cli-protocol.md`](../achilles-orchestrator/references/playwright-cli-protocol.md)). Save every page and component to `tests/e2e/docs/app-context.md` per [`stages-protocol.md`](../achilles-orchestrator/references/stages-protocol.md) §"App context"; an unsaved discovery is re-discovered next session. If the app is unreachable, return `NEEDS_CONTEXT` asking for screenshots or page structure; never guess selectors.

## Step 3: implement

A spec holds exactly the tests the expectations and the partition analysis demand: never padded toward a count, never stopped at one. Split files by area past ~200 lines.

Rules:

- Steps API from `./fixtures/base`; every selector in `page-repository.json` (with an evidence note, [`selector-evidence.md`](../achilles-orchestrator/references/selector-evidence.md)); a stable test id on every title ([`test-identity.md`](../achilles-orchestrator/references/test-identity.md)); `test.describe.configure({ timeout: 60_000 })` on every describe block.
- **File-level serial for tenant-mutating specs**: any POST / PUT / PATCH / DELETE against a mutable endpoint (entity create/update/delete, state transitions, role or permission changes, persisted uploads, password or MFA changes) means the file opens with `// serial-deliberate: <reason>` above `test.describe.configure({ mode: 'serial' })`. Parallel workers sharing a credential race CSRF tokens; serial at file level removes the race without capping global parallelism. Idempotent read-through-POST handlers are exempt; when in doubt, apply it.
- Tests depending on data from other tests handle both states; tests that need specific data `test.skip()` **by name** per the premise / app-state / infra taxonomy in `test-data-conventions` Rule 3 (only a premise is skippable).
- Any `steps.api*` call brings in `contract-testing`'s minimum obligations (status + error-envelope assertion per endpoint); an unasserted `apiGet` is not an oracle.
- Value order: functional tests, data verification, navigation, presence, negative, responsive, security.
- No stable selector for an element and the frontend source is in the workspace: run the `selector-development` JIT loop for it (the brief grants the one frontend file); otherwise record the fragile selector as test debt in the return.

### Variant order

1. **Happy path end to end** (introduces the selectors every later variant inherits).
2. **Error states**: validation, network failure, session expiry, invalid input per step.
3. **Edge cases** from the partition table in [`references/input-domain-analysis.md`](references/input-domain-analysis.md), never ad hoc.
4. **Mobile** (P0/P1): the happy path at 375×812. On a platform target this is landscape and the two device classes instead (§"Platform targets (iOS, Android)").
5. **Negative flows**: permission denied, unauthorised access, out-of-order steps; each asserts the refusal the user is shown, not only the redirect (§"UI outcome oracle").
6. **Data lifecycle** where the expectations list them: create → read → update → delete across sessions, draft persistence, bulk operations.
7. **Visual regression** where the surface is design-locked (see below).

Each variant is its own `test(...)`; spec shape and the readability check: [`spec-shape.md`](../achilles-orchestrator/references/spec-shape.md).

### Visual regression

`steps.verifyVisualMatch` wraps Playwright's `toHaveScreenshot` with a mask shape that resolves `{ elementName, pageName }` through the repository. Add one variant per design-locked page or component (marketing pages, settled design-system components, stable dashboards); skip surfaces under design churn. Mask every dynamic-content region (clocks, generated ids, "updated N minutes ago", avatars, live charts) by repository name; CSS animations are already disabled during the snapshot, so no animation-freezing hacks. First run writes the baseline; `--update-snapshots` refreshes it deliberately; generate baselines in the CI environment (Playwright fingerprints them per OS and browser). Element-scoped form and the raw-selector escape hatch: [`api-reference.md`](../achilles-orchestrator/references/api-reference.md) §"Visual regression".

### Oracle strength ladder

Every test proves its claim through an oracle, the assertion that fails when the app regresses. Required strength follows priority and whether the step mutates state. Orthogonal to `test-optimization.md` §3b's round-trip / delta / shape forms: L0–L3 picks the layer, §3b picks the assertion form within it.

| Level | Oracle | Proves |
|---|---|---|
| L0 | visibility (toast, heading, banner) | the UI said it worked |
| L1 | UI round-trip: reload or re-navigate, re-verify by extraction | the app renders the mutation after a fresh load |
| L2 | API oracle: `steps.apiGet` of the mutated resource + `contract-testing` minimum assertions | the backend serves the mutation |
| L3 | DB oracle: `steps.sql*` through `database-testing` (when the framework ships it) | the mutation persisted |

| Priority | Mutating steps | Non-mutating |
|---|---|---|
| P0 | ≥ L2 (L3 when a DB is configured and `steps.sql*` ships) | ≥ L1 |
| P1 | ≥ L1 | L0 acceptable |
| P2/P3 | L0 acceptable | L0 acceptable |

A P0 mutating step whose strongest oracle is L0 is a coverage gap (Step 7 loops back). **Bite check**: per journey, mutate the expected value of one L1+ assertion, confirm the test fails with a useful diff, revert.

### UI outcome oracle

A test that drives the app through the browser is a UI test, and its claim is about what the user experiences. On top of whatever rung the ladder demands, every UI test asserts **through the UI** the user-visible outcome of the action it is about. The ladder decides how deep the proof goes; this rule decides that the user's side of it is proven at all.

- **Success:** what the user sees change: the new row, the saved value after a reload, the confirmation message.
- **Refusal or failure** (negative flows, permission denied, validation, out-of-order steps, a guarded route): the feedback the user is shown, asserted by its text through a repository entry: the permission or error toast, the inline validation message, the banner, the disabled control and its explanation. Where the user ends up (the redirect target) is asserted too, but it is not the feedback.
- **Proxies never satisfy it on their own:** the URL after a redirect, the absence of an element, a status code from `steps.api*` or a helper request, a database row. Keep them as further oracles (they prove the guard held); the UI assertion proves the user was told.
- **Discover the outcome surface in Step 2:** trigger the outcome in your session and snapshot the toast or message while it is shown. Toasts are transient, so the test asserts them as they appear (an auto-waiting visibility and text check right after the action), never after a fixed wait. Save the entry with its evidence note.
- **No feedback where the user needs it** (a silent redirect, a refused save with no message) is a finding with evidence ([`finding-and-ledger-schema.md`](../achilles-orchestrator/references/finding-and-ledger-schema.md)), not a reason to drop the oracle: assert the feedback the user should get and tag the test `@known-defect` ([`test-identity.md`](../achilles-orchestrator/references/test-identity.md)). Never assert the silent outcome as the expected result.
- **Scope:** a test that opens no page (a contract, server-gate or data test) is not a UI test. A test that opens a page for any step is one for every step whose outcome the user can see; an API probe inside it adds an oracle and never replaces the UI one.

A UI test whose user-facing assertions are all proxies is a verification miss (`proxy-only`), the same class as an L0-only P0 mutation: Step 7 loops back.

### Tenant cleanup

Any journey whose happy path creates a persistent tenant entity (`j-*-add-<entity>` and the like) has an explicit `test.afterAll` teardown. UI exposes delete: use it through the Steps API and surface a teardown failure in the return. No delete affordance: call `cleanupViaApiBackdoor(<entity-type>, <id>)` from the local stub `tests/e2e/utils/cleanup-backdoor.ts`, catch `CleanupBackdoorUnavailableError`, push a `cleanup-blocked` annotation, and return `cleanup: blocked`. Never inline an ad-hoc cleanup that hides the pollution signal, never log in as a shared admin to invent a delete path, never leave a TODO instead.

```ts
// tests/e2e/utils/cleanup-backdoor.ts
export class CleanupBackdoorUnavailableError extends Error {
  constructor(entityType: string, id: string) {
    super(`cleanupViaApiBackdoor unavailable — cannot clean up ${entityType}:${id}`);
    this.name = 'CleanupBackdoorUnavailableError';
  }
}
export async function cleanupViaApiBackdoor(entityType: string, id: string): Promise<void> {
  throw new CleanupBackdoorUnavailableError(entityType, id);
}
```

```ts
test.afterAll(async ({}, testInfo) => {
  try { await cleanupViaApiBackdoor('user', createdId); }
  catch { testInfo.annotations.push({ type: 'cleanup-blocked', description: `user:${createdId}` }); }
});
```

When the framework ships the real helper, pin that version and make the stub a re-export; call sites do not change. `cleanup` ∈ `done | blocked | not-needed` in the return (`schemas/subagent-returns/composer.schema.json`).

## Step 4: stabilise

Run the new tests; fix every failure; repeat to 3 consecutive greens. Failures go through `failure-diagnosis` (evidence floor first; classify; heal test issues; report app bugs with evidence and leave the test). After a fix, re-run the full suite, not only the fixed test.

## Step 5: document

Write every scenario in plain English (no code, no selectors) to `tests/e2e/docs/test-scenarios.md`:

```markdown
### Test Name
**Area:** Dashboard
**Steps:** 1. Open the dashboard page  2. Look for the welcome message  3. Check that the company name appears
**Expected Result:** "Welkom terug" heading and the company name are visible
```

The document is the stakeholder-readable record of what is tested, reveals gaps code review misses, and is the diagnosis pre-read's scenario matrix.

## Step 6: review

**6a Optimisation**: load [`test-optimization.md`](../achilles-orchestrator/references/test-optimization.md), run its checks over this journey's tests, apply auto-fixes, re-stabilise on regression, emit its §8 return under `stage_4a`.

**6b API compliance**: the Stage 4b checklist in [`stages-protocol.md`](../achilles-orchestrator/references/stages-protocol.md) over this journey's tests only; fix, re-stabilise, and announce the **API Compliance Review** block in the return. A return that reports composed tests without it is incomplete.

**6c Judge**: standalone invocations (user request, onboard Phase 3, repair rewrites) end with an independent judge dispatched by the orchestrator ([`test-composition-standards.md`](../achilles-orchestrator/references/test-composition-standards.md) §4); you fix must-fix items, re-run 6a/6b if code changed, and wait for the next judge. Inside a coverage pass the Stage B reviewer is the judge; do not request a second.

## Step 7: coverage verification + whole-suite gate

1. Re-read the block's `Steps:`, `Branches:`, `State variations:`.
2. Build the matrix: item × covering tests, plus a partitions column mapping each input's equivalence classes and boundary pairs to tests.
3. Any item with zero tests → back to Step 3, then 4 and 6.
4. Exit only when every item is covered or each gap carries an explicit justification (a seeded row that cannot be created in tests, documented as an external-setup gap).
5. Then the whole-suite gate ([`test-optimization.md`](../achilles-orchestrator/references/test-optimization.md) §7); on refusal return `whole-suite-gate-failed` with the failures and do not mark the journey complete.

## Step 8: return

Composer schema (`schemas/subagent-returns/composer.schema.json`), envelope first (`role`, `cycle`, `status`, `next-action`), then `journey`, `pass`, `tests-added`, `run-time`, `cleanup`, `stage_4a`, `summary`; no test source, DOM or transcripts.

- `new-tests-landed`: counts and paths inline.
- `covered-exhaustively`: only after inspection; the per-expectation mapping table (`| Expectation | Covering spec | Test name |`, one row per `Test expectations:` entry, no `none` rows) goes to the spill file `tests/e2e/docs/.subagent-returns/composer-<journey>-<pass>-c<N>.md` (sentinel `<!-- subagent-returns:composer:<slug>:pass-<pass>:cycle-<cycle> -->`); the return carries `spill`. On a re-pass (passes 2–3) add the four lines `trigger 1 (map delta since pass 1)`, `trigger 2 (pass-1 gaps or deferred stabilisation)`, `trigger 3 (sibling-bug regression required here)`, `trigger 4 (unresolved review findings carried forward)`, each `none` or the evidence; the orchestrator rejects a return missing them.
- `blocked` with the reason (tenant data, environment, credentials) and `skipped` only with the authoriser the brief quoted.
- `no-new-tests-by-rationalisation` is not a return; inspect instead.

Findings (coverage gaps, app-bug flags, discoveries) use the canonical block in [`finding-and-ledger-schema.md`](../achilles-orchestrator/references/finding-and-ledger-schema.md) with ids `<journey-slug>-<pass>-<nn>` (or `<journey-slug>-<nn>` standalone). Commit subjects are the orchestrator's: `test(<j-slug>): <variant>` ([commit-conventions.md](../achilles-orchestrator/references/commit-conventions.md)).

## Platform targets (iOS, Android)

A brief whose target is a native app (`PLATFORM=ios` or `android`) loads [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) with this skill. The steps above still apply; these rules change them, and the Stage B reviewer checks each one as a must-fix. Step names and options come from [`platform-steps.md`](../platform-testing/references/platform-steps.md) only.

- **Where things live.** Specs under `tests/platform/<journey>/`, the fixture `tests/platform/fixtures/base.ts`, screens in `tests/platform/docs/app-context.md`. Step 2 discovery uses the [platform inspection protocol](../achilles-orchestrator/references/platform-inspection-protocol.md), not `playwright-cli`. Every run takes the one form in [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Run command", with a file or `--grep` after the config while iterating.
- **Variants.** The 375x812 mobile variant does not exist on a platform target. P0 and P1 add instead: the happy path in landscape where the app supports it (`setOrientation`, then `verifyOrientation`), the happy path on the small and the large device class (one run per capabilities file), and every permission prompt the journey raises as its own allow, deny and deferred branches ([platform skill](../platform-testing/SKILL.md) §"Permissions and system alerts").

### Start state and reset

A device keeps app data, login and granted permissions from the previous test. Every platform scenario opens with a comment naming its start state (screen, logged in or not, permission states, data present) and its reset level: `relaunch` (the fixture default, terminate and activate), `clear data`, or `reinstall`. A level above relaunch is arranged explicitly in the test or a setup project and the reason is in the comment. A test never relies on what an earlier test left on screen or on disk. A prompt that iOS shows once per install needs `reinstall` or a permission reset to appear. [Platform skill](../platform-testing/SKILL.md) §"App state and reset".

### Keyboard

The on-screen keyboard covers the lower part of the screen after any text entry. Before tapping or asserting an element below a field, call `hideKeyboard()` or bring the element into view with a directional scroll; never assert visibility of a control the keyboard may hide. Where the keyboard's presence is the behaviour (focus moves to the next field, the keyboard closes on submit), assert it with `verifyKeyboardShown`. Use the keyboard-up and keyboard-down snapshots in `app-context.md` to decide. [Platform skill](../platform-testing/SKILL.md) §"Keyboard".

### Gestures and scrolling

A native list renders only the rows near the viewport, so an element further down is absent, not hidden. Reach it with `scrollUntilFound` and an explicit direction. The web habit of checking `exists` and scrolling afterwards always fails here, because the check runs before the row exists. Swipe (element and screen), long press, pinch and zoom are first-class steps with their own variants where the journey uses them, and each is followed by an assertion of its effect (the row's actions shown, the item deleted, the map scale changed). `tapAt` with coordinates is the last resort and carries a comment with the reason. [Platform skill](../platform-testing/SKILL.md) §"Gestures and scrolling".

### Hybrid content

A screen that embeds web content has a native context and one or more `WEBVIEW_*` contexts; `app-context.md` records which context each screen element lives in. A spec switches explicitly with `switchContext`, confirms with `verifyContext`, and switches back to `NATIVE_APP` before leaving the screen. Repository pages belong to one context; a test never relies on an element resolving in whatever context happens to be active. [Platform skill](../platform-testing/SKILL.md) §"Hybrid content".

### Platform divergence

Write the spec once for every platform first. Element names are the same across platforms (one page name, one selector set per platform in the page repository), so a shared spec addresses `submit` on `LoginPage` everywhere. A platform-specific branch (`test.skip(repo.platform === 'ios', '<reason>')`, or a step only one platform has) is allowed only with the reason written in the branch. A difference in behaviour rather than layout is a finding to report, not a branch to write around. [Platform skill](../platform-testing/SKILL.md) §"Platform divergence".

### Animations and timing

Transitions on a device take real time. Every wait is a polling verification (`verify*` steps poll until their timeout); a fixed sleep (`setTimeout`, `driver.pause`, `steps.pace` used as a delay) is refused. Animations are turned off through the capabilities file where the driver supports it, never in the spec. A transition that needs a longer timeout states it on that one verification with the reason. [Platform skill](../platform-testing/SKILL.md) §"Animations and timing".

### Web-only steps throw

On a platform run a web-only step (URL, tabs, cookies, storage, network waits, HTML and CSS reads, file upload, `selectDropdown`, `hover`, right click) throws `PlatformNotSupportedError`, and so does a platform step a platform cannot do (`pressBack` on iOS). Never catch the error to keep going and never wrap a step in a try to make it optional; use the platform step that does the job, or a stated platform branch. The oracle ladder carries over: the L1 round trip is a relaunch (`resetApp`) and a re-read of the screen instead of a page reload, and an L2 API oracle applies unchanged when the suite can reach the app's API. [`platform-steps.md`](../platform-testing/references/platform-steps.md) §"Step semantics".

## Anti-patterns

Presence-only coverage; hardcoded data that breaks when the environment changes; ignored flakes (a 1-in-10 failure is a bug); over-mocking (e2e exercises the real app; use a named skip, not a fake); giant spec files; count padding (three tests over distinct equivalence classes beat fifteen duplicates the dedup pass deletes).

## Invocation

`journey=<j-slug>` is the only parameter; `mode: re-pass` with trigger evidence arrives on passes 2–3. Cross-journey order and parallelism belong to the orchestrator; within a journey, variants are composed sequentially so each inherits the previous one's selectors.
