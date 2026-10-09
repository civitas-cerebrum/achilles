# Demonstration runs, instrument controls, traps, framework gaps

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

**If a project needs behaviour `achilles-show` does not provide**, that is a gap in the runner, not a licence to hand-roll a per-project config. Fix it in the package — see `contributing-to-achilles-protocol`.

## Control every instrument before you read it

Six separate controls appear above — the negative control, positive controls before absence
assertions, a page-level control element, the `noop` mutation, the per-mutation applied-check, and
a control on the applied-check itself. Every one was added *after* a specific failure. Stated
separately they read as six rules to remember; they are one rule, and stating it as one is what
stops the seventh instrument from producing the next phantom finding.

**Any instrument whose output you will read as evidence must first be shown capable of producing
a different output.**

The failure mode is always the same shape, and it is silent by construction: an instrument that
does not run produces no signal, and *no signal is indistinguishable from no defect*. It fails in
the direction that looks like success, a clean report, so nothing prompts you to check.

Measured, in this project alone:

| Instrument | How it failed | What it produced |
|---|---|---|
| mutation injection | `addInitScript(str)` where the API wants `{content: str}` | a coverage hole that did not exist |
| the applied-check built to catch that | resolved its dependency from the wrong directory | a documented survivor reported as a broken injection |
| the hook test runner | counts assert calls; a mistyped helper increments nothing | `all 28 tests passed` while 14 lines errored |

The third is the one worth dwelling on: it is the instrument that validates the other gates, it
failed the same way, and it was found only because a test count did not move. Note also the second
— the instrument written to enforce this exact rule broke this exact rule. Knowing the principle
is not sufficient; the calibration has to be run.

**The calibration: two points, always.** Show the instrument reports positive on a case you know
is positive, and negative on a case you know is negative. One point proves nothing — a checker
hard-wired to `true` passes any single positive test.

```
applied-check   → no injection must report FALSE; a known-caught mutation must report TRUE
mutation runner → the `noop` control must be green; a known-caught mutation must go red
a test suite    → must fail where the fix is absent (§8); must pass where it is present
a live probe    → a control element present on ANY build must be found (§9)
a grep/count    → run it once where you KNOW the answer is non-zero
a test runner   → make one case fail on purpose and confirm the tally moves
```

**Three questions before believing any "nothing found":**

1. Did the instrument actually run? Not "was it invoked" — did it reach the thing it measures?
2. Has it produced a *different* answer, on a case where the answer is known?
3. If the subject were broken, what exactly would be different in this output? If you cannot
   name it, you have not measured anything.

**Corollary: "could not measure" is never "measured nothing".** Keep the two apart in your data
structures, not only in your prose — the collapse happens silently at the point where a `null`
meets a boolean. §8b's UNCHECKED verdict exists because that collapse turned a tooling failure
into a coverage claim.

## Traps

Each of these cost a failed run or a wrong conclusion in practice.

| Trap | What happens | Fix |
|---|---|---|
| **Suite's default viewport** | ACs are signed off at one size; the project's device preset is another. Behaviour differs. | Pin the viewport explicitly in `beforeEach`. Cover the other size as its own test. |
| **Late-hydrating components** | Client-rendered regions (search/results grids) are absent when your first assertion runs; your feature gate checked an SSR'd element and passed. | `waitForState` on the client-rendered container before asserting against it. |
| **Self-consuming observables** | A sentinel watches a session-storage flag; the destination page's effect reads and deletes it before you assert. Test passes, bug is live. | Assert a state that persists — a DOM state marker at the source, not a message in flight. |
| **Assumed default states** | You click a toggle expecting it to open; it was already open, so you closed it. | Read the initial state, assert the round-trip, don't assume a starting position. |
| **Unredacted HAR** | Your bypass token appears in the request headers of every entry; hundreds of copies inside a bundle you are about to commit. | Redact by header name and strip response bodies. This also shrinks the HAR by ~20×. `companion-mode` §"Redaction" makes the pass mandatory for **any** captured HAR or console log, bundle or not; an ad-hoc capture is precisely where the pass has no owner. |
| **One ticket, two environments, one set of paths** | You verify the same ticket against two environments (preview and production, two viewports, two locales) from one output directory. `video.webm` / `trace.zip` / `network.har` are fixed names, so the second run silently overwrites the first. The report cites both; one exists, and nothing says which. | One bundle per environment, or one named subdirectory per environment inside the bundle. Count the artifacts against the number of runs you are about to claim, before writing the verdict. |
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

**REQUIRED SUB-SKILL:** to close a gap rather than work around it, use `contributing-to-achilles-protocol`.
