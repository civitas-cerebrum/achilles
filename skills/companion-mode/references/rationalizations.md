# Common rationalizations to refuse

| Excuse | Reality |
|---|---|
| "The user just wants a quick test, I'll skip the bundle." | The bundle IS the deliverable. A test without a bundle is the wrong skill — that's Stage 3. |
| "Video recording is heavy, I'll drop it." | Capture forms are contractual. Drop a flag and you've shipped an incomplete bundle. |
| "I'll commit this evidence spec into `tests/` so it's reusable." | Bundle specs stay in the bundle directory. Durable suite tests are written by Stage 3 / `onboarding` after the user accepts the Phase-6 offer — not by copying the bundle file. |
| "The page-repo proposal is small, I'll write it without asking." | Rule 2 of the `achilles-protocol` orchestrator (page-repository approval gate) still applies during companion-mode Phases 1–5. Approval gate or `autonomousMode: true`, no third option. |
| "The run looked fine but the screenshots felt off — I'll mark it INCONCLUSIVE to be safe." | INCONCLUSIVE is reserved for runner-level uncertainty (crash, setup error, no assertion reached). A passed run with surprising observations is PASSED with a `Notes` entry — see §"Verdict definitions". Marking it INCONCLUSIVE silently suppresses the automation offer (Rule 10) and is a contract violation. |
| "The user gave a third vague reply — I'll just keep clarifying." | Rule 2 caps the re-prompt loop at twice. On the third vague reply, treat the answer as `no` and end the session. An unbounded loop is the rationalization, not the discipline. |
| "The run failed, let me hand off to `failure-diagnosis` and bring back a passing bundle." | Failure is a valid bundle. Ship it first. The Phase-6 offer is what triggers the failure-diagnosis handoff, not Phase 4. |
| "I'll update `app-context.md` while I'm here." | No. Companion-mode Phases 1–5 do not feed the durable knowledge base. (Phase-6 graduation may, but only via the receiving skill — never directly.) |
| "User asked for a verification test — I'll just do Stage 3 instead, evidence isn't really needed." | If the request named evidence/screenshots/video, the user wants companion mode. Do not silently downshift. |
| "Bundle directory clutters the repo; I'll write to /tmp." | Bundles live in the repo so the user can attach them to PRs and tickets. /tmp is wrong. |
| "The user just said 'cool', I'll take that as a yes to graduation." | Vague reply ≠ "yes / (a) / (b)". Re-prompt; never guess the answer. |
| "The project is partially onboarded — let me just run the full `onboarding` pipeline anyway, it's better." | The user's choice between (a) "just this task" and (b) "full onboarding" is theirs. Inferring (b) when they picked (a), or vice versa, is a contract violation. |
| "The verdict is passed and the project is fully onboarded — I'll graduate the test silently to save a round-trip." | The Phase-6 offer is mandatory even when graduation seems obvious. The user might have run companion mode specifically because they did NOT want a durable test (e.g. evidence for a one-off ticket). Always ask. |
| "The verdict is failed — I'll skip the offer entirely since automation can't happen yet." | Wrong shape. On failure, print the failure-diagnosis offer (the deferred-automation message), don't print nothing. The user needs to know automation is on hold pending diagnosis, not silently dropped. |
| "User declined graduation — let me leave a TODO in the bundle to retry next session." | No. A decline is a decline. Companion mode does not pre-stage the next session's offer. The user can re-invoke companion mode or `achilles-protocol` themselves if they change their mind. |
| "The run failed — I'll offer `bug-report` right away since the screenshots show an obvious app bug." | The `bug-report` offer only comes **after** `failure-diagnosis` confirms the root cause is an app bug. Skipping `failure-diagnosis` risks filing a ticket for what is actually a selector mismatch or test setup issue. |
| "I'll pre-fill Severity and Priority when handing off to `bug-report`." | Severity and Priority are confirmed by the user inside `bug-report`'s own engine. Companion mode passes evidence only — it does not shortcut `bug-report`'s confirmation step. |
