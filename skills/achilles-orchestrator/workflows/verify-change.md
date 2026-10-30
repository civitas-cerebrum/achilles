# Workflow: verify-change

A code change is the unit of QA work: a ticket paired to a PR, a branch awaiting sign-off, or a developer who just finished building something. The run produces verified evidence, durable regression tests, a sentinel test per confirmed defect, and a negative-control result. Phase references live under [`../references/verify-change/`](../references/verify-change/).

Core principle: the diff says where to look and what is risky; the live app says what to assert. A test written from the diff binds to one branch's implementation; a test written from observed behaviour survives it.

## Two entry points, one method

| | A: ticket-driven | B: dev-triggered |
|---|---|---|
| Trigger | a tracker issue, a PR awaiting sign-off | "I've finished this, can you test it" |
| 1 | ticket + parent → acceptance criteria verbatim | the change set → criteria derived and confirmed through `NEEDS_CONTEXT` ([entry-b](../references/verify-change/entry-b-dev-triggered.md)) |
| 2 | PR review state is a QA signal | skipped when no PR exists; say so |
| 3 | worktree the branch | uncommitted work is not in a worktree: run against the dev's tree and say so |
| 5 | deployed preview, bypass tokens | the dev's local server |
| 8 | negative control: an environment without the fix | the merge-base: the strongest form and nearly free |

Every ticket gets its own run of steps 1–9; a second ticket in the same session re-enters at step 1 and gets its own bundle, named for its key.

## Prerequisites

A reachable app; a Playwright project with installed browsers; `git` worktree support; a tracker or pasted criteria; a second environment without the fix (or the merge-base); `E2E_MUTATION_CSS`/`E2E_MUTATION_INIT` hooks in the page fixture for the mutation probe, or source-level mutation when the app runs locally. Missing items are one `NEEDS_CONTEXT`; a run without a negative control is reported as unverified, never as regression cover.

Cost: one three-criteria ticket is roughly six full suite runs and five or more dispatches; budget it or scope step 8b to the criteria that matter, and say which.

## Steps

