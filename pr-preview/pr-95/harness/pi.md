# Achilles on pi

pi gets the methodology and expert mode: the skills under `skills/`, and one extension (`pi/index.ts`) that runs the orchestrator and its experts the way the Claude Code adapter does. There is no hook enforcement on pi.

## Install

```bash
pi install npm:@civitas-cerebrum/achilles        # user-wide
pi install npm:@civitas-cerebrum/achilles --local # this project; trust the project when pi asks
```

`package.json` declares `"pi": { "extensions": ["./pi/index.ts"], "skills": ["./skills"] }`. The browser primitive is unchanged: `npx playwright-cli` ships with the package; fetch the binary once with `npx playwright-cli install-browser chromium`.

## Expert mode

- **Delegate.** The main session calls `delegate_qa` (or `/achilles <task>`). In the TUI and RPC modes it answers `RUNNING <run-id>` at once, the status line shows the run, and the hand-back arrives as a message of its own when the orchestrator ends. In print and JSON mode, which end with the prompt, the tool waits and returns the hand-back itself.
- **One process per agent.** The orchestrator and every expert run as their own `pi` process (`--mode json -p --no-session`), each set up from `agents/achilles-<role>.md`: the prompt is appended to the system prompt, the `tools` list is mapped to pi's (`Read`→`read`, `Write`→`write`, `Edit`→`edit`, `Bash`→`bash`, `Grep`→`grep`, `Glob`→`find`,`ls`; skills need no tool, the model reads `SKILL.md`), a `skills:` entry is preloaded whole, and the model is the agent's own or the parent's. A child takes the parent's project-trust decision.
- **Dispatch.** Only the orchestrator's process has an `Agent` tool, shaped like Claude Code's (`subagent_type`, `prompt`, `description`), so the skills' dispatch instructions read the same on both harnesses. It accepts any `achilles-<role>` defined under `agents/` other than the orchestrator (bare or `achilles:`-qualified), runs it in the foreground and returns its final message. Tool calls from one message run in parallel. Experts register nothing and dispatch nobody; the main session gets `delegate_qa` only.
- **State.** The same files as on Claude Code: `.achilles/runs/<run-id>/` with `briefs/`, `reports/` and `resume.json`; `tests/e2e/docs/` for the workflow state files and ledgers ([state-files.md](../../skills/achilles-orchestrator/references/state-files.md)). The sign-off receipt `.achilles/adversarial-verification/<ticket>.json` is written by the orchestrator itself here.
- **Switch.** `ACHILLES_DISABLE=1` loads nothing. `ACHILLES_ROLE` is set by the extension on the processes it spawns and decides which tools a process registers; do not set it by hand.

## Not on pi

- **Hooks.** None. The behaviours the Claude Code adapter denies (commit bypass flags, AI attribution trailers, force-push, k6 ceilings, sign-off without a receipt and bundle, credentials in captured artifacts, non-inert selector edits) are stated as rules in the skills and are the operator's responsibility here.
- The Achilles pane, `progress.json` and stage-progress messages, the archiver, the return-shape validator and the sign-off hook.
