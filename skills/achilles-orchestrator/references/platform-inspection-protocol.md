# Platform inspection protocol: the native-app automation primitive

**Status:** single source of truth for live inspection of native apps (iOS, Android) across the Achilles skill suite. It plays the role [`playwright-cli-protocol.md`](playwright-cli-protocol.md) plays for the browser, and it mirrors that file section by section where the two tools agree.
**Tool:** `wdio session`, the WebdriverIO 10 CLI (`@wdio/cli` pinned at `10.2.0`), driving a running Appium server. No other channel is sanctioned for live native-app inspection: not an Appium MCP server, not a vendor CLI, not a hand-written WebdriverIO script. The step API the resulting tests use is in [`../../platform-testing/references/platform-steps.md`](../../platform-testing/references/platform-steps.md).

Every expert that inspects a running native app (inspectors mapping screens or proposing selectors, authors loading `platform-testing`, `test-composer`, `bug-discovery`, `failure-diagnosis` or `evidence-capture` on a platform target, reviewers checking the live screen) runs `wdio session` from its shell, in the one form below.

---

## 1. Why `wdio session`

A named `wdio session` keeps one Appium session alive in a background daemon between shell commands, the same open / snapshot / act-by-ref / close model as `playwright-cli`. Its snapshot lists interactive elements with refs (`e14`) and, with `--selectors`, the WebdriverIO selector that reaches each one, so the inspection output maps straight onto a page-repository entry. Every action prints the WebdriverIO code it ran.

What differs from the browser, and drives most of this protocol:

- **A device is not a browser process.** Two sessions on one device fight over the same screen. Isolation comes from one expert per device, not from the OS.
- **Devices are scarce and slow.** Opening a session can take tens of seconds, a forgotten session holds the device for every other run, and a real device may be shared.
- **System UI belongs to another process.** Permission prompts and system alerts are not part of the app's tree and are not the app's to dismiss.

---

## 2. Detection and install

### 2.1 Package install

The tested project pins `@wdio/cli` `10.2.0` as a devDependency (the scaffold adds it; [`../../platform-testing/SKILL.md`](../../platform-testing/SKILL.md) §"Scaffolding"). The pin is exact because the agent API is new and its snapshot behaviour already differs by platform (§5). Check reachability with:

```bash
npx --no-install wdio --version      # prints 10.2.0
```

A non-zero exit or another version is a scaffold gap, fixed by `npm install`, never by a global install or an unpinned `npx wdio@latest`.

### 2.2 No browser binary

A platform-only project downloads no Chromium. `npx playwright-cli install-browser` is not part of platform preflight. The Appium server, its drivers (XCUITest, UiAutomator2) and the device live outside the project; the project only knows the server URL.

### 2.3 Workspace artifacts

