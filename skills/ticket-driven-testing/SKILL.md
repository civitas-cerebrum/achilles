---
name: ticket-driven-testing
description: Use when a ticket from an issue tracker (Linear, Jira) is the unit of QA work — a QA ticket paired to a dev ticket, a PR awaiting QA sign-off, a "test this feature" request naming an issue key, or any ask to verify acceptance criteria against a branch that is not yet merged. Also use when asked to automate the tests for a ticket, produce evidence for a ticket, or QA a feature branch.
---

# Ticket-Driven Testing

## Overview

A ticket is not a test plan. It is a claim about behaviour, a branch that allegedly implements it, and a set of acceptance criteria someone will sign off against. This skill turns that into: verified evidence, durable regression tests, and sentinel tests for every defect found.

**Core principle: read the diff before you touch the app.** The code tells you which acceptance criteria are structurally guaranteed, which are merely probable, and where the defects are. Testing blind wastes the run and produces assertions that pass for the wrong reason.

**REQUIRED SUB-SKILL:** the evidence run itself is `companion-mode`. This skill wraps it with the ticket, branch, and diff context that companion-mode's Phase 1 assumes you already have.

### The sequence

Whenever you list what you are going to do, list these. All nine, in this order. Mark any you are skipping and say why — an omitted step is a decision, and it belongs in the report.

```
1  Read the ticket AND its parent          → ACs verbatim, branch, PR
2  Check PR review state                   → unresolved CHANGES_REQUESTED is itself a finding
3  Worktree the branch                     → never switch a shared checkout
4  Read the whole diff                     → BEFORE touching the app
5  Reach the environment                   → preview auth, bypass tokens
6  Probe live, then run companion-mode     → evidence bundle
7  Write durable tests + a sentinel per defect
8  RUN THE NEGATIVE CONTROL                → the suite MUST fail where the fix is absent
8b DISPATCH THE ADVERSARIAL REVIEW         → 4 subagents attack the tests; you do not self-assess
9  Report: AC verdicts and defects, separately
```

Step 8 is the one that gets dropped, and instructions have repeatedly failed to stop that — which is why 8b delegates it rather than reminding you. A suite nobody has seen fail is not regression cover, and "12/12 green on the branch" is not evidence that it would have caught anything.

## The Contract

Produce all five. A run that stops after evidence is half a deliverable.

1. **A ticket brief** — acceptance criteria, the dev branch, the PR and its review state.
2. **A diff review** — findings ranked by severity, each one a sentinel candidate.
3. **An evidence bundle** — via `companion-mode`, verdict grounded in the ACs.
4. **Durable tests** — regression cover in the suite, plus one sentinel per confirmed defect.
5. **A negative-control result** — proof the tests fail where the fix is absent (§8). Without it you have tests that pass, not tests that discriminate.

### The sign-off gate

**You may not report a QA verdict until you have run the negative control (§8) and can state its result.**

This is the one step baseline testing showed agents reliably skip. Asked "are we done, the suite is green?", an agent following this skill listed six sensible next actions and omitted the negative control entirely — while an agent with no skill at all reached for it unprompted. Having the section is not enough; it has to be a gate.

So, before writing any verdict, answer these three in the report:

- Did the suite run against an environment **without** the fix?
- Which tests **failed** there, and which **passed**?
- For each one that passed — is it close-regression cover of pre-existing behaviour (fine), or does it fail to discriminate the feature (worthless as AC cover)?

"The tests are green on the branch" answers none of these. If you cannot run the control, say so explicitly in the verdict — an unverified suite reported as unverified is honest; reported as regression cover it is not.

## Phases

### 1. Ticket intake

Read the QA ticket **and its parent**. QA tickets carry the test scope; parent dev tickets carry the acceptance criteria, the design links, and the implementation notes. Neither alone is enough.

Extract four things: the **ACs verbatim**, the **branch**, the **PR**, and the **current status**.

**Tracker-agnostic.** This skill needs six capabilities from whatever tracker is in play. Discover what is actually connected — an MCP server, a CLI, a REST token — and map onto it. Never hard-code one vendor's tool names into the workflow.

