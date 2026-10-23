---
name: evidence-capture
description: >
  Evidence-first verification of one functional task, loaded by an `author`
  dispatch: compose one Steps-API spec with per-step screenshots, run it with
  video, trace, HAR and console capture, and freeze an immutable, redacted
  bundle under `tests/e2e/evidence/<slug>-<ts>/` that a human can open or
  attach to a ticket. Triggers: "verify this flow with evidence", "screenshot
  every step", "record this scenario", "show me proof that X works",
  "evidence package for X", "daily QA task", and the evidence run inside the
  verify-change workflow. Not for growing a durable suite, expanding
  coverage, bug hunting, repair or single-failure diagnosis.
---

# Evidence capture

The deliverable is the bundle, not the test. The spec is the means; the bundle is what a human reads. No `journey-map.md`, no committed spec, no coverage pass required.

## Inputs (from the brief)

1. **Task**: one sentence stating the what.
2. **App URL**: explicit; never inferred from `playwright.config.ts`.
3. **Credentials or auth state** when the flow needs login; never invented.
4. **Pass criterion**: one sentence; the verdict is grounded in it, not in your reading.
5. **Bundle slug**: kebab-case; and an optional app build id for `summary.md`.
6. **Mode**: `live` (default: phases 1–5), `dry-run` (compose only; `summary.md` says `Verdict: NOT RUN`), `existing` (wrap a named spec with the capture flags without modifying it).

Any missing input is a `NEEDS_CONTEXT` return listing the missing items; do not guess.

## Phase 1: quick discovery

Open `npx playwright-cli -s=companion-<slug> open --browser=chromium <URL>`, snapshot each page the task touches (walk the happiest path once), note the elements you will touch, close the session. Task-scoped: no unrelated pages, no `app-context.md` edits (evidence runs are ephemeral). If the CLI cannot reach the app at the start, return `NEEDS_CONTEXT` asking for selectors or a screenshot per step; if it fails mid-walk, keep what you have and note the user-supplied remainder in `summary.md` §Notes.

## Phases 2–3: compose and run

Rules and the run command: [`references/compose-and-capture.md`](references/compose-and-capture.md). One spec at `tests/e2e/evidence/<slug>-<ts>/spec.ts` using `baseFixture`, every interaction through `steps.*`, `steps.screenshot()` after every meaningful step (`NN-<step>.png`), the final assertion quoting the pass criterion verbatim, HAR / console / video hooks wired in the spec. Repository entries are reused when they exist; new entries live inline in the bundle spec (the one sanctioned inline-selector exception, [`test-composition-standards.md`](../achilles-orchestrator/references/test-composition-standards.md) §3.1) and graduate to repository entries only if the scenario is later authored as a durable test.

A failing run is a first-class outcome: one in-bundle retry after fixing a suspected test issue, then the bundle ships with the failure evidence and the verdict `FAILED`. No stabilisation loop, no `failure-diagnosis` here; the orchestrator decides what follows.

## Phase 4: bundle

Layout, `summary.md` sections and verdict definitions: [`references/bundle-and-summary.md`](references/bundle-and-summary.md). `PASSED` (every assertion resolved, criterion reflected in the final assertion; surprising side observations go in Notes), `FAILED` (an assertion failed), `INCONCLUSIVE` (the runner never reached the criterion: crash, setup error, unreachable network). The verdict is read from the run output, never from how the screenshots look. Every link in `summary.md` points at a file that exists; missing captures are named under `## Capture gaps`.

## Redaction

Any captured `network.har` or `console.log` gets a redaction pass before anything else happens to it, whether or not a bundle is being assembled. Grep for the four `secrets-sweep` literal classes (credentials, API keys, PII shapes, tokens in `Authorization` / `Set-Cookie` and any `*-bypass` / `*-token` / `*-key` request header) and redact in place. Redact HARs **by header name across every entry**, not by searching for the value you know: one credential appears in every request. Strip response bodies at the same time. Record every redaction under `## Redactions` in `summary.md`. Evidence bundles are not swept by the secrets-sweep skill; this pass is their only one, and the adapter refuses a sign-off while a bundle still holds a live credential.

## Hard rules

1. The bundle is the deliverable; a passing test without a bundle is a failure of this skill. Phase 4 runs even when Phase 3 failed.
2. No capture is dropped to make the run faster; a capture that failed to record is a named gap.
3. No raw selectors outside the bundle-scoped exception; the spec is a proper Steps API test.
4. No edits to durable files (`journey-map.md`, `app-context.md`, `adversarial-findings.md`, `playwright.config.ts`, `package.json`, committed specs).
5. No exfiltration: bundle contents never leave the machine unless the brief authorises both the artifact and the destination.
6. Timestamped slug `<slug>-<YYYYMMDD-HHMMSS>`; never overwrite an existing bundle (append `-2`, `-3` on a same-second collision).
7. One environment per bundle or per named subdirectory (`preview/`, `production/`); count artifacts against runs before writing the verdict.
8. The bundle is immutable once Phase 4 freezes it; a graduated durable spec is written under `tests/`, never inside the bundle.
9. Visual review: every screenshot is checked for padding symmetry, alignment, clipping, hierarchy and state-transition layout; design findings go in `summary.md` §Notes (they are findings, not criterion failures).

## Return

`DONE` with the verdict, the absolute bundle path, the capture-gap and redaction summaries, and the design findings. The next step (graduate into a durable test via the author-scenario workflow, diagnose a failure, file a ticket) is the orchestrator's `NEEDS_CONTEXT` question to the user, not yours; include in `summary` the one line the orchestrator needs: the cascade-relevant facts you observed (project scaffolded or not, repository entries reused or proposed).
