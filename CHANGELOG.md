# Changelog

## 0.1.8 — unreleased

Achilles becomes a harness-neutral methodology (skills, agents, schemas, CLIs, reporter) with one Claude Code adapter. The main session is never bound; QA work runs in a separate orchestrator agent. Hooks advise by default and deny only irreversible or dangerous actions.

### Removed

- **The role kernel.** `kernel-mandate-role-gate`, `lib/kernel-mandate.sh`, the staged `achilles-qa.kernel-mandate.{json,md}` (23 roles), `scripts/kernel-mandate.lock.json`, `sync-kernel-mandate.mjs`, `build-agents.mjs` and the lints that compared them. Role scope is now the agent definition's tools and path lists.
- **Session activation.** `achilles-protocol-activation-watcher`, `achilles-kernel-activation-gate`, `lib/achilles-activation.sh`, the activation banner in 23 skills, `ACHILLES_PROTOCOL`, `KERNEL_MANDATE` and the negative cache. Nothing activates; the orchestrator agent is dispatched or it is not.
- **The dispatch-prefix grammar.** `<role>-<slug>:` descriptions and the `<<kernel-mandate-role: ROLE#nonce>>` brief line. Experts are dispatched by agent type (`achilles-inspector`, `achilles-author`, `achilles-reviewer`, `achilles-doc-writer`) with a brief file path.
- **The bash hook runtime**: all 48 hooks (41 under `hooks/`, 7 factory gates under `hooks/factory/`), `hooks/lib/`, `hooks/data/`, the validator bundle, the hook manifest and the bundled `jq`: 15,136 lines of shell in 66 files, plus 11,748 lines of bash test cases in 58 files. The behaviours that survive are the eight hooks in the adapter (see Added); their cases became 246 kit tests (253 with progress); six specs for behaviours not ported stay under `claude-code/tests/specs/` with the reason in its README.
- **Install copying.** Postinstall no longer writes `.claude/hooks/`, `.claude/skills/`, `.claude/agents/`, `.claude/settings.json` hook registrations, `kernel-mandate.json`, the install record `achilles-install.json`, the user-level routing skill `~/.claude/skills/achilles/` or the jq binary. `scripts/install/{record,skills,agents,hooks,user-trigger,mandate,jq}.js` and `scripts/sync-hooks.js` are gone; `scripts/install/chromium.js` stays.
- **`achilles-uninstall`.** There is nothing recorded to reverse. Uninstall is `claude plugin uninstall achilles`, or deleting the plugin entry postinstall merged into the settings file.
- **The 22 generated agents** (`cleanup`, `companion`, `contribution-handover`, `doc-author`, `fd`, `implementer`, `live-inspector`, `perf-reviewer`, `phase-validator`, `phase1`, `phase2`, `phase4`, `probe`, `process-validator`, `reviewer`, `scaffolder`, `secrets-sweep`, `stage2`, `task-reviewer`, `test-composer`, `verifier`, `workflow-reviewer`) and their return schemas `phase-validator` and `contribution-handover`.
- **Nine skills merged away** (25 → 16 directories, 20,617 → 10,651 lines):
  - `achilles-protocol` → `achilles-orchestrator` (routing table, preflight, contracts; its references move with it)
  - `onboarding` → `achilles-orchestrator/workflows/onboard.md`
  - `coverage-expansion` → `achilles-orchestrator/workflows/expand-coverage.md` and `references/pass-pipeline.md`
  - `test-repair` and `self-repair` → `achilles-orchestrator/workflows/repair-suite.md`
  - `ticket-driven-testing` → `achilles-orchestrator/workflows/verify-change.md` and `references/verify-change/`
  - `perf-onboarding` → the pipeline section of `performance-testing`
  - `workflow-reviewer` → `review` (with the judge charter and the Stage B contract)
  - `test-catalogue` and `work-summary-deck` → `qa-reporting`
  - `companion-mode` → `evidence-capture`
  - `contributing-to-achilles-protocol` → `CONTRIBUTING.md` and `achilles-orchestrator/references/framework-gap.md`
  - `requirement-intake` → `achilles-orchestrator/references/scenario-block.md`
  - Dropped outright: `anti-rationalizations.md`, `process-validator-workflow.md`, the doctrine deck template, the vendored `element-interactions-api.md` (upstream owns it), `known-limits.md` (the limits that remain are in `docs/harness/claude-code.md`), the in-skill hook documentation, the in-skill user-approval gates, the `/compact` instructions and the tool-name phrasing (`Skill`, `TaskCreate`, `Read`, `MultiEdit`, `subagent_type`).
