# Phase 6: report and automation offer

# Phase 6: Report and automation offer

Companion mode does not stop at the bundle. The deliverable is the evidence; the **next move** is to offer automation. The offer's shape depends on the project's onboarding state, which is determined by the same cascade detector the `onboarding` skill uses.

## Setup detection (run before printing the report)

Run the canonical cascade detector in [`../achilles-protocol/references/cascade-detector.md`](../../achilles-protocol/references/cascade-detector.md). It returns one of `A | B | C | None`. The detector's table and per-caller response matrix live there: do **not** re-paste the table here, and do not infer the levels from local memory. If the reference says Level D exists and this skill's offer matrix doesn't enumerate it, that's a bug in this skill, not the reference.

After running the detector, also check whether `tests/e2e/docs/coverage-expansion-state.json` exists. The cascade detector itself doesn't read that file; it answers "is this project onboarded?", not "is a pipeline mid-flight?", but companion-mode does treat the state file as a Phase-6 advisory (see "Mid-pipeline advisory" below).

Use the Read and Glob tools, not `ls`/`cat`. Record the level and the in-flight flag: they determine the offer and any advisory line below.

## Report message

Print one short message in this order:

1. **Verdict**: pass / fail / inconclusive, one line.
2. **Bundle path**: absolute path; the user is going to open it.
3. **Setup state**: one line: *"Detected: <Level None | A | B | C> — <one-line summary>"*.
4. **Next-step offer**: selected by verdict × setup state.

Do not list every screenshot in the report. The bundle is the listing; the message is the pointer.

## Visual inspection of evidence

Every evidence screenshot must be reviewed for design quality, not just functional correctness.
A screenshot that proves "the component rendered" can simultaneously show broken padding,
misalignment, or visual inconsistency that no assertion catches.

Check each screenshot for: padding/spacing symmetry, alignment of sibling elements, clipping or
overflow, visual hierarchy, and whether state transitions (expand, error, loading) degrade the
layout. See `ticket-driven-testing/references/phase-6-understanding.md` (6e) for the full checklist.

Report design findings in the tracker comment alongside the AC results; they are not AC failures,
but they are findings. A QA comment that shows a screenshot with visible padding issues and doesn't
mention them is incomplete.

When the run is wrapped by `ticket-driven-testing`, phase 8b (`ticket-driven-testing/references/phase-8b-adversarial-review.md`) dispatches `probe-visual`, a subagent
that reviews every evidence screenshot against this checklist. The gate enforces it: sign-off is
denied without `uiReviewed: true` in the adversarial verification receipt.

## Posting to the tracker

When the evidence run is tied to a ticket (the user named an issue key, or the task maps to one),
post a **brief** comment to the tracker with inline screenshots. Follow the format in
`ticket-driven-testing/references/reporting.md` §"Posting to the tracker":

1. **What was tested**: one or two sentences per AC.
2. **Evidence**: screenshots uploaded and embedded inline as markdown images (not as separate
   attachments). Use the tracker's upload API, then reference the `assetUrl` in the comment body.
3. **Negative control**: one or two sentences: was the suite run without the fix, and did the
   right tests fail? If not run, say so.
4. **Verdict**: the QA outcome and recommendation: ready to merge, needs fixes, or blocked.
   Caveats as one-liners.

That is the entire comment. No tables, no code review, no methodology beyond the negative control.
The screenshots carry the detail.

## Next-step offer matrix

The offer is **automation-first**. Failure-diagnosis remains the path on a failed run, but the durable-automation question is asked on every verdict where it makes sense.

### Verdict: PASSED

| Setup state | Offer (verbatim shape) |
|---|---|
| **None** (fully onboarded) | *"This task is now captured as evidence. Want me to **automate it into the durable suite**? I'll hand the task description, pass criterion, and selectors to `achilles-protocol` Stage 3 and let it author the durable test properly. (yes / no)"* |
| **A / B / C** (not onboarded or partially onboarded) | *"This task is now captured as evidence, but this project isn't fully set up for automation yet (Level <A/B/C>: <summary>). Want me to **automate this task**? Two ways forward — pick one: (a) **Just this task** — install the framework, scaffold the minimum needed, and add this single task as a durable test; (b) **Full onboarding** — run the autonomous `onboarding` pipeline (scaffold → happy path → journey mapping → coverage expansion → bug hunts → secrets sweep → summary deck). Or `no` to leave it as evidence-only."* |

### Verdict: FAILED

| Setup state | Offer (verbatim shape) |
|---|---|
| **Any** | *"Want me to hand off to `failure-diagnosis` to classify this as a test issue or an app bug? Once that's resolved, I can come back to the automation question."* The automation offer is **deferred** until the failure is diagnosed: it would be wrong to graduate a failing run into a durable test, and equally wrong to start onboarding off a flow that isn't actually working. If `failure-diagnosis` concludes the root cause is an **app bug** (not a test issue), companion mode offers a follow-on: *"Want me to file a bug ticket using `bug-report`? The evidence bundle is ready to attach."* |

### Verdict: INCONCLUSIVE

| Setup state | Offer (verbatim shape) |
|---|---|
| **Any** | *"Want me to retry the run, or are the captured artifacts enough for you to decide?"* No automation offer until the verdict resolves to passed or failed. |