1. **Intake** ([intake-and-isolation](../references/verify-change/intake-and-isolation.md)): read the ticket and its parent; criteria verbatim; branch; PR; write the ticket brief `docs/evidence/<ticket>/brief.md`. You read a tracker only through what your own tools reach (`gh issue view`, `gh pr view`); for any other tracker the ticket and parent text arrive in the delegation's context, else one `NEEDS_CONTEXT` asks for them.
2. **PR review state**: unresolved `CHANGES_REQUESTED` is itself a finding.
3. **Worktree** the branch; never switch a shared checkout.
4. **Diff review** (inspector, read-only: `git diff`, the changed source, config): findings ranked by severity, each a sentinel candidate; where to look, not what to assert.
5. **Environment**: preview auth, bypass tokens; record them for redaction.
6. **Build understanding by interacting** ([phase-6-understanding](../references/verify-change/phase-6-understanding.md)): an inspector drives the flow (`companion-<key>` session), observes sequence and timing, derives cases, evaluates what is undesirable, and returns the observed behaviour that becomes the assertions.
7. **Durable tests + sentinels** ([phase-7-durable-tests](../references/verify-change/phase-7-durable-tests.md)): an author writes one test per criterion plus a `test.fail()` sentinel per confirmed defect (the one sanctioned `test.fail()` use: ticketed, removed when fixed, tagged `@known-defect`), then runs the evidence capture of [`../../evidence-capture/SKILL.md`](../../evidence-capture/SKILL.md) against the branch to produce the ticket's bundle.
8. **Negative control** ([phase-8-negative-control](../references/verify-change/phase-8-negative-control.md)): you create the without-fix worktree when the control is the merge-base (`git merge-base`, `git worktree add`); the same author runs the new suite where the fix is absent. It must fail there; read the result per test: a test that passes on both sides either covers pre-existing behaviour (fine) or does not discriminate the feature (worthless as criterion cover).
   - **8b Adversarial review** ([phase-8b](../references/verify-change/phase-8b-adversarial-review.md)): first an author runs the mutation set (`.achilles/mutations.mjs`, `npx achilles-mutate --calibrate`, then the run; every source-level mutation reverted) and writes the mutation report. Then six fresh reviewers (review skill, Mode 4), one mission each, attack the tests in parallel, scoped to the diff and the criteria:
     `probe-mutation` (for each criterion, does any test catch the one-line change that breaks it: judges the mutation report's survivors and voids),
     `probe-coverage` (which criterion clauses and diff hunks have no assertion pointing at them),
     `probe-assertions` (per assertion: structural guarantee or one passing render observed; test-data conformance),
     `probe-value` (per test: keep, merge or delete, with evidence),
     `probe-outcome` (per criterion: user-visible outcome asserted, or a proxy standing in for it),
     `probe-visual` (every evidence screenshot reviewed as a designer would).
     You do not self-assess. Must-fix findings go back to the author, then to a fresh reviewer for that probe.
   - **8c Score** ([phase-8c-8e](../references/verify-change/phase-8c-8e-scoring-and-commit.md)): one more reviewer (`probe-rigour`) scores the testing itself 0–3 on six axes with the blocking floor; a 0 anywhere or a total ≤ 12 blocks sign-off.
   - **8d Commit or discard**: CX/revenue impact proposes; the user confirms through `NEEDS_CONTEXT`; discard into the bundle is the default.
   - **8e Verify note** ([`verification-record.md`](../references/verification-record.md)): a reviewer that neither wrote nor reviewed the tests records stable = N greens in the reporter history + a can-fail proof per family in `docs/evidence/<ticket>/verify.md`.
9. **Report** ([reporting](../references/verify-change/reporting.md)): the compliance sweep over the tests that back the verdict, the brief tracker comment (what was tested, inline screenshots, negative-control result, verdict; drafted by a doc-writer, posted with `gh` for a GitHub issue or PR, otherwise carried in the hand-back for the main session to post), then one more reviewer (`probe-verdict`, Mode 4) attacks the claims in the report itself.

## The contract

Five deliverables per ticket: the ticket brief (`docs/evidence/<ticket>/brief.md`, written at intake); the diff review; the evidence bundle named for this ticket, redacted; verified tests (one per criterion, one sentinel per defect), committed or discarded per 8d; the negative-control result. The sign-off receipt `.achilles/adversarial-verification/<ticket>.json` records the reviewers' verdicts (`negativeControl`, `mutations`, `review { reviewer, uiReviewed, coverageSufficient, scores }`; shape in [phase-8b](../references/verify-change/phase-8b-adversarial-review.md) §"After the probes"). The orchestrator records it from the reviewers' reports, or the harness adapter does so on its behalf; no expert writes it, and it is never written by hand without the probes having run. It lives in the session checkout's `.achilles/`, not in the ticket's worktree. A harness with a sign-off hook refuses a ticket transition to done or a published PR without it and the bundle ([`docs/harness/claude-code.md`](../../../docs/harness/claude-code.md)).

No QA verdict before the negative control has run and its result is stated; no verdict for a ticket without its own bundle. An unevidenced run is labelled unevidenced. For entry B the sign-off boundary is opening the PR.

Reference files also in use: [style-interaction-verification](../references/verify-change/style-interaction-verification.md) (mock-DOM styling tests as a documented fallback), [traps-and-instruments](../references/verify-change/traps-and-instruments.md) ("show me" runs: headed, `slowMo` ≥ 1500 ms, serial, recorded; instrument controls; framework gaps).

## Hand-back

`DONE` with the verdict, the bundle path, the tests committed or discarded, the negative-control table (which tests failed without the fix), the 8c scores, and the tracker comment text when a tracker is wired. `DONE_WITH_CONCERNS` for defects found (each with its sentinel and evidence). `NEEDS_CONTEXT` for criteria confirmation (entry B), the commit-or-discard ruling, and any environment you cannot reach.