| Capability | Linear | Jira | Fallback |
|---|---|---|---|
| Read a ticket | `get_issue` | `getJiraIssue` | REST / `curl` |
| Read its parent | `parentId` on the issue | `fields.parent` | same |
| Find the branch | `gitBranchName` field | branch in the dev-status panel, or the issue key as a branch prefix | `git branch -r \| grep -i <KEY>` |
| Find the PR | attachments / links | remote links, or the dev-status panel | `gh pr list --search "<KEY>"` |
| Post the report | `save_comment` | `addCommentToJiraIssue` | REST |
| Attach evidence | `prepare_attachment_upload` → PUT → `create_attachment_from_upload` | `attachFile` | REST multipart |
| Move status | `save_issue` with a state | `transitionJiraIssue` | REST |

Two portability rules that bite in practice: **status names are per-project**, so enumerate the available states rather than assuming a "Done" exists; and **the ticket key is the only reliable join** between tracker, branch and PR — expect the branch to carry the *dev* ticket's key while you work the *QA* ticket's, and confirm rather than infer.

If no tracker is reachable at all, the workflow still runs — the user pastes the ACs and the branch, and phases 2 onward are unchanged. Losing the tracker costs you intake and reporting, not the method.

### 2. PR state — a first-class QA signal

Check reviews and their timestamps against commit timestamps.

An **unresolved `CHANGES_REQUESTED`** on a ticket sitting in QA Testing is a finding in itself. A later commit may look like the fix, but "plausibly addressed" is not "re-approved" — report the gap rather than assuming it closed. Conversely, an automated reviewer's comment may already be fixed by a later commit; verify against the current code before repeating it as a defect.

### 3. Isolate the branch in a worktree

```bash
git worktree add ../<repo>-<ticket> origin/<feature-branch>
```

**Never switch the shared checkout.** Another session, another agent, or a running dev server may depend on the current branch. A worktree costs nothing and cannot disturb them.

### 4. Review the diff

Read every changed file. For each AC, decide what would actually prove it:

- **Structural guarantees beat visual ones.** "Only one sticky bar" is proven by an element computing `position: static` at that breakpoint — it *cannot* pin. A screenshot only shows it *did not* pin this time.
- **Find the load-bearing attributes.** `data-*` hooks, `inert`, `aria-*`, state-marker classes. These are the stable selectors, and they usually already exist — check before proposing a source change.
- **Note what the diff deletes.** Removed feature flags, removed route mappings, removed components each imply a regression surface.

Record findings now, with severity. They become sentinels in phase 7.

### 5. Reach the environment

Feature branches deploy to preview URLs that are usually **protection-gated**. Symptom: `curl` returns HTTP 200 with a provider login page, not your app.

- Put the bypass token in a gitignored env file. Verify the gitignore pattern actually covers it.
- **Do not set the suite's base-URL variable in a shared env file** — it silently retargets every other suite. Pass it per command.
- For a CLI browser session, providers usually accept the token as a query parameter that sets a bypass cookie for the session.

### 6. Discovery, then evidence

Probe the live page for the geometry and state the ACs talk about — computed `position`, element rects, CSS custom properties, which elements sit near the viewport top, counts of duplicated nodes. One well-designed probe returning JSON beats a dozen snapshots.

Then run `companion-mode` for the evidence bundle.

> **Phases 1–9 are one sequence.** A run that stops at 7 has produced tests nobody has shown to discriminate the fix. 8 is not optional follow-up.

### 7. Durable tests and sentinels

Regression tests go in the project's suite, not the bundle. One test per AC, plus edge cases and close-regression cover for what the diff touched nearby.

For each confirmed defect, write a **sentinel**: assert the *correct* behaviour and mark it `test.fail()`. It fails today, keeps the suite green, and flips to a loud "expected to fail but passed" the moment someone fixes the bug — which is the signal to delete it.

```ts
test('TC_...[SENTINEL <TICKET>-D1]: <correct behaviour>', async ({ steps }) => {
  test.fail(true, 'Known defect: <what is wrong>. Delete this sentinel once fixed.')
  await steps.verifyCount('stateMarker', 'SomePage', { exactly: 0 })
})
```

**Pick a durable observable.** A sentinel is worthless if the app erases its own evidence — see the session-storage trap below.

If the suite runs against an environment where the feature is not deployed yet, gate it:

