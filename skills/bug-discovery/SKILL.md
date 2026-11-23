---
name: bug-discovery
description: >
  Adversarial probing of a live (or, in static mode, inferred) application
  for one journey, page set, or the whole app, loaded by an `author`
  dispatch. Triggers: "find bugs", "break the app", "bug hunt", "quality
  audit", "edge case testing", "exploratory testing", "find issues", and the
  adversarial passes 4–5 of coverage expansion (per journey, with a
  negative-case matrix). Not for writing initial tests (author-scenario),
  expanding coverage (test-composer per journey, expand-coverage across the
  app), evidence runs (evidence-capture), or load testing ("stress test the
  app" here means malformed input and state corruption, not throughput).
---

# Bug discovery

Probe the live app **before** reading any context: the first-time effect catches what familiarity hides. Context is used afterwards to filter, classify and derive more findings.

Think like a QA engineer: the starting question for every page or journey is "what would a QA engineer assigned to this feature write tests for, including the negative complement of every positive expectation?". Bug-hunting categories (race conditions, cross-feature, cumulative state) extend above that floor.

## Scope from the brief

| Scope | Input | Matrix |
|---|---|---|
| Journey (coverage pass 4 or 5) | the journey block, repository slice, pass number, ledger and lockfile paths, the app-wide pattern catalogue, and a **negative-case matrix** | supplied; every entry must be probed; open-ended categories extend above it ([`references/adversarial-probe-contract.md`](references/adversarial-probe-contract.md)) |
| Journey or page set (hunt-bugs) | the journey block or page list, the session charter budget, focus ids | derive it yourself: for every positive flow you observe, at least one negative complement (missing field, malformed input, unauthorised access, replay, session boundary) before moving on |

Risk tags arrive in the brief (never by reading the map during phase 1); `elevated` journeys get the higher end of the probe budget. Phase selector: `full` (default), `1a-element-probing`, `1b-flow-probing` (needs 1a's findings). Mode: `live` (default) or `static` ([`references/static-mode.md`](references/static-mode.md): every finding `inferred: true`).

The reviewer that follows you will cross-reference the matrix against your ledger entries (`matrix-missed`), attempt probes you did not (`adversarial-missed`), check every ledger line's shape, and in pass 5 check that each regression test locks its boundary rather than a surrogate. Cover every matrix entry on cycle 1.

## Prerequisites

A green suite (otherwise return `blocked: suite-red`); `page-repository.json` populated; `playwright-cli` reachable; `app-context.md` present (phases 2 and 4 are limited without it; say so).

## Session charter

Write it before probing so the run terminates on diminishing returns and phase 7 can say what was not probed:

```
Mission:       app-wide | journey: j-<slug> | page-set: <…>
Probe budget:  default 30 probes, or 8 elements × all categories per page, 3 flow variations per flow (the brief may override)
Stop rules:    close a category after 8 consecutive probes with no new anomaly;
               close a page when every category is closed or its budget is hit;
               close the session when every in-mission page is closed or the budget is hit.
```

The return carries `budget consumed: <n>/<budget> probes, <closed>/<total> categories closed`.

## Phases

| Phase | Read |
|---|---|
| 1a element probing, 1b flow probing (live app, no context), 2 context cross-reference, 3 test cross-reference, 4 context-derived analysis | [`references/phases-1-4-probing-and-analysis.md`](references/phases-1-4-probing-and-analysis.md) |
| 5 classification and prioritisation | [`references/phase-5-classification.md`](references/phase-5-classification.md) |
| 6 reproduction tests | [`references/phase-6-reproduction.md`](references/phase-6-reproduction.md) |
| 7 report and triage lifecycle | [`references/phase-7-report-and-triage.md`](references/phase-7-report-and-triage.md) |
| App-wide pattern scan (the pass-4 prelude) | [`references/app-wide-scan.md`](references/app-wide-scan.md) |

Gates: 1b needs 1a; 2 needs 1a + 1b; 3 and 4 need 2 (and may run together); 5 needs 2–4; 6 needs 5; 7 needs 6. Work them in order.

Assertion strategy for reproduction tests: assert the **correct** behaviour, so the test fails against the bug today and turns green, unmodified, when it is fixed. Never lock buggy behaviour; never `test.fail()` (the one sanctioned use is a ticketed sentinel in the verify-change workflow). Every reproduction spec gets the Stage 4b compliance sweep and the judge review before the report cites it.

## Platform targets (iOS, Android)

On a native app, load [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md); probing runs in your own `wdio session` per the [platform inspection protocol](../achilles-orchestrator/references/platform-inspection-protocol.md), closed before you return, and every probe states the device, OS version and real or virtual. The web categories (input tamper, state skip, auth tamper) still apply. A device adds three probe families that have no web equivalent; for each in-scope flow, probe every member that applies and record the ones that do not, with the reason, in the charter.

**Interruptions and lifecycle.** Interrupt the flow at its riskiest step (mid-form, mid-payment, mid-upload) and assert that its state survives or recovers with a clear message:

- background and resume (`backgroundApp` for a few seconds, and long enough for the OS to reclaim memory where the device allows);
- lock and unlock the device mid-flow;
- an incoming notification (the app's own push or another app's) pulled down or tapped;
- low and lost connectivity, then recovery (airplane mode or the network profile the server offers), checking for duplicate submissions on reconnect;
- kill and relaunch mid-flow (`terminateApp`, then `launchApp`), checking drafts, half-finished orders and the login state.

[`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Interruptions and lifecycle".

**Device capabilities**, where the app uses them: biometrics (enrolled, not enrolled, failed match, cancelled), camera (granted, denied, no camera), location (granted, denied, changed mid-flow, approximate only), push (enabled, disabled at OS level), the clipboard (paste into fields, sensitive values copied out) and the share sheet (share out, cancelled, receiving shared content). [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Device capabilities".

**Permission prompt branches.** Every prompt the flow raises is probed with allow, deny and the deferred answer ("Allow once", "Ask next time", dismissed), plus revoking the permission in the middle of a flow that needs it. The deny branch must show the app's fallback (an explanation, a disabled feature, a link to settings); a crash, a blank screen or a silent no-op is a finding. Arrange a known state with `setPermission`, raise a prompt again with a reinstall or a permission reset, and never auto-accept. [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Permissions and system alerts".

Probes that change device state (lock, connectivity, permissions) happen only on a device the brief assigns for it; every probe restores the state it changed before the session closes. Reproduction tests for these findings go under `tests/platform/` and follow [`../test-composer/SKILL.md`](../test-composer/SKILL.md) §"Platform targets (iOS, Android)".

## Findings and ledger

Every finding uses the canonical block (`- **<FINDING-ID>** [<severity>] — <title>` with `scope` / `expected` / `observed` / `coverage`) from [`finding-and-ledger-schema.md`](../achilles-orchestrator/references/finding-and-ledger-schema.md) §1: ids `<journey-slug>-<pass>-<nn>` inside a pass, `<journey-slug>-<nn>` standalone; severities `critical | high | medium | low | info` ("No impact (DOM-only)" in phase 5 is the report label for `info`); every finding above `info` cites captured evidence. Ledger appends to `tests/e2e/docs/adversarial-findings.md` follow §3 of that file and are validated in memory before the lockfile is released. Probe-category vocabulary: §3.6 (`auth-tamper`, `input-tamper`, `state-skip`, `idor`, `race`, `boundary-values`, `compound`, …).

Patterns already in `tests/e2e/docs/app-wide-patterns.md` are cited as `coverage: app-wide:<pattern-id>`, not re-derived.

## Return

Probe schema (`schemas/subagent-returns/probe.schema.json`), envelope first: `status` ∈ `findings-emitted | clean | blocked`; `journey`, `pass`, `findings-emitted`, `finding-ids`, `probes`, `boundaries`, `probe_categories`, `tests-added`, `stabilization`, the charter line, `spill` (full finding blocks at `tests/e2e/docs/.subagent-returns/probe-<journey-slug>-<pass>-c<cycle>.md`, sentinel `<!-- subagent-returns:probe:<slug>:pass-<pass>:cycle-<cycle> -->`), `summary`. No transcripts, no DOM snapshots, no test source in the return.

Commits are the orchestrator's: `docs(bug-hunt): j-<slug> — N findings` standalone, the pass rows inside coverage expansion ([commit-conventions.md](../achilles-orchestrator/references/commit-conventions.md)).
