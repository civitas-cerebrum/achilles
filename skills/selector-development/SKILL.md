---
name: selector-development
description: >
  Add one inert test attribute (data-testid or the project's detected
  convention) to a frontend element that has no stable selector, prove the
  change is inert with an eight-step guardrail pipeline (typecheck, unit,
  e2e, visual diff), and return the new selector. Loaded by an `author`
  dispatch on a selector brief, which grants one frontend file. Triggers:
  Stage 2 inspection finding no stable selector, failure-diagnosis blaming a
  fragile selector, "add stable selectors to <X>", "audit selectors across
  the app". Only when the frontend source and `tests/e2e/` share a
  workspace, or on a platform brief the native or React Native app source
  and `tests/platform/` (testID, accessibilityIdentifier, resource id). Never modifies structure, classes, ids, aria, handlers or text.
---

# Selector development

Smallest possible diff: one element, one attribute, one round trip. Audit mode repeats the same loop page by page under the orchestrator.

## Reference index

| Reference | Holds |
|---|---|
| [`references/selector-convention.md`](references/selector-convention.md) | Attribute precedence and naming rules |
| [`references/inertness-contract.md`](references/inertness-contract.md) | The additive-only contract |
| [`references/guardrail-pipeline.md`](references/guardrail-pipeline.md) | The eight steps, the receipt journal, the revert path |
| [`references/audit-mode-workflow.md`](references/audit-mode-workflow.md) | The whole-app loop |

## Preconditions

Both must hold, else return `skipped` with the reason:

| Gate | Check | `skipped_reason` |
|---|---|---|
| Workspace | `package.json` declares a frontend framework (`react`, `vue`, `svelte`, `@angular/core`, `solid-js`, `preact`, `lit`) and a component tree exists under `src/`, `app/` or `pages/`; `tests/e2e/` holds at least one `*.spec.ts` | `not-frontend-project` |
| Missing selector | the element has no test attribute (`data-testid` / `data-cy` / `data-qa` / `data-test`), no unique role + accessible name, and no unique stable text | `selector-already-stable` |

## Platform variant (iOS, Android)

A native app has no `data-testid`. Its stable handle is the accessibility identifier, which the page repository reads as `accessibility id` (or `id` on Android for a resource id), the top of the platform preference order ([selector-evidence.md](../achilles-orchestrator/references/selector-evidence.md) §"Selector mapping and preference"). On a platform brief the gates and the patch change; the receipt, the one-file grant and the revert path do not.

**Workspace gate (replaces the web one).** The project is a native or React Native app when the workspace holds one of: `package.json` with `react-native` or `expo` (React Native); an `*.xcodeproj` or `*.xcworkspace`, or `Package.swift`, with Swift or Objective-C views (iOS); a `build.gradle` or `build.gradle.kts` with the Android application plugin and `AndroidManifest.xml` (Android, Kotlin, Java or Compose). It does not need a web framework in `package.json` and does not need `tests/e2e/`; it needs at least one spec under `tests/platform/`. None of these present: `skipped`, `not-frontend-project`. A Flutter, Xamarin or other cross-platform stack that the identifiers below do not cover returns `skipped` with the stack named.

**Missing-selector gate.** The element has no accessibility id, no resource id (Android), and no unique, stable label; a positional or text-only candidate from the inspection snapshot is what brings it here.

**The attribute, by stack** (one added property on one element, nothing else):

| Stack | Added at source | Repository key it enables |
|---|---|---|
| React Native | `testID="<value>"` on the component (maps to the accessibility identifier on iOS and the resource id on Android) | `accessibility id` (ios), `id` (android) |
| iOS UIKit | `view.accessibilityIdentifier = "<value>"`, or the Identifier field in a storyboard or xib | `accessibility id` |
| iOS SwiftUI | `.accessibilityIdentifier("<value>")` on the view | `accessibility id` |
| Android Views | `android:id="@+id/<value>"` where the view has none; otherwise `android:contentDescription` only when the element has no visible label (it is read aloud by screen readers, so it must be a meaningful label, never a test token) | `id` (resource id) or `accessibility id` |
| Jetpack Compose | `Modifier.testTag("<value>")`, only where `testTagsAsResourceId` is already enabled on the root; if it is not, enabling it would be a second edit, so return `blocked` with `skipped_reason: no-inert-option`, naming the one-time `testTagsAsResourceId` change for the project owner, as for any out-of-scope element | `id` |

