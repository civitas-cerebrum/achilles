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
  workspace. Never modifies structure, classes, ids, aria, handlers or text.
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
