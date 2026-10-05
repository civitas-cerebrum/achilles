# achilles-qa — role ledger

The human copy of `hooks/data/achilles-qa.kernel-mandate.json`: the roles,
what each one is refused, where work changes hands. The manifest is what is
enforced — an edit here changes nothing about what is enforced.

Upstream this file is rendered by `kernel-mandate doc`, which ships in
`@civitas-cerebrum/kernel-mandate`. This repo does not depend on that
package and will not, so the renderer cannot be run here and
`scripts/sync-kernel-mandate.mjs` can neither regenerate this file nor diff
it. The role inventory — the glance table, the per-role sections, the
dispatch list and the counts — is therefore maintained by hand against the
manifest, and `scripts/lint-doc-drift.mjs` fails the build when the role
names or the stated count here disagree with the manifest. The three
sections that are a cross-product of the role set are marked in place as an
unregenerated snapshot, because they cannot be maintained by hand.

## What this is

An operating system for agents working in this project: **20 roles**,
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
| **batch-reviewer** | Approver: reviews a batch of composed specs and records the batch verdict in tests/e2e/docs/onboarding-status.json. | `docs/**`<br>`tests/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **cleanup** | Cleanup / dedup worker for the coverage-expansion cleanup pass (`cleanup-<scope>:`): removes redundant specs under tests/e2e/** and re-runs the suite to prove the remainder is still green. | `docs/**`<br>`tests/**` | `tests/e2e/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **companion** | companion-mode verification worker (`companion-<task-slug>:`): verifies one task against the live app in its own playwright-cli session and lands the evidence bundle under tests/e2e/evidence/**. | `docs/**`<br>`tests/**` | `tests/e2e/evidence/**`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **contribution-handover** | Pre-push handover author (`contribution-handover-<slug>:`): fills .contribution-handover.json from the contributing skill's guardrail checklist by reading this repo's own documentation and the branch diff. | `.contribution-handover.template.json`<br>`README.md`<br>`docs/**`<br>`package.json`<br>`schemas/**`<br>`skills/**` | `.contribution-handover.json` | `^git status\b`<br>`^git log\b`<br>`^git diff\b` | — |
| **fd** | failure-diagnosis worker (`fd-<test-slug>:`, `fd-ci-<run-id>:`): reproduces one failing spec against the live app in its own playwright-cli session, classifies deterministic vs flaky, and lands the diagnosis plus any heal under tests/e2e/**. | `docs/**`<br>`tests/**` | `tests/e2e/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **in-flight-composer** | Same mandate as test-composer, for specs composed mid-pipeline (coverage-expansion passes, self-repair heals). | `docs/**`<br>`tests/**`<br>`tests/e2e/page-repository.json` | `tests/e2e/**` | `^npx playwright test\b` | — |
| **orchestrator**<br>*(main session)* | The main session driving the achilles QA pipeline: walks the app, records pipeline state under tests/** and .achilles/**, runs the suite, commits, and dispatches every subagent role. | `.achilles/**`<br>`.gitignore`<br>`README.md`<br>`docs/**`<br>`package.json`<br>`playwright.config.ts`<br>`tests/**` | `.achilles/**`<br>`.gitignore`<br>`tests/**` | `^npx playwright test --list\b`<br>`^git status\b`<br>`^git log\b`<br>`^git diff\b`<br>`^git add\b`<br>`^git commit\b`<br>`^npx playwright test\b`<br>`^npm test\b`<br>`^npm run test:repair\b`<br>`^npx playwright-cli (close-all\|kill-all\|list)\b` | `batch-reviewer`<br>`cleanup`<br>`companion`<br>`contribution-handover`<br>`fd`<br>`in-flight-composer`<br>`perf-reviewer`<br>`phase-validator`<br>`phase1`<br>`phase2`<br>`phase4`<br>`probe`<br>`process-validator`<br>`reviewer`<br>`scaffolder`<br>`selector-diff-validator`<br>`stage2`<br>`test-composer`<br>`workflow-reviewer` |
| **perf-reviewer** | Approver for the perf pipeline: reviews tests/perf/** deliverables and records the verdict in tests/perf/docs/perf-onboarding-status.json. | `docs/**`<br>`tests/perf/**` | `tests/perf/docs/perf-onboarding-status.json` | — | — |
| **phase-validator** | Approver: emits the per-phase greenlight into tests/e2e/docs/onboarding-status.json after checking the phase's deliverables on disk. | `docs/**`<br>`tests/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **phase1** | journey-mapping Phase 1 discovery worker (`phase1-<entry>:`): crawls one entry-point subtree in its own playwright-cli session and returns the page + element list. | `docs/**`<br>`tests/**` | `tests/e2e/docs/app-context.md`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **phase2** | journey-mapping Phase 2 flow-identification worker (`phase2-<scope>:`): walks one scope's flows in its own playwright-cli session and returns the flow list, appending only its discovery notes. | `docs/**`<br>`tests/**` | `tests/e2e/docs/app-context.md`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **phase4** | journey-mapping Phase 4 worker: `phase4-cycle-<N>:` section agents discover one section of the map in their own playwright-cli session, and `phase4-prioritise-author:` is the only legitimate author of tests/e2e/docs/journey-map.md and its `<!-- journey-mapping:generated -->` sentinel. | `docs/**`<br>`tests/**` | `tests/e2e/docs/.phase4-cycle-state.json`<br>`tests/e2e/docs/.subagent-returns/**`<br>`tests/e2e/docs/journey-map.md` | `^npx playwright-cli\b` | — |
| **probe** | Stage A adversarial prober (`probe-j-<slug>:` for coverage-expansion passes 4-5 and bug-discovery, `probe-app-wide:` for the pass-4 pattern scan): probes the live app in its own playwright-cli session, appends findings to tests/e2e/docs/adversarial-findings.md under the advisory lock, and in pass 5 writes regression specs for verified boundaries. | `docs/**`<br>`tests/**` | `tests/e2e/**` | `^npx playwright-cli\b`<br>`^npx playwright test\b` | — |
| **process-validator** | Approver: validates that the pipeline followed the documented process and records the finding in tests/e2e/docs/onboarding-status.json. | `docs/**`<br>`tests/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **reviewer** | Stage B in-loop reviewer (`reviewer-j-<slug>:` per journey, `reviewer-batch-pass-<N>:` for the cycle-1 compositional batch): reads Stage A's output and the live app in its own playwright-cli session and returns greenlight or improvements-needed. | `docs/**`<br>`tests/**` | `tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **scaffolder** | Write-only author of the Phase 1-2 scaffold: playwright.config.ts, package.json scripts, .gitignore entries, tests/e2e/playwright.setup.ts, tests/e2e/fixtures/**, tests/e2e/docs/app-context.md and tests/e2e/page-repository.json. | `.gitignore`<br>`README.md`<br>`docs/**`<br>`package.json`<br>`playwright.config.ts`<br>`tests/e2e/**` | `.gitignore`<br>`package.json`<br>`playwright.config.ts`<br>`tests/e2e/.gitignore`<br>`tests/e2e/docs/app-context.md`<br>`tests/e2e/fixtures/**`<br>`tests/e2e/page-repository.json`<br>`tests/e2e/playwright.setup.ts` | — | — |
| **selector-diff-validator** | Read-only validator: compares selector changes across tests/** and reports. | `tests/**` | — | — | — |
| **stage2** | Stage 2 element-inspection worker (`stage2-<scenario>:`): inspects the pages of one approved scenario in its own playwright-cli session and RETURNS proposed page-repository entries — the page repository itself stays the scaffolder's file. | `docs/**`<br>`tests/**` | `tests/e2e/.auth/**`<br>`tests/e2e/docs/.subagent-returns/**` | `^npx playwright-cli\b` | — |
| **test-composer** | Authors Playwright specs under tests/e2e/** from a journey brief and self-verifies them with the runner. | `docs/**`<br>`tests/**`<br>`tests/e2e/page-repository.json` | `tests/e2e/**` | `^npx playwright test\b` | — |
| **workflow-reviewer** | Approver: reviews a phase's deliverables against the ledger and records the verdict in tests/e2e/docs/onboarding-status.json. | `docs/**`<br>`tests/**` | `tests/e2e/docs/onboarding-status.json` | — | — |

## Each role, and what it is refused

### `batch-reviewer`

Approver: reviews a batch of composed specs and records the batch verdict in tests/e2e/docs/onboarding-status.json. Reads only; no shell.

- **Binds when** the host dispatches an agent of type `batch-reviewer`, or when the brief carries `<<kernel-mandate-role: batch-reviewer#<nonce>>>` and the description begins `batch-reviewer-<slug>:`.
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
- see what `batch-reviewer` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `cleanup` writes (`tests/e2e/**`)
- see what `companion` writes (`tests/e2e/evidence/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `fd` writes (`tests/e2e/**`)
- see what `in-flight-composer` writes (`tests/e2e/**`)
- see what `perf-reviewer` writes (`tests/perf/docs/perf-onboarding-status.json`)
- see what `phase-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `phase1` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase2` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase4` writes (`tests/e2e/docs/.phase4-cycle-state.json`, `tests/e2e/docs/.subagent-returns/**`, `tests/e2e/docs/journey-map.md`)
- see what `probe` writes (`tests/e2e/**`)
- see what `process-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `reviewer` writes (`tests/e2e/docs/.subagent-returns/**`)
- see what `stage2` writes (`tests/e2e/.auth/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `test-composer` writes (`tests/e2e/**`)
- see what `workflow-reviewer` writes (`tests/e2e/docs/onboarding-status.json`)

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

### `in-flight-composer`

Same mandate as test-composer, for specs composed mid-pipeline (coverage-expansion passes, self-repair heals).

- **Binds when** the host dispatches an agent of type `in-flight-composer`, or when the brief carries `<<kernel-mandate-role: in-flight-composer#<nonce>>>` and the description begins `in-flight-composer-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`, `tests/e2e/page-repository.json`
- **Writes** `tests/e2e/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright test\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `database-testing`, `selector-development`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `orchestrator` — the main session

The main session driving the achilles QA pipeline: walks the app, records pipeline state under tests/** and .achilles/**, runs the suite, commits, and dispatches every subagent role. It authors no runner or resolution config — playwright.config.ts, package.json and the Phase 1-2 scaffold (fixtures, setup, page repository, app context) are written by the scaffolder role it dispatches. Never touches application source or secrets.

- **Binds when** the host dispatches an agent of type `orchestrator`, or when the brief carries `<<kernel-mandate-role: orchestrator#<nonce>>>` and the description begins `orchestrator-<slug>:`.
- **Tools** `Agent`, `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `.achilles/**`, `.gitignore`, `README.md`, `docs/**`, `package.json`, `playwright.config.ts`, `tests/**`
- **Writes** `.achilles/**`, `.gitignore`, `tests/**`
- **Authored code may import** **nothing by name** (relative imports inside its own scope still work)
- **Runs** `^npx playwright test --list\b`, `^git status\b`, `^git log\b`, `^git diff\b`, `^git add\b`, `^git commit\b`, `^npx playwright test\b`, `^npm test\b`, `^npm run test:repair\b`, `^npx playwright-cli (close-all|kill-all|list)\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost:3000`, `localhost:4173`
- **Skills** `achilles-protocol`, `agents-vs-agents`, `bug-discovery`, `bug-report`, `companion-mode`, `contract-testing`, `contributing-to-achilles-protocol`, `coverage-expansion`, `database-testing`, `failure-diagnosis`, `journey-mapping`, `mandate-designer`, `onboarding`, `perf-onboarding`, `performance-testing`, `secrets-sweep`, `selector-development`, `self-repair`, `test-catalogue`, `test-composer`, `test-data-conventions`, `test-repair`, `ticket-driven-testing`, `work-summary-deck`, `workflow-reviewer`
- **Dispatches** `batch-reviewer`, `cleanup`, `companion`, `contribution-handover`, `fd`, `in-flight-composer`, `perf-reviewer`, `phase-validator`, `phase1`, `phase2`, `phase4`, `probe`, `process-validator`, `reviewer`, `scaffolder`, `selector-diff-validator`, `stage2`, `test-composer`, `workflow-reviewer`

**May not** 
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `perf-reviewer`

Approver for the perf pipeline: reviews tests/perf/** deliverables and records the verdict in tests/perf/docs/perf-onboarding-status.json. Reads only; no shell.

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
- see what `batch-reviewer` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `cleanup` writes (`tests/e2e/**`)
- see what `companion` writes (`tests/e2e/evidence/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `contribution-handover` writes (`.contribution-handover.json`)
- see what `fd` writes (`tests/e2e/**`)
- see what `in-flight-composer` writes (`tests/e2e/**`)
- see what `phase-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `phase1` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase2` writes (`tests/e2e/docs/app-context.md`, `tests/e2e/docs/.subagent-returns/**`)
- see what `phase4` writes (`tests/e2e/docs/.phase4-cycle-state.json`, `tests/e2e/docs/.subagent-returns/**`, `tests/e2e/docs/journey-map.md`)
- see what `probe` writes (`tests/e2e/**`)
- see what `process-validator` writes (`tests/e2e/docs/onboarding-status.json`)
- see what `reviewer` writes (`tests/e2e/docs/.subagent-returns/**`)
- see what `scaffolder` writes (`.gitignore`, `package.json`, `playwright.config.ts`, `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts`)
- see what `stage2` writes (`tests/e2e/.auth/**`, `tests/e2e/docs/.subagent-returns/**`)
- see what `test-composer` writes (`tests/e2e/**`)
- see what `workflow-reviewer` writes (`tests/e2e/docs/onboarding-status.json`)

### `phase-validator`

Approver: emits the per-phase greenlight into tests/e2e/docs/onboarding-status.json after checking the phase's deliverables on disk. Reads only; no shell.

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

Approver: validates that the pipeline followed the documented process and records the finding in tests/e2e/docs/onboarding-status.json. Reads only; no shell.

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

Write-only author of the Phase 1-2 scaffold: playwright.config.ts, package.json scripts, .gitignore entries, tests/e2e/playwright.setup.ts, tests/e2e/fixtures/**, tests/e2e/docs/app-context.md and tests/e2e/page-repository.json. No shell and no dispatch — the orchestrator runs `npx playwright test --list` to verify what it wrote, so the role that authors the runner's config never runs the runner.

- **Binds when** the host dispatches an agent of type `scaffolder`, or when the brief carries `<<kernel-mandate-role: scaffolder#<nonce>>>` and the description begins `scaffolder-<slug>:`.
- **Tools** `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `.gitignore`, `README.md`, `docs/**`, `package.json`, `playwright.config.ts`, `tests/e2e/**`
- **Writes** `.gitignore`, `package.json`, `playwright.config.ts`, `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts`
- **Skills** `achilles-protocol`

**May not** 
- use `Agent`, `Bash`
- run any shell command
- dispatch any subagent
- reach any network destination
- see what `contribution-handover` writes (`.contribution-handover.json`)
- see what `perf-reviewer` writes (`tests/perf/docs/perf-onboarding-status.json`)

### `selector-diff-validator`

Read-only validator: compares selector changes across tests/** and reports. Writes nothing; no shell.

- **Binds when** the host dispatches an agent of type `selector-diff-validator`, or when the brief carries `<<kernel-mandate-role: selector-diff-validator#<nonce>>>` and the description begins `selector-diff-validator-<slug>:`.
- **Tools** `Glob`, `Grep`, `Read`
- **Reads** `tests/**`
- **Writes** —

**May not** 
- use `Agent`, `Bash`, `Edit`, `Skill`, `Write`
- write any file — it has no write grants
- run any shell command
- dispatch any subagent
- reach any network destination
- invoke any skill
- see what `contribution-handover` writes (`.contribution-handover.json`)

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

### `test-composer`

Authors Playwright specs under tests/e2e/** from a journey brief and self-verifies them with the runner. Reads the page repository and docs; writes nothing outside tests/e2e/**.

- **Binds when** the host dispatches an agent of type `test-composer`, or when the brief carries `<<kernel-mandate-role: test-composer#<nonce>>>` and the description begins `test-composer-<slug>:`.
- **Tools** `Bash`, `Edit`, `Glob`, `Grep`, `Read`, `Skill`, `Write`
- **Reads** `docs/**`, `tests/**`, `tests/e2e/page-repository.json`
- **Writes** `tests/e2e/**`
- **Authored code may import** `@civitas-cerebrum/element-interactions`, `@playwright/test`
- **Runs** `^npx playwright test\b` — anchored patterns; a command that does not match is refused.
- **Reaches** `localhost`
- **Skills** `achilles-protocol`, `database-testing`, `selector-development`, `test-composer`, `test-data-conventions`

**May not** 
- use `Agent`
- dispatch any subagent
- see what `contribution-handover` writes (`.contribution-handover.json`)

### `workflow-reviewer`

Approver: reviews a phase's deliverables against the ledger and records the verdict in tests/e2e/docs/onboarding-status.json. Reads only; no shell.

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

## Handover contracts

Work changes hands through the filesystem: one role writes a path,
another reads it. Every row below is a contract the kernel enforces from
both ends — the writer may write it, the reader may read it, and no one
else can do either.

> **Snapshot of the upstream render — not regenerated here.** This table
> is a cross-product of the role set and cannot be maintained by hand. The
> rows below are the output of `kernel-mandate doc` as committed in
> `78ffa90` ("Ship the role ledger with the QA mandate"), rendered from a
> manifest of 10 roles. The manifest now declares 20, and the handovers
> involving the 10 roles added since are missing here.

| from | to | what changes hands |
|---|---|---|
| `batch-reviewer` | `in-flight-composer` | `tests/e2e/docs/onboarding-status.json` |
| `batch-reviewer` | `orchestrator` | `tests/e2e/docs/onboarding-status.json` |
| `batch-reviewer` | `phase-validator` | `tests/e2e/docs/onboarding-status.json` |
| `batch-reviewer` | `process-validator` | `tests/e2e/docs/onboarding-status.json` |
| `batch-reviewer` | `scaffolder` | `tests/e2e/docs/onboarding-status.json` |
| `batch-reviewer` | `selector-diff-validator` | `tests/e2e/docs/onboarding-status.json` |
| `batch-reviewer` | `test-composer` | `tests/e2e/docs/onboarding-status.json` |
| `batch-reviewer` | `workflow-reviewer` | `tests/e2e/docs/onboarding-status.json` |
| `in-flight-composer` | `batch-reviewer` | `tests/e2e/**` |
| `in-flight-composer` | `orchestrator` | `tests/e2e/**` |
| `in-flight-composer` | `phase-validator` | `tests/e2e/**` |
| `in-flight-composer` | `process-validator` | `tests/e2e/**` |
| `in-flight-composer` | `scaffolder` | `tests/e2e/**` |
| `in-flight-composer` | `selector-diff-validator` | `tests/e2e/**` |
| `in-flight-composer` | `test-composer` | `tests/e2e/**` |
| `in-flight-composer` | `workflow-reviewer` | `tests/e2e/**` |
| `orchestrator` | `batch-reviewer` | `tests/**` |
| `orchestrator` | `in-flight-composer` | `tests/**` |
| `orchestrator` | `perf-reviewer` | `tests/**` |
| `orchestrator` | `phase-validator` | `tests/**` |
| `orchestrator` | `process-validator` | `tests/**` |
| `orchestrator` | `scaffolder` | `.gitignore`, `tests/**` |
| `orchestrator` | `selector-diff-validator` | `tests/**` |
| `orchestrator` | `test-composer` | `tests/**` |
| `orchestrator` | `workflow-reviewer` | `tests/**` |
| `perf-reviewer` | `batch-reviewer` | `tests/perf/docs/perf-onboarding-status.json` |
| `perf-reviewer` | `in-flight-composer` | `tests/perf/docs/perf-onboarding-status.json` |
| `perf-reviewer` | `orchestrator` | `tests/perf/docs/perf-onboarding-status.json` |
| `perf-reviewer` | `phase-validator` | `tests/perf/docs/perf-onboarding-status.json` |
| `perf-reviewer` | `process-validator` | `tests/perf/docs/perf-onboarding-status.json` |
| `perf-reviewer` | `selector-diff-validator` | `tests/perf/docs/perf-onboarding-status.json` |
| `perf-reviewer` | `test-composer` | `tests/perf/docs/perf-onboarding-status.json` |
| `perf-reviewer` | `workflow-reviewer` | `tests/perf/docs/perf-onboarding-status.json` |
| `phase-validator` | `batch-reviewer` | `tests/e2e/docs/onboarding-status.json` |
| `phase-validator` | `in-flight-composer` | `tests/e2e/docs/onboarding-status.json` |
| `phase-validator` | `orchestrator` | `tests/e2e/docs/onboarding-status.json` |
| `phase-validator` | `process-validator` | `tests/e2e/docs/onboarding-status.json` |
| `phase-validator` | `scaffolder` | `tests/e2e/docs/onboarding-status.json` |
| `phase-validator` | `selector-diff-validator` | `tests/e2e/docs/onboarding-status.json` |
| `phase-validator` | `test-composer` | `tests/e2e/docs/onboarding-status.json` |
| `phase-validator` | `workflow-reviewer` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `batch-reviewer` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `in-flight-composer` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `orchestrator` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `phase-validator` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `scaffolder` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `selector-diff-validator` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `test-composer` | `tests/e2e/docs/onboarding-status.json` |
| `process-validator` | `workflow-reviewer` | `tests/e2e/docs/onboarding-status.json` |
| `scaffolder` | `batch-reviewer` | `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `scaffolder` | `in-flight-composer` | `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `scaffolder` | `orchestrator` | `.gitignore`, `package.json`, `playwright.config.ts`, `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `scaffolder` | `phase-validator` | `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `scaffolder` | `process-validator` | `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `scaffolder` | `selector-diff-validator` | `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `scaffolder` | `test-composer` | `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `scaffolder` | `workflow-reviewer` | `tests/e2e/.gitignore`, `tests/e2e/docs/app-context.md`, `tests/e2e/fixtures/**`, `tests/e2e/page-repository.json`, `tests/e2e/playwright.setup.ts` |
| `test-composer` | `batch-reviewer` | `tests/e2e/**` |
| `test-composer` | `in-flight-composer` | `tests/e2e/**` |
| `test-composer` | `orchestrator` | `tests/e2e/**` |
| `test-composer` | `phase-validator` | `tests/e2e/**` |
| `test-composer` | `process-validator` | `tests/e2e/**` |
| `test-composer` | `scaffolder` | `tests/e2e/**` |
| `test-composer` | `selector-diff-validator` | `tests/e2e/**` |
| `test-composer` | `workflow-reviewer` | `tests/e2e/**` |
| `workflow-reviewer` | `batch-reviewer` | `tests/e2e/docs/onboarding-status.json` |
| `workflow-reviewer` | `in-flight-composer` | `tests/e2e/docs/onboarding-status.json` |
| `workflow-reviewer` | `orchestrator` | `tests/e2e/docs/onboarding-status.json` |
| `workflow-reviewer` | `phase-validator` | `tests/e2e/docs/onboarding-status.json` |
| `workflow-reviewer` | `process-validator` | `tests/e2e/docs/onboarding-status.json` |
| `workflow-reviewer` | `scaffolder` | `tests/e2e/docs/onboarding-status.json` |
| `workflow-reviewer` | `selector-diff-validator` | `tests/e2e/docs/onboarding-status.json` |
| `workflow-reviewer` | `test-composer` | `tests/e2e/docs/onboarding-status.json` |

### Dispatch

A dispatch is the other handover. It binds only when the brief says which
role is being summoned, in this grammar:

```
description:  <role>-<slug>: <one line of task>
brief line 1: <<kernel-mandate-role: <role>#<nonce>>>
subagent_type: <role>            (when the host supplies agent types)
```

The nonce is fresh per dispatch. A brief without the tag, or naming a role
the dispatcher may not summon, is refused at the `Agent` call — before the
child exists.

- `orchestrator` may summon `batch-reviewer`, `cleanup`, `companion`, `contribution-handover`, `fd`, `in-flight-composer`, `perf-reviewer`, `phase-validator`, `phase1`, `phase2`, `phase4`, `probe`, `process-validator`, `reviewer`, `scaffolder`, `selector-diff-validator`, `stage2`, `test-composer`, `workflow-reviewer`

## The workflow

Each box is a stage: what happens, and the role that holds it. The
thick arrows are the phase order the driving session moves through;
plain arrows are dispatches; dotted arrows are handovers, labelled with
the path that changes hands: where the work goes next, and where a
result returns to the stage that dispatched it. The table below carries
every path in full.

> **Snapshot of the upstream render — not regenerated here.** The
> flowchart's handover arrows are a cross-product of the role set and
> cannot be drawn by hand. The diagram and the stage table below are the
> output of `kernel-mandate doc` as committed in `78ffa90` ("Ship the role
> ledger with the QA mandate"), rendered from a manifest of 10 roles. The
> 10 roles added since hold no stage in it.

```mermaid
flowchart TD
  n_s_scaffold["scaffold<br><i>orchestrator</i>"]
  n_s_scaffold_suite["scaffold-suite<br><i>scaffolder</i>"]
  n_s_drive_pipeline["drive-pipeline<br><i>orchestrator</i>"]
  n_s_compose["compose<br><i>test-composer</i>"]
  n_s_compose_in_flight["compose-in-flight<br><i>in-flight-composer</i>"]
  n_s_review_phase["review-phase<br><i>workflow-reviewer</i>"]
  n_s_validate_phase["validate-phase<br><i>phase-validator</i>"]
  n_s_validate_process["validate-process<br><i>process-validator</i>"]
  n_s_review_batch["review-batch<br><i>batch-reviewer</i>"]
  n_s_review_perf["review-perf<br><i>perf-reviewer</i>"]
  n_s_validate_selectors["validate-selectors<br><i>selector-diff-validator</i>"]
  n_s_scaffold ==> n_s_drive_pipeline
  n_s_scaffold -- dispatch --> n_s_scaffold_suite
  n_s_drive_pipeline -- dispatch --> n_s_scaffold_suite
  n_s_drive_pipeline -- dispatch --> n_s_compose
  n_s_drive_pipeline -- dispatch --> n_s_compose_in_flight
  n_s_drive_pipeline -- dispatch --> n_s_review_phase
  n_s_drive_pipeline -- dispatch --> n_s_validate_phase
  n_s_drive_pipeline -- dispatch --> n_s_validate_process
  n_s_drive_pipeline -- dispatch --> n_s_review_batch
  n_s_drive_pipeline -- dispatch --> n_s_review_perf
  n_s_drive_pipeline -- dispatch --> n_s_validate_selectors
  n_s_scaffold_suite -. "tests/e2e/.gitignore +4" .-> n_s_drive_pipeline
  n_s_scaffold_suite -. "playwright.config.ts +7" .-> n_s_scaffold
  n_s_compose -. "tests/e2e/**" .-> n_s_compose_in_flight
  n_s_compose -. "tests/e2e/**" .-> n_s_drive_pipeline
  n_s_compose_in_flight -. "tests/e2e/**" .-> n_s_review_phase
  n_s_compose_in_flight -. "tests/e2e/**" .-> n_s_drive_pipeline
  n_s_review_phase -. "tests/e2e/docs/onboarding-status.json" .-> n_s_validate_phase
  n_s_review_phase -. "tests/e2e/docs/onboarding-status.json" .-> n_s_drive_pipeline
  n_s_validate_phase -. "tests/e2e/docs/onboarding-status.json" .-> n_s_validate_process
  n_s_validate_phase -. "tests/e2e/docs/onboarding-status.json" .-> n_s_drive_pipeline
  n_s_validate_process -. "tests/e2e/docs/onboarding-status.json" .-> n_s_review_batch
  n_s_validate_process -. "tests/e2e/docs/onboarding-status.json" .-> n_s_drive_pipeline
  n_s_review_batch -. "tests/e2e/docs/onboarding-status.json" .-> n_s_validate_selectors
  n_s_review_batch -. "tests/e2e/docs/onboarding-status.json" .-> n_s_drive_pipeline
  n_s_review_perf -. "tests/perf/docs/perf-onboarding-status.json" .-> n_s_validate_selectors
  n_s_review_perf -. "tests/perf/docs/perf-onboarding-status.json" .-> n_s_drive_pipeline
```

| stage | role | reads | writes | runs | dispatches |
|---|---|---|---|---|---|
| **scaffold** | `orchestrator` | `tests/**`<br>`docs/**`<br>`package.json`<br>`playwright.config.ts`<br>`.gitignore`<br>`README.md`<br>`.achilles/**` | `tests/**`<br>`.gitignore`<br>`.achilles/**` | `npx playwright test --list`<br>`git status`<br>`git log`<br>`git diff`<br>`git add`<br>`git commit` | `scaffolder` |
| **scaffold-suite** | `scaffolder` | `tests/e2e/**`<br>`docs/**`<br>`package.json`<br>`playwright.config.ts`<br>`.gitignore`<br>`README.md` | `playwright.config.ts`<br>`package.json`<br>`.gitignore`<br>`tests/e2e/.gitignore`<br>`tests/e2e/playwright.setup.ts`<br>`tests/e2e/fixtures/**`<br>`tests/e2e/docs/app-context.md`<br>`tests/e2e/page-repository.json` | — | — |
| **drive-pipeline** | `orchestrator` | `tests/**`<br>`docs/**`<br>`.achilles/**` | `tests/**`<br>`.achilles/**` | `npx playwright test`<br>`npm test`<br>`npm run test:repair` | `scaffolder`<br>`test-composer`<br>`in-flight-composer`<br>`workflow-reviewer`<br>`phase-validator`<br>`process-validator`<br>`batch-reviewer`<br>`perf-reviewer`<br>`selector-diff-validator` |
| **compose** | `test-composer` | `tests/**`<br>`docs/**`<br>`tests/e2e/page-repository.json` | `tests/e2e/**` | `npx playwright test` | — |
| **compose-in-flight** | `in-flight-composer` | `tests/**`<br>`docs/**`<br>`tests/e2e/page-repository.json` | `tests/e2e/**` | `npx playwright test` | — |
| **review-phase** | `workflow-reviewer` | `tests/**`<br>`docs/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **validate-phase** | `phase-validator` | `tests/**`<br>`docs/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **validate-process** | `process-validator` | `tests/**`<br>`docs/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **review-batch** | `batch-reviewer` | `tests/**`<br>`docs/**` | `tests/e2e/docs/onboarding-status.json` | — | — |
| **review-perf** | `perf-reviewer` | `tests/perf/**`<br>`docs/**` | `tests/perf/docs/perf-onboarding-status.json` | — | — |
| **validate-selectors** | `selector-diff-validator` | `tests/**` | — | — | — |

## Review loops

A loop is where work comes back for another pass: a verdict lands, the
role that planned the work reads it, and the work is dispatched again.
These are the loops this OS allows — anything else is a straight line.

> **Snapshot of the upstream render — not regenerated here.** Both the
> enumerated loops and the "191 longer loops" count are a cross-product of
> the role set and cannot be recomputed by hand. They are the output of
> `kernel-mandate doc` as committed in `78ffa90` ("Ship the role ledger
> with the QA mandate"), rendered from a manifest of 10 roles. With 20
> roles declared, both the list and the count are understatements.

- `batch-reviewer` → `in-flight-composer` → `batch-reviewer`
- `batch-reviewer` → `orchestrator` → `batch-reviewer`
- `batch-reviewer` → `phase-validator` → `batch-reviewer`
- `batch-reviewer` → `process-validator` → `batch-reviewer`
- `batch-reviewer` → `scaffolder` → `batch-reviewer`
- `batch-reviewer` → `test-composer` → `batch-reviewer`
- `batch-reviewer` → `workflow-reviewer` → `batch-reviewer`
- `in-flight-composer` → `orchestrator` → `in-flight-composer`
- `in-flight-composer` → `phase-validator` → `in-flight-composer`
- `in-flight-composer` → `process-validator` → `in-flight-composer`

(191 longer loops exist, each a composition of the ones above.)

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
- **Runtime behaviour of authored code.** The import and capability screens read the text a role writes; they are not a sandbox.

