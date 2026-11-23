---
name: platform-testing
description: >
  Native app UI testing on iOS and Android through Appium, with the same Steps
  API as web and one switch (PLATFORM=ios or PLATFORM=android). Loaded by an
  `author` or `inspector` dispatch on a platform target. Triggers: "test the
  iOS app", "test the Android app", "native app tests", "Appium", "wdio
  session", "capabilities file", "tests/capabilities", "PLATFORM=ios",
  "PLATFORM=android", "tests/platform", "platform-onboard", "onboard the iOS app",
  "onboard the Android app", "set up platform testing", "real device", "emulator", "simulator", "bundle id", "app
  package". Read references/platform-steps.md before writing any platform
  spec, fixture or page-repository entry; never invent a platform step or
  selector key. Not for the mobile viewport variant (a web test at 375x812 in
  a browser, owned by test-composer), mobile web in a browser, or desktop apps
  (macos and windows are declared, not implemented yet).
---

# Platform testing

Native apps (iOS, Android) tested through the same Steps API as web: element-interactions picks the driver family from one switch, `PLATFORM`, and element-repository resolves the platform's page by name. The spec reads the same; the discipline does not. Platform testing is not web testing with different selectors. Every rule in §"Platform discipline" exists because a web assumption breaks on a device, and a reviewer treats a missing one as a must-fix, the way a missing mobile viewport variant is a must-fix on web.

"Mobile" keeps meaning the 375x812 viewport variant of a web test. This skill calls the native modality **platform** (`platform-testing`, `tests/platform/`), and its platform values are exactly `web | android | ios | macos | windows`.

## Reference index

| Reference | Holds |
|---|---|
| [`references/platform-steps.md`](references/platform-steps.md) | The only home of the platform API: fixture options, env vars, fixture values, step semantics, every platform step, the multi-platform page repository shape, element primitives |
| [`../achilles-orchestrator/references/platform-inspection-protocol.md`](../achilles-orchestrator/references/platform-inspection-protocol.md) | The inspection primitive: `wdio session` invocation, snapshots, refs, actions, alerts, cleanup |
| [`../achilles-orchestrator/references/selector-evidence.md`](../achilles-orchestrator/references/selector-evidence.md) | The selector evidence note, including its platform fields |
| [`../achilles-orchestrator/references/api-reference.md`](../achilles-orchestrator/references/api-reference.md) | The shared Steps API (names and argument order are the same on every platform) |

## Absolute rules

1. Read `references/platform-steps.md` before writing a spec, fixture or repository entry. Never write a platform step, option or selector key from memory.
2. Capabilities live only in `tests/capabilities/<device>.json`. No capability literal in a spec, fixture, config, brief or skill output; the harness rejects one in a spec or fixture.
3. A run has one form (§"Run command"); an inspection has one form (the protocol §3.1). The same capabilities file serves both.
4. A web-only step on a platform run throws, and so does a platform step a platform cannot do. Never catch `PlatformNotSupportedError` to keep going; branch with a stated reason (§"Platform divergence").
5. Every verification polls. No fixed sleeps, ever; wait for a state.
6. Never auto-accept a permission prompt or system alert by default (§"Permissions and system alerts").
7. One expert per device, one session per expert, closed at the end of the turn (§"Devices are scarce and slow").
8. One page repository per project, one page name per platform inside it.
9. Positional selectors never land without a better alternative, a fallback, or a row in `tests/platform/docs/known-issues.md`.
10. Results name the device, the OS version and whether it was a real or a virtual device, read from the ledger's `devices[]`.

## Prerequisites

Collected in the orchestrator's preflight (phase 1); any missing item is a `NEEDS_CONTEXT` return. The orchestrator collects and records; it never opens a session. The first session on each device is opened by the dispatched inspector at the start of phase 3.

- **The app.** Its id (`bundleId` on iOS, `appPackage` on Android) in the capabilities file, or a build (`.ipa`/`.app`, `.apk`/`.aab`) and the command that produces it.
- **A capabilities file per device** under `tests/capabilities/`, with `platformName` matching `PLATFORM`, or the values for one (platform, device class, real or virtual, OS version, app id), which the scaffold phase writes into the file.
- **An Appium server** with the platform's driver (XCUITest, UiAutomator2), given as a URL with its base path or as `env:<VAR>` (normally `env:APPIUM_URL`). A literal private URL is never committed.
- **Tooling.** `npx --no-install wdio --version` prints `10.2.0`; Node meets WebdriverIO 10's minimum (advisory: older Node may work but is unsupported). No browser download.

