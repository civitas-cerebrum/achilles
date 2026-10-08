# achilles-qa — role ledger

Human copy of `hooks/data/achilles-qa.kernel-mandate.json`. The manifest is enforced; this file is not. `lint-doc-drift` fails when the role names or the stated count here disagree with the manifest.

## What this is

An operating system for agents working in this project: **23 roles**,
each with its own tools, paths, commands and dispatch rights. The kernel
(`kernel-mandate-role-gate.sh`) runs as a `PreToolUse` hook on every tool
call, resolves which role is making it, and refuses anything the manifest
does not grant. Rules that would otherwise be prose in a prompt — "the
reviewer only reads the deliverable" — are tool-call denials here.

- **Main session** — bound to `orchestrator`. Everything you type in this session is held to that role.
- **A subagent that binds to no role** — `readonly` (it may read, and nothing else).
- **Role tag corroboration** — `auto`: how hard a subagent's claimed role must be corroborated before the kernel believes it.
- **Scope** — the manifest governs the directory tree it sits in. Nothing outside it is touched, and nothing outside it is protected.

## Roles at a glance

| role | mandate | reads | writes | runs | dispatches |
|---|---|---|---|---|---|
| **cleanup** | Cleanup / dedup worker for the coverage-expansion cleanup pass (`cleanup-<scope>:`): removes redundant specs under tests/e2e/** and re-runs the suite to prove the remainder is still green. | `docs/**`<br>`tests/**` | `tests/e2e/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **companion** | companion-mode verification worker (`companion-<task-slug>:`): verifies one task against the live app in its own playwright-cli session and lands the evidence bundle under tests/e2e/evidence/**. | `docs/**`<br>`tests/**` | `tests/e2e/evidence/**`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **contribution-handover** | Pre-push handover author (`contribution-handover-<slug>:`): fills .contribution-handover.json from the contributing skill's guardrail checklist by reading this repo's own documentation and the branch diff. | `.contribution-handover.template.json`<br>`README.md`<br>`docs/**`<br>`package.json`<br>`schemas/**`<br>`skills/**` | `.contribution-handover.json` | `^git status\b`<br>`^git log\b`<br>`^git diff\b` | — |
| **doc-author** | Writes documentation only: docs/** (except the evidence trail docs/evidence/**), CLAUDE.md and project skills under .claude/skills/**. | `.claude/skills/**`<br>`CLAUDE.md`<br>`README.md`<br>`docs/**`<br>`tests/**` | `.claude/skills/**`<br>`CLAUDE.md`<br>`docs/**`<br>*except* `docs/evidence/**` | — | — |
| **fd** | failure-diagnosis worker (`fd-<test-slug>:`, `fd-ci-<run-id>:`): reproduces one failing spec against the live app in its own playwright-cli session, classifies deterministic vs flaky, and lands the diagnosis plus any heal under tests/e2e/**. | `docs/**`<br>`tests/**` | `tests/e2e/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **implementer** | Writes one change: specs, fixtures and support code under tests/** (never the page repository, which live inspection owns) and the change report (report.md in the change's folder under docs/evidence/). | `docs/**`<br>`package.json`<br>`playwright.config.ts`<br>`tests/**` | `docs/evidence/*/report.md`<br>`tests/**`<br>*except* `**/page-repository*.json`<br>`tests/e2e/docs/onboarding-status.json` | `^npx playwright test\b`<br>`^npx tsc --noEmit\b`<br>`^npm run test:unit\b` | — |
| **live-inspector** | Inspects the running app before any selector exists: writes throwaway inspection specs under the inspect dir (tests/e2e/inspect/**, deleted before hand-back), selector evidence under docs/evidence/selectors/** and a proposal note in the change's folder under docs/evidence/. | `docs/**`<br>`tests/**`<br>`tests/e2e/page-repository.json` | `docs/evidence/*/proposal-*.md`<br>`docs/evidence/selectors/**`<br>`tests/e2e/inspect/**` | `^npx playwright test --config tests/e2e/inspect\b`<br>`^npx achilles-selector-evidence\b` | — |
| **orchestrator**<br>*(main session)* | The main session driving the achilles QA pipeline: walks the app, records pipeline state under tests/** and .achilles/**, runs the suite, commits, and dispatches every subagent role. | `.achilles/**`<br>`.gitignore`<br>`README.md`<br>`docs/**`<br>`package.json`<br>`playwright*.config.ts`<br>`tests/**` | `.achilles/**`<br>`.gitignore`<br>`docs/evidence/*/brief.md`<br>`docs/evidence/*/review-package.md`<br>`tests/**` | `^npx playwright test --list\b`<br>`^git status\b`<br>`^git log\b`<br>`^git diff\b`<br>`^git add\b`<br>`^git commit\b`<br>`^npx playwright test\b`<br>`^npx playwright-cli (close-all\|kill-all\|list)\b`<br>`^npm run verify\b`<br>`^npm run change:start\b` | `cleanup`<br>`companion`<br>`contribution-handover`<br>`doc-author`<br>`fd`<br>`implementer`<br>`live-inspector`<br>`perf-reviewer`<br>`phase-validator`<br>`phase1`<br>`phase2`<br>`phase4`<br>`probe`<br>`process-validator`<br>`reviewer`<br>`scaffolder`<br>`secrets-sweep`<br>`stage2`<br>`task-reviewer`<br>`test-composer`<br>`verifier`<br>`workflow-reviewer` |
| **perf-reviewer** | Approver for the perf pipeline: reviews tests/perf/** deliverables and records the verdict in tests/perf/docs/perf-onboarding-status.json. | `docs/**`<br>`tests/perf/**` | `tests/perf/docs/perf-onboarding-status.json` | — | — |
| **phase-validator** | Approver: emits the per-phase greenlight into tests/e2e/docs/onboarding-status.json after checking the phase's deliverables on disk. | `docs/**`<br>`tests/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **phase1** | journey-mapping Phase 1 discovery worker (`phase1-<entry>:`): crawls one entry-point subtree in its own playwright-cli session and returns the page + element list. | `docs/**`<br>`tests/**` | `tests/e2e/docs/app-context.md`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **phase2** | journey-mapping Phase 2 flow-identification worker (`phase2-<scope>:`): walks one scope's flows in its own playwright-cli session and returns the flow list, appending only its discovery notes. | `docs/**`<br>`tests/**` | `tests/e2e/docs/app-context.md`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **phase4** | journey-mapping Phase 4 worker: `phase4-cycle-<N>:` section agents discover one section of the map in their own playwright-cli session, and `phase4-prioritise-author:` is the only legitimate author of tests/e2e/docs/journey-map.md and its `<!-- journey-mapping:generated -->` sentinel. | `docs/**`<br>`tests/**` | `tests/e2e/docs/.phase4-cycle-state.json`<br>`tests/e2e/docs/.subagent-returns/**`<br>`tests/e2e/docs/journey-map.md` | `^npx playwright-cli\b` | — |
| **probe** | Stage A adversarial prober (`probe-j-<slug>:` for coverage-expansion passes 4-5 and bug-discovery, `probe-app-wide:` for the pass-4 pattern scan): probes the live app in its own playwright-cli session, appends findings to tests/e2e/docs/adversarial-findings.md under the advisory lock, and in pass 5 writes regression specs for verified boundaries. | `docs/**`<br>`tests/**` | `tests/e2e/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **process-validator** | Approver: validates that the pipeline followed the documented process and records the finding in tests/e2e/docs/onboarding-status.json. | `docs/**`<br>`tests/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **reviewer** | Stage B in-loop reviewer (`reviewer-j-<slug>:` per journey, `reviewer-batch-pass-<N>:` for the cycle-1 compositional batch): reads Stage A's output and the live app in its own playwright-cli session and returns greenlight or improvements-needed. | `docs/**`<br>`tests/**` | `tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **scaffolder** | Write-only author of the Phase 1-2 scaffold and the Phase 7 env wiring: playwright.config.ts, package.json scripts, .gitignore entries, .env and .env.example, tests/e2e/playwright.setup.ts, tests/e2e/fixtures/**, tests/e2e/docs/app-context.md and tests/e2e/page-repository.json. | `.env`<br>`.env.example`<br>`.gitignore`<br>`README.md`<br>`docs/**`<br>`package.json`<br>`playwright*.config.ts`<br>`tests/e2e/**` | `.env`<br>`.env.example`<br>`.gitignore`<br>`package.json`<br>`playwright*.config.ts`<br>`tests/e2e/.gitignore`<br>`tests/e2e/docs/app-context.md`<br>`tests/e2e/fixtures/**`<br>`tests/e2e/page-repository.json`<br>`tests/e2e/playwright.setup.ts` | — | — |
| **secrets-sweep** | Phase 7 secrets sweep: rewrites hard-coded credentials, keys, PII and app URLs in specs and fixtures under tests/** to process.env references. It writes no .env or config (the scaffolder wires those) and has no shell; the orchestrator re-runs the suite after it returns. | `tests/**` | `tests/**` | — | — |
| **stage2** | Stage 2 element-inspection worker (`stage2-<scenario>:`): inspects the pages of one approved scenario in its own playwright-cli session and RETURNS proposed page-repository entries — the page repository itself stays the scaffolder's file. | `docs/**`<br>`tests/**` | `tests/e2e/.auth/**`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **task-reviewer** | Approver: reads the brief, the implementer's report and the review package for one change and records findings (Critical / Important / Minor, each with file:line and a fix) in review.md in the change's folder under docs/evidence/. | `docs/**`<br>`package.json`<br>`playwright.config.ts`<br>`tests/**` | `docs/evidence/*/review.md` | `^npx tsc --noEmit\b`<br>`^npm run test:unit\b`<br>`^npm run test:hooks\b` | — |
| **test-composer** | Authors Playwright specs under tests/e2e/** from a journey brief and self-verifies them with the runner. | `docs/**`<br>`tests/**`<br>`tests/e2e/page-repository.json` | `tests/e2e/**`<br>`tests/e2e/page-repository.json` | `^npx playwright test\b` | — |
| **verifier** | Approver: independently runs a change and records the verdict in verify.md in the change's folder under docs/evidence/; only it may set that note's Status: complete. | `docs/**`<br>`package.json`<br>`playwright.config.ts`<br>`tests/**` | `docs/evidence/*/verify.md` | `^npx playwright test\b`<br>`^npx tsc --noEmit\b`<br>`^npm run test:unit\b`<br>`^npm run test:hooks\b` | — |
| **workflow-reviewer** | Approver: reviews a phase's deliverables against the ledger and records the verdict in tests/e2e/docs/onboarding-status.json. | `docs/**`<br>`tests/**` | `tests/e2e/docs/onboarding-status.json` | — | — |

## Each role, and what it is refused

### `cleanup`

Cleanup / dedup worker for the coverage-expansion cleanup pass (`cleanup-<scope>:`): removes redundant specs under tests/e2e/** and re-runs the suite to prove the remainder is still green. Never the status ledger and never the page repository.

- **Binds when** the host dispatches an agent of type `cleanup`, or when the brief carries `<<kernel-mandate-role: cleanup#<nonce>>>` and the description begins `cleanup-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright-cli\b`, `^npx playwright test\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `companion`

companion-mode verification worker (`companion-<task-slug>:`): verifies one task against the live app in its own playwright-cli session and lands the evidence bundle under tests/e2e/evidence/**. Writes no suite specs, no ledger and no page repository.

- **Binds when** the host dispatches an agent of type `companion`, or when the brief carries `<<kernel-mandate-role: companion#<nonce>>>` and the description begins `companion-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/evidence/**`, `tests/e2e/docs/.subagent-returns/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright-cli\b`, `^npx playwright test\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `companion-mode`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `contribution-handover`

Pre-push handover author (`contribution-handover-<slug>:`): fills .contribution-handover.json from the contributing skill's guardrail checklist by reading this repo's own documentation and the branch diff. Writes exactly that one file.

- **Binds when** the host dispatches an agent of type `contribution-handover`, or when the brief carries `<<kernel-mandate-role: contribution-handover#<nonce>>>` and the description begins `contribution-handover-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `.contribution-handover.template.json`, `README.md`, `docs/**`, `package.json`, `schemas/**`, `skills/**`
- **Writes** `.contribution-handover.json`
- **Runs** `^git status\b`, `^git log\b`, `^git diff\b` — anchored patterns; a command that does not match is refused.
- **Skills** `contributing-to-achilles-protocol`

**May not** 
- use `Agent`
- dispatch any subagent
- reach any network destination
- see what `cleanup` writes (`tests/e2e/**`)
- see what `companion` writes (`tests/e2e/evidence/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `fd` writes (`tests/e2e/**`)
- see what `perf-reviewer` writes (`tests/perf/docs/perf-onboarding-status.json`)
- see what `phase-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `phase1` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase2` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase4` writes (`tests/e2e/docs/.phase4-cycle-state.json`, `tests/e2e/docs/.subagent-returns/**`, `tests/e2e/docs/journey-map.md`)
- see what `probe` writes (`tests/e2e/**`)
- see what `process-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `reviewer` writes (`tests/e2e/docs/.subagent-returns/**`)
- see what `secrets-sweep` writes (`tests/**`)
- see what `stage2` writes (`tests/e2e/.auth/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `test-composer` writes (`tests/e2e/**`)
- see what `workflow-reviewer` writes (`tests/e2e/docs/onboarding-status.json`)

### `doc-author`

Writes documentation only: docs/** (except the evidence trail docs/evidence/**), CLAUDE.md and project skills under .claude/skills/**. No shell, no dispatch, no authored code.

- **Binds when** the host dispatches an agent of type `doc-author`, or when the brief carries `<<kernel-mandate-role: doc-author#<nonce>>>` and the description begins `doc-author-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `.claude/skills/**`, `CLAUDE.md`, `README.md`, `docs/**`, `tests/**`
- **Writes** `.claude/skills/**`, `CLAUDE.md`, `docs/**`
- **Never writes** `docs/evidence/**` — carved out of the write scope; deny beats allow.
- **Skills** `achilles-protocol`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `fd`

failure-diagnosis worker (`fd-<test-slug>:`, `fd-ci-<run-id>:`): reproduces one failing spec against the live app in its own playwright-cli session, classifies deterministic vs flaky, and lands the diagnosis plus any heal under tests/e2e/**. Never the status ledger and never the page repository.

- **Binds when** the host dispatches an agent of type `fd`, or when the brief carries `<<kernel-mandate-role: fd#<nonce>>>` and the description begins `fd-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright-cli\b`, `^npx playwright test\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `database-testing`, `failure-diagnosis`, `selector-development`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `implementer`

Writes one change: specs, fixtures and support code under tests/** (never the page repository, which live inspection owns) and the change report (report.md in the change's folder under docs/evidence/). Proves its own work with the test runner on its own shard, the type check and the unit runner. Never reviews or verifies its own change and dispatches nothing.

- **Binds when** the host dispatches an agent of type `implementer`, or when the brief carries `<<kernel-mandate-role: implementer#<nonce>>>` and the description begins `implementer-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `package.json`, `playwright.config.ts`, `tests/**`
- **Writes** `docs/evidence/*/report.md`, `tests/**`
- **Never writes** `**/page-repository*.json`, `tests/e2e/docs/onboarding-status.json` — carved out of the write scope; deny beats allow.
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright test\b`, `^npx tsc --noEmit\b`, `^npm run test:unit\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `contract-testing`, `database-testing`, `failure-diagnosis`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `live-inspector`

Inspects the running app before any selector exists: writes throwaway inspection specs under the inspect dir (tests/e2e/inspect/**, deleted before hand-back), selector evidence under docs/evidence/selectors/** and a proposal note in the change's folder under docs/evidence/. Proposes; never edits the page repository, specs or fixtures.

- **Binds when** the host dispatches an agent of type `live-inspector`, or when the brief carries `<<kernel-mandate-role: live-inspector#<nonce>>>` and the description begins `live-inspector-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`, `tests/e2e/page-repository.json`
- **Writes** `docs/evidence/*/proposal-*.md`, `docs/evidence/selectors/**`, `tests/e2e/inspect/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright test --config tests/e2e/inspect\b`, `^npx achilles-selector-evidence\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `orchestrator` — the main session

The main session driving the achilles QA pipeline: walks the app, records pipeline state under tests/** and .achilles/**, runs the suite, commits, and dispatches every subagent role. It authors no runner or resolution config — playwright.config.ts, package.json and the Phase 1-2 scaffold (fixtures, setup, page repository, app context) are written by the scaffolder role it dispatches. Never touches application source or secrets.

- **Binds as** the main session (`mainSessionRole`); it is never dispatched.
- **Tools** `Agent`, `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `.achilles/**`, `.gitignore`, `README.md`, `docs/**`, `package.json`, `playwright*.config.ts`, `tests/**`
- **Writes** `.achilles/**`, `.gitignore`, `docs/evidence/*/brief.md`, `docs/evidence/*/review-package.md`, `tests/**`
- **Authored code may import** **nothing by name** (relative imports inside its own scope still work)
- **Runs** `^npx playwright test --list\b`, `^git status\b`, `^git log\b`, `^git diff\b`, `^git add\b`, `^git commit\b`, `^npx playwright test\b`, `^npx playwright-cli (close-all|kill-all|list)\b`, `^npm run verify\b`, `^npm run change:start\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost:3000`, `localhost:4173`
- **Skills** `achilles-protocol`, `agents-vs-agents`, `bug-discovery`, `bug-report`, `companion-mode`, `contract-testing`, `contributing-to-achilles-protocol`, `coverage-expansion`, `database-testing`, `failure-diagnosis`, `journey-mapping`, `onboarding`, `perf-onboarding`, `performance-testing`, `requirement-intake`, `secrets-sweep`, `selector-development`, `self-repair`, `test-catalogue`, `test-composer`, `test-data-conventions`, `test-repair`, `ticket-driven-testing`, `work-summary-deck`, `workflow-reviewer`
- **Dispatches** `cleanup`, `companion`, `contribution-handover`, `doc-author`, `fd`, `implementer`, `live-inspector`, `perf-reviewer`, `phase-validator`, `phase1`, `phase2`, `phase4`, `probe`, `process-validator`, `reviewer`, `scaffolder`, `secrets-sweep`, `stage2`, `task-reviewer`, `test-composer`, `verifier`, `workflow-reviewer`

