---
name: companion-mode
description: >
  Use when a QA engineer needs ad-hoc functional verification of a specific task with rich
  evidence (per-step screenshots, video, trace, HAR, console) — not a durable suite test, not a
  full coverage pass, not bug-hunting. Triggers on "companion mode", "companion entry mode",
  "QA companion", "verify this flow with evidence", "evidence package for X", "screenshot every
  step", "record this scenario", "video of this flow", "evidence-backed test", "daily QA task",
  "manual test assistance", "help me check that <feature> still works", "show me proof that X
  works", "capture screenshots while you do this", "run a quick verification with proof". Use
  for single-task functional verification with evidence output. Do NOT use to grow a durable
  test suite (that is Stages 1-4 of `achilles-protocol`), to expand coverage iteratively
  (that is `coverage-expansion`), to compose a journey portfolio (that is `test-composer`), to
  hunt bugs adversarially (that is `bug-discovery`), to repair a rotted suite (that is
  `test-repair`), or to diagnose a single failing test (that is `failure-diagnosis`).
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session. Skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Companion Mode — Evidence-First Single-Task Verification

> **Skill names: see `../achilles-protocol/references/skill-registry.md`.** Copy skill names from the registry verbatim. Never reconstruct a skill name from memory or recase it.

A daily QA-companion entry mode: take one focused functional verification task, run it against the live app, and produce a complete evidence bundle (per-step screenshots, video, Playwright trace, HAR, console log, summary) the QA engineer can hand to a developer, attach to a ticket, or hold next to a manual checklist. Optimized for low-friction entry: no `journey-map.md` required, no committed spec required, no five-pass pipeline.

**Core principle:** the deliverable is **the evidence bundle**, not the test code. The test code is the means; the bundle is the artifact a human reads. Every output decision serves the engineer who will open the bundle, not the agent that produced it.

---

## When This Skill Activates

This skill is **opt-in only**. It activates when the user asks for evidence-first single-task verification, not during routine test authoring or coverage work.

| Context | When it activates |
|---|---|
| **Ad-hoc verification** | "Verify the checkout flow works on staging and show me proof" |
| **Evidence package** | "Capture evidence that the password reset still works end-to-end" |
| **Manual-test assist** | "Help me document this manual test step by step with screenshots" |
| **Smoke + record** | "Run a quick smoke on the login page and record it" |
| **Stakeholder demo** | "I need a video of the new dashboard flow to attach to the release ticket" |

It does NOT activate from:

- "Write a test for the checkout flow" → that is `achilles-protocol` Stages 1–4.
- "Cover this journey" → `test-composer`.
- "Increase coverage" → `coverage-expansion`.
- "Find bugs in this app" → `bug-discovery`.
- "Why is this test failing?" → `failure-diagnosis`.
- "The whole suite is broken" → `test-repair`.
- "Generate a QA report from past work" → `work-summary-deck`.

If the user's intent is durable test growth, route them to the right skill; do NOT silently expand companion mode into a coverage pass.

---

## Distinctions from neighbouring skills

| Skill | Scope | Output | Persistence |
|---|---|---|---|
| `achilles-protocol` Stage 3 | One scenario, durable | `tests/<spec>.spec.ts` | Committed to suite |
| `onboarding` | Whole app from zero | Install + scaffold + happy path + journey map + 5 coverage passes + 2 bug hunts + secrets sweep + summary deck | Fully committed pipeline |
| `test-composer` | One journey, full variant set | Many spec files for that journey | Committed |
| `coverage-expansion` | Whole app, iterative | Suite-wide growth across passes | Committed |
| `bug-discovery` | Adversarial probing | Findings + reproduction tests | Findings ledger |
| `failure-diagnosis` | One failing test | Diagnosis + fix or app-bug report | Test repaired or bug filed |
| `test-repair` | A rotted suite | Cluster-by-cluster repair to restore green | Suite-wide commits |
| `ticket-driven-testing` | One tracker ticket + its dev branch | Ticket brief + diff review + evidence bundle + durable tests + sentinels | Bundle, suite commits, defect reports |
| `companion-mode` (this) | **One functional task** | **Evidence bundle** | Bundle on disk; spec optional via Phase-6 graduation |

**Ticket-shaped work:** when the unit of work is a tracker ticket with a dev branch awaiting QA sign-off (rather than a free-standing "verify X" request), start from `ticket-driven-testing` instead. It owns ticket intake, PR review-state checks, worktree isolation and diff review, then invokes this skill for the evidence run, then continues into durable regression tests and defect sentinels. Companion mode's Phase 1 assumes the app URL, credentials and pass criterion are already known; `ticket-driven-testing` is what establishes them from the ticket and the diff.

