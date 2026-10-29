# Achilles on pi

pi gets the methodology and expert mode: the skills under `skills/`, and one extension (`pi/index.ts`) that runs the orchestrator and its experts the way the Claude Code adapter does, with the Claude Code adapter's Bash judge and secrets screen as guards.

## Install

`npm install @civitas-cerebrum/achilles` does this for you when `pi` is on PATH: a project install runs `pi install <package> --local --approve` (the approval is for that one command; pi asks for project trust as usual at the next session), a global one `pi install <package>`. `ACHILLES_SKIP_PI_REGISTRATION=1` skips it. By hand:

```bash
pi install npm:@civitas-cerebrum/achilles        # user-wide
pi install npm:@civitas-cerebrum/achilles --local # this project; trust the project when pi asks
```

`package.json` declares `"pi": { "extensions": ["./pi/index.ts"], "skills": ["./skills"] }`. The browser primitive is unchanged: `npx playwright-cli` ships with the package; fetch the binary once with `npx playwright-cli install-browser chromium`.

## Expert mode

- **Delegate.** The main session calls `delegate_qa` (or `/achilles <task>`). In the TUI and RPC modes it answers `RUNNING <run-id>` at once, the status line shows the run, and the hand-back arrives as a message of its own when the orchestrator ends. In print and JSON mode, which end with the prompt, the tool waits and returns the hand-back itself. `run: <id>` (or `/achilles resume <run-id> [notes]`) resumes an earlier run in its own directory from its `resume.json`, as on Claude Code.
- **One process per agent.** The orchestrator and every expert run as their own `pi` process (`--mode json -p --no-session`), each set up from `agents/achilles-<role>.md`: the prompt is appended to the system prompt, the `tools` list is mapped to pi's (`Read`→`read`, `Write`→`write`, `Edit`→`edit`, `Bash`→`bash`, `Grep`→`grep`, `Glob`→`find`,`ls`; skills need no tool, the model reads `SKILL.md`), a `skills:` entry is preloaded whole, the model is the agent's own or the parent's, and the thinking level is the definition's `effort` (`medium` for the inspector, author and doc-writer) or else the parent's level, passed as `--thinking` so a run never mixes levels when the settings file changes mid-run. A child takes the parent's project-trust decision.
- **Dispatch.** Only the orchestrator's process has an `Agent` tool, shaped like Claude Code's (`subagent_type`, `prompt`, `description`), so the skills' dispatch instructions read the same on both harnesses. It accepts any `achilles-<role>` defined under `agents/` other than the orchestrator (bare or `achilles:`-qualified), runs it in the foreground and returns its final message. Tool calls from one message run in parallel. Experts register nothing and dispatch nobody; the main session gets `delegate_qa` only. A spawned orchestrator or expert exits when its parent process is gone, so a main session killed outright leaves no run working with nobody to hand back to.
- **State.** The same files as on Claude Code: `.achilles/runs/<run-id>/` with `briefs/`, `reports/` and `resume.json`; `tests/e2e/docs/` for the workflow state files and ledgers ([state-files.md](../../skills/achilles-orchestrator/references/state-files.md)). The sign-off receipt `.achilles/adversarial-verification/<ticket>.json` is written by the orchestrator itself here.
- **Guards** (`pi/guards.ts`, in the orchestrator's and the experts' processes; the main session is never touched). pi's `tool_call` runs the Claude Code adapter's Bash judge (`claude-code/hooks/bash-judge.ts`) unchanged: it blocks a commit-check bypass, AI attribution in a commit or PR, a force-push (not `--force-with-lease`), a recursive `rm` outside the project, k6 over its limits, and with `achilles-factory-rules.json` unapproved spend; it gives a `playwright-cli` call its `-s=<role>-<hash>` session; its advice is appended to the tool's result. A `bash` call with no timeout gets `ACHILLES_PI_BASH_TIMEOUT` seconds (600 by default, Claude Code's cap): pi's bash has none, and one command that never returns (a `playwright-cli run-code` whose promise never resolves, say) would hold the expert, the orchestrator and the main session indefinitely. An explicit timeout is kept, so a long k6 soak can still ask for more. A `write` or `edit` that puts a secret into a file in scope of the factory rule `secrets.none` is blocked.
- **Switch.** `ACHILLES_DISABLE=1` loads nothing. `ACHILLES_ROLE` is set by the extension on the processes it spawns and decides which tools a process registers; do not set it by hand.

## Not on pi

- **The run-state hooks**: the sign-off record and its credential check, the selector inertness guard, the ledger and return-shape checks, spec hygiene and dispatch advice. They read the run registry the Claude Code adapter keeps; on pi the skills state the same rules.
- The Achilles pane, `progress.json` and stage-progress messages, the archiver, the return-shape validator and the sign-off hook.
