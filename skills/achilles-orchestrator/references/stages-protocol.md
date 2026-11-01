# Stages protocol: inspection, authoring, review

The agent-side content of the four-stage authoring pipeline. The orchestration (who is dispatched when, what counts as approval) is [`../workflows/author-scenario.md`](../workflows/author-scenario.md). Stage 1 (the scenario) is the inspector's discovery plus the brief; this file starts at the format it produces.

The browser primitive for Stages 1–3: [`playwright-cli-protocol.md`](playwright-cli-protocol.md). The API surface Stage 3 writes against: [`api-reference.md`](api-reference.md).

## Stage 1 output: the scenario

```
Scenario: [Descriptive name]
  Given [precondition]
  And [additional precondition if needed]
  When [action the user takes]
  And [additional action if needed]
  Then [expected outcome]
  And [additional verification if needed]
```

Complex flows become several scenarios. A complete scenario in the brief is reformatted, not re-discovered; only what is unclear becomes a question.

### App context

Every inspector, author or probe that visits a page or discovers a component appends to `tests/e2e/docs/app-context.md`, the project's living knowledge base. Per page:

```markdown
## PageName — `/route/pattern`
**Purpose:** One sentence.
**Sections:** Major UI areas.
**Data fields:** Labels and value types shown.
**Actions:** Buttons, links, forms.
**States:** Empty, loaded, error variations.
**Navigation:** Reached from → links to.
**Known issues:** Bugs or quirks observed.
```

Re-read the file before appending (parallel experts share it); never rewrite another entry. Without it every session starts from zero and the failure-diagnosis pre-read has nothing to compare against.

## Stage 2: element inspection (inspector)

1. Open a session and navigate to each page in the scenario: `npx playwright-cli -s=stage2-<slug> open --browser=chromium <URL>`; later `goto` / `click` / `fill` reuse the session.
2. Snapshot (`… snapshot`) and read the DOM for a reliable selector per element. Preference: `data-test` / `data-testid` > `id` > stable CSS > text > XPath.
3. Build the proposed entries; mark which are new versus already present in `page-repository.json`.
4. Record the inspection facts per element in the report: URL path, how the state was reached, tag, role, accessible name, test attribute, the match count for the candidate (1, or ≥ 1 for a `"list": true` entry), the frame title if framed, and a snapshot excerpt or screenshot path. These are the author's input for the evidence sequence in Stage 3 ([`selector-evidence.md`](selector-evidence.md)); the inspector inserts nothing and runs no evidence tool.
5. Close the session.

**No stable selector.** When inspection yields only fragile candidates (position-dependent CSS, drifting text, role collisions, nth-child chains): if the workspace holds the frontend source (`package.json` lists the UI framework; a `src/`-style component tree exists), the author's brief gains a `selector-development` JIT step for that element; if not, record the best candidate with a test-debt note in the return. Do not harden with compound selectors or nth-child chains; that adds brittleness without stability.

**Live app unreachable.** Return `NEEDS_CONTEXT` listing the elements that need user-supplied selectors; never guess.

Proposed entries use the repository shape:

```json
{ "pages": [ { "name": "LoginPage", "elements": [
  { "elementName": "usernameInput", "selector": { "css": "input[data-test='username']" } },
  { "elementName": "submitButton",  "selector": { "css": "button[type='submit']", "text": "Log In" } }
] } ] }
```

Entries that cannot be seen live (source-only, user-supplied, behind an interaction the tool cannot perform) are proposed with that fact stated; they ride along flagged `provisional` and are listed in the orchestrator's `DONE_WITH_CONCERNS` hand-back.

## Stage 3: write automation (author)

1. Read `tests/fixtures/base.ts` (or `tests/e2e/fixtures/base.ts`) and `playwright.config.ts`; create or repair only what is missing or broken. Read `../../test-data-conventions/SKILL.md` and `tests/e2e/docs/test-data-plan.md`; create the plan from the skill's template when it is missing.
2. Add the proposed entries to `page-repository.json` with `"provisional": true`, run `npx achilles-selector-evidence --page <Page> --element <element> …` for each (count 1, or ≥ 1 for `"list": true`; it writes `<Page>.<element>.md` + `.png`), and drop the flag in the same change ([`selector-evidence.md`](selector-evidence.md)). An entry the tool refuses or cannot reach stays flagged and is named in the return.
3. Read [`api-reference.md`](api-reference.md) in full; never write `steps.*` calls from memory.
4. Write the test through the Steps API: every interaction via `steps.*`; no raw `page.locator()`; selectors only by repository name; a stable test id at the head of every title ([`test-identity.md`](test-identity.md)); `test.describe.configure({ timeout: 60_000 })` on every describe block.
5. **Every test ends with a verification that proves the action's effect, causally.** Ask: if the action had silently done nothing, would this assertion still pass? If yes, it is a tautology. Catch: clicking a list item then asserting the list is present; hovering then asserting visibility; filling then asserting the input exists; clicking a button then asserting the button is enabled; filtering by regex then asserting the parent collection exists. Verify the specific effect instead (navigation, a selected-state attribute, the filled value or a dependent element, a modal, a URL change, the filtered result). Only a documented framework-smoke case may end on `verifyState('visible')`, with a one-line comment saying why.
6. Run `npx playwright test <spec>`.
7. On failure, follow `failure-diagnosis` (evidence floor first: trace, DOM at failure, console; classify; heal or report). New selectors go through Stage 2 again. App bugs are returned as `app-bug` with evidence and the test left as written.
8. On pass, meet the stability bar (3 consecutive greens), then run Stages 4a and 4b, stage the files (`git add`; the orchestrator commits) and return.

