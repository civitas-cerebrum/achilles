---
name: ticket-driven-testing
description: Use when a ticket from an issue tracker (Linear, Jira) is the unit of QA work — a QA ticket paired to a dev ticket, a PR awaiting QA sign-off, a "test this feature" request naming an issue key, or any ask to verify acceptance criteria against a branch that is not yet merged. Also use when asked to automate the tests for a ticket, produce evidence for a ticket, or QA a feature branch.
---

# Ticket-Driven Testing

## Overview

A ticket is not a test plan. It is a claim about behaviour, a branch that allegedly implements it, and a set of acceptance criteria someone will sign off against. This skill turns that into: verified evidence, durable regression tests, and sentinel tests for every defect found.

**Core principle: read the diff before you touch the app.** The code tells you which acceptance criteria are structurally guaranteed, which are merely probable, and where the defects are. Testing blind wastes the run and produces assertions that pass for the wrong reason.

**REQUIRED SUB-SKILL:** the evidence run itself is `companion-mode`. This skill wraps it with the ticket, branch, and diff context that companion-mode's Phase 1 assumes you already have.

## The Contract

Produce all four. A run that stops after evidence is half a deliverable.

1. **A ticket brief** — acceptance criteria, the dev branch, the PR and its review state.
2. **A diff review** — findings ranked by severity, each one a sentinel candidate.
3. **An evidence bundle** — via `companion-mode`, verdict grounded in the ACs.
4. **Durable tests** — regression cover in the suite, plus one sentinel per confirmed defect.
5. **A negative-control result** — proof the tests fail where the fix is absent (§8). Without it you have tests that pass, not tests that discriminate.

## Phases

### 1. Ticket intake

Read the QA ticket **and its parent**. QA tickets carry the test scope; parent dev tickets carry the acceptance criteria, the Figma links, and the implementation notes. Neither alone is enough.

Extract: the ACs verbatim, the branch name (trackers usually expose a `gitBranchName`), and the PR (usually a ticket attachment).

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

## 8. Prove the tests discriminate the fix — the negative control

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

## 9. Live observation — watch it, don't just assert it

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

## Status

**This skill has not been subagent-tested against baseline scenarios**, contrary to `superpowers:writing-skills`' Iron Law — it was authored under an explicit instruction not to dispatch subagents. Its content is derived from one complete real run (Linear PEDX-10619 / PR #4552) rather than from observed agent failures. Treat the Traps table as verified (each entry is a failure that actually occurred) and the phase structure as unverified. Run baseline pressure scenarios before relying on it broadly.