The target is recorded in `factory-rules` `contexts` in the platform shape:

```json
{ "platform": "ios", "capabilities": "tests/capabilities/iphone.json", "server": "env:APPIUM_URL" }
```

and each device in the ledger's `devices[]` (at least one once preflight is `completed` or `skipped`):

```json
{ "capabilities": "tests/capabilities/iphone.json", "platform": "ios", "osVersion": "17.5", "real": true, "model": "iPhone 15" }
```

`model` is optional and is a device model or class, never a personal device name. `devices[]` is stated at preflight and confirmed at inspect: the phase-3 inspector reports the OS version and real or virtual it observed for each device, and the orchestrator reconciles the entries. Reports read device, OS version and real or virtual from `devices[]`.

## Project layout

```
playwright.platform.config.ts        # testDir 'tests/platform', workers: 1, long timeouts, Achilles reporter
tests/capabilities/
  README.md                          # what each file targets; no secrets
  iphone.json                        # one W3C capabilities object per device or device class
  android.json
tests/platform/
  fixtures/base.ts                   # the baseFixture(...) call for platform runs
  page-repository.json               # platform-only projects only; otherwise tests/e2e/page-repository.json
  <journey>/*.spec.ts                # platform specs
  docs/
    platform-onboarding-status.json  # the platform ledger
    app-context.md                   # screens keyed by screen name and navigation path
    known-issues.md                  # positional selectors kept, platform divergences, environment limits
    platform-report.md               # the report (sentinel on line 1)
  evidence/<slug>-<ts>/              # platform evidence bundles (evidence-capture)
```

A project that already has `tests/e2e/page-repository.json` keeps one repository: platform pages are added to it (same page name, `"platform": "ios"` / `"android"`), and `tests/platform/page-repository.json` is not created.

## Run command

The only form:

```
PLATFORM=<platform> CAPABILITIES=tests/capabilities/<device>.json APPIUM_URL=<server-with-base-path> \
  npx playwright test -c playwright.platform.config.ts
```

While iterating, an author keeps the same prefix and adds its own file and `--grep <ids>` after `-c playwright.platform.config.ts`. Each device class is a separate run with its own capabilities file; there is no in-run device matrix. `APPIUM_USER` / `APPIUM_KEY` are set in the environment for a remote server that needs them.

## Scaffolding

The scaffold phase writes, and writes only what is missing:

1. **`playwright.platform.config.ts`**: `testDir: 'tests/platform'`; `workers: 1` (one worker per device; a second device is a second run, not a second worker); `fullyParallel: false`; long timeouts (`timeout: 180_000` per test, `expect: { timeout: 15_000 }`, a `globalTimeout` that fits the run budget); `retries: 0` while authoring; reporters `[['list'], ['html', { open: 'never', outputFolder: 'playwright-report-platform' }], ['@civitas-cerebrum/achilles/reporter']]`. No `use.browserName`, no `projects` per browser, no `webServer` for the app.
2. **`tests/capabilities/<device>.json`**, one per device or device class, plus **`tests/capabilities/README.md`** (one line per file: platform, device class, real or virtual, OS version, which app id). Example with fake values:

   ```json
   {
     "platformName": "iOS",
     "appium:automationName": "XCUITest",
     "appium:udid": "00000000-0000000000000000",
     "appium:bundleId": "com.example.shop",
     "appium:newCommandTimeout": 300,
     "appium:noReset": true,
     "appium:autoAcceptAlerts": false,
     "appium:autoDismissAlerts": false
   }
   ```

   The Android counterpart, also with fake values:

   ```json
   {
     "platformName": "Android",
     "appium:automationName": "UiAutomator2",
     "appium:udid": "emulator-5554",
     "appium:appPackage": "com.example.shop",
     "appium:appActivity": ".MainActivity",
     "appium:newCommandTimeout": 300,
     "appium:noReset": true,
     "appium:autoGrantPermissions": false,
     "appium:disableWindowAnimation": true
   }
   ```

   `appium:autoGrantPermissions: false` on Android and `appium:autoAcceptAlerts: false` on iOS are the never-auto-accept rule in file form (§"Permissions and system alerts"). Animations are turned off here where the driver supports it: `appium:disableWindowAnimation: true` on Android, `appium:reduceMotion: true` on an iOS simulator (§"Animations and timing"). A variant file for a different reset level (for example `iphone-clean.json` with `"appium:noReset": false`, or `"appium:fullReset": true` where the driver supports it) is a separate capabilities file, listed in the README (§"App state and reset"). Vendor and cloud options are keys in this file; credentials are not.