The signal that distinguishes companion mode from Stage-3 single-scenario authoring: **the user wants an artifact a human will open** (screenshots/video/PDF), not a spec they will check in. If the user wants both, run companion mode first to produce the bundle, then offer to graduate the test into the suite.

---

## Prerequisites

- **`@playwright/cli`**: needed for live discovery of the page when the user provides only a URL or a vague task. Ships as a hard dependency of `@civitas-cerebrum/achilles`, so it is always reachable via `npx playwright-cli` after `npm install`. The first `... open` call may need a one-shot browser fetch (`npx playwright-cli install-browser chromium`) on a fresh machine. If the live app is unreachable from this environment, the user must supply a complete step list and any required selectors. See [`../achilles-protocol/references/playwright-cli-protocol.md`](../achilles-protocol/references/playwright-cli-protocol.md).
- **App URL + task**: one URL or pre-authenticated state, one one-sentence task description. Credentials if the flow requires login. No `journey-map.md` needed.
- **`page-repository.json`**: used opportunistically. If the page exists in the repo, reuse the entries; if not, propose new ones inline (gated like Stage 2 unless `autonomousMode: true`).
- **Write access to `tests/e2e/evidence/`**: the bundle output directory. Created on first use.

---

## Phase Structure

```
Phase 1: Task Intake          ─── one-sentence task, URL, optional creds
Phase 2: Quick Discovery      ─── single-page playwright-cli snapshot, scoped to the task
Phase 3: Compose Evidence Test─── Steps API + per-step screenshots + tracing on
Phase 4: Run with Capture     ─── execute with video, trace, HAR, console, screenshots
Phase 5: Bundle               ─── write tests/e2e/evidence/<slug>-<ts>/
Phase 6: Report               ─── summary message with bundle path + pass/fail
```

**Hard gates:**
- 2 requires 1
- 3 requires 2 (cannot compose without knowing the page surface)
- 4 requires 3 (cannot capture evidence on a non-existent test)
- 5 requires 4 (the bundle assembles real artifacts, not placeholders)
- 6 requires 5

You MUST create a task per phase via TaskCreate and complete in order. Do not skip Phase 5 even if Phase 4 fails: a failure bundle is still the deliverable.

---

## Phase 1: Task Intake

Capture, in this order:

1. **Task description**: a single sentence stating the *what*: "Verify a returning user can log in and see their dashboard." If the user gave a paragraph, compress it; if they gave one word, ask for one clarifying sentence.
2. **App URL**: the entry point. If absent, ask for it; do NOT guess from `playwright.config.ts` baseURL; companion mode is environment-explicit.
3. **Credentials / state** (optional): if the task requires auth, ask for credentials or a path to a saved auth state. Never invent credentials.
3b. **Build identifier** (optional): a user-supplied app build/version id for the bundle's `summary.md` `**App build:**` line. If not supplied, the line reads `not supplied`; do not infer one.
4. **Pass criterion**: one sentence: "what does success look like to you?" The bundle's pass/fail verdict is grounded in this answer, not the agent's interpretation.
5. **Bundle slug**: a short kebab-case slug derived from the task (e.g. `checkout-happy-path`). The user may override.

If `autonomousMode: true` is in args, intake fields must arrive in args; do not prompt.

Write all five inputs to a Phase-1 record before advancing; they appear verbatim in the bundle's `summary.md`.

---

## Phase 2: Quick Discovery

Use `@playwright/cli` to take **one snapshot of each page the task touches**. Goal: enough surface knowledge to compose a stable test, not exhaustive mapping.

1. Open a dedicated session: `npx playwright-cli -s=companion-<bundle-slug> open --browser=chromium <entry-URL>`
2. Take a snapshot: `npx playwright-cli -s=companion-<bundle-slug> snapshot` → record the visible elements relevant to the task.
3. If the task spans multiple pages, walk the happiest path through the task once and snapshot each page (`-s=companion-<bundle-slug> goto <URL>` followed by `... snapshot`).
4. **Do NOT explore unrelated pages.** Companion mode is task-scoped. If the user asked to verify checkout, do not snapshot the admin panel.
5. **Do NOT update `app-context.md`.** This is intentional: companion-mode runs are ephemeral evidence sessions, not contributions to the durable knowledge base. Stages 1–4 and `test-composer` own that file.
6. Close the session at the end of Phase 2 (composing & running in Phases 3–4 use the spec runner, not the live CLI session): `npx playwright-cli -s=companion-<bundle-slug> close`.

If `@playwright/cli` is unavailable **at the start of Phase 2**, ask the user for either (a) the selectors needed for each step, or (b) a screenshot of the page so you can derive selectors. Do not proceed without one.

