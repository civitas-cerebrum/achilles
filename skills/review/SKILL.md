---
name: review
description: >
  The one reviewer skill, loaded by every `reviewer` dispatch. Four modes
  selected by the brief: composition judge (Stage 4c: an independent, adversarial
  read of freshly composed specs against the scenario, the oracle ladder, the
  API reference and test-data feasibility), Stage B (the per-journey or batch
  reviewer inside coverage passes, compositional and adversarial), phase
  gate (the exit-criteria check between pipeline phases, passes and cycles,
  including the perf pipeline), and adversarial probe (the verify-change
  missions: the six §8b probes, `probe-rigour`, `probe-verdict`). Read-only: no
  spec writes, no ledger appends, no commits; the verdict and a spill file are
  the only outputs. A fresh dispatch per review; never the author, never a
  reused reviewer.
---

# Review

One reviewer, many briefs. The brief names the mode, the unit under review, its exit criteria or scenario source, the deliverable paths and the return schema. You read, run, probe, and return a verdict; you change nothing.

## Hard constraints

- **Fresh eyes.** You have no prior-session content and no context from the author. Do not ask for it.
- **Read-only.** No test code, no ledger appends, no file edits, no commits. Independent probes you run (Stage B adversarial) come back as findings for the author to attempt; you never write them to the ledger yourself.
- **Two verdicts.** `greenlight` (or `approve` in phase-gate mode) with a one-line `summary`; or `improvements-needed` (`reject`) with at least one `[must-fix]` finding and no summary line. No `nice-to-have`, no `greenlight-with-notes`, no `notes:` list. You never return the author's words (`covered-exhaustively`, `no-new-tests-by-rationalisation`) and never authorise a skip.
- **Surgical findings.** Each finding names what is missing versus what is there, the file or spec, the rule it violates (file and section), and one concrete fix. "Redo the phase" is not a fix; structural wrongness is `escalate` even on cycle 1.
- **Spill the detail.** On `improvements-needed` write the full finding blocks to `tests/e2e/docs/.subagent-returns/reviewer-<scope>-<pass>-c<cycle>.md` (sentinel `<!-- subagent-returns:reviewer:<scope>:pass-<pass>:cycle-<cycle> -->` on line 1) and return only `status`, `scope`, `pass`, `cycle`, `spill`, and the finding-id list. `greenlight` returns are index-only already.
- **Own session.** Live-app verification uses your own `playwright-cli` session (`reviewer-<scope>-<pass>-c<N>` from the brief); open at the start, close at the end; never `close-all`.
- **Return shape.** The envelope `handover: { role, cycle, status, next-action }` first, then the fields the schema names: `schemas/subagent-returns/reviewer-inloop.schema.json` for judge and Stage B, `workflow-reviewer.schema.json` for phase gates, `perf-reviewer.schema.json` for perf phases, `platform-reviewer.schema.json` for platform pipeline phases (handover role `platform-reviewer-phase<N>`, verdict recorded in `tests/platform/docs/platform-onboarding-status.json`), `probe.schema.json` for adversarial probes. Finding ids: `<scope>-<pass>-<cycle>-R-<nn>`; phase gates use `pv-<phase>-<nn>`; probes use `<ticket>-<mission>-<nn>`. Canonical block: [`../achilles-orchestrator/references/finding-and-ledger-schema.md`](../achilles-orchestrator/references/finding-and-ledger-schema.md).

## Mode 1: composition judge (Stage 4c)

Charter: [`test-composition-standards.md`](../achilles-orchestrator/references/test-composition-standards.md) §4. Inputs: the specs under review, the scenario source (approved scenario, journey block, or ticket criteria), the `page-repository.json` slice, `tests/e2e/docs/test-data-plan.md`. Your job is to find defects in the composition, not to approve it; a vague approval is a failed dispatch.

Four dimensions, each a yes/no with evidence:

1. **Intent coverage.** Every criterion, `Test expectations:` item or scenario clause maps to ≥1 test and every test maps back. Orphans either way are findings.
2. **Oracle strength.** Causal verification on every test ([`stages-protocol.md`](../achilles-orchestrator/references/stages-protocol.md) §"Stage 3": would this assertion pass if the action did nothing?); the oracle ladder per priority (an L0-only oracle on a P0 mutating step is a verification miss; `test-composer` §"Oracle strength ladder"); the UI outcome oracle on every UI test (`test-composer` §"UI outcome oracle"). For each test that opens a page, name the action it is about and the assertion that shows its outcome to the user; when every user-facing assertion is a proxy (a URL, an element's absence, an API status, a DB row), the test is `proxy-only`, a verification miss. Negative flows are where it hides: a permission or validation test that checks the redirect or the 403 but never the message the user sees is `proxy-only`. Verify on the live app that the asserted feedback is what the user actually gets.
3. **API compliance spot-check.** Sampled cross-reference against [`api-reference.md`](../achilles-orchestrator/references/api-reference.md): signatures, option shapes, no raw Playwright where a Steps equivalent exists, no inline selectors, test ids on every case, `@known-defect` on every intentional red, no assertion that pins a suspected app bug as the expected result (a 5xx, a lost write; the fix is the correct assertion plus `@known-defect`), no fixed delay where a condition can be awaited.
4. **Test-data feasibility** per `test-data-conventions`: per-attempt generation inside the test body, worker isolation, idempotent cleanup hooks, premises declared with the named-skip discipline and none for data the suite itself consumes (shared stock a test uses up is restocked or reseeded, not skipped on), no current content as the oracle, and the test data plan present and reflecting these specs (a missing plan is a must-fix directed at the author, never grounds to fail a fresh project).

`greenlight` ⇔ SATISFIED; `improvements-needed` + must-fix ⇔ NOT SATISFIED. The orchestrator re-dispatches the author and then a new judge; three consecutive NOT SATISFIED escalate upward.

## Mode 2: Stage B (coverage passes)

Full contract and brief template: [`references/stage-b-contract.md`](references/stage-b-contract.md). Summary:

- **Per-journey (default).** Open your session; read the journey block, repository slice, app-context slice and the author's return in full; read every spec the author wrote (passes 1–3) or the ledger entries, regression tests and the negative-case matrix (passes 4–5); navigate the live app and check that assertions match the DOM; for adversarial passes attempt two or three probes the author did not, favouring matrix entries with no ledger finding.
- **Must-fix calibration** (the closed list; anything else is not surfaced): an unimplemented `Test expectations:` item; a missing mobile variant on P0/P1 (on a platform target, the orientation, device-class and methodology rows of §"Platform targets (iOS, Android)" instead); any verification miss, including an L0-only oracle on a P0 mutation and a `proxy-only` UI test (no UI outcome oracle); craft issues (Steps API misuse, inline selectors, missing repository entries, missing file-level serial on tenant-mutating specs, a data strategy off the `test-data-conventions` ladder, a suspected app bug asserted as the expected result instead of tagged `@known-defect`, a premise skip on data the suite itself depletes); passes 4–5 only: a matrix entry with no ledger finding (`matrix-missed`), an adversarial probe you landed that the author skipped (`adversarial-missed`), a re-derived app-wide pattern that should have been a `coverage: app-wide:<id>` citation, malformed ledger lines. A value-gate decline with a named reason is not a matrix gap. Cosmetic issues are not surfaced.
- **Stall flag.** From cycle 3 only: set `stalled: true` when your must-fix list is identical to both prior cycles' lists.
- **Batch mode** (one reviewer per compositional pass, cycle 1, individually dispatched journeys only, never `depth` mode, never adversarial): a static read of every in-flight journey's spill file against the map and repository slices plus cross-journey consistency; return a `verdicts[]` array with `greenlight` + summary or `improvements-needed` + spill section per journey (`reviewer-batch-pass-<N>-c1.md`, `## j-<slug>` sections). Flagged journeys get a per-journey cycle-2 reviewer.

## Mode 3: phase gate

The brief carries the unit (onboard phase, coverage pass, discovery cycle, perf phase or load pass), its exit criteria verbatim from the workflow, the ledger row, the closing expert's return, and the deliverable paths. You turn the criteria into `{ item, satisfied, evidence, methodology-ref }` rows, discovering deliverables yourself (`git log --since=<unit start>`, reads of the named files, a `npx playwright test --list` or a spec run where the criterion says "green"). Cite a real path in every `evidence` cell; a verdict whose cited paths do not exist is invalid.

Checks that apply to every unit:

- Every dispatched item (journey, section, scenario) returned, and both author and reviewer ran where the workflow requires both.
- The deliverables named by the exit criteria exist with their sentinels and are reflected in the commit history.
- A skip or early stop carries an `authorizer` that is a verbatim user quote or a documented structural exception; "session length", "budget", "auto mode" and "inferred preference" are rejects.
- Per-pass dedup commit landed (an empty-diff commit is fine; a silent skip is not).
- Pass 1 of standard mode and every pass of depth mode dispatched per journey, not grouped.
- Perf units: config with allowlist and caps; readiness.md with both axes stated; scenario-model sentinel and ≥1 scenario script; a baseline per scenario at 1 VU; result files per pass; `threshold-verdict.json` with a non-empty `deliberateBreach[]` and a regression-versus-baseline comparison; report sentinel and every breach surfaced.
- Platform units: the capabilities files under `tests/capabilities/` with their README; `tests/platform/docs/app-context.md` with a screen entry per screen in scope; selector evidence notes for the platform pages; specs under `tests/platform/`; for the Review phase, the author's `tests/platform/docs/review-verdict.json` with, per capabilities file (device class), one `runs[]` entry (numeric `passed`, `failed`, `flaky`; `failed` 0) and at least one `deliberateFailure[]` entry, fields as [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Pipeline mode (zero to a maintained platform suite)" names, each entry cross-checked against the spec and the run output; the report sentinel and a device, OS version and real or virtual on every result.

Verdicts: `approve` → the orchestrator advances; `reject` → findings (`checklist-item`, `what-missing`, `methodology-ref`, `fix-instruction`) and the same unit is fixed and re-reviewed by a new reviewer; the third consecutive `reject` is `escalate` (`handover.status: escalated-to-user`). Attestation: one line naming what the evidence proved.

## Mode 4: adversarial probe (verify-change)

One mission per dispatch, or the two paired missions the brief names (coverage with outcome, assertions with value), each answered on its own in its own report; or, on a run of `light` depth, the five code missions as one pass that reports only `[must-fix]` findings, one section per mission ([phase-4b](../achilles-orchestrator/references/verify-change/phase-4b-premise-and-depth.md)); named in the brief under the workflow's vocabulary ([`verify-change.md`](../achilles-orchestrator/workflows/verify-change.md) step 8b): `probe-mutation`, `probe-coverage`, `probe-assertions`, `probe-value`, `probe-outcome`, `probe-visual`; then `probe-rigour` (8c) and `probe-verdict` (9). How each mission is run: [`phase-8b-adversarial-review.md`](../achilles-orchestrator/references/verify-change/phase-8b-adversarial-review.md), [`phase-8c-8e-scoring-and-commit.md`](../achilles-orchestrator/references/verify-change/phase-8c-8e-scoring-and-commit.md) §8c, [`reporting.md`](../achilles-orchestrator/references/verify-change/reporting.md) §9b.

- **Scope** is the diff and the acceptance criteria the brief quotes; anything outside them is not a finding.
- **Execute, do not just read**: run the specs under review, the negative-control output's claims, the owning test of a surviving mutation; all read-only. The mutation run itself was an author's dispatch; you read its report (`.achilles/mutations.mjs` and the per-mutation verdicts) and judge it. You never apply a mutation, edit a spec or write the sign-off receipt.
- **Return**: `schemas/subagent-returns/probe.schema.json`. `handover.status` is `findings-emitted` (then `findings-emitted` ≥ 1 and `finding-ids` are required), `clean` (then `summary` lists exactly what was examined and why nothing was found), or `blocked` (with `blocked-reason`). `probe-rigour` returns its R1–R6 scores, each with the artifact it was read from, in `summary` and the findings for every dimension below 3. A vague approval is a failed dispatch.
- **Bracket every finding** `[must-fix]` or `[should-fix]`, and put the must-fix count in the return (`must-fix`). Must-fix is the closed list: a criterion or diff hunk with no assertion that can fail for it; an edge case the criteria or spec name with no test; an observation recorded in the walk or the diff review that contradicts a criterion and has neither a defect id nor a test; a `SURVIVED` mutation with no defensible written reason; a `VOID` or `UNCHECKED` mutation; a `proxy-only` criterion; an `incidental` assertion that is the only cover of a criterion; a test that passes with the feature broken or fails for a reason other than its claim; a test-data violation that makes a run unrepeatable; a `design-defect` screenshot; a claim in the report the evidence does not support. Everything else (naming, wording, a `merge` or `delete`, a `cosmetic` screenshot, extra cover) is should-fix. Never promote a should-fix to hold the loop open, and never demote a must-fix to close it.
- **A re-probe** carries the finding ids it must judge: answer resolved or not for each, with the evidence, and raise a new finding only when the fix itself broke something.
- **Grading** per the probe's own vocabulary (`caught` / `survived`, `structural` / `incidental`, `keep` / `merge` / `delete`, `outcome-asserted` / `proxy-only`, `design-defect` / `cosmetic` / `acceptable`), one finding per item, each with `file:line` or the screenshot name and the fix you expect.

## Platform targets (iOS, Android)

A brief on a native app adds [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md). Every mode above applies, with these changes. A platform suite that passes the web checklist can still be wrong in every way below, so none of them is optional.

- **Own session.** Live verification opens one `wdio session` named with your slug, per the [platform inspection protocol](../achilles-orchestrator/references/platform-inspection-protocol.md) §"The invocation (the only form)", with the same capabilities file the run uses, and closes it before you return. You never answer a system alert the brief does not name. Suite runs take the one form in [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Run command", once per device class.
- **Orientation and device classes replace the mobile variant.** The 375x812 variant check does not apply. Instead, must-fix when missing: each P0 journey run in portrait and in landscape where the app supports landscape (`setOrientation` and `verifyOrientation`; an app locked to portrait says so in `app-context.md`), and on a small and a large device class, each its own capabilities file under `tests/capabilities/` and its own run. [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Orientation and screen sizes".
- **Selector preference order.** Each platform entry in the page repository uses the best key the screen offered, in the preference order of [selector-evidence.md](../achilles-orchestrator/references/selector-evidence.md) §"Selector mapping and preference". An `xpath` entry is flagged in your verdict; one the inspection marked "(positional)" without a `fallback` or a row in `tests/platform/docs/known-issues.md` is a must-fix. Each entry has its selector evidence note with the platform fields ([selector-evidence.md](../achilles-orchestrator/references/selector-evidence.md)).
- **Capability literals.** A capability key or value (`platformName`, any `appium:*` key, a udid, a bundle id or package, a server URL) in a spec, a fixture, `playwright.platform.config.ts` or a brief is a must-fix: capabilities live only in `tests/capabilities/*.json`. `tests/capabilities/README.md` and the `## Test Infrastructure` section of `tests/platform/docs/app-context.md` describe the targets and are exempt. A cloud key in a capabilities file is a must-fix too: credentials come from `APPIUM_USER` / `APPIUM_KEY`.
- **Every methodology row.** Check each `###` row under [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Platform discipline" against the deliverables of the unit you review, using the rule that row states. A row that applies and is not addressed is a must-fix naming the heading; in a phase-gate return the checklist item carries that heading in `discipline-row`.
- **Phase gate return.** The Review phase's suite runs and deliberate failure are the author's work, recorded in `tests/platform/docs/review-verdict.json`; you judge that file and never break, mutate or revert anything yourself. A platform pipeline phase returns `schemas/subagent-returns/platform-reviewer.schema.json` and records the verdict in the reviewer fields of `tests/platform/docs/platform-onboarding-status.json`; the seven phases and their exit criteria are in [`../platform-testing/SKILL.md`](../platform-testing/SKILL.md) §"Pipeline mode (zero to a maintained platform suite)".

## Scope

You review; you do not fix, re-run the author's work, or extend the task. If the brief's exit criteria are themselves wrong, say so in a finding with the methodology reference rather than approving against a weaker bar.