`wdio session` writes snapshots, screenshots, page sources, `history.json`, `daemon.log` and exports to a per-session artifacts directory, `<project>/.wdio/session/<slug>/`, which `open` and `info` print. It ignores itself through `.wdio/session/.gitignore`. It can hold personal data read off the screen (names, account rows), so it is never committed and never attached to a report, ticket or evidence bundle as is. Nothing there is committed; evidence an expert keeps is copied to the existing evidence locations its brief names (selector evidence under `docs/evidence/selectors/**`, a change's folder under `docs/evidence/`, a platform evidence bundle under `tests/platform/evidence/<slug>-<ts>/`).

---

## 3. Session model

### 3.1 The invocation (the only form)

```bash
npx wdio session -s <expert-slug> open <platform> --appium-url "$APPIUM_URL" --capabilities tests/capabilities/<device>.json --bundle-id <id>   # android: --package <id>; an appium:app file: --app <path>
npx wdio session -s <expert-slug> snapshot -i --all --selectors
# ... actions by ref ...
npx wdio session -s <expert-slug> close
```

- `<platform>` is `ios` or `android` (the `Platform` vocabulary; `macos` and `windows` are declared, not implemented yet).
- `--appium-url` is the full server URL **including the base path** (`<appium-server>/wd/hub` on a server started with that base path). Without the base path, session creation fails with "unknown command". The value comes from `APPIUM_URL`; a literal private URL is never written into a brief, a spec or a committed file.
- `--capabilities` names a file under `tests/capabilities/`, the **same file** the test run uses (`E2E_CAPABILITIES`). Capabilities live only there; never pass them as inline JSON. The file is a **flat** object of top-level keys, with no `alwaysMatch` / `firstMatch` wrapper: the inspection CLI deep-merges a flat file, and the selector evidence tool reads top-level keys only.
- `open` **always** passes the app flag: `--bundle-id <id>` on ios, `--package <id>` on android, equal to the file's `appium:bundleId` / `appium:appPackage`. A build-specific capabilities file that names the app only by `appium:app` repeats it as `--app <path>` instead. `open --app <path>` checks that the path exists on the local machine unless it is a URL, so a file whose `appium:app` is a path on the Appium host cannot be inspected; for inspection use a URL or storage reference in `appium:app`, or a capabilities file that names the installed app by bundle id or package. `@wdio/cli` 10.2.0 checks for the flag before it merges the capabilities file, so `open` without it exits 2 even when the file names the app (found live). The flag's value is the file's app id, never a different one. The test run still reads the app id from the file only.
- `--activity <name>` does not exist on ios. On android pass it only with the file's own `appium:appActivity`; leave it out otherwise.
- **The defaults the CLI injects** (the one home of this list; other files cite it). The capabilities file sets explicitly every key whose CLI default must not apply. `@wdio/cli` 10.2.0 injects `appium:automationName` and `appium:newCommandTimeout` (3600) and `appium:deviceName` on both platforms; on android also `appium:autoGrantPermissions` (`true`), `appium:ignoreHiddenApiPolicyError`, `appium:disableWindowAnimation`, `appium:adbExecTimeout`, `appium:uiautomator2ServerInstallTimeout` and `appium:uiautomator2ServerLaunchTimeout`; on ios `appium:autoAcceptAlerts` (`false`). The file wins the merge only for keys it sets, so set `appium:automationName`, `appium:newCommandTimeout` (short, e.g. 300; never 3600), `appium:deviceName` and, on android, `appium:autoGrantPermissions: false`. The other injected keys can make the inspection session differ from the test run; when a difference matters, set that key in the file too.
- No capability or server flags on `open`: device, udid, reset behaviour, orientation and Appium timeouts are capabilities, and therefore file content. Besides the app flags above, `open` takes only `--replace`, `--launch-timeout`, `--idle-timeout` (never 0, at most 30 minutes), `--log-level`, `--snapshot` and the global flags.
- `-s <expert-slug>` comes before the action on every call.

The session name is the expert's slug (§3.2). Close your own session before you hand back; harness backstops differ (`docs/harness/*`; §7).

### 3.2 Session name = expert slug

One named session per expert, named with the expert's slug from its brief. The slug families are the ones in [`playwright-cli-protocol.md`](playwright-cli-protocol.md) §3.1 (`stage2-<slug>`, `composer-<journey>-<pass>-c<N>`, `probe-<journey>`, `fd-<slug>`, `companion-<slug>`), and the same ASCII, lowercase, dash-separated, ≤25-character budget applies. Siblings never share a name.

### 3.3 One expert per device

A capabilities file names a device (or a device class the server allocates from). At any moment one expert holds a session on a given device. The orchestrator plans waves so that two experts never get the same capabilities file at the same time; two devices means at most two platform experts in parallel. A second `open` on a busy device either waits on the server's allocation or fails; neither is a reason to retry in a loop.

### 3.4 Quarantine on start

At the start of a phase the orchestrator lists what is open and closes only sessions that belong to the run. It never opens a device session itself; `list` and `close` are its only `wdio session` actions:

```bash
npx wdio session list
npx wdio session -s <stale-slug> close
```

`close --all` is never used while experts are working. On a shared device it would also end sessions that are not the run's.

---

## 4. Output format and parsing

### 4.1 Default

Each action prints its result, then the WebdriverIO code it ran (`→ …`). `open` prints the session name, the target and the artifacts directory.

### 4.2 `--json` and `-q`

`--json` prints one JSON object per call, for a downstream JSON parser. `-q` prints only the requested data, for capturing a value in a shell variable. The snapshot's text layout and JSON shape are marked experimental by the tool and may change in a minor release; the ref syntax and the actions that take a ref are stable. This is one more reason for the exact pin.

### 4.3 Exit codes

`0` success, `1` the action failed, `2` usage error, `3` missing dependency or credentials, `4` no session with that name. Check the exit code, not the output tail, before acting on a result.

---

## 5. Snapshots and refs

### 5.1 Always `snapshot -i --all --selectors`

```bash
npx wdio session -s <slug> snapshot -i --all --selectors
```

- `-i` lists interactive elements only.
- `--all` includes elements the tool judges hidden. **On iOS the default snapshot showed only the navigation title**; with `--all` it lists the rendered rows, the same set as the page source. Rows further down a lazy list are not rendered yet and need a swipe. Pass `--all` on every platform so one habit works everywhere.
- `--all` marks off-screen or obscured elements `[hidden]`. **Swipe a `[hidden]` element into view before you tap it or take its element screenshot.** Found live: `tap <ref>` on a `[hidden]` element printed "Tapped …" and exited 0 but did nothing, and its element screenshot was black. A "Tapped" line and exit 0 do not prove the action worked; re-snapshot and compare. Selector evidence captured while the element was hidden is not acceptable: the evidence tool refuses it ([`selector-evidence.md`](selector-evidence.md) §"Platform pages"), so swipe the element into view and capture again.
- **Tap from mid-screen, then verify.** Also found live: a row that was no longer `[hidden]` but sat just above the iOS floating bottom toolbar swallowed `tap` the same way (exit 0, "Tapped", no navigation). Before tapping, swipe the target toward the middle of the screen. After every tap, re-snapshot and compare. A tap that changed nothing is retried once from mid-screen; if it still changes nothing, it is a finding, never a pass.
- `--selectors` ends each ref line with its best WebdriverIO selector.

Format (fake app, values illustrative):

```
- navigation "Orders"
  - text "Orders" [ref=e1]  → -ios class chain:**/XCUIElementTypeStaticText[`name == "Orders"`]
- listitem [ref=e6]  → (//XCUIElementTypeCell)[1] (positional)
  - button "Order 1042, Shipped" [ref=e5]  → ~order-row-1042
- switch "Notifications" [ref=e12]  → ~settings.notifications
- button "Back" [ref=e14]  → ~nav-back
```

- Refs are `eN`, scoped to the latest snapshot. They stay valid while the element exists; an action on a removed element fails with `REF_STALE`. Re-snapshot after every screen change before the next ref action.
- A selector marked **(positional)** depends on the element's index in the tree. It is a weak selector: it never goes into the page repository without a better alternative, a `fallback`, or a row in `tests/platform/docs/known-issues.md` (§5.3).
- Long snapshots print in parts (`--max-chars`, `--offset`); `find "<text>"` searches the whole snapshot and already includes hidden parts.

### 5.2 Scoping and change tracking

```bash
npx wdio session -s <slug> snapshot -i --all --selectors --scope e20   # only below one ref
npx wdio session -s <slug> tap e5 && npx wdio session -s <slug> snapshot -i --all --selectors --diff
npx wdio session -s <slug> find "Checkout"
```

`--diff` prints only what changed since the previous snapshot and must repeat that snapshot's flags (`--scope`, `-i`, `--all`); otherwise the whole tree is printed. The separate `diff` action has no `--all` flag, so do not use it on iOS: it would compare a snapshot that hides list content.

### 5.3 Selectors and the page repository

The selector a snapshot prints maps onto a repository `selector` as follows (the one home of this mapping; other files cite it):

| `wdio session` selector | Repository `selector` |
|---|---|
| `~value` | `{ "accessibility id": "value" }` |
| `-ios predicate string:expr` | `{ "predicate": "expr" }` |
| `-ios class chain:expr` | `{ "class chain": "expr" }` |
| `android=expr` | `{ "uiautomator": "expr" }` |
| `id=value` / resource-id | `{ "id": "value" }` |
| `//xpath` or `(//xpath)[n]` | `{ "xpath": "..." }`, last resort; anything marked "(positional)" needs a fallback or a row in `tests/platform/docs/known-issues.md` |

Which of several candidates to propose follows the preference order in [`selector-evidence.md`](selector-evidence.md) §"Selector mapping and preference". When the best candidate is positional or text-only and the workspace holds the app source, the element goes to `selector-development` for an `accessibilityIdentifier` / `testID` / `contentDescription` at source ([`../../platform-testing/SKILL.md`](../../platform-testing/SKILL.md) §"Accessibility identifiers").

Inspection proposes; it never writes the page repository. The author adds the entry on the right platform page (one page name per platform, [`../../platform-testing/references/platform-steps.md`](../../platform-testing/references/platform-steps.md) §"Page repository: one page name per platform") and records the selector evidence note per [`selector-evidence.md`](selector-evidence.md).

### 5.4 `source` and `screenshot`

```bash
npx wdio session -s <slug> source --path <file>.xml        # full XCUITest / UiAutomator2 XML
npx wdio session -s <slug> screenshot --path <file>.png
npx wdio session -s <slug> screenshot e5 --path <file>.png # one element
```

Read the page source when a snapshot hides an attribute a selector needs (`name`, `label`, `resource-id`, `content-desc`, class). The source snippet and the element screenshot are fields of the selector evidence note.

---

## 6. Actions

Every action takes a ref from the latest snapshot. A WebdriverIO selector string is accepted too, but a ref from a fresh snapshot is the habit.

| Action | Form | Platforms |
|---|---|---|
| Tap | `npx wdio session -s <slug> tap e5` | android, ios |
| Fill (clears first) | `npx wdio session -s <slug> fill e7 some text` | web, android, ios, macos, windows |
| Type (no clear) | `npx wdio session -s <slug> type e7 more` | web, android, ios, macos, windows |
| Swipe the screen | `npx wdio session -s <slug> swipe up` (`--percent 0..1`) | android, ios |
| Long press | `npx wdio session -s <slug> long-press e4 --duration 1500` | android, ios |
| Hide the keyboard | `npx wdio session -s <slug> keyboard hide` | android, ios |
| Contexts (hybrid) | `npx wdio session -s <slug> contexts`, then `contexts switch WEBVIEW_<name>` / `contexts switch NATIVE_APP` | android, ios |
| Deep link | `npx wdio session -s <slug> deeplink shop://orders/1042` (`--package <id>` when needed) | android, ios |
| App lifecycle | `npx wdio session -s <slug> app launch\|terminate\|state <app-id>` | android, ios |
| Background | `npx wdio session -s <slug> background 3` | android, ios |
| Rotate | `npx wdio session -s <slug> rotate landscape` | android, ios |
| Device log | `npx wdio session -s <slug> logs --source syslog` (ios) / `--source logcat` (android) | android, ios |
| Dialog status | `npx wdio session -s <slug> dialog status` | web, android, ios |

Rules that differ from the browser:

- **No `back` on iOS.** `back` is a web action; iOS has no system back. Tap the on-screen back button by ref. On Android the system back exists, but the CLI's `back` still targets the web; prefer the on-screen control, and record in the app context whether the screen also reacts to system back (the test uses `steps.pressBack()`, android only).
- **`scroll` is web only.** On a native list use `swipe <direction>` and re-snapshot, or `find "<text>"`. Lazy lists render only what is near the viewport, so "not in the snapshot" is not "not in the app" until you have swiped to the end.
- **`press`, `get`, `is` and `wait` are web or desktop actions** in 10.2.0. Read state from a fresh snapshot or the page source instead.
- **Keyboard up and down.** After a `fill` or a tap on a text field, snapshot with the keyboard up (which elements it covers, whether the submit control is still reachable), then `keyboard hide` and snapshot again. Record both in the app context; the composer uses them to decide where `hideKeyboard()` or a scroll is needed.
- **Hybrid screens.** On a screen that may embed web content, run `contexts` and record the context names per screen. Snapshot in each context you inspect; switch back to `NATIVE_APP` before leaving the screen.
- **`app terminate` / `launch` and `deeplink`** change app state; use them only where the brief's start state calls for it (§7.2).

---

## 7. Lifecycle and cleanup

### 7.1 Commands

| Command | When |
|---|---|
| `npx wdio session list` | What is open; before and after a phase |
| `npx wdio session -s <slug> info` | Where a session is: context, activity, target |
| `npx wdio session -s <slug> status` | Exit 0 if running, 4 if not |
| `npx wdio session -s <slug> close` | **End of every turn** that opened a session, success or failure |

Close your own session before you hand back, not at the end of the phase; harness backstops differ (`docs/harness/*`). The daemon's idle timeout is 30 minutes by default; a session left open holds the device that long, blocks every other expert that needs it, and on a shared device pool keeps the device marked busy. An expert that hits an error closes its session before it reports.

### 7.2 Read-only discipline

Inspection observes the app; it does not change the device or the user's data.

- Do not toggle device settings, change permissions in system settings, sign in or out of device accounts, install or remove apps, reset or reboot the device.
- Interruption and device-state probes (lock and unlock, notifications, connectivity, permission changes) never run in an inspection session; they are reproduction specs under `tests/platform/` that use the steps or the `driver` fixture, or a recorded framework gap ([`../../bug-discovery/SKILL.md`](../../bug-discovery/SKILL.md) §"Platform targets (iOS, Android)").
- Do not accept or dismiss a system alert to "get past it" (§8).
- Inside the app, take only the actions the brief's scope names (navigate, scroll, open a screen, type into a field the scenario uses). State-changing actions on real data (submit an order, delete an item, send a message) happen only when the brief names them and the data plan covers them ([`../../test-data-conventions/SKILL.md`](../../test-data-conventions/SKILL.md)).
- Leave the app on a neutral screen when the brief says so; the next test's start state is set by the fixture's reset, not by the inspector.

---

## 8. System alerts and permission prompts

Never accept a system alert by default. A permission prompt (location, camera, notifications, contacts, tracking) or a system alert is shown by another process, and each one is a branch of the app's behaviour that a test must cover (allow, deny, later): [`../../platform-testing/SKILL.md`](../../platform-testing/SKILL.md) §"Permissions and system alerts".

- The capabilities file sets `appium:autoAcceptAlerts: false` and `appium:autoDismissAlerts: false` on iOS, and `appium:autoGrantPermissions: false` on Android, unless the project has recorded a reason to do otherwise.
- When an alert appears, `dialog status` reports it. Record its text, the screen and the action that triggered it in the app context, take a screenshot, and stop that path. Accept or dismiss it only when the brief names that branch.
- An alert that blocks every action is a finding for the report, not an obstacle to clear.

---

## 9. Timeouts and budgets

- **Server side.** `appium:newCommandTimeout` in the capabilities file decides how long the server keeps an idle session. Keep it short (300 s, not the tool's 3600 s default) so a crashed expert frees the device in minutes.
- **Per action.** The global `--timeout <ms>` sets the request timeout of one action (capped at 60000). Use it to fail fast on a hung call; a timeout is reported, not retried in a loop.
- **Opening.** A session open on a real device can take tens of seconds. One failed open is reported with its output; "Timed out while enabling automation mode" on iOS means the device is locked, and the expert stops and reports instead of retrying.
- **Budgets.** The brief states how many screens or elements an expert inspects. A longer exploration is several briefs, each opening and closing its own session.

---

## 10. Dispatch-brief template

The orchestrator embeds this block in every brief for an expert that inspects a platform target.

```
## Platform inspection

Use `wdio session` from your shell, in exactly this form:

    npx wdio session -s <your-session-slug> open <platform> --appium-url "$APPIUM_URL" --capabilities tests/capabilities/<device>.json --bundle-id <id>   # android: --package <id>; an appium:app file: --app <path>
    npx wdio session -s <your-session-slug> snapshot -i --all --selectors
    # ... your work, acting by ref ...
    npx wdio session -s <your-session-slug> close

Your session slug: **<concrete-slug>**. Platform: **<ios|android>**.
Capabilities file: `tests/capabilities/<device>.json`. You are the only expert on this device.

Close your session yourself before you report, also on failure. Never accept
or dismiss a system alert unless this brief names that branch. Do not change
device settings.
Do NOT use `close --all` (the orchestrator owns cleanup).

Command surface and rules: `skills/achilles-orchestrator/references/platform-inspection-protocol.md` §3 / §5 / §6.
```

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `open` fails with "unknown command" | `--appium-url` lacks the server's base path | Use the full URL with the base path, from `APPIUM_URL` |
| iOS snapshot shows only the navigation title | Snapshot without `--all`; the tool judged the list hidden | `snapshot -i --all --selectors`; swipe for rows further down |
| `open` exits 2 although the capabilities file names the app | The CLI checks for the app flag before it merges the file | Pass `--bundle-id <id>` (ios) / `--package <id>` (android), equal to the file's app id, or `--app <path>` when the file names the app only by `appium:app` |
| `tap` printed "Tapped" and exited 0, but the screen did not change; the element screenshot is black | The element was `[hidden]` (off-screen or obscured), or sat at a screen edge under a floating toolbar | Swipe it toward mid-screen, re-snapshot, tap the fresh ref, re-snapshot and compare; still no change after one retry is a finding |
| "Timed out while enabling automation mode" (iOS) | The device is locked | Stop and report; do not retry in a loop |
| `back` refused on iOS | No system back on iOS; `back` is a web action | Tap the on-screen back button by ref |
| `REF_STALE` | The screen changed since the snapshot | Re-snapshot, then act |
| Exit code 4 | No session with that name (closed, never opened, or another name) | `list`; open with your own slug |
| An action fails with a dialog hint | A system or app alert is on screen | `dialog status`; record it; act only if the brief names the branch (§8) |
| The device stays busy after a run | A session was not closed | `list`, then `-s <slug> close` for the run's own sessions |
| An element is missing from the snapshot | Lazy list, keyboard covering it, another context, or a hidden element | `swipe` and re-snapshot; `keyboard hide`; `contexts`; `find "<text>"` |

---

## 12. Known constraints and live findings

The inspection tool was proven on a real iOS device. What held:

- `open ios --appium-url <server-with-base-path> --capabilities <file> --bundle-id <id>` opened a named session. Without `--bundle-id`, `open` exited 2 although the file named the app: the CLI checks the flag before it merges the file.
- The CLI injects its own defaults, which the file overrides only for keys it sets (the list: §3.1).
- `tap` on a `[hidden]` element reported success and did nothing; its element screenshot was black.
- `snapshot -i --all --selectors` listed every interactive element with a ref and a selector, accessibility id first, class chain or positional XPath marked "(positional)" otherwise.
- `tap <ref>`, `swipe up`, `source` (full XCUITest XML), `screenshot` and `export` worked; each action printed the WebdriverIO code it ran.
- `close` ended the session and freed the device.

What the protocol encodes from it: `--all` on every snapshot; the app flag on every `open`, equal to the file's app id; the base path inside `--appium-url`; capabilities (udid, `deviceName`, a short `newCommandTimeout`, `noReset`, `autoAcceptAlerts: false`) only from the capabilities file, with every CLI default overridden explicitly; swipe a `[hidden]` element into view before acting on it; no `back` on iOS; positional selectors never land without a better alternative.

Not yet proven, so treat as unverified and report surprises: Android (everything), `fill` on a text field, `long-press`, `contexts` on a hybrid app, and two sessions on two devices at once.

Other constraints:

- **The agent API is experimental** in `@wdio/cli` 10.2.0. The pin is exact; a version bump is a deliberate change that re-runs the smoke checks above.
- **`export`** writes a WebdriverIO mocha spec. It is a reading aid only; Achilles specs are Playwright specs through the Steps API, never an exported file.
- **Attaching to a session a failed test left open** is out of scope here; the test fixture closes its own sessions.