If the CLI **fails mid-walk** (succeeded on page 1, fails on page 2), fall back to (a)/(b) for the remaining pages: do not retry indefinitely, and do not abandon the partial discovery. The pages already snapshotted stay in the discovery output; the unreached pages get a one-line note in `summary.md` §Notes ("Discovery for `<PageName>` was completed via user-provided selectors after `playwright-cli` failure mid-walk.").

Output: a per-page list of the elements you'll touch in Phase 3.

## Phases 3 to 6

| Phase | Read |
|---|---|
| 3 Compose the evidence test, 4 Run with capture | [phases-3-4-compose-and-capture.md](references/phases-3-4-compose-and-capture.md) |
| 5 Bundle layout and `summary.md` | [bundle-and-summary.md](references/bundle-and-summary.md) |
| 6 Report, next-step offers, handoffs | [phase-6-report-and-offers.md](references/phase-6-report-and-offers.md) |
| Directory boundaries, minimum-scaffold writes, graduation paths, cross-skill summary | [graduation-and-boundaries.md](references/graduation-and-boundaries.md) |
| Autonomous-mode args | [autonomous-mode.md](references/autonomous-mode.md) |
| Rationalizations to refuse | [rationalizations.md](references/rationalizations.md) |
| Activation flowchart | [activation-flowchart.md](references/activation-flowchart.md) |

## Phase 5: Bundle

Write the bundle to `tests/e2e/evidence/<slug>-<YYYYMMDD-HHMMSS>/`: `summary.md`, `spec.ts`, `screenshots/`, `video.webm`, `trace.zip`, `network.har`, `console.log`, `run-output/`. Layout, `summary.md` sections and verdict definitions: [bundle-and-summary.md](references/bundle-and-summary.md).

### Redaction (mandatory — scoped to the artifact, not to the bundle)

**Any captured `network.har` or `console.log` gets a redaction pass
before anything else happens to it, whether or not a bundle is being
assembled around it.** The pass is owned by whoever captured the file.
A HAR written during an ad-hoc check, a one-off `recordHar` while
debugging, a console dump pasted into a scratch directory: same rule,
same moment. The rule is scoped to the artifact because a capture taken
outside any bundle never enters the bundle contract.

The pass: grep `console.log` and `network.har` for the four
`secrets-sweep` literal classes: credentials, API keys, PII shapes, and
tokens in `Authorization` / `Set-Cookie` headers, plus any
`*-bypass` / `*-token` / `*-key` request header, and redact matches in
place. Redact HARs **by header name across every entry**, not by
searching for the value you happen to know: one credential appears in
the headers of every request in the file, and hundreds of copies means
one missed occurrence is the default outcome of a value-based sweep.
Stripping response bodies at the same time shrinks the file by roughly
20×.