**May not** 
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `perf-reviewer`

Approver for the perf pipeline: reviews tests/perf/** deliverables and records the verdict in tests/perf/docs/perf-onboarding-status.json. No shell; writes only the ledger.

- **Binds when** the host dispatches an agent of type `perf-reviewer`, or when the brief carries `<<kernel-mandate-role: perf-reviewer#<nonce>>>` and the description begins `perf-reviewer-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/perf/**`
- **Writes** `tests/perf/docs/perf-onboarding-status.json`
- **Skills** `workflow-reviewer`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `cleanup` writes (`tests/e2e/**`)
- see what `companion` writes (`tests/e2e/evidence/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `contribution-handover` writes (`.contribution-handover.json`)
- see what `fd` writes (`tests/e2e/**`)
- see what `phase-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `phase1` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase2` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase4` writes (`tests/e2e/docs/.phase4-cycle-state.json`, `tests/e2e/docs/.subagent-returns/**`, `tests/e2e/docs/journey-map.md`)
- see what `probe` writes (`tests/e2e/**`)
- see what `process-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `reviewer` writes (`tests/e2e/docs/.subagent-returns/**`)
- see what `scaffolder` writes (`.env`, `.env.example`, `.gitignore`, `package.json`, `playwright*.config.ts`, `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts`)
- see what `stage2` writes (`tests/e2e/.auth/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `test-composer` writes (`tests/e2e/**`)
- see what `workflow-reviewer` writes (`tests/e2e/docs/onboarding-status.json`)

### `phase-validator`

Approver: emits the per-phase greenlight into tests/e2e/docs/onboarding-status.json after checking the phase's deliverables on disk. No shell; writes only the ledger.

- **Binds when** the host dispatches an agent of type `phase-validator`, or when the brief carries `<<kernel-mandate-role: phase-validator#<nonce>>>` and the description begins `phase-validator-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/docs/onboarding-status.json`
- **Skills** `workflow-reviewer`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `phase1`

journey-mapping Phase 1 discovery worker (`phase1-<entry>:`): crawls one entry-point subtree in its own playwright-cli session and returns the page + element list. The `phase1-test-infra:` variant additionally writes the canonical `## Test Infrastructure` section of tests/e2e/docs/app-context.md. Composes no specs.

- **Binds when** the host dispatches an agent of type `phase1`, or when the brief carries `<<kernel-mandate-role: phase1#<nonce>>>` and the description begins `phase1-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`
- **Runs** `^npx playwright-cli\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `journey-mapping`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `phase2`

journey-mapping Phase 2 flow-identification worker (`phase2-<scope>:`): walks one scope's flows in its own playwright-cli session and returns the flow list, appending only its discovery notes. Composes no specs.

- **Binds when** the host dispatches an agent of type `phase2`, or when the brief carries `<<kernel-mandate-role: phase2#<nonce>>>` and the description begins `phase2-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`
- **Runs** `^npx playwright-cli\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `journey-mapping`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `phase4`

journey-mapping Phase 4 worker: `phase4-cycle-<N>:` section agents discover one section of the map in their own playwright-cli session, and `phase4-prioritise-author:` is the only legitimate author of tests/e2e/docs/journey-map.md and its `<!-- journey-mapping:generated -->` sentinel. Cycle progress is recorded in tests/e2e/docs/.phase4-cycle-state.json.

- **Binds when** the host dispatches an agent of type `phase4`, or when the brief carries `<<kernel-mandate-role: phase4#<nonce>>>` and the description begins `phase4-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/docs/.phase4-cycle-state.json`, `tests/e2e/docs/.subagent-returns/**`, `tests/e2e/docs/journey-map.md`
- **Runs** `^npx playwright-cli\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `journey-mapping`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `probe`

Stage A adversarial prober (`probe-j-<slug>:` for coverage-expansion passes 4-5 and bug-discovery, `probe-app-wide:` for the pass-4 pattern scan): probes the live app in its own playwright-cli session, appends findings to tests/e2e/docs/adversarial-findings.md under the advisory lock, and in pass 5 writes regression specs for verified boundaries. Never the status ledger and never the page repository.

- **Binds when** the host dispatches an agent of type `probe`, or when the brief carries `<<kernel-mandate-role: probe#<nonce>>>` and the description begins `probe-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright-cli\b`, `^npx playwright test\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `bug-discovery`, `bug-report`, `database-testing`, `selector-development`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `process-validator`

Approver: validates that the pipeline followed the documented process and records the finding in tests/e2e/docs/onboarding-status.json. No shell; writes only the ledger.

- **Binds when** the host dispatches an agent of type `process-validator`, or when the brief carries `<<kernel-mandate-role: process-validator#<nonce>>>` and the description begins `process-validator-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/docs/onboarding-status.json`
- **Skills** `workflow-reviewer`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `reviewer`

Stage B in-loop reviewer (`reviewer-j-<slug>:` per journey, `reviewer-batch-pass-<N>:` for the cycle-1 compositional batch): reads Stage A's output and the live app in its own playwright-cli session and returns greenlight or improvements-needed. Writes ONLY its spillover file under tests/e2e/docs/.subagent-returns/ — it does not append to either ledger, does not modify specs and does not commit.

- **Binds when** the host dispatches an agent of type `reviewer`, or when the brief carries `<<kernel-mandate-role: reviewer#<nonce>>>` and the description begins `reviewer-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/docs/.subagent-returns/**`
- **Runs** `^npx playwright-cli\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `workflow-reviewer`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `scaffolder`

Write-only author of the Phase 1-2 scaffold and the Phase 7 env wiring: playwright.config.ts, package.json scripts, .gitignore entries, .env and .env.example, tests/e2e/playwright.setup.ts, tests/e2e/fixtures/**, tests/e2e/docs/app-context.md and tests/e2e/page-repository.json. No shell and no dispatch — the orchestrator runs `npx playwright test --list` to verify what it wrote, so the role that authors the runner's config never runs the runner.

- **Binds when** the host dispatches an agent of type `scaffolder`, or when the brief carries `<<kernel-mandate-role: scaffolder#<nonce>>>` and the description begins `scaffolder-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `.env`, `.env.example`, `.gitignore`, `README.md`, `docs/**`, `package.json`, `playwright*.config.ts`, `tests/e2e/**`
- **Writes** `.env`, `.env.example`, `.gitignore`, `package.json`, `playwright*.config.ts`, `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts`
- **Skills** `achilles-protocol`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)
- see what `perf-reviewer` writes (`tests/perf/docs/perf-onboarding-status.json`)

### `secrets-sweep`

Phase 7 secrets sweep: rewrites hard-coded credentials, keys, PII and app URLs in specs and fixtures under tests/** to process.env references. It writes no .env or config (the scaffolder wires those) and has no shell; the orchestrator re-runs the suite after it returns.

- **Binds when** the host dispatches an agent of type `secrets-sweep`, or when the brief carries `<<kernel-mandate-role: secrets-sweep#<nonce>>>` and the description begins `secrets-sweep-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `tests/**`
- **Writes** `tests/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`, `dotenv`
- **Skills** `achilles-protocol`, `secrets-sweep`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)
- see what `doc-author` writes (`.claude/skills/**`, `CLAUDE.md`, `docs/**`)
- see what `task-reviewer` writes (`docs/evidence/*/review.md`)
- see what `verifier` writes (`docs/evidence/*/verify.md`)

### `stage2`

Stage 2 element-inspection worker (`stage2-<scenario>:`): inspects the pages of one approved scenario in its own playwright-cli session and RETURNS proposed page-repository entries — the page repository itself stays the scaffolder's file. May persist a captured auth state under tests/e2e/.auth/**.

- **Binds when** the host dispatches an agent of type `stage2`, or when the brief carries `<<kernel-mandate-role: stage2#<nonce>>>` and the description begins `stage2-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/.auth/**`, `tests/e2e/docs/.subagent-returns/**`
- **Runs** `^npx playwright-cli\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `selector-development`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `task-reviewer`

Approver: reads the brief, the implementer's report and the review package for one change and records findings (Critical / Important / Minor, each with file:line and a fix) in review.md in the change's folder under docs/evidence/. Writes nothing else; runs only the type check, the unit runner and the hook fixture runner; never the app.

- **Binds when** the host dispatches an agent of type `task-reviewer`, or when the brief carries `<<kernel-mandate-role: task-reviewer#<nonce>>>` and the description begins `task-reviewer-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `package.json`, `playwright.config.ts`, `tests/**`
- **Writes** `docs/evidence/*/review.md`
- **Authored code may import** **nothing by name** (relative imports inside its own scope still work)
- **Runs** `^npx tsc --noEmit\b`, `^npm run test:unit\b`, `^npm run test:hooks\b` — anchored patterns; a command that does not match is refused.
- **Skills** `achilles-protocol`, `workflow-reviewer`

**May not** 
- use `Agent`
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `test-composer`

Authors Playwright specs under tests/e2e/** from a journey brief and self-verifies them with the runner. Reads the page repository and docs; writes nothing outside tests/e2e/**.

- **Binds when** the host dispatches an agent of type `test-composer`, or when the brief carries `<<kernel-mandate-role: test-composer#<nonce>>>` and the description begins `test-composer-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`, `tests/e2e/page-repository.json`
- **Writes** `tests/e2e/**`, `tests/e2e/page-repository.json`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright test\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `database-testing`, `selector-development`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `verifier`