```ts
test.beforeEach(async ({ steps }, testInfo) => {
  const present = await steps.isVisible('featureRoot', 'SomePage', { timeout: 5000 })
  testInfo.annotations.push({ type: 'feature-gate', description: `present: ${present}` })
  test.skip(!present, 'Not deployed here yet.')
  // TODO(<TICKET>): delete this guard once shipped — after that, absence IS the regression.
})
```

The `TODO` is not optional. A permanent silent skip is worse than no test.

### 8. Prove the tests discriminate the fix — the negative control

A green suite on the feature branch proves the assertions pass *where the feature exists*. It does not prove they would fail where it doesn't. Those are different claims, and only the second one makes the suite regression cover.

**Run the suite against an environment without the fix — usually production before the PR ships — and require it to FAIL.**

A gated suite will skip there, which proves only that the gate works. So give the gate an explicit off switch and use it:

```ts
const FEATURE_GATE_DISABLED = process.env.E2E_FEATURE_GATE === 'off'
test.skip(!present && !FEATURE_GATE_DISABLED, 'Not deployed on this environment yet.')
```

Read the result per test, not in aggregate. Three outcomes, three meanings:

| Outcome without the fix | Meaning |
|---|---|
| **Fails** | The test discriminates the feature. This is what you want from AC cover. |
| **Passes** | Either it is close-regression cover of *pre-existing* behaviour (correct — filter drawers and sort controls should pass on both), or it asserts nothing the feature changed and is worthless as AC cover. Decide which; do not assume the charitable reading. |
| **Skips** | You forgot the off switch. The run told you nothing. |

**`test.fail()` sentinels cannot pass this control**, and it is worth knowing why before it confuses you: on an environment without the feature they fail because the element is *missing*, not because the defect is *present* — and `test.fail()` reports that as passed. A sentinel is indistinguishable between "bug reproduced" and "feature absent". The feature gate is what keeps that harmless; nothing else does.

#### 8b. Dispatch the adversarial test review

Do not self-assess your own tests. **Dispatch subagents whose mission is to attack them.** Baseline testing established why: an agent that has just written a suite reliably skips checking whether it can fail — three separate instruction-level fixes failed to change that. Delegation works where instruction did not, because the reviewer never wrote the tests and has nothing else on its list.

Dispatch these **four in parallel**, scoped to the diff and the ACs. Anything outside those two is out of scope — an unbounded critic returns "you didn't test Safari 14 on 3G" forever.

| Mission | Question it must answer | Required output |
|---|---|---|
| `probe-mutation` | For each AC, what concrete one-line change to the app would break it — and does any test catch it? **Make the change, run the suite, revert.** | Per mutation: the diff hunk, and `caught` / `survived` |
| `probe-coverage` | Which AC clauses and which hunks of the diff have **no** assertion pointing at them? | Gap list keyed to AC text and `file:line` |
| `probe-assertions` | Does each assertion prove a structural guarantee, or did it observe one passing render? | Per assertion: `structural` / `incidental`, with the reason |
| `probe-value` | Is each test **worth keeping** — does it protect behaviour a user would notice losing, at a maintenance cost the risk justifies? | Per test: `keep` / `merge` / `delete`, with the reason |

**On `probe-value` specifically.** The other three ask whether a test *works*; this one asks whether it should *exist*. A test can catch its mutation and still be a liability. The four verdicts it hunts for:

- **Redundant** — another test already fails for the same cause. The second one adds run time and a second thing to update, not a second signal.
- **Testing the framework** — asserting that the router routes or the component library renders. That is someone else's test suite.
- **Cost exceeds risk** — a slow, fragile, environment-sensitive test guarding something trivial or cosmetic. Every future failure of it will be triaged, and most will be noise.
- **Unfalsifiable in practice** — technically green, but it would pass in nearly every world, including broken ones. `probe-mutation` catches the strong form; this catches the weak form the mutation happened not to touch.

Bias it toward **`merge` over `delete`**, and require evidence for either — name the test that already covers it, or the specific reason the risk does not warrant the cost. Deleting cover is the one recommendation here that can lose information permanently, so an unevidenced `delete` is a rejected finding. Coverage counts are not the goal: twelve tests where six would do is worse than six, because the six carry the same signal and half the maintenance.

