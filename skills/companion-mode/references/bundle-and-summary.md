# Phase 5: bundle layout and summary.md

# Phase 5: Bundle

Write the bundle directory with this exact layout:

```
tests/e2e/evidence/<slug>-<YYYYMMDD-HHMMSS>/
├── summary.md           ← human-readable verdict, links, criterion, observations
├── spec.ts              ← the composed test
├── screenshots/
│   ├── 01-navigate.png
│   ├── 02-fill-email.png
│   └── …
├── video.webm           ← full recording
├── trace.zip            ← Playwright trace (open with `npx playwright show-trace`)
├── network.har          ← HAR file
├── console.log          ← browser console output
└── run-output/          ← raw playwright output (kept for forensic use)
```

**One run per environment, one path per run.** `video.webm`, `trace.zip`
and `network.har` are fixed names. If the same task is verified against
more than one environment, viewport, or locale in one pass, the second
run overwrites the first at every one of them — silently, because
Playwright is doing exactly what it was told. Give each environment its
own bundle, or its own named subdirectory inside the bundle
(`preview/`, `production/`), and count the artifacts against the number
of runs before writing the verdict. A summary that cites two runs over
one set of files is citing evidence that no longer exists.

## `summary.md` — required sections

```markdown
# Companion-mode evidence — <task description verbatim>

**Run timestamp:** <ISO 8601 local + UTC offset>
**Verdict:** ✅ PASSED  |  ❌ FAILED  |  ⚠️ INCONCLUSIVE
**App URL:** <url>
**Browser:** chromium <version>   <!-- from `npx playwright --version` or the report metadata -->
**App build:** <user-supplied id, or "not supplied">
**Pass criterion (user-supplied):** "<verbatim>"

## What I did
<numbered list of step labels matching the screenshot filenames>

## What I observed
<one short paragraph stating what actually happened, written for a human reader>

## Evidence
- Video: [video.webm](video.webm)
- Trace: [trace.zip](trace.zip) — open with `npx playwright show-trace trace.zip`
- HAR: [network.har](network.har)
- Console: [console.log](console.log)
- Per-step screenshots: [`screenshots/`](screenshots/)

## Test code
[`spec.ts`](spec.ts)

## Reproduction
```bash
npx playwright test tests/e2e/evidence/<slug>-<ts>/spec.ts --headed --trace=on
```

## Notes
<optional — anomalies, retries, environment caveats, suspected app behaviour>
```

## Verdict definitions

The bundle's `summary.md` carries one of three verdicts. These are not interchangeable — choosing the wrong one undermines the Phase-6 offer matrix (Rule 10 defers automation only on FAILED and INCONCLUSIVE; misclassifying a passed run as INCONCLUSIVE silently dodges the offer the user is owed).

- **PASSED** — the test ran to completion AND every assertion in the spec resolved successfully AND the user-supplied pass criterion is reflected in the final assertion. Surprising side observations (a console warning, an unexpected toast, a slow page load) do NOT downgrade PASSED — they go in `summary.md` §Notes, the verdict stays PASSED.
- **FAILED** — the test ran to completion AND at least one assertion failed (or threw a Playwright timeout, mismatched expectation, etc.). A failure of the spec's pass-criterion assertion lands here even if everything else passed. The bundle ships with the failure evidence; Phase 6 offers `failure-diagnosis`, not the automation-graduation offer.
- **INCONCLUSIVE** — strictly reserved for cases where the verdict cannot be determined: the runner crashed before any assertion ran, the assertion threw a non-assertion error before evaluating (e.g., `TypeError` in test setup, network unreachable, browser failed to launch), or the spec did not reach the pass-criterion line. INCONCLUSIVE is **not** a hedge for "the run passed but something looked off" — that is PASSED with a Notes entry.

## Output discipline

- **No fabricated evidence.** Every link in `summary.md` MUST point to a file that exists. If video/HAR/trace failed to record (browser quirk, permission), the link is removed and a `## Capture gaps` section names what's missing. Never link a placeholder.
- **No paraphrasing the user's criterion.** Copy it verbatim with quotes. The reader needs to confirm the test answered the question they asked.
- **Bundle is self-contained.** Anyone with the directory and a Playwright install can reproduce — no extra config files outside the bundle are required.
- **Verdict is determined by the runtime, not by the agent's aesthetic judgment.** Read the assertion outcomes from the Playwright run output; do not invent INCONCLUSIVE because "the screenshots look weird."