Approver: independently runs a change and records the verdict in verify.md in the change's folder under docs/evidence/; only it may set that note's Status: complete. Runs the test runner (a spend-incurring spec only when the brief grants the project's spend opt-in), the type check, the unit runner and the hook fixture runner. Never edits code, specs or fixtures.

- **Binds when** the host dispatches an agent of type `verifier`, or when the brief carries `<<kernel-mandate-role: verifier#<nonce>>>` and the description begins `verifier-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `package.json`, `playwright.config.ts`, `tests/**`
- **Writes** `docs/evidence/*/verify.md`
- **Authored code may import** **nothing by name** (relative imports inside its own scope still work)
- **Runs** `^npx playwright test\b`, `^npx tsc --noEmit\b`, `^npm run test:unit\b`, `^npm run test:hooks\b` — anchored patterns; a command that does not match is refused.
- **May set** `SPEND_OPT_IN` in front of a command — the project's spend opt-in, granted per run in the brief.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `failure-diagnosis`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `workflow-reviewer`

Approver: reviews a phase's deliverables against the ledger and records the verdict in tests/e2e/docs/onboarding-status.json. No shell; writes only the ledger.

- **Binds when** the host dispatches an agent of type `workflow-reviewer`, or when the brief carries `<<kernel-mandate-role: workflow-reviewer#<nonce>>>` and the description begins `workflow-reviewer-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`
- **Writes** `tests/e2e/docs/onboarding-status.json`
- **Skills** `workflow-reviewer`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)