**Non-negotiables for these dispatches:**

- **They must execute, not just read.** The most dangerous defect found in the run this skill came from was a sentinel that *passed while the bug was live* — the destination page consumed the session-storage flag it asserted on before the assertion ran. No amount of reading would have caught that; running it did.
- **Silence is not a pass.** A reviewer that reports nothing is indistinguishable from a lazy one. Require the shape: findings, **or** an explicit *"I attempted these N mutations and the suite caught all N"* with the list. An empty return is a failed dispatch, not a clean bill of health.
- **A surviving mutation is a finding, not a suggestion.** It means a stated AC has no test that can fail for it. Fix the test before reporting the verdict.

Write the outcome to `.achilles/adversarial-verification/<ticket-key>.json`:

```json
{
  "ticket": "<KEY>", "ranAt": "<ISO-8601>",
  "negativeControl": { "environment": "<url>", "failed": 5, "passed": 1, "skipped": 0 },
  "mutations": [{ "ac": "AC-2", "hunk": "…", "caught": true }],
  "coverageGaps": [], "incidentalAssertions": [], "lowValueTests": []
}
```

That receipt is what the harness gate looks for — see `harness-hooks.md`. Writing it by hand without running the probes defeats the only mechanism that catches this failure, and the failure it catches is *your own*.

### 9. Live observation — watch it, don't just assert it

Assertions confirm what you thought to ask. Watching the page reveals what you didn't. Before trusting a green suite, drive the flow once by hand — screenshot **and** probe state after **every** action, not just at the end.

Step in increments small enough to catch transitions, and capture both a screenshot and a state dump at each step:

```
y=0     header=40,143   pcp=631,712   pos=static  inert=1  stuckMarker=0
y=400   header=0,103    pcp=231,312   pos=static  inert=1  stuckMarker=0
y=560   header=0,103    pcp=71,152    pos=static  inert=1  stuckMarker=1   ← defect window opens
y=1200  header=0,103    pcp=-569,-488 pos=static  inert=0  stuckMarker=1   ← merge completes
```

That trace located a defect window no assertion had bounded: between y≈560 and y≈700 the row reports itself stuck while still `static` **and still half-visible under the header** — so a user can click a pill that is about to report the wrong telemetry. A pass/fail test would never have surfaced the *width* of that window.

**Live comparison.** Where the change is visual, drive the same URL and the same scroll positions on the environment *with* the fix and the one *without*, and diff the screenshots. Differences you cannot explain are findings.

**Assert a control element, always.** A live probe that reports "the feature's selectors are absent" is ambiguous: the feature may be missing, or *the page may never have loaded*. Bot protection, an auth wall or a CDN challenge all render a page where every product selector is absent — and it looks exactly like a shipped-but-disabled feature.

Include one element in every probe that must exist on **any** build of the page (a header, a footer, `<main>`). If the control is missing too, you are not looking at the app and every conclusion from that probe is void. Note also that a suite reaching production via an allowlisted header (`x-e2e-test`) proves nothing about whether an *ad-hoc* browser can — the CLI session gets challenged where the suite sails through.

## "Show me" — demonstration runs

**When the user says "show me", "let me see it", "watch it run", "demo this", or anything of that shape, they are not asking for a pass/fail summary. They are asking to watch.** Deliver a run that is:

- **headed** — a real browser window,
- **born slow** — `launchOptions.slowMo` ≥ **1500ms** per action, so the native real-time recording is watchable as-is. Prefer the project's existing hook (`E2E_SLOWMO=<ms>`) where it has one. Same standard `self-repair` applies to bug recordings; 500ms proved too fast to track individual actions.
- **recorded** — video always on, and **serial** (`workers: 1`), because parallel workers open several windows at once and produce interleaved footage nobody can follow,
- **retry-free** — a retry overwrites the recording of the attempt they watched.

**Use the shipped runner — do not hand-write this per project:**

```bash
npx achilles-show <path|--grep …>        # every arg forwards to `playwright test`
```

`achilles-show` derives a run from the project's existing `playwright.config.*`, applying exactly the overrides above, and writes mp4s to `show-recordings/<timestamp>/`. Nothing in the project's own config changes, and there is no second config to maintain or drift.

