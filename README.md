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
| **Companion mode** | Single-task evidence-first verification for daily QA. Runs one focused check against the live app and produces a bundle of per-step screenshots, video, Playwright trace, HAR, console log, and a summary — the artifact a developer reads, not a durable suite test. |
| **Test catalogue** | Stakeholder-facing PDF answering *"what scenarios are we running, and why?"* — A4-landscape, organised by portal and priority, with skipped-with-reason transparency. |
| **Work summary deck** | Branded HTML deck summarising the QA work delivered, exportable to PDF for managers, product owners, and clients. |

---

## Installation

```bash
npm install @civitas-cerebrum/achilles
```

That's the whole install. `@civitas-cerebrum/element-interactions` and `@playwright/test` come along as transitive dependencies — you don't have to add them yourself.

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

---

## What you get

Inside the package:

| Directory | What's there | Who reads it |
|---|---|---|
| `skills/` | 15+ Claude Code skill packs covering scaffold, journey-mapping, test-composer, bug-discovery, secrets-sweep, coverage-expansion, and the orchestrator's onboarding workflow | Claude Code (auto-discovered) |
| `hooks/` | Harness hooks that enforce contract discipline at the tool boundary — phase-ordering, dispatch-shape validation, return-schema validation, ledger integrity, parent-only-orchestrator policies, playwright-cli session isolation | Claude Code (registered in `~/.claude/settings.json` by postinstall) |
| `schemas/` | JSON Schemas for subagent return shapes + the onboarding-status ledger; fixtures for both the valid and invalid cases | Subagent return validators + reviewer subagents |
| `scripts/` | `postinstall.js` is the only script shipped in the tarball (skill+hook copy + chromium fetch); the lint/build/sync scripts live in the repo only — `compile-schemas.mjs` + `validate-schema-fixtures.mjs` (schemas:lint), `build-validator.mjs` (regenerates the bundled validator), `lint-doc-drift.mjs` (doc-surface drift), `sync-hooks.js` (dev convenience) | npm install, CI |

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