- The `./hooks/*` and `./scripts/postinstall.js` package exports; the `esbuild` and jq dependencies.

### Added

- **Claude Code plugin adapter** under `claude-code/`: the package root is the plugin root (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`), one hook module (`claude-code/hooks.ts`, declared in `claude-code/hooks.json`), shared libraries (shell parser, commit and spend classifiers, import-boundary, test-id and selector-diff scanners), data vocabularies and a spec suite. Install from the marketplace (`claude plugin marketplace add civitas-cerebrum/achilles`, `claude plugin install achilles@achilles`), from a checkout (`claude --plugin-dir .`) or through npm.
- **`delegate_qa`** tool and **`/achilles <task>`** command. Both start the `achilles-orchestrator` agent in the background and answer `RUNNING` plus a run id at once; progress shows in the status line and the Achilles pane; the hand-back is queued as a prompt of its own when the orchestrator's turn completes, so the main session reports it without the user typing.
- **Expert mode on pi** (`pi/index.ts`, declared in `package.json` under `pi.extensions`). `delegate_qa` and `/achilles <task>` run the orchestrator in its own `pi` process; the orchestrator gets an `Agent` tool shaped like Claude Code's and dispatches each expert into a process of its own. Every process is set up from the same `agents/achilles-<role>.md` (prompt, tools mapped to pi's, preloaded skills), so the skills read the same on both harnesses and a new `achilles-<role>` file is a new expert on both. The main session gets no `Agent` tool and experts dispatch nobody. The orchestrator's and experts' processes run the Claude Code adapter's Bash judge and secrets screen as pi guards (`pi/guards.ts`), and `npm install` registers the package with pi when `pi` is on PATH (`ACHILLES_SKIP_PI_REGISTRATION=1` skips it). A `bash` call an Achilles agent makes with no timeout gets 600 s on pi (`ACHILLES_PI_BASH_TIMEOUT`), where pi has no default: one hung command stalled a whole onboarding for four hours. An orchestrator or expert process exits when its parent is gone (a parent killed by a signal runs no `session_shutdown`). The judge's helpers moved to `claude-code/hooks/io.ts` and its Claude Code registration to `bash-hook.ts`, so it loads outside Claude Code.
- **Thinking effort per role.** `agents/achilles-{inspector,author,doc-writer}.md` set `effort: medium`; the orchestrator and the reviewer (the judge) set none and take the session's. Claude Code registers the agents with that effort; pi passes it as `--thinking`, and the parent's level to the roles without one.
- **Resume by run id.** `delegate_qa` takes an optional `run` and `/achilles` takes `resume <run-id> [notes]`, on Claude Code and on pi: the run keeps its id and `.achilles/runs/<id>/` directory and the orchestrator is told to read its `resume.json` first. Without it every delegation made a new run, and a resume depended on the task text. A run with no `resume.json`, a malformed id or one still running is refused. On pi, an orchestrator or expert process that cannot start now hands back `BLOCKED` instead of never answering.
- **Run progress.** The adapter tracks each run's stages (the phases of the pipeline ledger it writes, else a `plan` in its `resume.json`), the experts at work and the ones that handed back. The status line names the stage and the experts by brief, the pane draws a stage checklist, `.achilles/runs/<run-id>/progress.json` holds it all for the main session to read, and a stage that ends while stages remain queues a short progress prompt for the main session to relay.
- **`achilles-orchestrator` skill** with seven workflows (`author-scenario`, `onboard`, `map-journeys`, `expand-coverage`, `hunt-bugs`, `repair-suite`, `verify-change`): routing table with entry conditions, preflight (cascade level, resume files, tooling, questions), dispatch contract (briefs and reports as files, role → agent → skill table, concurrency, fresh reviewer), worker return contract, upward hand-back contract (`DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, `BLOCKED`), ten scope rules, one verification bar, state and commit discipline.
- **Five hand-authored agents** under `agents/`: `achilles-orchestrator`, `achilles-inspector`, `achilles-author`, `achilles-reviewer`, `achilles-doc-writer`, each with its tool list and path scope in prose. The adapter registers them from these files at session start; a bare `achilles-<role>` type is rewritten to the plugin-qualified one.
- **Eight hooks** (one TypeScript module on a shared parsed-command model), contract in `docs/harness/claude-code.md`: Bash judge, pipeline ledger model, sign-off, dispatch discipline, return review, spec hygiene, selector development, reporting. The denies: commit bypass flags, AI attribution in commits and PRs, `k6` ceilings and production targets, `git push --force`, `rm -rf` outside the project, credential shapes in committed files, sign-off without a reviewer receipt and bundle or with a live credential in the bundle, and a non-inert selector edit. Everything else is advice or a rewrite. `ACHILLES_DISABLE=1` and the `git push --force` / `rm -rf` denies ship with the adapter today; the remaining hooks land with the hook port on this branch.
- **`docs/harness/`**: `claude-code.md` (install, how a task runs, agent scopes, the hook table, switches, limits) and `pi.md`. Harness vocabulary lives there and nowhere under `skills/`.
- **`CONTRIBUTING.md`**: the methodology/adapter split, duplicate-search and upstream-diff steps, commit conventions (no AI attribution trailers), the lint and the PR checklist.
- **pi**: `"pi": { "skills": ["./skills"] }` in `package.json`, keyword `pi-package`; `pi install npm:@civitas-cerebrum/achilles` loads the skills. Postinstall prints the command when `pi` is on PATH.
- **`ACHILLES_DISABLE=1`**: the adapter's kill switch for new sessions. **`ACHILLES_SKIP_CLAUDE_REGISTRATION=1`** skips the plugin registration at install; **`ACHILLES_REQUIRE_CLAUDE=1`** makes a missing `claude` CLI fail that step in CI.
- Schemas: `factory-rules.schema.json` and `canonical-sections.txt` move from `hooks/data/` to `schemas/`.
- `npm test` runs five suites (schemas, doc lint, CLIs, reporter, adapter) through `scripts/run-suites.mjs`; `test:adapter` validates the plugin with `--strict` and runs its spec suite.

