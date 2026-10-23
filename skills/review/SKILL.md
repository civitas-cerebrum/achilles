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
- **Return shape.** The envelope `handover: { role, cycle, status, next-action }` first, then the fields the schema names: `schemas/subagent-returns/reviewer-inloop.schema.json` for judge and Stage B, `workflow-reviewer.schema.json` for phase gates, `perf-reviewer.schema.json` for perf phases, `probe.schema.json` for adversarial probes. Finding ids: `<scope>-<pass>-<cycle>-R-<nn>`; phase gates use `pv-<phase>-<nn>`; probes use `<ticket>-<mission>-<nn>`. Canonical block: [`../achilles-orchestrator/references/finding-and-ledger-schema.md`](../achilles-orchestrator/references/finding-and-ledger-schema.md).

## Mode 1: composition judge (Stage 4c)

Charter: [`test-composition-standards.md`](../achilles-orchestrator/references/test-composition-standards.md) §4. Inputs: the specs under review, the scenario source (approved scenario, journey block, or ticket criteria), the `page-repository.json` slice, `tests/e2e/docs/test-data-plan.md`. Your job is to find defects in the composition, not to approve it; a vague approval is a failed dispatch.

Four dimensions, each a yes/no with evidence:

1. **Intent coverage.** Every criterion, `Test expectations:` item or scenario clause maps to ≥1 test and every test maps back. Orphans either way are findings.
2. **Oracle strength.** Causal verification on every test ([`stages-protocol.md`](../achilles-orchestrator/references/stages-protocol.md) §"Stage 3": would this assertion pass if the action did nothing?); the oracle ladder per priority (an L0-only oracle on a P0 mutating step is a verification miss; `test-composer` §"Oracle strength ladder").
3. **API compliance spot-check.** Sampled cross-reference against [`api-reference.md`](../achilles-orchestrator/references/api-reference.md): signatures, option shapes, no raw Playwright where a Steps equivalent exists, no inline selectors, test ids on every case, `@known-defect` on every intentional red.
4. **Test-data feasibility** per `test-data-conventions`: per-attempt generation inside the test body, worker isolation, idempotent cleanup hooks, premises declared with the named-skip discipline, no current content as the oracle, and the test data plan present and reflecting these specs (a missing plan is a must-fix directed at the author, never grounds to fail a fresh project).

`greenlight` ⇔ SATISFIED; `improvements-needed` + must-fix ⇔ NOT SATISFIED. The orchestrator re-dispatches the author and then a new judge; three consecutive NOT SATISFIED escalate upward.

## Mode 2: Stage B (coverage passes)

Full contract and brief template: [`references/stage-b-contract.md`](references/stage-b-contract.md). Summary:

- **Per-journey (default).** Open your session; read the journey block, repository slice, app-context slice and the author's return in full; read every spec the author wrote (passes 1–3) or the ledger entries, regression tests and the negative-case matrix (passes 4–5); navigate the live app and check that assertions match the DOM; for adversarial passes attempt two or three probes the author did not, favouring matrix entries with no ledger finding.
- **Must-fix calibration** (the closed list; anything else is not surfaced): an unimplemented `Test expectations:` item; a missing mobile variant on P0/P1; any verification miss, including an L0-only oracle on a P0 mutation; craft issues (Steps API misuse, inline selectors, missing repository entries, missing file-level serial on tenant-mutating specs, a data strategy off the `test-data-conventions` ladder); passes 4–5 only: a matrix entry with no ledger finding (`matrix-missed`), an adversarial probe you landed that the author skipped (`adversarial-missed`), a re-derived app-wide pattern that should have been a `coverage: app-wide:<id>` citation, malformed ledger lines. A value-gate decline with a named reason is not a matrix gap. Cosmetic issues are not surfaced.
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

Verdicts: `approve` → the orchestrator advances; `reject` → findings (`checklist-item`, `what-missing`, `methodology-ref`, `fix-instruction`) and the same unit is fixed and re-reviewed by a new reviewer; the third consecutive `reject` is `escalate` (`handover.status: escalated-to-user`). Attestation: one line naming what the evidence proved.

## Mode 4: adversarial probe (verify-change)

One mission per dispatch, named in the brief under the workflow's vocabulary ([`verify-change.md`](../achilles-orchestrator/workflows/verify-change.md) step 8b): `probe-mutation`, `probe-coverage`, `probe-assertions`, `probe-value`, `probe-outcome`, `probe-visual`; then `probe-rigour` (8c) and `probe-verdict` (9). How each mission is run: [`phase-8b-adversarial-review.md`](../achilles-orchestrator/references/verify-change/phase-8b-adversarial-review.md), [`phase-8c-8e-scoring-and-commit.md`](../achilles-orchestrator/references/verify-change/phase-8c-8e-scoring-and-commit.md) §8c, [`reporting.md`](../achilles-orchestrator/references/verify-change/reporting.md) §9b.

- **Scope** is the diff and the acceptance criteria the brief quotes; anything outside them is not a finding.
- **Execute, do not just read**: run the specs under review, the negative-control output's claims, the owning test of a surviving mutation; all read-only. The mutation run itself was an author's dispatch; you read its report (`.achilles/mutations.mjs` and the per-mutation verdicts) and judge it. You never apply a mutation, edit a spec or write the sign-off receipt.
- **Return**: `schemas/subagent-returns/probe.schema.json`. `handover.status` is `findings-emitted` (then `findings-emitted` ≥ 1 and `finding-ids` are required), `clean` (then `summary` lists exactly what was examined and why nothing was found), or `blocked` (with `blocked-reason`). `probe-rigour` returns its R1–R6 scores, each with the artifact it was read from, in `summary` and the findings for every dimension below 3. A vague approval is a failed dispatch.
- **Grading** per the probe's own vocabulary (`caught` / `survived`, `structural` / `incidental`, `keep` / `merge` / `delete`, `outcome-asserted` / `proxy-only`, `design-defect` / `cosmetic` / `acceptable`), one finding per item, each with `file:line` or the screenshot name and the fix you expect.

## Scope

You review; you do not fix, re-run the author's work, or extend the task. If the brief's exit criteria are themselves wrong, say so in a finding with the methodology reference rather than approving against a weaker bar.
