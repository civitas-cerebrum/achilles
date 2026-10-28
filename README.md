# Achilles

[![NPM Version](https://img.shields.io/npm/v/@civitas-cerebrum/achilles?color=rgb(88%2C%20171%2C%2070))](https://www.npmjs.com/package/@civitas-cerebrum/achilles)

## What

Achilles (`@civitas-cerebrum/achilles`, MIT) is a QA methodology for coding agents. It takes a web app from no tests to a maintained Playwright suite, hunts bugs, repairs rotted suites and verifies code changes with evidence. The package is harness-neutral: 16 skills, five agent definitions, return-shape schemas, five CLIs and a Playwright reporter, plus one adapter for Claude Code. The output is plain Playwright specs on [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions); they run without any agent. Design background: [Agentic Shift-Left](docs/agentic-shift-left.md).

Your main session is never bound by Achilles rules. QA work goes to a separate orchestrator agent, which dispatches four kinds of expert and hands back one verdict.

## Install

Requirements: Node 20 or later and a web app with a reachable URL. Claude Code 2.1.287 or later for the plugin.

| Harness | Command | What happens |
|---|---|---|
| Any, through npm | `npm i -D @civitas-cerebrum/achilles` | Fetches the Chromium used for live inspection. On a machine with Claude Code, postinstall registers the package as a plugin in the project's `.claude/settings.local.json` (`-g`: `~/.claude/settings.json`), in place from `node_modules`; nothing is copied. |
| Claude Code, direct | `/plugin install achilles --marketplace civitas-cerebrum/achilles` at the prompt, or from a shell `claude plugin marketplace add civitas-cerebrum/achilles` then `claude plugin install achilles@achilles` | User-level plugin for every project; no npm install needed for the agents, skills and hooks. The CLIs and reporter still come from the npm package. |
| pi | `pi install npm:@civitas-cerebrum/achilles` | Loads the skills and the pi extension (`pi/index.ts`): `delegate_qa`, `/achilles` and expert mode, with the orchestrator and each expert in their own `pi` process, and the Bash judge and secrets screen as guards. `npm install` registers it when pi is on PATH. See [docs/harness/pi.md](docs/harness/pi.md). |

Set `ACHILLES_SKIP_CLAUDE_REGISTRATION=1` to install without touching Claude Code settings, `ACHILLES_SKIP_PI_REGISTRATION=1` to skip the pi install, and `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` to skip the Chromium fetch. A failed step prints a warning; the install still succeeds. npm 11 and later block a dependency's install script until it is approved: when npm lists `@civitas-cerebrum/achilles` under blocked install scripts, the plugin is not registered; run `npm install-scripts approve @civitas-cerebrum/achilles` and install again. Restart Claude Code after the install; the plugin loads at the next session. Uninstall: `claude plugin uninstall achilles`, or delete the `achilles` entries from the settings file postinstall wrote; npm runs no uninstall script.

## Use

From the main session on Claude Code, call the `delegate_qa` tool or type `/achilles <task>`:

```text
/achilles onboard this project; the app runs at http://localhost:3000, login is in .env
/achilles verify PROJ-123 on this branch
/achilles the checkout suite is red since yesterday, repair it
```

What comes back, and when:

1. At once: `RUNNING` plus a run id. The orchestrator agent starts in the background; progress shows in the status line and the Achilles pane. Your session stays free.
2. When the run ends: a hand-back arrives as a turn of its own, without you typing. Its first word is one of `DONE` (deliverables, commits, verification evidence), `DONE_WITH_CONCERNS` (the same, plus rulings it needs from you), `NEEDS_CONTEXT` (a numbered question list) or `BLOCKED` (an owner action and what it unblocks).
3. On `NEEDS_CONTEXT`: answer the questions in the chat. The main session re-delegates with your answers; the orchestrator resumes from `.achilles/runs/<run-id>/resume.json`, not from the conversation. Work that landed before the question is already committed. The orchestrator asks everything it needs in one hand-back; it never asks mid-run.

pi works the same way: `delegate_qa` and `/achilles` start the orchestrator in its own `pi` process, it dispatches each expert into another, and the hand-back arrives as a message of its own ([docs/harness/pi.md](docs/harness/pi.md)).

Scope rules the orchestrator keeps: every unit of work is reviewed by a fresh reviewer before the run advances; no silent skips; app bugs are reported with evidence, never worked around; a long run commits what landed and names a resume file at every exit. The contract is [`skills/achilles-orchestrator/SKILL.md`](skills/achilles-orchestrator/SKILL.md).

## Skills

One orchestrator skill with seven workflows, and 15 expert skills that the experts load on the orchestrator's brief.

| Skill | Workflow or role | What it does |
|---|---|---|
| `achilles-orchestrator` | the controller | Routing table, preflight, dispatch and hand-back contracts, verification bar, state and commit discipline |
| ↳ `workflows/author-scenario.md` | one scenario | One durable test from a scenario, URL, bundle or fix request; API questions |
| ↳ `workflows/onboard.md` | zero to suite | Eight phases: scaffold, groundwork, happy paths, journey map, coverage, bug hunt, secrets sweep, report |
| ↳ `workflows/map-journeys.md` | discovery | Sentinel-bearing `tests/e2e/docs/journey-map.md` from inspectors driving the app section by section |
| ↳ `workflows/expand-coverage.md` | coverage | Five passes per journey across the map (`standard`, `breadth`, `depth`); adversarial ledger, residual risk |
| ↳ `workflows/hunt-bugs.md` | adversarial | Probe every journey (`live` or `static`); findings ledger and reproduction specs |
| ↳ `workflows/repair-suite.md` | repair | One failing test, a batch, or the unattended `npm run test:repair`; heals with stability evidence, quarantine ledger |
| ↳ `workflows/verify-change.md` | change QA | A ticket, PR or branch: diff review, evidence bundle, durable tests and sentinels, negative control, verify note |
| `test-composer` | author | The full variant set for one journey; stabilised, reviewed, coverage checked |
| `bug-discovery` | author | Adversarial probing of one journey or page set; the probe contracts behind hunt-bugs and passes 4 and 5 |
| `failure-diagnosis` | author | Evidence-based triage of a failing test, local or from a CI run; stability validation; niche-edge-case catalogue |
| `evidence-capture` | author | One spec with per-step screenshots, video, trace, HAR and console, frozen as a redacted bundle |
| `contract-testing` | author | Status, schema, error-envelope and header assertions for every `steps.api*` call |
| `database-testing` | author | Row, cell, column and transaction assertions for `steps.sql*`; the DB as oracle |
| `performance-testing` | author | k6 load, stress, spike, soak and breakpoint tests with SLO thresholds; the perf pipeline |
| `agents-vs-agents` | author | Red-teaming, guardrail, bias and prompt-injection tests for AI features |
| `selector-development` | author | One inert test attribute per element with an eight-step inertness proof; JIT or audit |
| `secrets-sweep` | author | Credentials, keys, PII shapes and URLs moved out of the suite into `.env` |
| `test-data-conventions` | author (companion) | Where a scenario's data comes from, who creates it, who cleans it up |
| `journey-mapping` | inspector, doc-writer | The per-section inspection brief and the map author's rules |
| `review` | reviewer | Composition judge, Stage B reviewer and phase gate; one vocabulary per mode |
| `qa-reporting` | doc-writer | Work summary deck and test catalogue, rendered and inspected |
| `bug-report` | doc-writer | A pre-filled tracker ticket from evidence and a reproduction |

Skill directory names are the invocation names. Framework references (the Steps API, stages protocol, composition standards, test identity, selector evidence, browser protocol) live under `skills/achilles-orchestrator/references/`.

## Agents

Five hand-authored definitions under `agents/achilles-<role>.md`. Tools and path scopes are the role boundary: an author cannot approve its own work, a reviewer cannot touch a spec, the orchestrator never writes a spec and never opens a browser.

| Agent | Role | Scope in one line |
|---|---|---|
| `achilles-orchestrator` | controller | Routes the task, writes briefs and run state under `.achilles/runs/<run>/`, dispatches the experts, reads their reports, commits landed work; runs the suite and git, never a browser session, never a spec |
| `achilles-inspector` | looks first | Reads the workspace and drives the live app in its own browser session; writes evidence, discovery notes and proposals, never a spec or the page repository |
| `achilles-author` | writes tests | Owns `tests/**` and the page repository; the scaffold brief adds the runner config and `.env*`, the selector brief adds one inert attribute in one frontend file; proves its work with the runner |
| `achilles-reviewer` | fresh eyes | Verifies on disk and in the running app, runs the suite read-only, writes a verdict; never edits what it reviews, a new instance per review |
| `achilles-doc-writer` | documents | Turns reports and evidence into docs under `docs/**` and `tests/e2e/docs/**`; no code, no commits |

Nesting is main session → orchestrator → expert, and stops there. The exact tool lists and path scopes are in the agent files and the agents table of [docs/harness/claude-code.md](docs/harness/claude-code.md).

## Hooks (Claude Code)

One TypeScript module, eight hooks, acting on the five Achilles agents only. Default posture: advise. A deny is reserved for irreversible or dangerous actions and always names the action to take.

1. **Bash judge**: denies commit bypass flags, commits and PRs carrying AI attribution, `k6` runs over the VU, duration, allowlist or production limits, `git push --force`, `rm -rf` outside the project and credential shapes written into committed files; advises on commit grammar and protected paths; rewrites a missing `playwright-cli -s=<slug>` from the agent id.
2. **Pipeline ledger model**: denies nothing; advises on phase skips, approvals without an envelope and missing deliverables in the onboarding and perf ledgers, and keeps an integrity hash.
3. **Sign-off**: denies a tracker transition to done or a published PR without the reviewer-written receipt and evidence bundle, and any sign-off while the bundle holds a live credential.
4. **Dispatch discipline**: denies nothing; advises on brief shape, concurrency limits and a reviewer that is not fresh.
5. **Return review**: denies nothing; validates each expert's return against its schema and shows the problem in the pane.
6. **Spec hygiene**: denies nothing; advises on missing test ids, import-boundary breaches, the evidence floor for diagnosis edits and factory rules when the project opts in.
7. **Selector development**: denies any frontend edit on a selector brief other than one added inert test attribute; shows the eight-step order as state.
8. **Reporting**: denies nothing; archives a Playwright run's artifacts under `.achilles/runs/` when the Achilles reporter did not, closes each expert's browser sessions when its turn ends, and puts a run summary line in the hand-back.

The full table (events, exact deny lists, advice, switches, limits) is [docs/harness/claude-code.md](docs/harness/claude-code.md); that page is the contract the module implements.

## Switches

| Switch | Effect |
|---|---|
| `ACHILLES_DISABLE=1` in the shell | the adapter passes every event through for new sessions; the tools still answer that it is off |
| `ACHILLES_SKIP_CLAUDE_REGISTRATION=1` at install | postinstall does not register the plugin with Claude Code |
| `ACHILLES_SKIP_PI_REGISTRATION=1` at install | postinstall does not install the package into pi |
| `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` at install | skip the Chromium fetch |
| `achilles-factory-rules.json` in the project root | opts into the factory content rules; no file, no rule |

The full table, including the reporter and CLI variables, is in [docs/harness/claude-code.md](docs/harness/claude-code.md); a lint keeps it equal to what the code reads.

## CLIs and reporter

| Command | Use |
|---|---|
| `npx achilles-mutate` | Injects the broken state an acceptance criterion forbids and reports `CAUGHT`, `WRONG-TEST`, `SURVIVED`, `VOID` or `UNCHECKED`; `--calibrate` proves each check can answer both ways, `--repeat 3` controls flake. Needs a `noop` mutation and an `E2E_MUTATION_*` hook in the `page` fixture. |
| `npx achilles-show <spec>` | Runs a spec headed at `slowMo` 1500 with video and trace, one worker, and writes mp4 to `show-recordings/<timestamp>/` (webm without `ffmpeg`). Arguments pass to `playwright test`. |
| `npx achilles-self-repair` | Unattended repair: baselines the suite, separates flake from deterministic failures, spawns one `claude -p` worker per red spec file, verifies heals, writes a session report. Wired as `npm run test:repair` by the scaffold; needs Claude in the runner. |
| `npx achilles-scenario-lint` | Lints `#### <ID> — <title>` scenario blocks against the project's factory rules. |
| `npx achilles-selector-evidence` | Captures live evidence for one committed page-repository entry. |

The reporter keeps a local ledger of outcomes and copies each failing attempt's evidence; it never fails a run:

```ts
reporter: [['list'], ['html', { open: 'never' }], ['@civitas-cerebrum/achilles/reporter']],
```

History goes to `.achilles/history/tests.ndjson` (`failed 6 of last 10 runs` appears next to a failure); per-attempt evidence to `.achilles/runs/<runId>/`. `ACHILLES_REPORTER=off` disables it.

## Run in CI

The scaffold writes `playwright.config.ts` (reporters `html`, `json` and the Achilles reporter), `tests/e2e/<journey>.spec.ts`, fixtures, a setup file and a `test:repair` script. It writes no CI workflow. The suite runs with `npx playwright test`; no agent is involved.

```yaml
# .github/workflows/e2e.yml
name: e2e
on: [pull_request]
jobs:
  e2e:
    runs-on: ubuntu-latest
    env:
      ACHILLES_SKIP_CLAUDE_REGISTRATION: "1"
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD: "1"
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - run: npx playwright test --reporter=junit
        env:
          # the secrets sweep moves credentials into .env (gitignored); pass them here
          E2E_USER: ${{ secrets.E2E_USER }}
```

Adjust the variable names to the keys in your `.env`. The commands are Playwright's own; the recipe has not been run against an onboarded project in this release.

## What Achilles is not

- No hosted runner and no dashboard. Everything runs on your machine or your CI.
- No native mobile. "Mobile variants" are viewport emulation in Playwright.
- No runtime self-healing. Repair happens in an agent session or through `achilles-self-repair`; a CI run does not retry a step with a model.
- No enforcement outside Claude Code. On pi the skills state the same rules; keeping them is the operator's job.
- No published benchmark. Detection rate, cost and duration have not been measured and published. Onboarding dispatches many subagents and consumes a large share of a plan's usage window.

## Upgrading from 0.1.7 or a 0.2.0 branch install

Earlier installers copied the harness into `.claude/` (or `~/.claude/` for `-g`). 0.1.8 copies nothing: the plugin loads in place from `node_modules` or the marketplace. The old copies are not removed by the new postinstall and keep running until you delete them, so clean up once:

1. **With the old package still installed**, run `npx achilles-uninstall --project` (and `npx achilles-uninstall --global` if you ever installed with `-g` or had the user-level routing skill). It removes what the install record lists. 0.1.x had no uninstaller; go to step 2.
2. **By hand**, in each `.claude/` directory Achilles wrote to (and `~/.claude/`), delete: the Achilles hook scripts under `hooks/` (the 41 `*-gate.sh`, `*-guard.sh`, `*-watcher.sh`, `*-writer.sh`, `*-chain.sh`, `*-registry.sh`, `*-stepper.sh`, `*-archiver.sh`, `*-cleanup-on-stop.sh`, `*-revert-on-stop.sh` scripts) plus `hooks/factory/`, `hooks/lib/`, `hooks/data/` and `hooks/bin/jq`; the copied skills under `skills/` (`achilles-protocol`, `onboarding`, `coverage-expansion`, `test-repair`, `self-repair`, `companion-mode`, `workflow-reviewer`, `test-catalogue`, `work-summary-deck`, `perf-onboarding`, `ticket-driven-testing`, `contributing-to-achilles-protocol`, `requirement-intake`, `sql-client` and the twelve that kept their names); the 22 generated agents under `agents/`; `kernel-mandate.json`, `kernel-mandate.md`, `kernel-mandate.achilles.json`, any `kernel-mandate.achilles-new.json`, `achilles-qa.kernel-mandate.json`; and the install record `achilles-install.json`. Remove the user-level routing skill `~/.claude/skills/achilles/` and `~/.claude/achilles-install.json`.
3. **In `.claude/settings.json`** (and `~/.claude/settings.json`), remove every entry under `hooks` whose command points into `.claude/hooks/` or `~/.claude/hooks/`. Your own hook entries stay.
4. Install 0.1.8 and restart Claude Code. The switches `ACHILLES_PROTOCOL`, `KERNEL_MANDATE`, `CIVITAS_SKIP_HOOK_INSTALL` and `CIVITAS_SKIP_JQ_INSTALL` are no longer read; drop them from shells and CI. There is no session activation step and no `achilles-uninstall` command; uninstall is `claude plugin uninstall achilles` or removing the plugin entry from the settings file.

What else changes for you: no banner at session start; questions arrive as `NEEDS_CONTEXT` hand-backs instead of mid-run prompts; the old slash commands (`/onboarding`, `/coverage-expansion` and the rest) are `/achilles <task>`; hooks advise where they used to deny, except the eight denies listed above. The full list is in [CHANGELOG.md](CHANGELOG.md).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md): the methodology/adapter split, commit conventions (no AI attribution trailers), the lint (`node scripts/lint-doc-drift.mjs`) and the PR checklist. `npm test` runs every suite (schemas, doc lint, CLIs, reporter, adapter) and exits non-zero on any failure.

## License

MIT.