3. **`tests/platform/fixtures/base.ts`**: the `baseFixture(base, <repository path>, { ... })` call from [`references/platform-steps.md`](references/platform-steps.md) §"Fixture options". `platform` and `session` default to `PLATFORM`, `CAPABILITIES` and `APPIUM_URL`; the file names no capability, server or app id.
4. **`package.json`**: `@wdio/cli` pinned at exactly `10.2.0` in `devDependencies`; `webdriverio` `^10` as a devDependency (element-interactions imports it dynamically); scripts `"test:platform": "playwright test -c playwright.platform.config.ts"` and, when the app is built from this workspace, `"app:build:ios"` / `"app:build:android"`.
5. **The app build and install step.** When the app is built from source, the build command is a script, its output path is the `appium:app` value of a build-specific capabilities file or is installed once with `steps.installApp(<path>)` in a setup project, and the README in `tests/capabilities/` says which. When the app is already on the device, the capabilities file carries its id and no install happens. A signing or trust failure during install is an environment failure (§"Real device versus emulator").
6. **`.gitignore`**: `playwright-report-platform/`, `test-results/`, `.achilles/`, the build output directory.
7. **No Chromium download** for a platform-only project: no `npx playwright install`, no `playwright-cli install-browser`. A project with both web and platform suites keeps its existing browser setup.
8. **The ledger** `tests/platform/docs/platform-onboarding-status.json` initialised with every phase `pending`, and `tests/platform/docs/app-context.md` with its `## Test Infrastructure` section (server reachable, devices, app ids, alert policy).

## Pipeline mode (zero to a maintained platform suite)

The orchestrator runs seven phases with a fresh phase-gate review between each. The ledger is `tests/platform/docs/platform-onboarding-status.json` (schema `schemas/platform-onboarding-status.schema.json`, row semantics as in [state-files.md](../achilles-orchestrator/references/state-files.md) §"Pipeline ledgers"). Phases carry a numeric `id` 1-7 with a fixed `name`: 1 `preflight`, 2 `scaffold`, 3 `inspect`, 4 `selectors`, 5 `compose`, 6 `review`, 7 `report`. The ledger also holds `devices[]` (§"Prerequisites").

**Phase gates.** After each phase the orchestrator dispatches the existing reviewer role, fresh each time, loading [`../review/SKILL.md`](../review/SKILL.md). Its handover role is `platform-reviewer-phase<N>` (N = the phase id) and its return follows `schemas/subagent-returns/platform-reviewer.schema.json`. Each check of a §"Platform discipline" row is one `checklist[]` item whose `section6-row` is that row's heading text (for example `Permissions and system alerts`). Ledger ownership follows the perf precedent: the reviewer records its verdict in the phase's reviewer fields (`reviewerVerdict`, `reviewerCycles`, `reviewerFindings`) and nothing else; the orchestrator writes phase `status`, `handoverEnvelope` and `devices[]`. The orchestrator records the closing expert's envelope before it dispatches the gate, because a phase cannot become approved without one. The gate brief names the platform ledger.

