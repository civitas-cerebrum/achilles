# Roles and dispatch

## How the kernel binds in Achilles

[`achilles-kernel-activation-gate.sh`](../../../hooks/achilles-kernel-activation-gate.sh) (PreToolUse, every tool) runs the vendored kernel only while the Achilles protocol is active in the session. It relays the kernel's verdict unchanged; with no active session the kernel is not consulted. The kernel reads `.claude/kernel-mandate.json` (staged from `hooks/data/achilles-qa.kernel-mandate.json`); under a global install, a project without one is governed by `~/.claude/achilles-qa.kernel-mandate.json`. The main session is the `orchestrator` role. Roles and grants: [role ledger](../../../hooks/data/achilles-qa.kernel-mandate.md). Kernel internals: the upstream [kernel-mandate](https://github.com/civitas-cerebrum/kernel-mandate) repo.

Prerequisite: postinstall installs one agent definition per role into the project's `.claude/agents/` (`~/.claude/agents/` with `npm i -g`).

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

## Change loop

The orchestrator dispatches every step and each note has one writer, so these are the only paths through a change. `<change>` is the change's folder name under `docs/evidence/`.

| Dispatch | Writes | Hands to |
|---|---|---|
| `live-inspector-<change>:` | `docs/evidence/<change>/proposal-*.md`, backed by `docs/evidence/selectors/**` and `tests/e2e/inspect/**` | `orchestrator` |
| `implementer-<change>:` | `tests/**` and `docs/evidence/<change>/report.md`; the orchestrator bundles them into `review-package.md` | `orchestrator` (review package to `task-reviewer`) |
| `task-reviewer-<change>:` | findings in `docs/evidence/<change>/review.md` | `orchestrator` |
| `verifier-<change>:` | the verdict in `docs/evidence/<change>/verify.md`; only the verifier sets `Status: complete` | `orchestrator` |
| `doc-author-<slug>:` | `docs/**` except `docs/evidence/**`; a change to `CLAUDE.md` or `.claude/skills/**` is written as `docs/proposals/<topic>.md` for the operator to apply | `orchestrator` |

- Review loop: `task-reviewer` → `orchestrator` → `implementer` → `task-reviewer`. Findings go back to the same implementer, resumed; the re-review checks only the listed items. At most 5 rounds, then the orchestrator escalates to the operator.
- Verify loop: `verifier` → `orchestrator` → `implementer` → `verifier`. A failing verdict becomes a fix round, followed by a new independent verification.
- Instruction changes: `doc-author` writes `docs/proposals/<topic>.md`; the operator (a human) reviews it and applies it to `CLAUDE.md` or `.claude/skills/**`. No role is granted those paths.
- The round cap and resuming the same implementer are protocol rules, not path scopes.

## Verify, switch off, limits

- Verify: `bash hooks/tests/run.sh 85-qa-mandate-scopes`.
- Switches: [opt-in-surfaces.md](opt-in-surfaces.md).
- Deactivation: a terminal ledger write (`complete`/`aborted`) by an approver, or session end; no mid-session off switch ([harness-hooks.md](harness-hooks.md) §"Session-scoped activation").
- Limits, including KL-13 (the orchestrator may write `tests/**`; delegating scaffold and specs is methodology): [known-limits.md](known-limits.md).