### Changed

- **No activation banner.** A session starts clean; nothing scans the transcript, nothing writes under `.achilles/` until a run starts.
- **Questions arrive as `NEEDS_CONTEXT` hand-backs**, all at once, after the run has committed what landed and written `.achilles/runs/<run-id>/resume.json`. Answering in the chat re-dispatches the orchestrator, which resumes from the file. No skill asks the user mid-run.
- **Session slugs** for `playwright-cli -s=<slug>` name the journey without its `j-` prefix (`composer-<slug>-3-c1`, not `composer-j-<slug>-3-c1`); the Bash judge rewrites a missing or malformed slug from the agent id instead of refusing the call.
- **Hooks advise instead of deny**, except the eight denies listed under Added. Phase order, ledger transitions, brief shape, return shape, test ids, import boundaries and the evidence floor are reported as advice and caught by the review dispatch, not refused at the tool boundary. Separation of duties comes from agent scope.
- **The installer registers the plugin instead of writing `.claude/`.** A local install merges `extraKnownMarketplaces.achilles` (a directory marketplace pointing at `node_modules/@civitas-cerebrum/achilles`) and `enabledPlugins["achilles@achilles"]` into the project's `.claude/settings.local.json`; `-g` writes `~/.claude/settings.json`. Where `claude` 2.1.287 or later is on PATH the CLI makes the same registration. The merge is add-only and leaves an unparsable file alone. An upgrade needs nothing: the plugin is read from its folder.
- The orchestrator dispatches experts with the ordinary Agent tool, in the foreground, and reads their report files, never their transcripts. Nesting is main → orchestrator → expert; experts dispatch nobody.
- The reviewer is a fresh instance per review; `achilles-self-repair` dispatches its workers with `--worker` and the same report schema as the interactive repair workflow.
- Skill text is harness-neutral: no tool names, hook names, `.claude/` paths or dispatch grammar; `scripts/lint-doc-drift.mjs` enforces it (checks 1, 2, 5, 6, 8, 10, 11, 12, 14; checks 3, 4, 7, 9 and 13 left with the kernel and the bash runtime).
- Package description, keywords and `files` (now `bin`, `skills`, `agents`, `schemas`, `reporter`, `claude-code`, `.claude-plugin`, the postinstall and the Chromium step) follow the new layout. `docs/index.html` and `docs/agentic-qa.html` describe 0.1.8; the counts lint keeps their figures equal to the tree.

