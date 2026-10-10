# Achilles

[![NPM Version](https://img.shields.io/npm/v/@civitas-cerebrum/achilles?color=rgb(88%2C%20171%2C%2070))](https://www.npmjs.com/package/@civitas-cerebrum/achilles)

## What

Achilles (`@civitas-cerebrum/achilles`, MIT) is a QA methodology for Claude Code: 25 skills that take a web app from no tests to a Playwright suite, with hooks that enforce the process at the tool boundary. The output is plain Playwright specs on [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions); they run without the agent. Design background: [Agentic Shift-Left](docs/agentic-shift-left.md).

## Why

The rules are enforced by hooks and a role kernel, not by prompt text. Each row names the case file that pins the behaviour.

| Rule | Enforced by | Case |
|---|---|---|
| The orchestrator cannot write runner config | role kernel | `hooks/tests/cases/71-achilles-kernel-activation-gate.sh` |
| Secrets-sweep cannot read `.env` or write config | role kernel | `hooks/tests/cases/85-qa-mandate-scopes.sh` |
| A phase cannot be marked approved without a reviewer envelope | `onboarding-ledger-write-gate` | `hooks/tests/cases/51-onboarding-ledger-write-gate.sh` |
| MultiEdit is refused while the protocol is active | `achilles-multiedit-gate` | `hooks/tests/cases/88-achilles-multiedit-gate.sh` |
| A grouped first pass is refused | `standard-mode-first-pass-guard` | `hooks/tests/cases/49-standard-mode-first-pass-guard.sh` |
| Vendored kernel bytes must match the lock | `sync-kernel-mandate --check` | `hooks/tests/cases/84-sync-kernel-mandate-check.sh` |

Gates stay silent until a session activates the protocol (an Achilles skill runs, a protocol-role subagent is dispatched, or an Achilles `/<skill>` command is typed). Operators can switch them off; see [Switches](#switches-and-uninstall).

## Five-minute start

Requirements: Node 20 or later, Claude Code, a web app with a reachable URL.

```bash
cd your-project
npm i -D @civitas-cerebrum/achilles
claude          # start Claude Code from the project root
```

Then type `/onboarding` and give the app URL. Start Claude Code from the project root: hook commands use `"$CLAUDE_PROJECT_DIR"`, which Claude Code sets to the directory the session started in, so a session started elsewhere resolves the hooks to the wrong place. The Claude Code hooks reference states no minimum version for `CLAUDE_PROJECT_DIR`; any release that runs `PreToolUse` hooks with `settings.json` command registrations is expected to work (checked as of 2026-10).

`postinstall` writes this (checked by installing the packed tarball into an empty project):

| Path | What |
|---|---|
| `.claude/skills/` | 25 Achilles skills (plus `sql-client`, a dependency's skill) |
| `.claude/agents/` | 22 role agents |
| `.claude/hooks/` | 41 hook scripts, plus 7 opt-in factory gates in `hooks/factory/` |
| `.claude/settings.json` | hook registrations, as `"$CLAUDE_PROJECT_DIR"/.claude/hooks/<file>`; existing hooks kept |
| `.claude/kernel-mandate.json`, `.claude/kernel-mandate.md` | the role manifest and its human-readable ledger; an existing manifest is never overwritten (KL-11) |
| `.claude/achilles-install.json` | install record, used by `achilles-uninstall` |
| `~/.claude/skills/`, `~/.claude/agents/` | user-level copies of the skills and agents |

A local install also fetches a jq binary into `.claude/hooks/bin/` (pinned by sha256) and the Chromium used for live-DOM inspection. A global install (`-g`) writes hooks to `~/.claude/` instead.

Onboarding runs eight phases: scaffold, groundwork, happy path, journey map, coverage, bug hunt, secrets sweep, summary deck. It dispatches many subagents. Expect it to consume a large share of a Claude plan's usage window; no cost or duration figure is published yet. Phase contract: [`skills/onboarding/SKILL.md`](skills/onboarding/SKILL.md). Other entry phrases: "increase coverage", "find bugs", "repair the suite", "verify the checkout flow with evidence", "QA this ticket", "perf-onboard this project".

Opt-outs, set before install: `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, `CIVITAS_SKIP_HOOK_INSTALL=1`, `CIVITAS_SKIP_JQ_INSTALL=1` (hooks then need `jq` on PATH).

### Run in CI

The scaffold writes `playwright.config.ts` (reporters `html`, `json` and `@civitas-cerebrum/achilles/reporter`), `tests/e2e/<journey>.spec.ts`, `tests/e2e/fixtures/`, `tests/e2e/playwright.setup.ts`, and a `test:repair` script in `package.json`. It does not write a CI workflow or a `test` script. The suite runs with `npx playwright test`; no agent and no Claude are involved.

```yaml
# .github/workflows/e2e.yml
name: e2e
on: [pull_request]
jobs:
  e2e:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shard: [1, 2]
    env:
      CIVITAS_SKIP_HOOK_INSTALL: "1"
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD: "1"
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - run: npx playwright test --shard=${{ matrix.shard }}/2 --reporter=junit
        env:
          # the secrets-sweep phase moves credentials into .env (gitignored); pass them here
          E2E_USER: ${{ secrets.E2E_USER }}
```

Adjust the variable names to the keys in your `.env`. The snippet shards two ways and writes JUnit; drop `--shard` and `--reporter=junit` for a plain run. The recipe has not been run against a real onboarded project in this release; the commands are Playwright's own. No PR-comment integration ships. `achilles-self-repair` (`npm run test:repair`) spawns Claude Code workers, so it needs Claude in the runner.

## Verify it works

In a session where an Achilles skill is active, ask the agent to write `playwright.config.ts`. The call is refused:

```text
[BLOCKED] Role 'orchestrator' may not write 'playwright.config.ts' — it is outside the role's write scope.
```

Case: `hooks/tests/cases/71-achilles-kernel-activation-gate.sh`. Without an active Achilles session the same write is allowed, because the gates are dormant. To run the refusal without a session, pipe a payload to the installed gate:

```bash
printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s/playwright.config.ts","content":"x"}}' "$PWD" "$PWD" \
  | CLAUDE_PROJECT_DIR=$PWD ACHILLES_PROTOCOL=1 .claude/hooks/achilles-kernel-activation-gate.sh
```

From a repository checkout, `npm test` runs every suite (schemas, kernel lock, doc-drift lint, hooks, factory gates, CLIs, reporter, agents) and exits non-zero on any failure. `npm run test:hooks` runs the hook suite alone.

## Governance model

While an Achilles skill is active, a role kernel checks every tool call. The main session is the `orchestrator`; each subagent is bound to the role its dispatch brief names. The manifest defines 23 roles, each with read and write scopes, command patterns and imports. Full grants: [role ledger](hooks/data/achilles-qa.kernel-mandate.md). Dispatch grammar (`<role>-<slug>:` description, `<<kernel-mandate-role: ROLE#nonce>>` first line of the brief): [roles-and-dispatch.md](skills/achilles-protocol/references/roles-and-dispatch.md).

| Role family | Writes | Does not |
|---|---|---|
| `orchestrator` (main session) | `tests/**`, `.achilles/**`, `.gitignore`, evidence briefs | write runner config or `package.json`; read `src/**` or `.env` |
| `scaffolder` | `playwright.config.ts`, `package.json` scripts, `.env`, fixtures, page repository | read files (write-only) |
| `test-composer` | specs and page repository under `tests/e2e/**` | write config; import beyond the test framework |
| workers (`phase1`, `phase2`, `phase4`, `stage2`, `probe`, `reviewer`, `fd`, `cleanup`, `companion`, `secrets-sweep`) | files in their own lane | write config; `secrets-sweep` has no shell and no `.env` |
| approvers (`workflow-reviewer`, `phase-validator`, `process-validator`, `perf-reviewer`) | one verdict file | author the deliverables; run commands |
| change loop (`implementer`, `live-inspector`, `task-reviewer`, `verifier`, `doc-author`) | per-change artifacts under `docs/evidence/`, `tests/**` | `verifier` alone sets `Status: complete` on its note |

Real refusals, from the installed gate:

```text
[BLOCKED] Role 'orchestrator' may not write 'playwright.config.ts' — it is outside the role's write scope.
[BLOCKED] Role 'orchestrator' may not run this command — the segment 'npm test' matches none of the role's permitted command patterns.
```

The first is pinned by `71-achilles-kernel-activation-gate.sh`, the second by `85-qa-mandate-scopes.sh` ("orchestrator npm test").

## Switches and uninstall

| Switch | Effect |
|---|---|
| `KERNEL_MANDATE=0` | bypasses the role kernel; Achilles gates still run |
| `ACHILLES_PROTOCOL=0` | a new session does not activate the protocol |
| `achilles-factory-rules.json` in the project root | opts into the 7 factory gates; absent, they allow |
| `npx achilles-uninstall --project <dir>` | removes hooks, registrations, skills, agents and mandate files recorded at install; `--global` instead removes the user-level copies |

The 40 switches and opt-in files, with blast radius (lint checks the 35 the code reads): [opt-in-surfaces.md](skills/achilles-protocol/references/opt-in-surfaces.md). The kernel is an operator-controlled guard, not a barrier against the operator.

Counts: 48 hook scripts (41 in `hooks/` plus 7 factory gates), 39 of them named `*-gate.sh` or `*-guard.sh`.

## Known limits

Full table (20 rows): [known-limits.md](skills/achilles-protocol/references/known-limits.md).

| ID | Limit |
|---|---|
| KL-03 | the import-boundary gate is a static floor, not a sandbox |
| KL-05 | `k6 run` and perf worker dispatches are refused under an active kernel; run perf-onboarding with `KERNEL_MANDATE=0` |
| KL-06 | ticket sign-off on a tracker is refused until the tracker's tools are added to the mandate |
| KL-07 | `repair-worker-*` dispatches and contribution `gh pr create` are refused under an active kernel |
| KL-13 | the orchestrator may write anything under `tests/**`; delegation is methodology there |
| KL-15 | Bash guards judge the plain words of one command line, not aliases or scripts |

## What Achilles is not

- Claude Code only. Skills are markdown, but hooks, roles and dispatch exist only for Claude Code.
- No hosted runner and no dashboard. Everything runs on your machine or your CI.
- No native mobile. "Mobile variants" are viewport emulation in Playwright.
- No runtime self-healing. Repair happens offline in an agent session (`self-repair`, `test-repair`); a CI run does not retry a step with a model.
- No published benchmark. Detection rate, cost and duration have not been measured and published.

## How it compares

As of 2026-10; competitor facts come from public pages and third-party summaries and were not re-verified against the products.

| Alternative | What it does | Where Achilles differs | Where Achilles is behind |
|---|---|---|---|
| Playwright MCP or the Playwright planner/generator/healer agents, used directly | Agent explores the live DOM and writes Playwright; process is whatever you prompt | Hooks enforce phase order, role scopes and review envelopes; mutation verdicts check tests can fail | More setup and subagent cost; Playwright's own agents are first-party |
| QA skill packs (for example qaskills.sh) | Advisory skills installed into an agent | Enforced by hooks rather than advisory | Smaller catalogue; no one-command install of third-party skills |
| TesterArmy e2e (Apache-2.0, launched July 2026) | Plain-English steps recorded and replayed without a model; web and mobile; JUnit and a GitHub Action | Plain Playwright output; role separation | No run-time replay, no mobile, Claude Code only, CI recipe untested here |
| Hosted AI testing (Momentic, QA Wolf, Octomind and others) | Managed or SaaS authoring and maintenance with dashboards | Local, MIT, no vendor-held tests | No hosted runner, no dashboard, no vendor support, no benchmark |

## Tools in the package

| Command | Use |
|---|---|
| `npx achilles-mutate` | Injects the broken state an acceptance criterion forbids and reports `CAUGHT`, `WRONG-TEST`, `SURVIVED`, `VOID` or `UNCHECKED`. `--calibrate` checks that every applied-check can answer both ways; `--repeat 3` controls flake. Needs a `noop` entry and an `E2E_MUTATION_*` hook in your `page` fixture. See `skills/ticket-driven-testing/SKILL.md` §8b. |
| `npx achilles-show <spec>` | Runs a spec headed at `slowMo` 1500 with video and trace, one worker, no retries, and writes mp4 to `show-recordings/<timestamp>/`. Arguments pass to `playwright test`. mp4 needs `ffmpeg-static` or a system `ffmpeg`; otherwise the webm is kept. |
| `npx achilles-self-repair` | Baselines the suite, separates flake from deterministic failures, spawns one Claude Code worker per red spec file, writes a session report. |
| `npx achilles-scenario-lint`, `npx achilles-selector-evidence` | Factory-rule scenario lint; selector evidence capture. |
| `npx achilles-uninstall` | Reverses the install. |

The reporter keeps a local ledger of test outcomes and copies each failing attempt's evidence:

```ts
reporter: [['list'], ['html', { open: 'never' }], ['@civitas-cerebrum/achilles/reporter']],
```

History goes to `.achilles/history/tests.ndjson` (`failed 6 of last 10 runs` appears next to a failure); per-attempt evidence goes to `.achilles/runs/<runId>/`. It never fails a run. `ACHILLES_REPORTER=off` disables it; the other variables (`ACHILLES_HISTORY_RUNS`, `ACHILLES_HISTORY_DAYS`, `ACHILLES_HISTORY_MAX_ENTRIES`, `ACHILLES_ARTIFACT_RETAIN`, `ACHILLES_ARTIFACT_MAX_MB`) are in [opt-in-surfaces.md](skills/achilles-protocol/references/opt-in-surfaces.md).

## Contributing

Read [`skills/contributing-to-achilles-protocol/`](skills/contributing-to-achilles-protocol/SKILL.md) and [`hook-authoring.md`](skills/contributing-to-achilles-protocol/references/hook-authoring.md). Run `npm test` before opening a PR. The vendored role kernel is maintained upstream; change it there, then `node scripts/sync-kernel-mandate.mjs`.

## License

MIT. The package bundles a pinned `jq` 1.7.1 binary, fetched at install from <https://github.com/jqlang/jq/releases/tag/jq-1.7.1> and licensed MIT (copyright Stephen Dolan and jq contributors); see <https://github.com/jqlang/jq/blob/jq-1.7.1/COPYING>.
