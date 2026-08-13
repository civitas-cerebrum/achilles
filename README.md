# Achilles — Autonomous Quality Assurance

[![NPM Version](https://img.shields.io/npm/v/@civitas-cerebrum/achilles?color=rgb(88%2C%20171%2C%2070))](https://www.npmjs.com/package/@civitas-cerebrum/achilles)

> ### *"Achilles, complete E2E test automation of example.com."*
>
> One sentence. The agent owns everything that follows — scaffold, crawl, journey map, happy path, coverage passes, adversarial bug-hunts, summary deck. No incremental confirmations, no scope renegotiation, no babysitting.

---

A new medium of quality assurance, powered by Playwright and harness engineering. The system comprises two packages: [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions) — a Steps API that streamlines UI interactions — and `@civitas-cerebrum/achilles` — the QA methodology that drives the agentic process around it.

Achilles will drive **Claude Code** (or any LLM agent) to autonomously scaffold, map, compose, probe, and report on a web application's test surface.

---

## 🤖 Autonomous Quality Assurance

The harness ships inside the npm package. When you install `@civitas-cerebrum/achilles`, your coding agent picks the methodology up from `node_modules` automatically — nothing extra to configure. The hooks that gate every phase, pass, and cycle transition register themselves in `~/.claude/settings.json` on postinstall. The agent doesn't *opt into* the methodology; it has no other path through the work.

You drive it in plain English. The orchestrators detect project state and route to the right skill on their own:

> *"Onboard this project — automate https://your-app-url.com from zero."*
> *"Increase coverage."*
> *"Find bugs."*
> *"Repair the suite."*
> *"Verify the checkout flow with evidence."*

Once the run starts, the agent owns the lifecycle. No incremental confirmation prompts, no scope renegotiation, no "are you sure you want me to keep going?" — the harness enforces phase completion before any advance, so the agent either finishes the work or surfaces a blocker for human triage.

| Capability | What it does |
|---|---|
| **Zero-to-suite onboarding** | Installs deps, scaffolds the framework, crawls the app, automates the happy path, completes the journey map, runs priority-tiered coverage passes, runs adversarial bug-hunts, and produces a summary deck — all behind a single confirmation gate, with no further prompts after kickoff. |
| **Journey mapping** | Discovers pages and user flows, prioritises them by business impact, and writes the journey-map blueprint that every downstream test traces back to. |
| **Coverage expansion** | Iterates the journey map and grows the suite per journey across three modes: *standard* (the default — three compositional passes, two adversarial passes, and a dedup pass), *breadth* (one fast horizontal sweep), and *depth* (strict per-journey parallelism on every pass, for high-stakes audits). State-changing steps are verified by API/database oracles, not just UI toasts. Independent journeys are dispatched in parallel. |
| **Per-journey test composition** | For one mapped journey, composes the full portfolio: happy path, error states, edge cases, mobile variants, negative flows, data-lifecycle scenarios. |
| **Adversarial bug discovery** | Probes the live app first — the "first-time effect", where fresh eyes catch what familiarity blinds you to — then cross-references findings against existing tests. Produces a deduplicated bug ledger where each finding is evidence-backed, risk-weighted, ranked by severity and business priority, and tracked through a triage lifecycle — with reproduction tests. |
| **Agents-vs-agents AI red-teaming** | Adversarial testing of LLM-integrated features: guardrail verification, bias detection, prompt injection, compliance auditing. One LLM plays the adversary, the application's AI is the target, a third LLM judges the result. |
| **API contract testing** | Locks the backend surface (status codes, response shape, error envelopes, critical headers) against drift, separately from UI flow tests. |
| **Database testing** | Persistence-layer verification: query/assert SQL state, transactions, and DB-as-oracle for UI/API mutations. Extends contract-testing and test-composer. |
| **Failure diagnosis** | When a test fails in any mode, runs evidence-based triage — screenshot analysis, DOM inspection, root-cause hypothesis — then either fixes the test autonomously or flags an app bug with the evidence to back it. |
| **Suite repair** | When many tests fail at once (suite rot, app drift), batch-clusters failures by shared root cause and heals them per cluster instead of one-by-one — far faster than per-test diagnosis at scale. |
| **Self repair** | Autonomous per-file repair, runnable hands-off from a script (`npm run test:repair` → the `achilles-self-repair` bin) or interactively. Baselines the suite, separates flake from deterministic failures, spawns one repair worker per red spec file, verifies heals with suite-order re-runs, and writes an audit-grade session report — every test ends green or explained (app-bug report with evidence, quarantine, or operator-pending). Per-flow presets are derived autonomously from the project's own suite scripts (`test:e2e:regression` → `test:repair:regression`) via `achilles-self-repair --init-scripts`. |
| **Companion mode** | Single-task evidence-first verification for daily QA. Runs one focused check against the live app and produces a bundle of per-step screenshots, video, Playwright trace, HAR, console log, and a summary — the artifact a developer reads, not a durable suite test. |
| **Test catalogue** | Stakeholder-facing PDF answering *"what scenarios are we running, and why?"* — A4-landscape, organised by portal and priority, with skipped-with-reason transparency. |
| **Work summary deck** | Branded HTML deck summarising the QA work delivered, exportable to PDF for managers, product owners, and clients. |

---

## Installation

```bash
npm install @civitas-cerebrum/achilles
```

That's the whole install. `@civitas-cerebrum/element-interactions` and `@playwright/test` come along as dependencies — achilles cannot drive a suite without the framework, so it is always installed, on every package manager and every install flag.

The framework is declared as a **range** (`>=0.3.8 <1.0.0`) rather than a caret pin, so a new framework release reaches you on a plain `npm update` without waiting for an achilles release. If you write specs that `import` from `@civitas-cerebrum/element-interactions` directly, add it to your own `dependencies` too: pnpm and yarn deliberately do not hoist another package's dependencies to your project root, so a package you import should be one you declare.

`postinstall` does everything end-to-end on a single `npm install`:

1. Lands the agent skills into `<your-project>/.claude/skills/` and `~/.claude/skills/`.
2. Lands the harness hooks into `~/.claude/hooks/` and registers them in `~/.claude/settings.json` (pre-existing user hooks preserved).
3. Bundles a pinned `jq` binary at `~/.claude/hooks/bin/jq` for hook JSON parsing.
4. Fetches the chromium headless-shell binary that the harness uses for live-DOM inspection — `@playwright/cli` is a transitive dep, and `postinstall` calls `playwright-cli install-browser chromium` for you (idempotent — no-ops when already cached).

So after one `npm install`, restart Claude Code and you're ready to drive.

> **Why the chromium fetch matters.** The methodology bundles `@playwright/cli` so skills can drive a real browser from the Bash tool — no MCP plugin to enable, no `.mcp.json` to write. The harness inspects the live DOM before writing any locator, which removes the most common source of AI-generated test flakiness.

**Opt-outs** (set before `npm install`):
- `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` — skip the chromium fetch (offline installs, container builds with a pre-warmed cache).
- `CIVITAS_SKIP_HOOK_INSTALL=1` — skip the hook registration in `~/.claude/settings.json` (enterprise-managed settings).
- `CIVITAS_SKIP_JQ_INSTALL=1` — skip the bundled jq fetch (rely on system jq on PATH).

### `achilles-mutate`

Behavioural mutation testing: prove the suite can **fail**.

```bash
npx achilles-mutate                       # reads .achilles/mutations.mjs
npx achilles-mutate --only pills-hidden   # one mutation, while iterating
```

A green suite proves nothing until you have watched it go red for the right reason. `achilles-mutate`
injects the broken state an acceptance criterion forbids (CSS or an init script, applied through
your own `page` fixture) and reports whether the suite noticed.

It reports four verdicts, not two:

| | meaning |
|---|---|
| `CAUGHT` | the test that **owns** that criterion failed |
| `WRONG-TEST` | something failed, but not the owner — a broken shared precondition, not coverage |
| `SURVIVED` | the mutation applied and nothing failed. A finding. |
| `VOID` | checked, and the mutation never took effect — fix the injection |
| `UNCHECKED` | the applied-check could not run. An infrastructure failure, not a fact about coverage |

`VOID` exists because an un-applied mutation and an uncaught one both leave the suite green, and
reading the second as a coverage hole manufactures work that isn't there. `UNCHECKED` is separate
from it on the same principle one level up: a check that could not run is a bug report about the
harness, not a verdict about the tests. `WRONG-TEST` exists
because a mutation "caught" by fifteen tests usually means a shared precondition broke — which
destroys the report's ability to say *which* criterion regressed.

```bash
npx achilles-mutate --calibrate      # prove every applied-check can report BOTH answers
npx achilles-mutate --repeat 3       # flake control: the owning test must fail 2 of 3
npx achilles-mutate --concurrency 4  # mutations are independent — run them in parallel
```

`--repeat` exists because one run per mutation means any failing test counts as CAUGHT: on a suite
with a 1–2% flake rate that reports coverage it never measured. With `--repeat`, a mutation counts
only if the same test fails in a majority of runs, and repeats that disagree are flagged rather
than silently resolved. `--concurrency` matters on a slow suite — serial execution is what makes
N mutations cost N × suite-runtime.

`--calibrate` runs each mutation's applied-check twice — injected (must be `true`) and clean (must
be `false`) — and fails on any that cannot produce both. Worth running on its own: the applied-check
only fires when a mutation *survives*, so a check that is broken for a mutation your suite reliably
catches is never exercised by a normal run. On its first use here it found one, a width-scoped
mutation whose check ran at a width where the mutation does not apply.

Requires a `noop` entry (the harness's own control) and an `E2E_MUTATION_*` hook in your `page`
fixture; the runner prints both if they're missing. See `skills/ticket-driven-testing/SKILL.md` §8b.

## `achilles-show` — watch a test run, and get a video

A green checkmark does not show *what* a test did. For QA review, sign-off, or handing evidence to a developer, the footage is the deliverable.

```bash
npx achilles-show tests/regression/checkout.spec.ts
npx achilles-show --grep "TC_042"
E2E_VIEWPORTS=mobile npx achilles-show tests/regression_mobile
```

Every argument is forwarded to `playwright test`, so the usual filters work. Recordings land in `show-recordings/<timestamp>/`, named after the test, as **mp4**.

**No config file to write.** It derives a run from the `playwright.config.*` you already have and overrides only what makes a run watchable — headed, `slowMo` ≥ 1500ms, `video`/`trace` on, `workers: 1`, `retries: 0`, generous timeouts. Your own config is never modified. Point it elsewhere with `ACHILLES_SHOW_CONFIG=<path>`.

Each override earns its place: **`workers: 1`** because parallel workers open several windows at once and produce interleaved footage nobody can follow; **`retries: 0`** because a retry overwrites the recording you just watched; **long timeouts** because `slowMo` multiplies every action's wall time, so CI-tuned timeouts fire spuriously. Recordings are paced **at the source** so the native footage needs no post-processing — never slow a video down afterwards.

`E2E_SLOWMO=<ms>` overrides the pacing (default 1500; 500 proved too fast to track individual actions).

> **mp4 encoding.** Playwright records **webm** and bundles a *decode-only* ffmpeg — no mp4 muxer, no h264 — so it cannot transcode. `ffmpeg-static` is an **optional dependency**: the package is tiny, and its ~43MB binary arrives via a postinstall that pnpm and friends block by default, so `achilles-show` fetches it on first use. A system `ffmpeg` on `PATH` is used as a fallback. With neither, the webm is kept and the run says so explicitly rather than silently shipping the wrong format.

---

## The Achilles reporter — flakiness across runs, and the evidence to explain it

A Playwright reporter that keeps a local ledger of every test's outcome, copies each failing **attempt's** evidence the moment that attempt ends, and prints an end-of-run summary that separates flaky from failed and says how often each failure has failed before.

```ts
reporter: [['list'], ['html', { open: 'never' }], ['@civitas-cerebrum/achilles/reporter']],
```

It composes — add it alongside your existing reporters, never instead of them.

- **Per-attempt evidence.** Attempt 0 is usually the honest failure and the retry is what passed; both are copied into `.achilles/runs/<runId>/`, with the attempt each artifact belongs to recorded in `manifest.json`. Copies, never moves, so `show-report` and `show-trace` are unaffected.
- **History.** `.achilles/history/tests.ndjson` accumulates one entry per test per run, so a failure arrives with `failed 6 of last 10 runs` attached instead of no context at all. Bounded and pruned on every run; a damaged ledger reads as no history and is compacted on the next run.
- **The heel.** A test that fails in at least half of the recorded runs is marked as one — a chronic weak point reads differently from a first-time failure.
- Never fails a run. Every filesystem and parse operation is contained; on failure it logs one line and the run reports exactly as it would have.

It coordinates with `hooks/playwright-artifact-archiver.sh` rather than duplicating it: the reporter records what the run left on disk, and the hook skips any path already covered. The two are complementary — the hook is the zero-config backstop that also catches runs killed mid-flight, the reporter reads the *resolved* config (so a computed `outputDir` is no obstacle) and runs however Playwright was invoked, including from CI or an IDE.

| Variable | Default | Effect |
|---|---|---|
| `ACHILLES_REPORTER` | — | `off` disables the reporter entirely |
| `ACHILLES_REPORTER_SLOWEST` | `3` | how many slow tests to name |
| `ACHILLES_REPORTER_SLOW_MS` | `1000` | below this, the slowest section is omitted |
| `ACHILLES_HISTORY_RUNS` | `20` | runs kept in the ledger |
| `ACHILLES_HISTORY_DAYS` | `30` | age bound on ledger entries |
| `ACHILLES_HISTORY_MAX_ENTRIES` | `5000` | hard ceiling on ledger size |
| `ACHILLES_ARTIFACT_RETAIN` | `5` | archived runs kept (`0` disables archiving; shared with the archiver hook) |
| `ACHILLES_ARTIFACT_MAX_MB` | `512` | per-run ceiling above which trace/video blobs are skipped |

`NO_COLOR`, a non-TTY stdout and `TERM=dumb` all switch the summary to plain text; `FORCE_COLOR=1` overrides.

---

## What you get

Inside the package:

| Directory | What's there | Who reads it |
|---|---|---|
| `skills/` | 15+ Claude Code skill packs covering scaffold, journey-mapping, test-composer, bug-discovery, secrets-sweep, coverage-expansion, and the orchestrator's onboarding workflow | Claude Code (auto-discovered) |
| `hooks/` | Harness hooks that enforce contract discipline at the tool boundary — phase-ordering, dispatch-shape validation, return-schema validation, ledger integrity, parent-only-orchestrator policies, playwright-cli session isolation | Claude Code (registered in `~/.claude/settings.json` by postinstall) |
| `schemas/` | JSON Schemas for subagent return shapes + the onboarding-status ledger; fixtures for both the valid and invalid cases | Subagent return validators + reviewer subagents |
| `scripts/` | `postinstall.js` is the only script shipped in the tarball (skill+hook copy + chromium fetch); the lint/build/sync scripts live in the repo only — `compile-schemas.mjs` + `validate-schema-fixtures.mjs` (schemas:lint), `build-validator.mjs` (regenerates the bundled validator), `lint-doc-drift.mjs` (doc-surface drift), `sync-hooks.js` (dev convenience) | npm install, CI |
| `reporter/` | The Achilles Playwright reporter — cross-run flakiness history, per-attempt evidence copying, and the end-of-run summary | Your `playwright.config` (`reporter: [...]`) |
| `bin/` | `self-repair.mjs` — the `achilles-self-repair` CLI driver behind `npm run test:repair`: baselines the suite, classifies flake vs deterministic failures, spawns one Claude Code worker subprocess per red spec file, verifies heals, writes the session report | You (or your CI), via `npm run test:repair` |

---

## Drive a pipeline

In your project's Claude Code session:

```
onboard this project — automate https://your-app-url.com from zero
```

The orchestrator runs the eight-phase pipeline (scaffold → groundwork → happy-path → journey-mapping → coverage-expansion → bug-discovery → secrets-sweep → summary deck) end-to-end. Every phase / pass / cycle transition goes through a `workflow-reviewer-*` subagent. Findings land in a deduplicated `tests/e2e/docs/adversarial-findings.md` ledger; verified boundaries get regression specs; suspected bugs get `@bug + test.fixme()` placeholders for human triage.

Other entry phrases that route to the right subskill:

> *"increase coverage."*
> *"find bugs."*
> *"repair the suite."*
> *"self repair."* — or hands-off from a terminal: `npm run test:repair`
> *"verify the checkout flow with evidence."*

See [`skills/onboarding/SKILL.md`](skills/onboarding/SKILL.md) for the full eight-phase contract.

---

## Working autonomously

Once kicked off, the orchestrators run end-to-end without further prompts. `onboarding` takes a fresh project from no test automation to a complete suite — install, scaffold, crawl, happy path, journey map, five priority-tiered coverage passes, two bug-hunt passes, summary deck — emitting periodic progress updates but requiring no confirmation after the initial gate. `coverage-expansion` and `bug-discovery` follow the same pattern at smaller scope. The harness hooks are the safety layer that prevent the agent from talking itself out of contract completion. The agent owns the entire lifecycle of a test suite — discovery, growth, repair, adversarial probing, reporting — and ships its work as durable artifacts rather than transient chat output.

---

## Verifying (from a repo checkout)

```bash
npm run schemas:lint   # compiles every schema and exercises every fixture
npm run test:hooks     # full hook test suite (count printed at the end)
npm pack --dry-run     # tarball shape sanity check
```

---

## License

MIT