**Fix mode.** Skip Stages 1–2: read the API reference and the spec, diagnose, fix, meet the stability bar, sweep. Never add selectors silently.

## Stage 4a: optimisation

Load [`test-optimization.md`](test-optimization.md) and run its checks over every spec written or modified in this dispatch, plus `base.ts` and the `## Test Infrastructure` section of `app-context.md`. Apply the auto-fixes; write helpers into `base.ts` only when both gates in §4 of that file hold; re-run the affected tests; emit the structured return per its §8. A regression from an auto-fix goes back through step 7 above before Stage 4b.

## Stage 4b: API compliance review

Runs every time Stage 4a returns clean, per spec, before moving on. Load the API reference again; cross-reference every call. Checklist:

1. **Signatures**: argument count, order (`elementName` before `pageName`), types.
2. **Imports**: every type (`DropdownSelectType`, `EmailFilterType`, `FillFormValue`, …) from `@civitas-cerebrum/element-interactions` or `@civitas-cerebrum/email-client`; nothing invented.
3. **Naming**: `pageName` PascalCase, `elementName` camelCase, both present in `page-repository.json`.
4. **Listed elements**: `child` as `{ pageName, elementName }`, not an inline selector.
5. **Dropdowns**: `DropdownSelectType.RANDOM | .VALUE | .INDEX` with the matching companion field.
6. **Email API**: `sendEmail` / `receiveEmail` / `receiveAllEmails` / `cleanEmails` signatures; `EmailFilterType` filters.
7. **No raw Playwright** where a `steps.*` equivalent exists.
8. **Fixtures**: only `steps`, `repo`, `interactions`, `contextStore`, `page` plus the project's own.
9. **Waits**: state strings `'visible' | 'hidden' | 'attached' | 'detached'`; the `waitForResponse` callback pattern.
10. **Verifications**: `{ exactly | greaterThan | lessThan }` for `verifyCount`; bare `verifyText()` asserts non-empty (the 4-arg `notEmpty` form is deprecated).
11. **Causal verification** on every test (the Stage 3 doctrine, review-side): presence of a trailing assertion, and it fails under a no-op.
12. **Identity**: every case titled `TCXX-NNNNNN · <behaviour>` (another shape only via the project's configured pattern); an intentional red carries `@known-defect` and names its report ([`test-identity.md`](test-identity.md)).
13. **Timeouts**: strip per-call overrides, `{ timeout }` options and inflated describe timeouts unless performance fatigue is recorded (a timeout-class failure Stage 3 resolved with the override, a slow-page note in `app-context.md`, or a `// perf:` / `// slow:` comment). Fixture-level and `test.setTimeout()` stay. Re-run after stripping; a timeout failure means the fatigue is real: revert that call and add the `// perf:` comment.

Report the review in the return under the heading **API Compliance Review** (files reviewed; per issue the file:line, what is wrong, the correct usage; or "All API calls match the documented signatures"). Fix every issue, investigate why it was written (a misread signature propagates into the next scenario), re-run, confirm green.

## Stage 4c: composition judge

After 4a and 4b are clean and before commit, the orchestrator dispatches a fresh reviewer in judge mode ([`test-composition-standards.md`](test-composition-standards.md) §4): four dimensions, SATISFIED or NOT SATISFIED, fresh judge per cycle, three consecutive NOT SATISFIED escalate upward. The author fixes must-fix findings, re-runs 4a/4b when code changed, and waits for the next judge; it never judges its own composition.

## Stage 4b is every mode's exit gate

Any mode that writes or edits test code runs the Stage 4b sweep over what it touched before it returns:

| Mode | When |
|---|---|
| author-scenario | after 4a, per spec |
| `test-composer` | Step 6b, before the coverage gate and the return |
| coverage passes | per journey per pass, inside the author; a return without the sweep is an incomplete unit |
| `bug-discovery` | over every reproduction test, `@dom-only` ones included |
| verify-change | before the ticket's sign-off |
| `evidence-capture` | on graduation into a durable spec (a bundle is not test code) |
| repair-suite, `failure-diagnosis` | over every spec a heal edited; a fix that reintroduces raw Playwright or a tautology made the suite worse while turning it green |
| `contract-testing`, `database-testing`, `agents-vs-agents` | over the specs they add |

Modes that write tests as a means to something else (reproducing a bug, healing a red, closing a ticket) are exactly the ones that skip the sweep, because their own goal reads as met the moment the test passes; and tests are written by copying the last one, so one unswept file propagates its mistakes. Announce the sweep with the **API Compliance Review** heading so the evidence is unambiguous.
