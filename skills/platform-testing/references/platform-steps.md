# Platform steps: the API surface for native app tests

The one file that holds the platform API of `@civitas-cerebrum/element-interactions` 0.4.0 and `@civitas-cerebrum/element-repository` 0.4.0. Every other skill and reference points here instead of repeating a signature.

**Both 0.4.0 releases are required, and neither is published yet.** Until they are, the platform modality cannot run in a consumer project: a project with either package below 0.4.0 is at cascade level A for platform ([`../../achilles-orchestrator/references/cascade.md`](../../achilles-orchestrator/references/cascade.md) §"Platform projects"). The signatures below follow the agreed 0.4.0 surface; once the packages are published, the installed typings win over this file where they differ, and the difference is reported as a framework gap ([`../../achilles-orchestrator/references/framework-gap.md`](../../achilles-orchestrator/references/framework-gap.md)). The web Steps API is unchanged and lives in [`../../achilles-orchestrator/references/api-reference.md`](../../achilles-orchestrator/references/api-reference.md); shared steps keep the names and argument order documented there on every platform.

Read this file in full before writing a platform spec, a platform fixture or a platform page-repository entry. Never write a platform step, option or selector key from memory.

## Platforms and driver families

```ts
export type Platform = 'web' | 'android' | 'ios' | 'macos' | 'windows';
export type DriverFamily = 'playwright' | 'appium';
export const PLATFORMS: readonly Platform[];
export function isPlatformName(value: unknown): value is Platform;
export function familyOf(platform: Platform): DriverFamily; // web -> playwright, rest -> appium
```

`Platform` is the only platform vocabulary. `mobile`, `native`, `selenium` and `appium` are never platform values. `macos` and `windows` are declared but not implemented yet: a session start on either throws `Error('Platform "<p>" is declared but not implemented yet.')`.

## Fixture options

Platform runs use the same `baseFixture` as web runs. Two options select and open the platform session:

```ts
import type { Platform } from '@civitas-cerebrum/element-repository';

export interface ServerOptions {
  protocol?: 'http' | 'https';
  hostname?: string;
  port?: number;
  path?: string;        // Appium base path, e.g. '/wd/hub'
  user?: string;
  key?: string;
}

export interface SessionStartContext {
  platform: Platform;
  capabilities: Record<string, unknown>; // exactly the JSON file content
  server: ServerOptions;
}

export interface SessionProvider {
  start(context: SessionStartContext): Promise<WebdriverIO.Browser>;
  stop(driver: WebdriverIO.Browser): Promise<void>;
}

export interface SessionOptions {
  capabilities?: string;                 // PATH to a JSON file. Default: process.env.E2E_CAPABILITIES
  server?: string | ServerOptions;       // URL (with base path) or object. Default: process.env.APPIUM_URL ?? 'http://127.0.0.1:4723'
  provider?: SessionProvider;            // default: the built-in Appium provider
  reset?: 'relaunch' | 'none';           // between tests. Default 'relaunch'
  onSessionStarted?: (driver: WebdriverIO.Browser) => Promise<void>;
}

// added to the existing BaseFixtureOptions
platform?: Platform;        // default: process.env.E2E_PLATFORM ?? 'web'; an unknown value throws
session?: SessionOptions;   // used only when familyOf(platform) === 'appium'
```

Rules:

- `capabilities` is always a file path. An inline object is not accepted.
- The library sends exactly the file's content. It adds, defaults and rewrites nothing. The file must contain `platformName`; if it disagrees with `platform` (case-insensitive), the run fails before a session opens and the message names both.
- The app under test comes from the file: `appium:bundleId` (ios, macos), `appium:appPackage` (android), `appium:app` otherwise. Steps that take an optional `appId` default to it.
- Credentials: `APPIUM_USER` / `APPIUM_KEY` fill `server.user` / `server.key` when not given. They are never read from the capabilities file.
- The session is worker-scoped; `reset: 'relaunch'` terminates and re-activates the app under test between tests.

The scaffolded fixture for a platform project:

```ts
// tests/platform/fixtures/base.ts
import { test as base, expect } from '@playwright/test';
import { baseFixture } from '@civitas-cerebrum/element-interactions';

export const test = baseFixture(base, 'tests/platform/page-repository.json', {
  timeout: 30000,
  // platform and session default to E2E_PLATFORM, E2E_CAPABILITIES and APPIUM_URL.
  // session: { reset: 'relaunch' },
});
export { expect };
```

A project that already has `tests/e2e/page-repository.json` passes that path instead; there is one page repository per project. The fixture carries no capability, no server URL and no app id.

## Environment variables

| Variable | Meaning |
|---|---|
| `E2E_PLATFORM` | `web` (default) \| `android` \| `ios` \| `macos` \| `windows` |
| `E2E_CAPABILITIES` | Path to the capabilities JSON file |
| `APPIUM_URL` | Full server URL including base path |
| `APPIUM_USER`, `APPIUM_KEY` | Optional credentials for a remote or cloud server |

This is the complete list. No other variable selects platform, device or server. Unprefixed `PLATFORM` and `CAPABILITIES` are not read: shells set them for their own purposes, and nothing ambient may change a web run. An unknown `E2E_PLATFORM` value throws.

## Fixture values

| Fixture | Platforms | Notes |
|---|---|---|
| `steps` | every platform | The Steps API; shared steps plus the platform steps below |
| `repo` | every platform | Built with `{ platform }` as its active platform |
| `interactions` | every platform | Raw interactions |
| `contextStore` | every platform | Per-test key-value store |
| `page` | `web` only | Playwright page |
| `driver` | appium family only | `WebdriverIO.Browser`; requesting it on `web` throws `PlatformNotSupportedError('driver', 'web')` |

## Step semantics

