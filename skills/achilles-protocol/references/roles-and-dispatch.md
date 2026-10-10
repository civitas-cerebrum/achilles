# Roles and dispatch

## How the kernel binds in Achilles

[`achilles-kernel-activation-gate.sh`](../../../hooks/achilles-kernel-activation-gate.sh) (PreToolUse, every tool) runs the vendored kernel only while the Achilles protocol is active in the session. It relays the kernel's verdict unchanged; with no active session the kernel is not consulted. The kernel reads `.claude/kernel-mandate.json` (staged from `hooks/data/achilles-qa.kernel-mandate.json`). The main session is the `orchestrator` role. Roles and grants: [role ledger](../../../hooks/data/achilles-qa.kernel-mandate.md). Kernel internals: the upstream [kernel-mandate](https://github.com/civitas-cerebrum/kernel-mandate) repo.

Prerequisite: postinstall installs one agent definition per role into `~/.claude/agents/`.

## Dispatch grammar

| Part | Rule | Example |
|---|---|---|
| `description` | role name, optional `-<slug>` (`[a-z0-9-]+`), then `:`; longest matching role name wins | `test-composer-j-login:` |
| `subagent_type` | the role name; a type from a different role than the description names is refused | `test-composer` |
| first line of `prompt` | `<<kernel-mandate-role: <role>#<nonce>>>`; required by this methodology (the kernel binds by nonce when present and refuses a tag naming a different role) | `<<kernel-mandate-role: test-composer#k9x2a1>>` |

Role names are the manifest's. `workflow-reviewer-phase3:` binds `workflow-reviewer`; `reviewer-j-login:` binds `reviewer`. The pre-kernel `composer-` description names no role and the kernel refuses it; the Achilles prefix hooks (schema routing, preread, activation) still accept `composer-*` for older briefs and transcripts. To mention another role in prose, write its name, never its tag form.

## Nonce

4+ lowercase letters or digits, unique per dispatch. Recipe: the last six characters of the Unix time in base 36.

## Grouped dispatch

Role first: `test-composer-group-<id>: j-a, j-b`. Rules: [coverage-expansion](../../coverage-expansion/SKILL.md) §"Grouped dispatch".

## Session slugs

The CLI session slug keeps the short `composer-` form: [playwright-cli-protocol.md](playwright-cli-protocol.md) §3.1.

## Verify, switch off, limits

- Verify: `bash hooks/tests/run.sh 85-qa-mandate-scopes`.
- Switches: [opt-in-surfaces.md](opt-in-surfaces.md).
- Deactivation: a terminal ledger write (`complete`/`aborted`) by an approver, or session end; no mid-session off switch ([harness-hooks.md](harness-hooks.md) §"Session-scoped activation").
- Limits, including KL-13 (the orchestrator may write `tests/**`; delegating scaffold and specs is methodology): [known-limits.md](known-limits.md).
