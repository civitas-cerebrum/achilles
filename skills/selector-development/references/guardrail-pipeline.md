# Guardrail pipeline

The eight steps, the receipt journal that records them, and the revert path. The author runs the steps in order and writes the journal entries itself; on Claude Code the adapter mirrors the step order as visible state and refuses a non-inert patch (`docs/harness/claude-code.md`), which is a backstop, not a substitute for the order below.

## The eight steps

| # | Step | Action |
|---|---|---|
| 1 | `before_snapshot` | `playwright-cli -s=<slug> screenshot tests/e2e/.selector-development/before/<scope>.png` |
| 2 | `patch_applied` | one attribute appended to one opening tag in one frontend file |
| 3 | `typecheck` | the project's typecheck script (`typecheck` → `tsc --noEmit` → `lint:types`) |
| 4 | `unit_tests` | the project's unit-test script (jest / vitest) |
| 5 | `e2e` | `npx playwright test <spec>` for the affected spec only |
| 6 | `after_snapshot` | the same route to `after/<scope>.png` |
| 7 | `visual_diff` | the visual-diff check the harness adapter provides, or the package's script through `npx`, over `before/<scope>.png` and `after/<scope>.png`; pass at 0 differing pixels (a project may allow up to 10) |
| 8 | `commit` | the patched file staged (`git add`) with the staged diff hash equal to the hash recorded at step 2; the orchestrator makes the commit on the author's return |

A step counts as done only when its `pass` entry is in the journal in sequence. A `fail` entry stops the pipeline; the next step is not attempted.

## Receipt journal

`tests/e2e/.selector-development/<scope>.receipt.json`, written before step 1, appended after every step:

```jsonc
{
  "schema_version": 2,
  "mode": "jit" | "audit",
  "scope": "<element-key>" | "<page-id>",
  "git_diff_hash": null,                 // sha256 of `git diff --cached`, set at step 2
  "attribute": { "name": "data-testid", "value": "submit-button" },
  "files": [],                           // the frontend file, set at step 2
  "steps": [ { "name": "before_snapshot", "status": "pass", "ts": "<ISO-8601>", "artifact": "…" } ]
}
```

Per-step extras: `artifact` on steps 1 and 6; `files` on step 2; `elapsed_ms` on steps 3 and 4; `spec` on step 5; `diff_pixels` on step 7. Write the file with a temp-and-rename so a crash never leaves partial JSON.

`tests/e2e/.selector-development/.current-scope` holds the active scope (one line); written at start, deleted at step 8 or on revert, so a stale scope never leaks into the next operation. Once step 8 is journaled the receipt is archived to `tests/e2e/.selector-development/archive/<scope>.<ts>.receipt.json`.

## Revert path

When any of steps 3–7 fails:

1. Append the `fail` entry with the artifact path (typecheck output, test report, the diff PNG).
2. `git checkout -- <files from the journal>`.
3. Delete the receipt and `.current-scope`.
4. Return `blocked` with `blocked_artifact` pointing at the failing output.

A re-attempt re-enters at step 1 with a fresh receipt; the inertness check applies to every frontend edit regardless, so a revert can never smuggle a non-inert change. The calling author (Stage 2, diagnosis, or the audit loop) decides whether to retry with a different attribute value, record test debt, or escalate through the orchestrator.
