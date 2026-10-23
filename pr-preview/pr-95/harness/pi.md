# Achilles on pi

pi consumes the methodology only: the skills under `skills/` load as pi skills; there is no hook enforcement and no plugin tool layer yet.

## Install

```bash
pi install npm:@civitas-cerebrum/achilles
```

`package.json` declares `"pi": { "skills": ["./skills"] }`, so every `skills/<name>/SKILL.md` is discoverable by its directory name. The browser primitive is unchanged: `npx playwright-cli` ships with the package; fetch the binary once with `npx playwright-cli install-browser chromium`.

## What runs where

- **Orchestration.** `skills/achilles-orchestrator/SKILL.md` describes the routing, dispatch and hand-back contracts in harness-neutral terms. On pi the agent that loads it is the orchestrator; the Agent-tool dispatch (type `achilles-<role>`, prompt = brief path + report path) maps to whatever subagent primitive the extension exposes, with the brief file written first. Without a subagent primitive the workflows still read as a checklist, but the fresh-reviewer and context-discipline rules cannot hold inside one context; say so in the hand-back.
- **Agents.** The five definitions under `agents/achilles-<role>.md` (`achilles-orchestrator`, `achilles-inspector`, `achilles-author`, `achilles-reviewer`, `achilles-doc-writer`) carry tool lists and path scopes in their frontmatter. lets-code-style extensions can read that frontmatter to configure subagents; nothing on pi enforces the scopes.
- **Hooks.** None. The behaviours the Claude Code adapter denies (commit bypass flags, AI attribution trailers, k6 ceilings, sign-off without a receipt and bundle, credentials in captured artifacts, non-inert selector edits) are stated as rules in the skills and are the operator's responsibility here.
- **State.** The same files: `.achilles/runs/<run-id>/` with `briefs/`, `reports/` and `resume.json`; `tests/e2e/docs/` for the workflow state files and ledgers ([state-files.md](../../skills/achilles-orchestrator/references/state-files.md)). The sign-off receipt `.achilles/adversarial-verification/<ticket>.json` is written by the orchestrator itself here; no hook records it.

## Not yet on pi

Status pane, hand-back delivery as a prompt submission, the archiver, the return-shape validator and the sign-off hook. Track the adapter work in the changelog; the methodology does not change when they land.