## Acting on the user's answer

**Passed × None × "yes":**
1. Invoke `achilles-protocol` with the documented Phase-6-graduation autonomous-mode args from the orchestrator's autonomous-mode cheat-sheet: `autonomousMode: true, entry: "stage3", bundlePath: "<absolute-path-to-bundle>"`. The bundle's `summary.md` holds the verbatim task description, pass criterion, and app URL; the bundle's `spec.ts` holds the already-discovered selectors. The orchestrator reads these from the bundle; companion-mode does not paste them into args.
2. The orchestrator enters at Stage 3 (writing the durable spec), runs Stage-4 API compliance review, and commits with a message that references the bundle path ("graduated from companion-mode bundle: `<path>`").
3. The bundle stays in `tests/e2e/evidence/` as the audit trail.

**Passed × A/B/C × "(a) just this task":**
1. Run the cascade detector's remediation steps for the matching level: installation (Level A), scaffolding (Level B), or scaffold check (Level C), but **scoped to the minimum needed** to host one durable test. Do not run the full onboarding pipeline.
2. Specifically: at Level A install `@civitas-cerebrum/element-interactions` and `@civitas-cerebrum/element-repository` per the README, write a minimal `playwright.config.ts`, `tests/fixtures/base.ts`, and `page-repository.json`, then proceed. At Level B, write the missing scaffold files. At Level C, no scaffolding is needed: the durable test can land without `journey-map.md` for a single-task graduation; the journey map is required by `coverage-expansion`/`test-composer`, not by Stage 3.
3. After the minimum scaffold is in place, invoke `achilles-protocol` with the same Phase-6-graduation args as the fully-onboarded case: `autonomousMode: true, entry: "stage3", bundlePath: "<absolute-path>"`. The orchestrator reads the task description, pass criterion, app URL, and selectors from the bundle.
4. Do **not** silently expand "just this task" into a full onboarding run. The user picked the narrow path explicitly.

**Passed × A/B/C × "(b) full onboarding":**
1. Invoke `onboarding`. Pass the task description and pass criterion as the `happyPathDescription` so the onboarding pipeline starts from the verified flow rather than re-discovering it.
2. Pass the bundle path so onboarding can reference the evidence bundle in its onboarding-report.md ("happy path verified in advance via companion-mode bundle: `<path>`").
3. The bundle stays in place as the pre-onboarding audit trail.

**Failed × `failure-diagnosis` accepted × diagnosis = app bug × "yes" (file ticket):**
1. Invoke `bug-report`. Pass the following inputs extracted from the bundle:
   - **Evidence files**: all files in `<bundle>/screenshots/`, `<bundle>/video.webm`, `<bundle>/console.log`, listed verbatim as attachments.
   - **Steps to reproduce**: the numbered step list under `## What I did` in `summary.md`.
   - **Actual result**: the failure assertion message from the Playwright run output (quoted verbatim).
   - **Environment**: the App URL from Phase 1.
   - **Pass criterion** (as the Expected result): copied verbatim from `summary.md`.
2. Companion mode does NOT pre-fill Severity or Priority: `bug-report` follows its own engine and asks the user to confirm those fields.
3. The bundle stays in place as the evidence source. Companion mode does not modify it.
4. After `bug-report` completes, the automation question is re-offered once the underlying app bug is resolved; companion mode does NOT automatically re-run or re-offer now.

**Failed × `failure-diagnosis` accepted × diagnosis = test issue:**
- The automation offer remains deferred. The user should fix the test issue (via `test-repair` if needed), then re-run companion mode to produce a fresh bundle.

**"no" or no response:**
- Leave the bundle in place. Do not delete, do not modify, do not retry.
- End the session.

## Mid-pipeline advisory

If the Phase-6 setup detection found `tests/e2e/docs/coverage-expansion-state.json` (a `coverage-expansion` resume marker), append one extra line to the Phase-6 report **regardless of verdict or setup level**:

> *"Detected an in-flight `coverage-expansion` run (state file present at `tests/e2e/docs/coverage-expansion-state.json`). Graduating this task is fine — it lands as a regular Stage-3 commit and does not interfere with the resume. Resume `coverage-expansion` separately when ready."*

The advisory does NOT alter the offer matrix, NOR does it block graduation. It is informational so the user knows their pending pipeline is still pending. Companion mode does not delete, modify, or otherwise interact with the state file.

## What companion mode does NOT decide

- It does NOT pick between "(a) just this task" and "(b) full onboarding" on the user's behalf. Even if onboarding seems "obviously better" for the project, the user picks. Inferring the answer is a contract violation.
- It does NOT hand off without an explicit "yes / (a) / (b)" from the user. A vague reply ("sure", "whatever") gets a clarifying re-prompt, not a guess.
- It does NOT chain handoffs. After dispatching to Stage 3, `onboarding`, or `bug-report`, companion mode is done; the receiving skill owns the rest. Do not "supervise" the durable run.
- It does NOT pre-fill Severity or Priority when handing off to `bug-report`. Those fields are confirmed by the user inside `bug-report`'s own engine.
- It does NOT invoke `bug-report` for a PASSED verdict. Bug filing is only offered when `failure-diagnosis` has confirmed an app bug on a FAILED run.