| id | name | Who | Deliverable | Exit |
|---|---|---|---|---|
| 1 | `preflight` | orchestrator | the app id or build; an existing capabilities file or the values for one; the server as a URL with base path or `env:<VAR>`; `npx --no-install wdio --version` checked; the target in `factory-rules` `contexts` (platform shape); `devices[]` in the ledger | every prerequisite stated, none inferred; at least one `devices[]` entry. The orchestrator opens no session |
| 2 | `scaffold` | author | the files in §"Scaffolding", including `tests/capabilities/<device>.json` for every `devices[]` entry | `npx playwright test -c playwright.platform.config.ts --list` exits 0; no Chromium downloaded; no capability literal outside `tests/capabilities/` |
| 3 | `inspect` | inspector, one per device | first, one session opened and closed on each device to prove the capabilities file and server; then `tests/platform/docs/app-context.md`: screens keyed by screen name and navigation path, entry points and deep links, permission prompts and where they fire, keyboard states, contexts per screen | every device opened and closed once, its observed OS version and real or virtual reported for the orchestrator to reconcile `devices[]`; every screen in scope has an entry; every prompt seen is listed with its trigger |
| 4 | `selectors` | author | platform pages in the one page repository, each entry with a selector evidence note (`npx achilles-selector-evidence --platform <p>`, [selector-evidence.md](../achilles-orchestrator/references/selector-evidence.md)) | no `provisional` entry without a stated reason; no positional selector without a fallback or a row in `tests/platform/docs/known-issues.md` (a project with both trees may use `tests/e2e/docs/known-issues.md`) |
| 5 | `compose` | author loading `test-composer` with this skill | `tests/platform/**/*.spec.ts` per journey, with the variants §"Platform discipline" adds | 3 consecutive greens per new test on each device class it targets; Stage 4b sweep clean |
| 6 | `review` | reviewer | the verdict, plus the whole-suite run per device class and one deliberate failure turning a test red | composition judge satisfied; §"Platform discipline" rows checked; suite green |
| 7 | `report` | doc-writer loading `qa-reporting` | `tests/platform/docs/platform-report.md` with `<!-- platform-testing:generated -->` on line 1 | every result names device, OS version and real or virtual, read from `devices[]`; findings in the canonical ledger |

Resume: the first ledger row that is not `completed` with `reviewerVerdict: approved`. One commit per phase (`chore(platform): scaffold platform suite`, `docs(platform): app context — <N> screens`, `feat(platform): selectors — <N> elements`, `test(platform): <journey> — <N> tests`, `docs(platform): platform-report — <verdict>`). The ledger is never hand-edited around a failed check.

## Platform discipline

One heading per nuance. Rows owned here are complete; the others give the rule and the skill that owns its detail. Cite a row by its heading (`platform-testing/SKILL.md` and the heading text).

### App state and reset

A browser context gives each web test a clean slate; a device keeps app data, login, caches and permissions between tests. Every scenario states its start state and its reset level, and each level has one mechanism:

| Level | Mechanism |
|---|---|
| none | `session: { reset: 'none' }` in the fixture; only for a describe block whose tests are a deliberate sequence, stated in the block |
| relaunch | the fixture default `session.reset: 'relaunch'` (terminate and activate between tests), or `steps.resetApp()` inside a test |
| clear data | no platform step exists for it. A capabilities-file variant (`"appium:noReset": false`, or `"appium:fullReset": true` where the driver supports it) run as its own run; anything else is a framework gap ([framework-gap.md](../achilles-orchestrator/references/framework-gap.md)), never an invented step |
| reinstall | `steps.removeApp(<appId>)` then `steps.installApp(<path>)` |

A test that needs more than relaunch says so and arranges it; it never depends on the previous test's leftovers. Accounts already logged in on the device are test data with an owner. Detail: [`../test-composer/SKILL.md`](../test-composer/SKILL.md) (start state and reset per scenario) and [`../test-data-conventions/SKILL.md`](../test-data-conventions/SKILL.md) (device-resident accounts and data).

### Install, upgrade, first launch

There is no install step on the web. On a device, first launch (onboarding screens, the first permission prompts, empty states) and upgrade from the previous version (migrated data, re-shown prompts) are journeys of their own, mapped and prioritised like any other. The scaffold provides the build and install step (§"Scaffolding"). Detail: [`../journey-mapping/SKILL.md`](../journey-mapping/SKILL.md).

### Permissions and system alerts

On the web, permissions are a config setting. On a device each permission prompt is a decision the user makes, shown by the operating system, and the app must handle every answer. Owned here:

- **Each prompt is a tested branch.** For every prompt the app can raise (notifications, location, camera, microphone, photos, contacts, tracking, Bluetooth, and Android's runtime permissions), the suite covers allow, deny, and the deferred answer where the OS offers one ("Allow once", "Ask next time", dismissing the prompt). The deny branch asserts the app's fallback (an explanation, a disabled feature, a settings link), not just that the app survived.
- **Never auto-accepted by default.** iOS capabilities files set `appium:autoAcceptAlerts: false` and `appium:autoDismissAlerts: false`; Android files set `appium:autoGrantPermissions: false`. Turning either on is a recorded project decision with a reason, and it removes the branches it hides from the claimed coverage.
- **Alerts belong to another process.** A system alert is not in the app's element tree and not in the page repository. A test answers it with `steps.acceptAlert()` / `steps.dismissAlert()` at the point the scenario reaches it, then asserts the app's reaction. No "dismiss any alert" helper in `beforeEach`, no blind accept in a fixture.
- **Arranging a known state.** A scenario whose subject is not the prompt itself starts from a set permission state with `steps.setPermission(<permission>, 'grant' | 'deny' | 'reset')` in its arrange step. That does not replace the prompt branches.
- **Re-prompt rules.** iOS asks once per install; Android may ask again until "Don't ask again". The scenario names the reset level that makes the prompt appear (reinstall or `setPermission(..., 'reset')`).
- **Where `setPermission` cannot work.** On iOS, setting or resetting a permission may be possible only on a simulator. An unsupported call throws `PlatformNotSupportedError`; the fallback is a fresh install on a virtual device, never a reinstall or reset on a shared real device.
- **Inspection never answers an alert** to get past it ([platform-inspection-protocol.md](../achilles-orchestrator/references/platform-inspection-protocol.md) §"System alerts and permission prompts").

The prompt inventory comes from the `inspect` phase; the review gate checks each prompt has its branches.

### Keyboard

The web keyboard never covers a target; a device keyboard does. A test dismisses the keyboard (`steps.hideKeyboard()`) or scrolls before tapping or asserting an element below it, and checks `steps.verifyKeyboardShown()` where the keyboard's presence is the behaviour. Inspection snapshots each form with the keyboard up and down. Detail: [`../test-composer/SKILL.md`](../test-composer/SKILL.md); inspection side: [platform-inspection-protocol.md](../achilles-orchestrator/references/platform-inspection-protocol.md) §"Actions".

### Gestures and scrolling

Off-screen web elements are still in the DOM; a native list renders only what is near the viewport. Reach an element in a list with `steps.scrollUntilFound(element, page, { direction })`, never "exists, then scroll". Swipe, long press, pinch and zoom are first-class steps, each with a verification of its effect. Coordinates (`tapAt`) are a last resort. Detail: [`../test-composer/SKILL.md`](../test-composer/SKILL.md); selectors for list items: [`../selector-development/SKILL.md`](../selector-development/SKILL.md).

### Navigation

URLs address any web state; an app has screens reached by a path of taps. `app-context.md` keys each screen by its name and its navigation path from launch, and lists the deep links that reach it where the app has them (`steps.openDeepLink` is the fast arrange step). System back exists on Android only (`steps.pressBack()`); iOS tests tap the on-screen control. Detail: [`../journey-mapping/SKILL.md`](../journey-mapping/SKILL.md).

### Orientation and screen sizes

The web viewport is a config number; on devices orientation and screen class change the layout. P0 journeys run in portrait and landscape where the app supports both (`steps.setOrientation`, `steps.verifyOrientation`), and on a small and a large device class, each a capabilities file. On a platform target this replaces the 375x812 mobile variant. Detail: [`../review/SKILL.md`](../review/SKILL.md).

### Interruptions and lifecycle

A web page is never backgrounded. Probes cover background and resume (`steps.backgroundApp`), kill and relaunch mid-flow (`steps.terminateApp` then `steps.activateApp`), lock and unlock, an incoming notification, and low or lost connectivity, each asserting that the flow's state survives or recovers. Lock and unlock, notifications and connectivity have no platform step: use the `driver` fixture value ([`references/platform-steps.md`](references/platform-steps.md) §"Fixture values") or record a framework gap ([framework-gap.md](../achilles-orchestrator/references/framework-gap.md)); never invent a step. Detail: [`../bug-discovery/SKILL.md`](../bug-discovery/SKILL.md).

### Hybrid content

A web page has one DOM; a hybrid screen has a native context and one or more webview contexts. The context is recorded per screen in `app-context.md`, a spec switches explicitly (`steps.switchContext`, `steps.verifyContext`) and switches back, and a page in the repository belongs to one context. Detail: [`../test-composer/SKILL.md`](../test-composer/SKILL.md); inspection: the protocol's `contexts` action.

### Accessibility identifiers

Web apps usually carry `data-testid` or roles; native apps often have no stable identifier. Preference: accessibility id, then resource-id (Android) / predicate (iOS), then class chain / UiSelector, then text, XPath last and flagged. Missing identifiers are added at source as `accessibilityIdentifier` (iOS), `contentDescription` or a resource id (Android), or `testID` (React Native). Detail: [`../selector-development/SKILL.md`](../selector-development/SKILL.md); the mapping table: [platform-inspection-protocol.md](../achilles-orchestrator/references/platform-inspection-protocol.md) §"Selectors and the page repository".

### Platform divergence

One web implementation runs in several browsers; iOS and Android are two implementations of one product. The page repository holds one page name with a selector set per platform and identical element names. A spec is shared first; a platform-specific branch (`test.skip(repo.platform === 'ios', '<reason>')` or a per-platform step) carries a stated reason, and a divergence in behaviour (not just layout) is a finding to report, not a branch to write around. Detail: [`../test-composer/SKILL.md`](../test-composer/SKILL.md); repository shape: [`references/platform-steps.md`](references/platform-steps.md) §"Page repository: one page name per platform".

### Devices are scarce and slow

Browsers are free and parallel; devices are neither. Owned here and by the orchestrator:

- **One expert per device.** The orchestrator never gives two concurrent experts the same capabilities file. Parallel width on platform work is the number of devices, not the host's limit.
- **One session per expert, closed at turn end.** Every inspection session is closed by the expert itself before it reports, on success and on failure. Only the Claude Code harness closes a forgotten session at turn end; on pi the CLI's `--idle-timeout` (30 minutes by default) is the only backstop, so nobody relies on either. The test fixture opens one worker-scoped session and closes it when the worker ends.
- **Short command timeouts.** `appium:newCommandTimeout` stays short (300 s is the reference) so a crashed run frees the device in minutes; per-action CLI timeouts fail fast; a hung call is reported, not retried in a loop.
- **`workers: 1` per device.** A config never runs two workers against one device. More devices means more runs, each with its own capabilities file.
- **Budgets for longer runs.** A brief states its budget (screens to inspect, tests to run, wall-clock). Whole-suite runs on a device happen at phase exits, not inside every brief; an author iterates on its own tests only. A run that would exceed the budget is split, never cut short silently.
- **A locked or busy device is an environment state.** "Timed out while enabling automation mode" on iOS, or a device the server will not allocate, is reported as `BLOCKED` with the evidence, not retried in a loop.

### Real device versus emulator

On the web there is no such distinction. Every result names the device (model or class), the OS version and whether it ran on a real device or an emulator/simulator. Signing, provisioning, trust prompts and device-lock failures are environment failures, never app bugs. Detail: [`../qa-reporting/SKILL.md`](../qa-reporting/SKILL.md).

### Animations and timing

Web steps auto-wait for actionability; device animations and transitions take real time. Every verification polls until its timeout (the steps do this in both families); animations are turned off in the capabilities file where the driver supports it (`appium:disableWindowAnimation: true` on Android, `appium:reduceMotion: true` on an iOS simulator); there are no fixed sleeps. A test that needs a longer wait for a slow transition states it on that wait and why. Detail: [`../test-composer/SKILL.md`](../test-composer/SKILL.md).

### Failure evidence

A web failure has a trace, the DOM and the console. A platform failure's evidence floor, before any classification: the page source (`page-source`, attached by the fixture), the screenshot (`failure-screenshot`), the device log (syslog on iOS, logcat on Android), a screen recording where the failure involves motion or timing, and the app and OS versions. Detail: [`../failure-diagnosis/SKILL.md`](../failure-diagnosis/SKILL.md); bundles a human will open: [`../evidence-capture/SKILL.md`](../evidence-capture/SKILL.md).

### Device capabilities

The web has no camera roll or biometrics to speak of. Where the app uses them, probes cover biometrics (enrolled, not enrolled, failed match), camera, location (granted, denied, changed mid-flow), push notifications, the clipboard and the share sheet. Detail: [`../bug-discovery/SKILL.md`](../bug-discovery/SKILL.md).

## Integration

`journey-mapping` maps screens and journeys into `tests/platform/docs/app-context.md`; `test-composer` writes the specs with this skill's rows; `selector-development` adds identifiers at source; `review` gates every phase; `failure-diagnosis` triages a red platform test with the evidence floor above; `bug-discovery` runs interruption and device-capability probes; `qa-reporting` writes the platform report; `test-data-conventions` owns device-resident accounts. A web suite and a platform suite in one project share the page repository and nothing else.

## Return

Envelope first, then: the target (platform, capabilities file, device class, real or virtual, OS version), files written, runs executed (the exact command, exit code, counts), the sessions opened and closed, the permission branches covered per prompt, findings (canonical blocks), and any `concerns` (a device that could not be reached, a branch that could not be arranged, a positional selector kept with a row in `tests/platform/docs/known-issues.md`).