When a bundle is being assembled, run this before Phase 5 freezes it
(and before Rule 11's immutability kicks in), and record every
redaction in `summary.md` under a `## Redactions` section: what was
redacted and where, named, not silent, consistent with the
no-fabrication rule. When there is no bundle, record it wherever the
artifact's provenance is recorded. Evidence bundles are NOT swept by
onboarding Phase 7's `secrets-sweep`; this step is their only redaction
pass.

**Partially harness-enforced by
[`hooks/evidence-bundle-gate.sh`](../../hooks/evidence-bundle-gate.sh).**
It DENIES QA sign-off (on every gated surface, comments included) while
a matched bundle's `*.har` or `console.log` still carries a live value
under a credential-bearing field name, at the bundle root or one level
into it. Unlike a missing bundle, an unredacted credential has no
legitimate outcome, so that branch is not graded.

Three limits, because a rule that overstates its backstop is worse than
one with none. The gate **follows the bundle**: a capture it cannot
find is unscanned, which is exactly why the rule above is scoped to the
artifact and not to the gate's reach. Its detection is **name-and-shape
based** (field names against a fixed vocabulary; HAR bodies for
`access_token`-shaped assignments), so a credential in a field named
nothing like one is not found. And it fires **at sign-off**, hundreds of
tool calls after the capture. It is a last-boundary backstop. You own
the pass.

## Modes

| Mode | Behaviour |
|---|---|
| `mode: live` (default) | Run the test against the live app and produce the full bundle (Phases 1–6). |
| `mode: dry-run` | Phases 1–3 only; emit the spec and a stub `summary.md` marked `Verdict: NOT RUN`. Used when the user wants to review the test before executing (e.g. against production). |
| `mode: existing` | Skip Phase 3; user names an existing spec, companion mode wraps it with the Phase-4 capture flags and produces a bundle. Used to retrofit evidence onto a spec that already lives in the suite. |

`mode: existing` does not modify the wrapped spec. It runs it as-is with the capture flags.

## Hard rules

These override convenience and apply to every invocation.

1. **The bundle is the deliverable.** A run that produces a passing test but no bundle is a failure of the skill, not a success. Phase 5 is mandatory.
2. **The Phase-6 transition to durable automation requires an explicit `yes / (a) / (b)`.** A vague reply ("sure", "ok", "whatever") gets a clarifying re-prompt, never a guess. Re-prompt at most twice; on a third vague reply, treat the answer as `no` and end the session. (Rule 10 owns the "offer is mandatory" half; Rule 2 owns "what counts as an answer to it.")
3. **Do NOT invoke other companions inline before Phase 6.** Phases 1–5 of companion mode do not chain into `coverage-expansion`, `test-composer`, `bug-discovery`, `failure-diagnosis`, `test-repair`, or `onboarding`. The Phase-6 offer is the *only* handoff path, and even there the handoff requires the user's explicit answer.
4. **Do NOT compress scope by skipping captures.** If video failed to record, that goes in the `Capture gaps` section: the answer is never "drop the video flag to make the run faster." All capture forms are part of the contract.
5. **No raw selectors in the spec.** Same rule as Stage 3. Bundle specs are still proper Steps API tests, not throw-away `page.locator(...)` snippets.
6. **No edits to durable knowledge files during Phases 1–5.** `journey-map.md`, `app-context.md`, `adversarial-findings.md`, the project's `playwright.config.ts`, and the project's `package.json` are read-only during companion mode's own phases. They become writable **only** during Phase 6, and only along these paths:
   - **Receiving-skill writes (most cases):** `achilles-protocol` Stage 3 or `onboarding` performs the writes. Companion mode does not touch these files itself.
   - **Companion-mode minimum-scaffold writes (one carve-out):** when the user picks `(a) just this task` and the cascade detector returned Level A or B, companion mode itself performs the install and minimum scaffold per §"Phase-6 minimum-scaffold writes". This is the **only** case where companion mode writes outside the evidence directory, and it is bounded to exactly the files listed in that section. Anything beyond that table (touching `journey-map.md`, `adversarial-findings.md`, regenerating `app-context.md`, editing committed test specs) is a contract violation regardless of phase.
7. **No data exfiltration of evidence.** Bundles can contain credentials in screenshots, HAR responses, console logs. Do NOT post bundle contents to chat platforms, gists, or external services unless the user has explicitly authorised both the artifact and the destination. Same constraint applies in autonomous mode: the caller's authorisation is for the run, not the upload.
8. **Timestamp the slug.** Two runs of the same task on the same day must NOT clobber each other. The `<slug>-<YYYYMMDD-HHMMSS>` directory shape is fixed. If a directory at that exact path already exists at the moment of bundle write (rare, but possible under same-second concurrent invocations), append `-<n>` starting from `-2` and try again. Never overwrite an existing bundle.
9. **Do NOT silently expand "just this task" into full onboarding.** When the user picks option (a) at the Phase-6 offer, the cascade-detector remediation runs scoped to the minimum needed to host one durable test (install at Level A; missing scaffold files at Level B; nothing at Level C). Running the full `onboarding` pipeline because "the project would benefit from it" is a contract violation. The user explicitly chose the narrow path.
10. **Do NOT skip the Phase-6 automation offer when the verdict is PASSED.** Even if the project is not onboarded and the user "probably just wants the evidence," the offer is still printed. The user can decline, but they cannot be deprived of the choice. The only verdicts that suppress the automation offer are FAILED (deferred until `failure-diagnosis` resolves it) and INCONCLUSIVE (deferred until verdict resolves).
11. **The bundle is immutable post-Phase-5.** Once Phase 5 has assembled the bundle, the directory at `tests/e2e/evidence/<slug>-<ts>/` is read-only for the rest of the session and for every future session. Companion mode does not move it, copy it, modify any file inside it (including `summary.md`), or delete it, even on a Phase-6 graduation. The receiving skill (Stage 3 or `onboarding`) **reads** from the bundle but writes the durable spec to `tests/<name>.spec.ts`, never inside the bundle directory. If a future companion-mode run for the same task is needed, it gets its own timestamped bundle per Rule 8; old bundles are never overwritten.

## Exit gate — compliance sweep

**Exit gate: the compliance sweep is not optional.** This mode writes test code, so it runs the Stage-4b compliance sweep over every spec it touched before it returns, and announces it with the documented **API Compliance Review** block. That sweep is where API misuse, tautological assertions, missing test IDs and untagged intentional reds get caught. Harness-enforced at stop time by `hooks/compliance-sweep-exit-gate.sh`; the rule and the per-mode table live in [`stages-protocol.md`](../achilles-protocol/references/stages-protocol.md) §"Stage 4b is every mode's exit gate".

An evidence bundle is not test code and needs no sweep; the moment a bundle graduates into a durable spec, it does.
