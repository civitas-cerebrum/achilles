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
4. Write the test to [`test-baseline.md`](test-baseline.md): the Steps API only ([TB-A1](test-baseline.md#tb-a1) to [TB-A4](test-baseline.md#tb-a4)), repository names only ([TB-A5](test-baseline.md#tb-a5)), a stable id at the head of every title ([TB-I1](test-baseline.md#tb-i1)), a timeout budget only where a test needs more than the default ([TB-W1](test-baseline.md#tb-w1), [TB-W2](test-baseline.md#tb-w2)).
5. **Every test proves the action's effect, causally**: the oracle is present and tied to the action ([TB-R4](test-baseline.md#tb-r4)), and it would fail if the action had silently done nothing ([TB-R5](test-baseline.md#tb-r5), which lists the tautologies to catch).
6. Run `npx playwright test <spec>`.
7. On failure, follow `failure-diagnosis` (evidence floor first: trace, DOM at failure, console; classify; heal or report). New selectors go through Stage 2 again. App bugs are returned as `app-bug` with evidence and the test left as written.
8. On pass, meet the stability bar (3 consecutive greens), then run Stages 4a and 4b, stage the files (`git add`; the orchestrator commits) and return.

**Fix mode.** Skip Stages 1–2: read the API reference and the spec, diagnose, fix, meet the stability bar, sweep. Never add selectors silently.

## Stage 4a: optimisation

Load [`test-optimization.md`](test-optimization.md) and run its checks over every spec written or modified in this dispatch, plus `base.ts` and the `## Test Infrastructure` section of `app-context.md`. Apply the auto-fixes; write helpers into `base.ts` only when both gates in §4 of that file hold; re-run the affected tests; emit the structured return per its §8. A regression from an auto-fix goes back through step 7 above before Stage 4b.

## Stage 4b: API compliance review

Runs every time Stage 4a returns clean, per spec, before moving on. Load the API reference again and check every touched test against [`test-baseline.md`](test-baseline.md) (only the touched test must be clean). Checklist:

1. **Signatures, imports, option shapes**: [TB-A7](test-baseline.md#tb-a7), [TB-A8](test-baseline.md#tb-a8), [TB-A10](test-baseline.md#tb-a10).
2. **Repository names** (including `child: { pageName, elementName }`): [TB-A5](test-baseline.md#tb-a5), [TB-A6](test-baseline.md#tb-a6).
3. **No raw Playwright**: [TB-A1](test-baseline.md#tb-a1) to [TB-A4](test-baseline.md#tb-a4), [TB-A2b](test-baseline.md#tb-a2b), [TB-A11](test-baseline.md#tb-a11), [TB-A12](test-baseline.md#tb-a12), [TB-A14](test-baseline.md#tb-a14); a version gap is an upgrade ([TB-A13](test-baseline.md#tb-a13)).
4. **Fixtures**: [TB-A9](test-baseline.md#tb-a9).
5. **Flow control and structure**: [TB-F1](test-baseline.md#tb-f1) to [TB-F7](test-baseline.md#tb-f7), [TB-S1](test-baseline.md#tb-s1) to [TB-S9](test-baseline.md#tb-s9).
6. **Oracle**: [TB-R4](test-baseline.md#tb-r4), [TB-R5](test-baseline.md#tb-r5), [TB-R6](test-baseline.md#tb-r6).
7. **Identity**: [TB-I1](test-baseline.md#tb-i1) to [TB-I4](test-baseline.md#tb-i4).
8. **Timeouts**: [TB-W1](test-baseline.md#tb-w1). Strip an override without a recorded reason and re-run; a timeout failure means the need is real: revert that call and add the `// perf:` or `// slow:` comment.
9. **Support files the change touched**: [TB-X1](test-baseline.md#tb-x1) to [TB-X4](test-baseline.md#tb-x4).

Report the review in the return under the heading **API Compliance Review** (files reviewed; per issue the rule id (`TB-…`), the file:line, what is wrong, the correct usage; or "All API calls match the documented signatures"). Fix every issue, investigate why it was written (a misread signature propagates into the next scenario), re-run, confirm green.

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
