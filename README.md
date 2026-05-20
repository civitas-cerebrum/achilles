# Achilles — Autonomous Quality Assurance

[![NPM Version](https://img.shields.io/npm/v/@civitas-cerebrum/achilles?color=rgb(88%2C%20171%2C%2070))](https://www.npmjs.com/package/@civitas-cerebrum/achilles)

The methodology package — agent skills, harness hooks, return-shape schemas, and post-install plumbing — that drives [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions) through an end-to-end QA pipeline.

Achilles is what you install when you want **Claude Code** (or any LLM agent driving Playwright) to autonomously scaffold, map, compose, probe, and report on a web application's test surface. It does not replace element-interactions; it sits on top of it and **orchestrates** the framework through eight documented phases.

---

## Three packages, one pipeline

| Package | Role |
|---|---|
| [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions) | The Steps API — a Playwright facade. Programmatic surface for humans + AI to write tests. |
| **`@civitas-cerebrum/achilles`** (this package) | The methodology — agent skills + harness hooks + return-shape schemas + postinstall plumbing. |
| `@civitas-cerebrum/achilles-cli` (optional) | A deterministic shell-driven orchestrator CLI for running the pipeline non-interactively. |

If you only want the Steps API in your own hand-written tests, install element-interactions alone. If you want Claude Code to drive the whole pipeline, install achilles.

---

## Installation

```bash
npm install --save-dev @civitas-cerebrum/achilles
```

That's the whole install. `@civitas-cerebrum/element-interactions` and `@playwright/test` come along as transitive dependencies — you don't have to add them yourself.

`postinstall` lands the agent skills + harness hooks into both:

- `<your-project>/.claude/skills/` and `<your-project>/.claude/hooks/`
- `~/.claude/skills/` and `~/.claude/hooks/`

so Claude Code picks them up automatically on the next session restart.

After install, run once to fetch the headless-shell binary the harness uses for live DOM inspection:

```bash
npx playwright-cli install-browser chromium
```

---

## What you get

Inside the package:

| Directory | What's there | Who reads it |
|---|---|---|
| `skills/` | 15+ Claude Code skill packs covering scaffold, journey-mapping, test-composer, bug-discovery, secrets-sweep, coverage-expansion, and the orchestrator's onboarding workflow | Claude Code (auto-discovered) |
| `hooks/` | Harness hooks that enforce contract discipline at the tool boundary — phase-ordering, dispatch-shape validation, return-schema validation, ledger integrity, parent-only-orchestrator policies, playwright-cli session isolation | Claude Code (registered in `~/.claude/settings.json` by postinstall) |
| `schemas/` | JSON Schemas for subagent return shapes + the onboarding-status ledger; fixtures for both the valid and invalid cases | Subagent return validators + reviewer subagents |
| `scripts/` | `postinstall.js` (skill+hook copy + chromium fetch), `compile-schemas.mjs` + `validate-schema-fixtures.mjs` (schemas:lint), `sync-hooks.js` (dev convenience) | npm install, CI |

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

Once kicked off, the orchestrator runs end-to-end without further prompts — the harness hooks are the safety layer that prevent the agent from talking itself out of contract completion. `coverage-expansion` and `bug-discovery` follow the same pattern at smaller scope. The agent owns the entire lifecycle of a test suite — discovery, growth, repair, adversarial probing, reporting — and ships its work as durable artifacts rather than transient chat output.

---

## Verifying the package locally

```bash
npm run schemas:lint   # all 9 subagent-return schemas + 6 onboarding-status fixtures
npm run test:hooks     # 365 hook tests
npm pack --dry-run     # tarball shape sanity check
```

---

## License

MIT
