# Achilles

**Point your coding agent at a web app. Get back a Playwright suite you own.**

[![NPM Version](https://img.shields.io/npm/v/@civitas-cerebrum/achilles?color=rgb(88%2C%20171%2C%2070))](https://www.npmjs.com/package/@civitas-cerebrum/achilles)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Node 20+](https://img.shields.io/badge/node-%3E%3D20-339933)

Achilles is a QA team that lives inside your agent. Hand it a URL and it maps the app, writes the tests, hunts for bugs, and has every piece of work checked by a reviewer that did not write it. What lands in your repo is plain Playwright: specs that run with `npx playwright test`, no agent required.

It also takes the jobs nobody wants: a red suite after a refactor, a ticket that needs proof before it closes, a flaky test that fails one run in ten.

```text
you    /achilles onboard this project; the app runs at http://localhost:3000, login is in .env
       RUNNING  run 2026-11-01-a7c3   (you keep working, progress shows in the status line)

       ... inspector maps 9 journeys, author writes them, reviewer re-runs every one ...

       DONE  41 specs across 9 journeys, all green on 3 consecutive runs
             2 app bugs reported with reproductions (tests/e2e/docs/adversarial-findings.md)
             secrets moved to .env, committed in 6 commits
```

*An illustration of the flow; real counts depend on your app.*

## Quick start

You need Node 20+, a web app with a reachable URL, and Claude Code 2.1.287+ (or [pi](docs/harness/pi.md)).

```bash
npm i -D @civitas-cerebrum/achilles   # registers the Claude Code plugin in place, fetches Chromium
```

Restart Claude Code, then ask:

```text
/achilles onboard this project; the app runs at http://localhost:3000
```

That's it. On npm 11+, if npm lists Achilles under blocked install scripts, run `npm install-scripts approve @civitas-cerebrum/achilles` and install again. Other ways to install are [below](#install).

## What you can ask for

| Say | Achilles runs | You get |
|---|---|---|
| `/achilles onboard this project` | **onboard**, zero to suite in eight phases | Scaffold, happy paths, a journey map, deep coverage, a bug hunt, a secrets sweep and a report |
| `/achilles write a test: a guest can't check out with an empty cart` | **author-scenario** | One durable, reviewed test |
| `/achilles map the user journeys` | **map-journeys** | `tests/e2e/docs/journey-map.md`, prioritised by business impact |
| `/achilles expand coverage on checkout` | **expand-coverage** | Five passes per journey: variants, errors, edge cases, adversarial probes |
| `/achilles try to break the app` | **hunt-bugs** | A findings ledger and a reproduction spec per bug |
| `/achilles the checkout suite is red since yesterday, repair it` | **repair-suite** | Heals with stability evidence; real app bugs reported, never papered over |
| `/achilles verify PROJ-123 on this branch` | **verify-change** | Diff review, an evidence bundle, new tests and a negative control proving they can fail |

Specialist skills join in when the work calls for them: API contract tests, database assertions, k6 performance tests, red-teaming AI features, inert test-attribute selectors, test-data lifecycle, bug reports, and a summary deck for stakeholders.

## What lands in your repo

Ordinary Playwright specs on [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions), with selectors kept in one page repository instead of scattered through the tests:

```ts
// tests/e2e/checkout.spec.ts
import { test } from '../fixtures/base';

test('a signed-in shopper can check out a single item', async ({ steps }) => {
  await steps.navigateTo('/products/veggie-wrap');
  await steps.click('addToCart', 'ProductPage');
  await steps.click('checkoutButton', 'CartPage');
  await steps.verifyText('orderStatus', 'ConfirmationPage', 'Order placed');
});
```

```json
// tests/e2e/page-repository.json
{ "pages": [{ "name": "CartPage", "elements": [
  { "elementName": "checkoutButton", "selector": { "role": "button", "name": "Checkout" } }
]}]}
```

The tests run in CI like any other suite. Achilles is only needed to write and repair them.

## How it works

```text
your session ──/achilles──▶ orchestrator ──brief──▶ inspector     drives the live app, gathers evidence
     ▲                         │   ▲                author        writes specs and the page repository
     │                         │   └──report────── reviewer      fresh instance, verifies, never edits
     │                         │                    reproducer    decides whether a suspected defect is a bug
     └────── one verdict ──────┘                    doc-writer    maps, reports, decks
```

- **Your session stays yours.** The work runs in a separate orchestrator agent in the background. You get `RUNNING` and a run id at once, and one hand-back at the end: `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT` or `BLOCKED`.
- **Nobody marks their own homework.** Every unit of work is checked by a fresh reviewer before the run moves on. An author cannot approve, and a reviewer cannot edit.
- **No questions mid-run.** If Achilles needs something from you, it commits what it has, writes a resume file and asks everything at once. Answer in the chat and it picks up where it stopped; `/achilles resume <run-id>` works after a crash too.
- **Bugs are reported, not worked around.** A suspected app bug never becomes the expected result: the test keeps the correct assertion, is tagged `@known-defect` and points at the finding, with its evidence.
- **The finder does not confirm.** Before a suspected defect becomes a sentinel or a ticket, a fresh reproducer decides from the criteria, the live app and the source whether it is a bug, real only in the source, a spec question or intended. On Claude Code a defect filing or a sign-off without that verdict is refused.
- **Guardrails, not handcuffs.** On Claude Code eight hooks watch the Achilles agents. They advise by default and block only what can't be undone: force pushes, `rm -rf` outside the project, bypassed commit checks, credentials in committed files, sign-off without a reviewer receipt.

The full contract is in [`skills/achilles-orchestrator/SKILL.md`](skills/achilles-orchestrator/SKILL.md), and the design thinking in [Agentic Shift-Left](docs/agentic-shift-left.md).

## Tools that come with it

| Command | What it's for |
|---|---|
| `npx achilles-mutate` | Proves your tests can fail. Injects the broken state an acceptance criterion forbids and reports `CAUGHT`, `WRONG-TEST`, `SURVIVED`, `VOID` or `UNCHECKED`. `--calibrate` checks every probe can answer both ways; `--repeat 3` controls for flake. Needs a `noop` mutation and an `E2E_MUTATION_*` hook in the `page` fixture. |
| `npx achilles-show <spec>` | Replays a spec headed and slowed down (`slowMo` 1500) with video and trace, and saves an mp4 to `show-recordings/<timestamp>/` (webm without `ffmpeg`). |
| `npx achilles-self-repair` | Unattended repair. Baselines the suite, separates flake from real failures, sends one `claude -p` worker per red spec file and verifies each heal. The scaffold wires it as `npm run test:repair`. |
| `npx achilles-selector-evidence` | Captures live evidence (count, outline, screenshot) for one page-repository entry. |
| `npx achilles-scenario-lint` | Lints `#### <ID> — <title>` scenario blocks against your project's factory rules. |

There's also a **Playwright reporter** that remembers. It keeps a local history of every test, so a failure shows up as `failed 6 of last 10 runs`, and it copies each failing attempt's evidence. It never fails a run.

```ts
reporter: [['list'], ['html', { open: 'never' }], ['@civitas-cerebrum/achilles/reporter']],
```

History lives in `.achilles/history/tests.ndjson` and per-attempt evidence in `.achilles/runs/<runId>/`. Set `ACHILLES_REPORTER=off` to disable it.

## Install

| Where | Command | Notes |
|---|---|---|
| Any project, npm | `npm i -D @civitas-cerebrum/achilles` | Registers the plugin in `.claude/settings.local.json` (`-g`: `~/.claude/settings.json`), loaded in place from `node_modules`; nothing is copied. Fetches Chromium for live inspection. |
| Claude Code, marketplace | `claude plugin marketplace add civitas-cerebrum/achilles` then `claude plugin install achilles@achilles` | A user-level plugin for every project. The CLIs and reporter still come from the npm package. |
| pi | `pi install npm:@civitas-cerebrum/achilles` | Skills plus the pi extension: `delegate_qa`, `/achilles` and expert mode, each expert in its own `pi` process. See [docs/harness/pi.md](docs/harness/pi.md). |

Restart Claude Code after installing. To uninstall, run `claude plugin uninstall achilles` or delete the `achilles` entries postinstall added to the settings file.

<details>
<summary><b>Switches</b></summary>

| Switch | Effect |
|---|---|
| `ACHILLES_DISABLE=1` in the shell | The adapter passes every event through for new sessions; the tools say it is off |
| `ACHILLES_SKIP_CLAUDE_REGISTRATION=1` at install | Don't register the plugin with Claude Code |
| `ACHILLES_SKIP_PI_REGISTRATION=1` at install | Don't install the package into pi |
| `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` at install | Skip the Chromium fetch |
| `achilles-factory-rules.json` in the project root | Opt into the factory content rules; no file, no rules |

A failed install step prints a warning and the install still succeeds. The full table, including reporter and CLI variables, is in [docs/harness/claude-code.md](docs/harness/claude-code.md).

</details>

## Run the suite in CI

The scaffold writes `playwright.config.ts`, the specs, fixtures, a setup file and a `test:repair` script, but no CI workflow, because CI doesn't need Achilles. A starting point:

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
          # the secrets sweep moved credentials into .env (gitignored); pass them here
          E2E_USER: ${{ secrets.E2E_USER }}
```

Rename the variables to match your `.env`. The commands are Playwright's own; this recipe hasn't been run against an onboarded project in this release.

## Under the hood

<details>
<summary><b>The 16 skills</b>: one orchestrator with seven workflows, and 15 expert skills</summary>

| Skill | Role | What it does |
|---|---|---|
| `achilles-orchestrator` | controller | Routing, preflight, dispatch and hand-back contracts, the verification bar, state and commit discipline |
| ↳ `workflows/author-scenario.md` | one scenario | One durable test from a scenario, URL, bundle or fix request |
| ↳ `workflows/onboard.md` | zero to suite | Scaffold, groundwork, happy paths, journey map, coverage, bug hunt, secrets sweep, report |
| ↳ `workflows/map-journeys.md` | discovery | `tests/e2e/docs/journey-map.md` from inspectors driving the app section by section |
| ↳ `workflows/expand-coverage.md` | coverage | Five passes per journey (`standard`, `breadth`, `depth`); adversarial ledger, residual risk |
| ↳ `workflows/hunt-bugs.md` | adversarial | Probe every journey (`live` or `static`); findings ledger and reproduction specs |
| ↳ `workflows/repair-suite.md` | repair | One failing test, a batch, or unattended `npm run test:repair`; stability evidence, quarantine ledger |
| ↳ `workflows/verify-change.md` | change QA | A ticket, PR or branch: diff review, evidence bundle, durable tests, negative control, verify note |
| `test-composer` | author | The full variant set for one journey |
| `bug-discovery` | author | Adversarial probing of one journey or page set |
| `failure-diagnosis` | author | Evidence-based triage of a failing test, local or from CI |
| `evidence-capture` | author | One spec with per-step screenshots, video, trace, HAR and console, frozen as a redacted bundle |
| `contract-testing` | author | Status, schema, error-envelope and header assertions for every `steps.api*` call |
| `database-testing` | author | Row, cell, column and transaction assertions for `steps.sql*` |
| `performance-testing` | author | k6 load, stress, spike, soak and breakpoint tests with SLO thresholds |
| `agents-vs-agents` | author | Red-teaming, guardrail, bias and prompt-injection tests for AI features |
| `selector-development` | author | One inert test attribute per element, with an eight-step inertness proof |
| `secrets-sweep` | author | Credentials, keys, PII and URLs moved out of the suite into `.env` |
| `test-data-conventions` | author (companion) | Where a scenario's data comes from, who creates it, who cleans it up |
| `journey-mapping` | inspector, doc-writer | The per-section inspection brief and the map author's rules |
| `review` | reviewer | Composition judge, in-loop reviewer and phase gate |
| `defect-confirmation` | reproducer | One suspected defect reproduced independently; the verdict is the standard defect evidence |
| `qa-reporting` | doc-writer | Work summary deck and test catalogue |
| `bug-report` | doc-writer | A pre-filled tracker ticket from evidence and a reproduction |

Framework references (the Steps API, stages protocol, composition standards, selector evidence, browser protocol) live under `skills/achilles-orchestrator/references/`.

</details>

<details>
<summary><b>The six agents</b> and what each may touch</summary>

| Agent | Role | Scope |
|---|---|---|
| `achilles-orchestrator` | controller | Routes the task, writes briefs and run state under `.achilles/runs/<run>/`, dispatches experts, reads their reports, commits landed work. Never opens a browser, never writes a spec |
| `achilles-inspector` | looks first | Drives the live app in its own browser session; writes evidence and proposals, never a spec or the page repository |
| `achilles-author` | writes tests | Owns `tests/**` and the page repository; proves its work with the runner |
| `achilles-reviewer` | fresh eyes | Verifies on disk and in the running app, writes a verdict, never edits what it reviews; a new instance per review |
| `achilles-reproducer` | confirms defects | Reproduces one suspected defect without reading the suite or earlier reports; returns `bug`, `real-in-source`, `spec-ambiguity` or `not-a-bug`; a new instance per defect |
| `achilles-doc-writer` | documents | Turns reports and evidence into docs under `docs/**` and `tests/e2e/docs/**`; no code, no commits |

Nesting is main session → orchestrator → expert, and stops there. Exact tool lists are in the agent files under `agents/` and in [docs/harness/claude-code.md](docs/harness/claude-code.md).

</details>

<details>
<summary><b>The eight hooks</b> (Claude Code)</summary>

One TypeScript module acting on the six Achilles agents only. It advises by default; a deny is kept for irreversible or dangerous actions and always names the action to take instead.

1. **Bash judge.** Denies commit bypass flags, AI attribution in commits, PRs, issues and comments, `k6` runs over the VU, duration, allowlist or production limits, `git push --force`, `rm -rf` outside the project, and credential shapes in committed files. Advises on commit grammar and protected paths, and fills in a missing `playwright-cli -s=<slug>`.
2. **Pipeline ledger model.** Advises on phase skips, approvals without an envelope and missing deliverables; keeps an integrity hash.
3. **Sign-off, defect filing and outbound text.** Denies an AI signature in a ticket, comment, page or chat message (agent framing gets a note). Advises on a tracker transition to done, or a published PR, without the reviewer's receipt and evidence bundle; denies it while the bundle holds a live credential or while a defect it reports has no reproducer's verdict. Denies a bug or rework filing made before the run searched the tracker for an existing ticket, or that cites no defect the reproducer confirmed as a bug.
4. **Dispatch discipline.** Advises on brief shape, concurrency and reviewers that aren't fresh.
5. **Return review.** Validates each expert's return against its schema.
6. **Spec hygiene.** Denies an AI signature in a report document. Advises on test ids, import boundaries, the evidence floor for diagnosis edits, and factory rules when the project opts in.
7. **Selector development.** Denies any frontend edit on a selector brief other than one added inert test attribute.
8. **Reporting.** Archives run artifacts, closes each expert's browser sessions and adds a run summary to the hand-back.

The contract the module implements is [docs/harness/claude-code.md](docs/harness/claude-code.md).

</details>

## What Achilles is not

- **Not a hosted service.** No runner, no dashboard; everything runs on your machine or your CI.
- **Not native mobile.** "Mobile variants" are viewport emulation in Playwright.
- **Not runtime self-healing.** Repair happens in an agent session or through `achilles-self-repair`; a CI run never asks a model to retry a step.
- **Not enforced outside Claude Code.** On pi the skills state the same rules; keeping them is the operator's job.
- **Not benchmarked yet.** Detection rate, cost and duration haven't been measured and published. Onboarding dispatches many subagents and uses a large share of a plan's usage window.

## Upgrading from 0.1.7 or a 0.2.0 branch install

Earlier versions copied hooks, skills and agents into `.claude/`. 0.1.8 copies nothing, and **the old copies keep running until you remove them**:

1. With the old package still installed, run `npx achilles-uninstall --project` (and `--global` if you used `-g`). 0.1.x had no uninstaller; skip to step 2.
2. Delete what's left by hand, and remove the `hooks` entries in `.claude/settings.json` that point into `.claude/hooks/`.
3. Install 0.1.8, restart Claude Code, and drop `ACHILLES_PROTOCOL`, `KERNEL_MANDATE`, `CIVITAS_SKIP_HOOK_INSTALL` and `CIVITAS_SKIP_JQ_INSTALL` from shells and CI.
4. Replace the old slash commands (`/onboarding`, `/coverage-expansion`, `/test-repair`, …) with `/achilles <task>`.

The exact file list for step 2 is in the [CHANGELOG](CHANGELOG.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the methodology/adapter split, commit conventions (no AI attribution trailers), the doc lint and the PR checklist. `npm test` runs every suite: schemas, doc lint, CLIs, reporter and adapter.

## License

[MIT](LICENSE)