## What the kernel refuses for every role

These hold whatever the manifest says, and are not listed per role above:

- **Its own control surfaces** — the manifest, `.claude/settings.json`, the hooks, `.claude/agents/`, `.mcp.json` and the kernel state directory. A role that could rewrite the rules has no rules.
- **Secrets** — `.env` and its relatives are outside every read scope unless a role is explicitly granted them, on the file channel and through the shell alike.
- **Re-anchoring** — `git -C`, `npm --prefix` and the rest of the family, which would run a permitted command somewhere else.
- **Constructed destinations** — authored code that builds a network target at run time (`fetch("htt"+"p://…")`, a dynamic `import`, `new WebSocket(host)`) rather than naming one.
- **Deletion is a write** — `rm`, `rmdir` and `unlink` are held to write scope.
- **Failing closed** — if the kernel itself faults, the call is denied, not allowed.

### What it does not check

- **The dispatch brief.** What a dispatcher pastes into a child's brief is bounded only by what the dispatcher itself may read. Path scopes bound the filesystem, not the conversation.
- **Field-level rules.** "Only a judge may set `verdict: green`" is not a path scope; it belongs in a hook of your own.
- **`Status: complete` in a change's `verify.md` is approver-class.** Only the `verifier` may
  declare a change verified. In this manifest that is also a path decision — `docs/evidence/*/verify.md`
  is in the verifier's write scope and no other role's, and the `doc-author` has `docs/evidence/**`
  carved out — so the orchestrator that drove a change cannot write its verify note at all. A project
  that widens any role's scope over `docs/evidence/**` keeps the rule in a field-level gate of its own,
  which refuses `Status: complete` from any caller that is not a verifier dispatch, the way the
  onboarding ledger's write gate refuses a self-approved verdict.
- **Runtime behaviour of authored code.** The import and capability screens read the text a role writes; they are not a sandbox.