Never flag-patch the CI config to achieve this by hand. `slowMo` multiplies every action's wall time, so CI-tuned timeouts fire spuriously; demo settings leaking into CI are actively harmful.

**Never slow footage down afterwards.** The slow-down happens at the source — pacing the actions treats the cause, time-stretching the video treats the symptom. If actions still blur, raise `slowMo` and re-record.

**Container format is a separate concern from pacing.** Transcoding webm → mp4 changes container and codec, not timing, so it does not conflict with the born-slow rule. `achilles-show` handles this: it resolves `ffmpeg-static` → `ffmpeg` on `PATH` → keeps the webm and says so explicitly. Never silently ship a format the user did not ask for.

Gitignore `show-recordings/` — demonstration footage is not a repo artifact.

**If a project needs behaviour `achilles-show` does not provide**, that is a gap in the runner, not a licence to hand-roll a per-project config. Fix it in the package — see `contributing-to-element-interactions`.

## Traps

Each of these cost a failed run or a wrong conclusion in practice.

| Trap | What happens | Fix |
|---|---|---|
| **Suite's default viewport** | ACs are signed off at one size; the project's device preset is another. Behaviour genuinely differs. | Pin the viewport explicitly in `beforeEach`. Cover the other size as its own test. |
| **Late-hydrating components** | Client-rendered regions (search/results grids) are absent when your first assertion runs; your feature gate checked an SSR'd element and passed. | `waitForState` on the client-rendered container before asserting against it. |
| **Self-consuming observables** | A sentinel watches a session-storage flag; the destination page's effect reads and deletes it before you assert. Test passes, bug is live. | Assert a state that persists — a DOM state marker at the source, not a message in flight. |
| **Assumed default states** | You click a toggle expecting it to open; it was already open, so you closed it. | Read the initial state, assert the round-trip, don't assume a starting position. |
| **Unredacted HAR** | Your bypass token appears in the request headers of every entry — hundreds of copies inside a bundle you are about to commit. | Redact by header name and strip response bodies. This also shrinks the HAR by ~20×. |
| **Bundle size** | Trace + video + HAR + an HTML report that duplicates all three easily exceeds 200MB. | Promote trace/video to the bundle root, drop the duplicate report, slim the HAR. Decide deliberately whether the directory is committed or gitignored. |
| **Blocked postinstall scripts** | pnpm blocks dependency build scripts by default and only prints a warning. A package whose binary is fetched in `postinstall` resolves to a path that does not exist, failing at call time, not install time. | Read the "Ignored build scripts" warning. Add the package to `pnpm.onlyBuiltDependencies`, or run its installer directly. |
| **Bare `spec.ts` is not collected** | Playwright's default `testMatch` (`**/*.@(spec\|test).ts`) requires a prefix before `.spec` — a file literally named `spec.ts` matches nothing and the run reports "No tests found". | Set `testMatch: 'spec.ts'` in the bundle-local config, or prefix the filename. |
| **HTML report nested in `outputDir`** | The HTML reporter wipes its folder before writing and refuses to start when it sits inside the test output folder. | Point `outputFolder` outside `outputDir`. |
| **Bot protection reads as "feature absent"** | An ad-hoc browser hitting production gets a CDN challenge page. Every feature selector is absent, so the probe looks like a clean "not deployed yet" — while you are actually looking at a block page. | Probe a control element that exists on any build (header/footer/`<main>`). Control missing ⇒ conclusion void. See §9. |
| **Green on the branch mistaken for regression cover** | The suite passes where the feature exists, and nobody checks it fails where it doesn't. Assertions that key off something unrelated to the change pass in both places. | Run the negative control (§8) and read it per test. |
| **Diagnosing against the wrong control** | A check fails on your PR and passes on someone else's, so you conclude your change caused it — when the real variable was the *author*, the base commit, or the branch age. You then "fix" something that was never broken. | Pick a control that differs from yours in **one** dimension. Comparing to another PR by the same author, or to your own branch before the change, is a control; comparing to a different person's PR is not. |
| **Test tooling reaching outside the test directory** | Adding a dependency, a lockfile entry, or a package-manager setting for a test convenience changes how *every* app in the workspace installs or builds. Local runs never see it; CI does. | Keep test tooling inside the test package. If a change edits the root manifest or the lockfile, that is the moment to ask whether the feature justifies workspace-wide reach — usually a runtime fetch or an optional dependency does the same job with no blast radius. |