- Shared steps keep their names and `(elementName, pageName, ...)` argument order on every platform.
- Every element step, the platform gestures included, takes an optional trailing options object: its own options merged with `StepOptions` (element selection `strategy`, `index`, `text`, `attribute`, `value`, and the per-call `timeout`), as the existing steps do ([`../../achilles-orchestrator/references/api-reference.md`](../../achilles-orchestrator/references/api-reference.md)).
- A web-only step called on an appium-family platform throws `PlatformNotSupportedError(<stepName>, <platform>)`. A platform-only step called on `web` throws the same. A platform step one platform cannot do (`pressBack` on ios) throws the same.
- Web-only steps, as designed for element-interactions 0.4.0 (confirm against the installed package's `PlatformNotSupportedError` behaviour before relying on the list): URL steps, tabs, cookies, storage, network waits, HTML and CSS reads, file upload, `selectDropdown`, `hover` and `rightClick`. The `hover` step throws on a platform run even though the `hover` primitive exists on the `Element` interface (§"Element primitives").
- Nothing warns and continues. A skipped action is a thrown error, never a log line and a green test.
- Every `verify*` step and matcher polls until its timeout in both families. A platform assertion never reads once.

The error class is defined once, in element-repository, and re-exported by element-interactions, so `instanceof` works across both packages:

```ts
export class PlatformNotSupportedError extends Error {
  readonly method: string;
  readonly platform: Platform;
  constructor(method: string, platform: Platform);
  // message: `"<method>" is not supported on platform "<platform>".`
}
```

A spec that must run on several platforms and hits a step one of them cannot do takes a platform branch with a stated reason (see [`../SKILL.md`](../SKILL.md) §"Platform divergence"); it never catches `PlatformNotSupportedError` to keep going.

## Platform steps

Names are fixed; all return `Promise<void>` unless noted.

```ts
import type {
  SwipeDirection, SwipeOptions, ScrollIntoViewOptions,
  LongPressOptions, TapAtOptions, PinchOptions,
} from '@civitas-cerebrum/element-repository';
import type { StepOptions } from '@civitas-cerebrum/element-interactions';

type VerifyOptions = { timeout?: number; errorMessage?: string };

// App
steps.launchApp(appId?: string)
steps.activateApp(appId?: string)
steps.terminateApp(appId?: string)
steps.backgroundApp(seconds: number)
steps.resetApp()                                   // terminate + activate the app under test
steps.installApp(appPath: string)
steps.removeApp(appId: string)
steps.openDeepLink(url: string, appId?: string)

// Gestures on an element (each delegates to the element primitive of the same name)
steps.swipe(elementName, pageName, direction: SwipeDirection, options?: SwipeOptions & StepOptions)
steps.scrollIntoView(elementName, pageName, options?: ScrollIntoViewOptions & StepOptions)   // existing step, gains direction
steps.scrollUntilFound(elementName, pageName, options?: ScrollIntoViewOptions & StepOptions)
steps.longPress(elementName, pageName, options?: LongPressOptions & StepOptions)
steps.pinch(elementName, pageName, options?: PinchOptions & StepOptions)
steps.zoom(elementName, pageName, options?: PinchOptions & StepOptions)

// Gestures on the screen
steps.swipeScreen(direction: SwipeDirection, options?: SwipeOptions)
steps.tapAt(x: number, y: number)                  // screen coordinates

// Device
steps.pressBack()                                  // android only
steps.hideKeyboard()
steps.setOrientation(orientation: 'portrait' | 'landscape')
steps.acceptAlert()
steps.dismissAlert()
steps.setPermission(permission: string, state: 'grant' | 'deny' | 'reset')

// Contexts
steps.getContexts(): Promise<string[]>
steps.switchContext(name: string)                  // 'NATIVE_APP' or a 'WEBVIEW_*' name

// Assertions (polling)
steps.verifyAppInForeground(appId?: string, options?: VerifyOptions)
steps.verifyOrientation(orientation: 'portrait' | 'landscape', options?: VerifyOptions)
steps.verifyKeyboardShown(options?: VerifyOptions & { negated?: boolean })   // negated: true asserts it is hidden
steps.verifyContext(name: string, options?: VerifyOptions)

// Extraction
steps.getPageSource(): Promise<string>
```

The element gestures are also on the fluent chain, after any strategy selector:

```ts
await steps.on('orderRow', 'OrdersPage').nth(2).swipe('left');
await steps.on('orderRow', 'OrdersPage').longPress({ duration: 1500 });
await steps.on('photo', 'GalleryPage').zoom({ scale: 2 });
await steps.on('photo', 'GalleryPage').pinch();
await steps.on('map', 'StorePage').tapAt({ x: 40, y: 40 });   // offset from the element's top-left
await steps.on('lastRow', 'OrdersPage').scrollIntoView({ direction: 'down' });
```

Direction and option types (`SwipeDirection`, `SwipeOptions`, `ScrollIntoViewOptions`, `LongPressOptions`, `TapAtOptions`, `PinchOptions`) are defined once, in element-repository; a spec that needs one imports it from there and never redefines it.

Usage notes that follow from the semantics:

- The element gestures (`swipe`, `scrollIntoView`, `longPress`, `tapAt`, `pinch`, `zoom`) call the repository element's own primitive (§"Element primitives"); element-interactions never re-implements them.
- `scrollUntilFound` is the step for lazy lists. Give the direction; never check `exists` first and scroll after.
- `steps.verifyKeyboardShown()` asserts the keyboard is up; `steps.verifyKeyboardShown({ negated: true })` asserts it is down, as `negated` does on every other verification.
- `steps.tapAt(x, y)` taps screen coordinates and is a last resort: it breaks across device classes and orientations. Prefer an element step.
- `acceptAlert` / `dismissAlert` act on a system or app alert that is on screen; neither is called "just in case" (see [`../SKILL.md`](../SKILL.md) §"Permissions and system alerts").
- `setPermission` sets a permission state before a scenario starts. It is the arrange step for a "permission already granted / denied" branch, not a substitute for testing the prompt.

## Page repository: one page name per platform

One file may hold the same page name once per platform:

```json
{ "pages": [
  { "name": "LoginPage", "platform": "web",     "elements": [ { "elementName": "submit", "selector": { "css": "button[type=submit]" } } ] },
  { "name": "LoginPage", "platform": "android", "elements": [ { "elementName": "submit", "selector": { "accessibility id": "login-submit" } } ] },
  { "name": "LoginPage", "platform": "ios",     "elements": [ { "elementName": "submit", "selector": { "accessibility id": "login-submit" } } ] }
] }
```

- `platform` missing means `web`. Element names for one logical element are identical across platforms, so one spec addresses `submit` on `LoginPage` everywhere.
- Existing flags (`provisional`, `list`, `fallback`) keep their meaning.
- Selector keys on platform pages: `accessibility id`, `id`, `xpath`, `class name`, `uiautomator`, `predicate`, `class chain`, `text`, plus the enhanced `role` + `name`.
- `id` on a platform page is the resource-id on android and the `name` lookup on ios. Never CSS.
- Lookup: with an active platform set, the repository uses the page whose `name` matches and whose `platform` (default `web`) equals the active platform. No such page throws `ElementRepository: page '<name>' has no entry for platform '<active>'. Available: <list>.` Two repository instances with different active platforms work side by side.

Mapping an inspection selector to a repository selector: [`../../achilles-orchestrator/references/platform-inspection-protocol.md`](../../achilles-orchestrator/references/platform-inspection-protocol.md) §"Selectors and the page repository". Preference order: [`../../achilles-orchestrator/references/selector-evidence.md`](../../achilles-orchestrator/references/selector-evidence.md) §"Selector mapping and preference".

## Element primitives

The `Element` interface in element-repository carries the per-element primitives on every platform.

Existing and unchanged: `click`, `fill`, `clear`, `check`, `uncheck`, `hover`, `doubleClick`, `pressSequentially`, `dragTo`, `waitFor`, `isVisible`, `isEnabled`, `isChecked`, `exists`, `textContent`, `getAttribute`, `inputValue`, `boundingBox`, `screenshot`, `count`, `all`, `first`, `nth`, `scrollIntoView(options?: ScrollIntoViewOptions)` (`{ direction?, timeout? }`), `swipe(direction: SwipeDirection, options?: SwipeOptions)` (`{ distance?, timeout? }`).

New:

```ts
longPress(options?: LongPressOptions): Promise<Element>;  // { duration?, timeout? }; duration ms, default 1000
tapAt(offset: { x: number; y: number }, options?: TapAtOptions): Promise<Element>; // px from the element's top-left
pinch(options?: PinchOptions): Promise<Element>;          // { scale?, timeout? }; scale in (0,1), default 0.5
zoom(options?: PinchOptions): Promise<Element>;           // scale > 1, default 2
rawText(): Promise<string>;                               // the text without trimming
```

- The four gestures return the element itself, like every other interaction, so they chain.
- On platform elements all four use W3C pointer actions.
- On web elements `longPress` and `tapAt` use the mouse; `pinch` and `zoom` throw `PlatformNotSupportedError('pinch' | 'zoom', 'web')`.
- Platform `first()` / `nth(i)` index for real; `filter()` throws `PlatformNotSupportedError` when it cannot be honoured.
- Text on ios reads `label`, then `value` (`value` first for a text input); `textContent()`, the `text` selector strategy and text lookups follow the same rule.
- `ElementChain` gains `scrollIntoView(options?)`, `swipe(direction, options?)` and the four gestures as chain steps.

## Failure evidence

On a failed platform test the fixture attaches, through `testInfo.attach`, `failure-screenshot` (`image/png`) and `page-source` (`text/xml`). The rest of the platform evidence floor (device log, screen recording, app and OS version) is in [`../SKILL.md`](../SKILL.md) §"Failure evidence".

## Package facts

- `@civitas-cerebrum/element-repository` 0.4.0 and `@civitas-cerebrum/element-interactions` 0.4.0, both required and neither published yet; element-interactions depends on element-repository `^0.4.0`.
- `webdriverio ^10` is an optional peer, imported dynamically; web users install nothing new. The driver type in every signature is `WebdriverIO.Browser`.