### Upgrading from 0.1.7 or a 0.2.0 branch install

The earlier installers copied the harness into `.claude/` (or `~/.claude/` for `-g`). 0.1.8 does not remove those copies, and the old hooks keep running until you do.

1. With the old package still installed, run `npx achilles-uninstall --project` (and `--global` if you installed with `-g` or had the user-level routing skill). 0.1.x had no uninstaller: continue with step 2.
2. By hand, in each `.claude/` directory Achilles wrote to (and `~/.claude/`): delete the 41 Achilles hook scripts under `hooks/` plus `hooks/factory/`, `hooks/lib/`, `hooks/data/` and `hooks/bin/jq`; the 25 copied skills under `skills/` (and `sql-client`); the 22 generated agents under `agents/`; `kernel-mandate.json`, `kernel-mandate.md`, `kernel-mandate.achilles.json`, `kernel-mandate.achilles-new.json`, `achilles-qa.kernel-mandate.json`; `achilles-install.json`; the routing skill `~/.claude/skills/achilles/` and `~/.claude/achilles-install.json`.
3. In `.claude/settings.json` (and `~/.claude/settings.json`), remove every `hooks` entry whose command points into `.claude/hooks/` or `~/.claude/hooks/`. Your own entries stay.
4. Install 0.1.8 (`npm i -D @civitas-cerebrum/achilles`, or the marketplace install) and restart Claude Code. Drop `ACHILLES_PROTOCOL`, `KERNEL_MANDATE`, `CIVITAS_SKIP_HOOK_INSTALL` and `CIVITAS_SKIP_JQ_INSTALL` from shells and CI; use `ACHILLES_SKIP_CLAUDE_REGISTRATION=1` where CI used `CIVITAS_SKIP_HOOK_INSTALL=1`.
5. Replace the old slash commands (`/onboarding`, `/coverage-expansion`, `/test-repair`, `/companion-mode`, …) with `/achilles <task>` or the `delegate_qa` tool. Projects with `achilles-factory-rules.json` keep it; the factory rules are read by the spec-hygiene hook and the CLIs.

## 0.2.0 — never published, superseded by 0.1.8

0.2.0 was never published to npm. Its kernel, activation, install-copying and uninstall items below are superseded by 0.1.8 and listed for anyone who installed it from a branch; the remaining items (CLIs, reporter behaviour, Bash parsing, mandate grants that became agent scopes) carried into 0.1.8 in their new form.

### Upgrading from 0.1.7 (superseded)

- **One-time overwrite.** 0.1.7 kept no install record. The first 0.2.0 install replaces every hook, hook library, hook data file and skill file in `.claude/` (for `-g`, in `~/.claude`) whose content differs from the package, including ones you edited. Postinstall prints how many files it replaced. From then on, a file you edit is never overwritten or pruned; postinstall warns once and leaves it.
- **Restart Claude Code** after the install to pick up the new hooks.
- **User-level copies.** A local install no longer copies skills and agents to `~/.claude`. It removes the copies an earlier recorded local install left there, unless you edited them, and names any unrecorded user-level skill with an Achilles name: 0.1.7 kept no record, and a user-level skill wins over the project's copy of the same name.
- **Staged mandate.** If `.claude/kernel-mandate.json` differs from what Achilles staged, it is left as it is and the new QA mandate is written beside it as `kernel-mandate.achilles-new.json`, with one notice. An unedited copy is refreshed.