Those last two are the same failure in different clothes: **applying less rigour to your own changes than to the code under test.** A QA agent that runs a negative control on the application and then pushes an unverified packaging change has simply moved the untested surface, not removed it.

## Framework gaps

When an assertion has no API surface, do **not** silently drop to raw driver calls. Assert the strongest expressible proxy, capture the rest as screenshots, and record the gap.

Known gap: **document-level geometry.** "No horizontal clipping" is `documentElement.scrollWidth > clientWidth`, and step-based frameworks generally have no element-free assertion for it. Proxy: assert every control stays present and reachable at each width, and let the per-width screenshots carry the visual proof.

**REQUIRED SUB-SKILL:** to close a gap rather than work around it, use `contributing-to-element-interactions`.

## Reporting

Report defects the diff review found even when every AC passes — they are the value a human reviewer could not get from a green suite. Separate them clearly from AC verdicts: **"all three ACs pass, and here are four defects"** is a coherent and common outcome.

Never silently upgrade a defect into an AC failure, or silently drop one because the ACs passed.

## Baseline testing

Three pressure scenarios, run against subagents with and without this skill. The results are worth stating plainly, because two of them argue *against* parts of the skill.

Scenarios 2 and 3 were run against the draft; scenario 1 was re-run against the current text after the harness bug described below was fixed.

| Scenario | Without the skill | With the skill |
|---|---|---|
| **Green suite, 2h to sprint end, "are we done?"** | Refused to sign off. Named "verify the tests can fail" as its **first, non-negotiable** action. Deferred reading the diff to step 5, after testing. | Refused to sign off. **Negative control as step 1**, §8b probes as step 2, results read per test, receipt written. (The *draft* omitted the control entirely — see below.) |
| **Start QA; shared checkout is dirty, teammate's server running** | Already correct: `git worktree add`, no checkout, no stash, isolated port. | Same, plus PR-state check and diff-before-app ordering. |
| **All 3 ACs pass; diff contains a telemetry defect** | Reported the defect, flagged the A/B implications, filed a linked ticket. Set the ticket **Done**. | Same, plus a `test.fail()` sentinel, and declined to self-close. |

**What this actually establishes.** The competent baseline is high. Worktree isolation and reporting an out-of-scope defect are things a good agent already does — those sections codify existing practice rather than correcting a failure, and should be read as reference, not as discipline.

What the skill measurably adds: **diff-before-testing ordering**, **PR review-state as a QA signal** (never mentioned in any baseline), **`test.fail()` sentinels**, and **not self-closing a ticket**.

### How step 8 was made to fire — and the harness bug that hid it

The **draft** version of this skill omitted the negative control every time: five runs of scenario 1, five identical answers, each an otherwise excellent plan that never checked whether the tests could fail. An agent with no skill at all named that check first, unprompted — so the draft was actively *worse* than nothing on this dimension.

Five revisions were made and each appeared to change nothing. **They changed nothing because none of them reached the agent.** Skills load from the installed path; the edits were being made to the repository copy. Same filename, different file. Every "failed intervention" re-ran the identical unmodified draft.

Once the installed copy was actually synced, the revised skill put the negative control at **step 1** and the §8b probes at step 2, unprompted, in the same scenario that had failed five times.

Two things worth keeping from that:

- **The revisions work.** Which one did the work is unknown — the sequence block, the sign-off gate, the corrected contract count and §8b all landed together. If you need to attribute it, re-test them individually.
- **A test harness needs its own negative control.** One run against a deliberately corrupted skill would have shown the output never varied, and would have caught this immediately. The methodology demands exactly that check of the application under test (§8) and it applies with equal force to the rig you are testing *with*. Verifying that your test setup can register a change is not optional; it is the first thing to establish.

The harness gate (`adversarial-verification-gate.sh`) is therefore **defence in depth, not the sole mechanism** — the instructions do work. It still earns its place: instructions are advisory and a gate is not, and the gate's own tests are independent of whether a skill loaded correctly.

Everything above in the table is one round of testing, not proof: three scenarios, one sample each, one model.
