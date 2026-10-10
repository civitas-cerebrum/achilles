# Phases 3–4: compose the evidence test, run with capture

# Phase 3: Compose the Evidence Test

Write **one** spec file under `tests/e2e/evidence/<slug>-<ts>/spec.ts` (the bundle directory, not the suite's `tests/`). The test uses the standard Steps API but with explicit per-step evidence calls.

## Composition rules

- Use `baseFixture` from `tests/fixtures/base.ts` exactly as Stage 3 does.
- Every interaction goes through `steps.*` — no raw `page.locator()`.
- After every meaningful step (navigation, fill, click, verification), call `steps.screenshot({ path: '<bundle>/screenshots/<NN>-<step>.png' })`. Numbering is zero-padded so files sort naturally.
- The final verification asserts the user-supplied pass criterion from Phase 1 — NOT a paraphrase. Quote it as the test name and the assertion message so the bundle reader can trace it.
- Use named selectors via `page-repository.json` when entries already exist; otherwise inline a minimal proposal scoped to this bundle's directory rather than mutating the project's repo.
- Test name format: `companion: <task description verbatim>`.
- **Wire the HAR and console capture hooks in the spec itself.** The Phase-4 capture table only populates if these hooks are in place; if you omit them, the bundle ships with `Capture gaps: HAR` / `Capture gaps: console` and the cause is the spec, not the runner. Specifically:
  - **Console capture:** in a `test.beforeEach`, register `page.on('console', msg => …)` and write each message to `<bundle>/console.log` with timestamp and level.
  - **HAR capture:** in the `baseFixture` extension or a `test.use({ contextOptions: { recordHar: { path: '<bundle>/network.har', mode: 'minimal' } } })` call, set `recordHar` to write to the bundle's `network.har`.
  - **Video capture:** in the spec, call `test.use({ video: 'on' })` — video is wired in-spec, not via a runner flag.
  - A bundle with `Capture gaps` because the hook was omitted is a contract violation, not a recording failure. Wiring failures (browser version, permissions, disk full) are recording failures and warrant the gap entry; missing hooks are skill failures and require fixing the spec.

## Forbidden in companion mode

- **Do NOT** `npm version patch` — companion mode does not ship code.
- **Do NOT** add the spec to the project's `tests/` directory unless the user explicitly asks "graduate this to the suite" in Phase 6.
- **Do NOT** edit `playwright.config.ts` — the runner config is set by the harness in Phase 4.
- **Do NOT** modify `tests/e2e/docs/journey-map.md`, `app-context.md`, `adversarial-findings.md`, or any companion ledger. These belong to the durable pipeline.

## Selector handling

- If a needed selector is missing from `page-repository.json`, present the proposed entry to the user and wait for approval (per Rule 2 of `achilles-protocol`). The only exception is `autonomousMode: true`, identical to the orchestrator's autonomous-mode contract.
- The proposed entry is added to the project's `page-repository.json` only if the user accepts; otherwise it lives inline in the bundle's spec.
- Bundle-scoped inline proposals are the suite's **one documented exception** to the durable-spec inline-selector ban — labelled citation, canonical text: `../achilles-protocol/references/test-composition-standards.md` §3.1 (they graduate to repo entries at Stage-3 graduation).

---

# Phase 4: Run with Capture

Execute the test with full instrumentation. The companion-mode runner overrides Playwright config for this run only — the project's `playwright.config.ts` stays untouched.

Run command shape:

```bash
npx playwright test tests/e2e/evidence/<slug>-<ts>/spec.ts \
  --output=tests/e2e/evidence/<slug>-<ts>/run-output \
  --reporter=html,json \
  --trace=on \
  --workers=1
```

Required capture flags:

| Capture | Flag / mechanism | Lands at |
|---|---|---|
| Per-step screenshots | `steps.screenshot()` calls in the spec | `<bundle>/screenshots/` |
| Video recording | `test.use({ video: 'on' })` in the spec | `<bundle>/run-output/.../video.webm` (move to `<bundle>/video.webm`) |
| Playwright trace | `--trace=on` | `<bundle>/run-output/.../trace.zip` (move to `<bundle>/trace.zip`) |
| HAR (network) | Configure `recordHar` in test fixture context | `<bundle>/network.har` |
| Console output | Listen on `page.on('console', …)` from a `before` hook in the spec | `<bundle>/console.log` |

If the run fails: do **NOT** invoke `failure-diagnosis`. Companion mode treats failure as a first-class outcome — the bundle still ships with the failure evidence, and Phase 6 reports `verdict: failed` with the screenshot/video pointers. The QA engineer decides what to do with it (file a ticket, escalate, retry). If the user explicitly asks to debug after seeing the bundle, *then* hand off to `failure-diagnosis`.

A failure-shaped run that the agent suspects is a test issue (wrong selector, missing repo entry) gets **one** in-bundle retry only after fixing the cause; if it still fails, the bundle ships and Phase 6 names the suspected cause without further retry. Companion mode is not a stabilization loop — that is `test-composer`'s job.