**Rows of a lazy list.** A row is identified by a stable per-row value (the item's id or its stable text, for example ``testID={`order-row-${order.id}`}``), never by its position. A spec addresses a specific row through one repository entry per known or seeded item, keyed by that item's stable id or text. A native list renders only the rows near the viewport, so `scrollUntilFound` must be able to name a row that is not rendered yet; an index-based identifier (`row-3`) changes with scrolling, sorting and data and cannot do that ([`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Gestures and scrolling").

The value follows the project's naming convention ([`references/selector-convention.md`](references/selector-convention.md)). Changing an existing accessibility label, visible text or content description is not inert and is out of scope (`no-inert-option`).

**Guardrails on a platform brief.** Before and after snapshots are `npx wdio session -s <slug> screenshot` captures of the same screen in the same state, per the [platform inspection protocol](../achilles-orchestrator/references/platform-inspection-protocol.md); typecheck and unit tests run the project's own scripts (`tsc` for React Native; the Xcode or Gradle unit target when the brief names its command); the e2e step is the affected platform spec in the one run form ([`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Run command") against a build that contains the patch. A rebuild and reinstall is part of the loop; when the brief gives no build command the patch is staged and returned `blocked` with `blocked_artifact` naming the missing build step, never claimed verified. The visual diff compares the two screenshots as on web.

## JIT loop (one element)

1. Receive the scope (element key, page, spec) from the brief; run both gates.
2. Initialise the receipt `tests/e2e/.selector-development/<element-key>.receipt.json` and write `.current-scope`.
3. **Before snapshot**: `playwright-cli -s=<slug> screenshot tests/e2e/.selector-development/before/<scope>.png`.
4. **Patch**: append the detected attribute to the target opening tag; nothing else changes. The adapter refuses any broader diff to frontend source on a selector brief; the receipt records the file and the staged diff hash.
5. **Typecheck**: the project's script (`typecheck` → `tsc --noEmit` → `lint:types`).
6. **Unit tests**: the project's script (jest / vitest).
7. **E2E**: `npx playwright test <spec>` for the affected spec only.
8. **After snapshot** to `after/<scope>.png`.
9. **Visual diff**: run the visual-diff check the harness adapter provides, or `npx` the package's script, over `before/<scope>.png` and `after/<scope>.png`; pass at 0 differing pixels (a project may configure up to 10).
10. **Stage**: `git add` the patched file; record the staged diff hash in the receipt; clear `.current-scope`, archive the receipt. The orchestrator commits `feat(selectors): add data-testid='<value>' to <element-key>` on your return; you never commit.
11. Return the envelope (below).

On any failure in steps 5–9: `git checkout -- <patched files>`, delete the receipt, clear `.current-scope`, return `blocked` with `blocked_artifact` pointing at the failing output. Never retry with a different attribute value inside the same dispatch.

Out of scope, returned as `blocked` with `skipped_reason: no-inert-option`: elements rendered by a library that swallows unknown props; any change that would need a wrapper, a child or a prop.

## Audit mode

Prerequisite: a sentinel-bearing `tests/e2e/docs/journey-map.md` (otherwise `blocked` naming map-journeys). The orchestrator dispatches one author per page from the site map (independent pages in parallel); each author snapshots the page, applies the missing-selector gate per interactive or asserted node, runs the JIT loop per qualifying node (one receipt each; the orchestrator commits once per page on the author's return), and records results in `tests/e2e/.selector-development/audit-ledger.json` keyed by page id (dedup and resumption). Details: [`references/audit-mode-workflow.md`](references/audit-mode-workflow.md).

## Return

```jsonc
{
  "handover": { "role": "author", "cycle": 1, "status": "ok | skipped | blocked", "next-action": "…" },
  "mode": "jit" | "audit",
  "scope": "<element-key>" | "<page-id>",
  "attribute": { "name": "data-testid", "value": "submit-button" },
  "files_modified": ["src/components/Form.tsx"],
  "guardrails": { "before_snapshot": "pass", "patch_applied": "pass", "typecheck": "pass",
                  "unit_tests": "pass", "e2e": "pass", "after_snapshot": "pass", "visual_diff": "pass" },
  "ledger_entry": "…",                                   // audit mode
  "skipped_reason": "no-inert-option | not-frontend-project | selector-already-stable | null",
  "blocked_artifact": "<path> | null"
}
```

`ok`: attribute added, file staged, ready to commit; the calling author resumes with the new selector. `skipped`: a gate exited early. `blocked`: a guardrail failed and the patch was reverted.

Out of scope: cross-repository frontends, auto-PRs into a separate repo, migrating one attribute family to another, hardening already-stable elements, visual regression beyond the inertness diff.