### Added

- *(superseded)* Role kernel: while an Achilles skill is active, every tool call is checked against the QA mandate (23 roles), staged into `.claude/kernel-mandate.json`. Only the kernel runtime ships; the mandate-designer skill and the kernel's schemas do not.
- *(superseded)* Five change-loop roles: `live-inspector`, `implementer`, `task-reviewer`, `verifier`, `doc-author`, each with its own write scope and one hand-off path. A `doc-author` proposes changes to `CLAUDE.md` and skills as `docs/proposals/<topic>.md`. In 0.1.8 the verify-change workflow runs on the five agents.
- *(superseded)* Seven opt-in factory gates under `hooks/factory/`, active only when `achilles-factory-rules.json` exists in the project. In 0.1.8 the rule file is read by the spec-hygiene hook and the CLIs.
- *(superseded)* `achilles-import-boundary-gate` (static import screen on `tests/` and root config) and `achilles-multiedit-gate` (MultiEdit is refused while the protocol is active). The import boundary is advice in the spec-hygiene hook; the MultiEdit gate is gone.
- *(superseded)* Routing skill `~/.claude/skills/achilles`, the one file a local install writes user-level.
- *(superseded)* One generated agent definition per QA role, installed to `.claude/agents/`.
- CLIs: `achilles-scenario-lint`, `achilles-selector-evidence`; *(superseded)* `achilles-uninstall`.
- *(superseded)* `achilles-uninstall [--global | --project [dir]] [--dry-run]` removes what postinstall recorded.
- *(superseded)* Install record `achilles-install.json` in each `.claude/` directory Achilles installs into.
- Skill `requirement-intake` (now `references/scenario-block.md`); references for the controller protocol, verification record, known limits and opt-in surfaces (now the controller contract, the verification record and `docs/harness/claude-code.md`).

### Changed

- *(superseded)* Postinstall copies by content instead of file time; files a newer version no longer ships are pruned unless edited; install scope follows `-g`; a project install registers its hooks as `"$CLAUDE_PROJECT_DIR"/.claude/hooks/<file>`; postinstall runs for `npm install <folder>`. 0.1.8 copies nothing.
- Postinstall never exits non-zero: a failing step is a warning, since a failed `npm i -g` removed the package while leaving the harness behind. Kept in 0.1.8.
- *(superseded)* A session that never activated the protocol leaves no file behind; the transcript scan, the negative cache and the jq failure mode. There is no activation in 0.1.8.
- Bash guards split a command line with one shared parser and judge the primary ways an agent writes: redirects, `tee`, `cp`/`mv`/`rm`, `sed -i`, and `git checkout`/`restore`/`reset --hard`/`clean`/`rm` on protected paths. Obfuscated forms are out of scope. The parser carries into the adapter's Bash judge.
- *(superseded)* The bundled jq is checked against a pinned sha256; a PreToolUse call is denied when `jq` or a hook library is missing. No jq in 0.1.8.
- *(superseded)* Approval-class ledger writes must come from an approver `agent_type`; Phase 7 is dispatched as `secrets-sweep-phase7:` with `subagent_type: secrets-sweep`. Separation of duties is agent scope in 0.1.8; the dispatch grammar is gone.
- The package declares `"engines": { "node": ">=20" }` and its tarball no longer includes schema fixtures.
- *(superseded)* QA mandate grants: the `probe` role may author code that uses `network` and may run `mkdir`/`rmdir` on the findings lock; the Stage-4b roles may read the protocol references. These became the author agent's scope.
- Pass 5 commits one per journey, `test(<j-slug>-regression): lock <N> boundaries`, with one `lock <boundary>` line per lock in the body.
- The status ledgers accept `escalate`, the reviewer's verdict word, as the same verdict as `escalated-to-user`. Neither counts as approval, and either satisfies the 3-round reject cap.
