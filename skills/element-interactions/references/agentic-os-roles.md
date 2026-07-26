# Agentic-OS role privileges

**Status:** authoritative spec for the role → privilege model enforced by the agentic-OS hook pair. Cited from the hook headers and `harness-hooks.md`.
**Scope:** the process model (dispatch = process creation under a role user), the privilege-class vocabulary, the per-role assignment, the process table, role resolution, and fail-open semantics.

For the isolation contract this model mechanises, see [`../../coverage-expansion/references/subagent-isolation.md`](../../coverage-expansion/references/subagent-isolation.md). For the session-slug convention the role claim rides on, see [`playwright-cli-protocol.md`](playwright-cli-protocol.md) §3.

---

## The model

The harness treats the agentic run as an operating system:

| OS concept | Harness realisation |
|---|---|
| Process creation | An `Agent` dispatch. The orchestrator is the only context privileged to create processes (single-level fan-out). |
| User / login name | The dispatch description's role prefix (`composer-`, `reviewer-`, `probe-`, `workflow-reviewer-`, …). |
| passwd + sudoers | [`../../../hooks/lib/agent-role-privileges.sh`](../../../hooks/lib/agent-role-privileges.sh) — the single source of truth mapping role → denied privilege classes. |
| Process table | `<project>/.achilles/.agent-process-table.json`, written by [`../../../hooks/agentic-process-registrar.sh`](../../../hooks/agentic-process-registrar.sh) on every dispatch (30-minute TTL; hook-authored state — direct writes are denied). |
| Kernel capability check | [`../../../hooks/agent-role-privilege-guard.sh`](../../../hooks/agent-role-privilege-guard.sh) on `PreToolUse:Bash` and `PreToolUse:Agent` — denies command classes the executing context's role lacks. |
| Ring boundary | The `agent_id` field on hook payloads: tool calls from dispatched subagents carry a non-empty `agent_id`; the orchestrator's carry none. |
| setuid / privilege drop | [`../../../hooks/agentic-user-exec.sh`](../../../hooks/agentic-user-exec.sh) — when the role users are provisioned, subagent Bash commands are re-executed under the role-bound `achl-*` OS user (see §"OS-user execution mode"). |
| useradd / account provisioning | [`../../../scripts/agentic-os/provision-role-users.sh`](../../../scripts/agentic-os/provision-role-users.sh) — operator-run; creates the role users, tier groups, sudoers drop-in, project ACLs, and the enablement marker. |

A subagent's privilege set is fixed at dispatch time by its role and cannot be raised from inside the process — the guard reads the mapping from the shared library, not from anything the subagent can write (the process table itself is protected by `hook-authored-state-guard.sh` and `protected-artifact-bash-guard.sh`).

## Privilege classes

| Class | What it gates | Who loses it |
|---|---|---|
| `payload-ingest` | Bash dumps (`cat`, `head`, `tail`, `less`, `more`, `nl`, `strings`, `base64`, `xxd`, `od`) of subagent payload artifacts: `*.spec.ts` test source, `tests/e2e/docs/.subagent-returns/` spill files, `.playwright-cli/` traces, `test-results/`, `playwright-report/`, HAR/trace archives. | **orchestrator** |
| `mutate` | Write-shaped Bash: `git commit`, `rm`/`mv`/`cp`/`touch`/`mkdir`/`ln`/`chmod`/`chown`/`truncate`, in-place editors (`sed -i`, `perl -i`), package installs, `tee`/redirection into non-scratch targets (`/dev/*`, `/tmp/*`, `$TMPDIR` stay allowed). | reviewer-inloop, workflow-reviewer, perf-reviewer, phase-validator, process-validator |
| `browser` | `playwright-cli` invocations. | cleanup, phase4-prioritise-author (text-only contracts) |
| `dispatch` | Nested `Agent` dispatch from inside a subagent context. | every known role |
| `remote-push` | `git push`. | every known role |

`payload-ingest` is the context-leak class: it is how subagent payload content would flow **upward** into the orchestrator window, violating the "never hold subagent payload content" rule. Metadata reads (`ls`, `find`, `wc`, `grep -c`, `grep -l`, `stat`) are always allowed, and the class is enforced only while a pipeline is live (live process-table entries, or an onboarding / coverage-expansion / perf ledger on disk) so ordinary dev sessions are untouched. The `Read` tool is not gated by this class — the single sanctioned bounded read (one journey's pass-4 ledger section) goes through `Read`, never a Bash dump.

## Roles

| Role (description prefix) | Denied classes |
|---|---|
| orchestrator (no `agent_id`) | `payload-ingest` |
| composer (`composer-*`) | `dispatch remote-push` |
| reviewer-inloop (`reviewer-*`) | `dispatch remote-push mutate` |
| probe (`probe-*`) | `dispatch remote-push` |
| workflow-reviewer (`workflow-reviewer-*`) | `dispatch remote-push mutate` |
| perf-reviewer (`perf-reviewer-*`) | `dispatch remote-push mutate` |
| phase-validator (`phase-validator-*`) | `dispatch remote-push mutate` |
| process-validator (`process-validator-*`) | `dispatch remote-push mutate` |
| section-agent (`phase4-*`) | `dispatch remote-push` |
| phase4-prioritise-author (`phase4-prioritise-author*`) | `dispatch remote-push browser` |
| phase1-discovery (`phase1-*`) / phase2-discovery (`phase2-*`) | `dispatch remote-push` |
| stage2-inspector (`stage2-*`) | `dispatch remote-push` |
| cleanup (`cleanup-*`) | `dispatch remote-push browser` |
| companion (`companion-*`) / failure-diagnosis (`fd-*`) | `dispatch remote-push` |
| load-run (`load-run-*`) | `dispatch remote-push` |
| unconfined (any other prefix) | *(none — fail-open)* |

Free-form dispatches outside the methodology's role vocabulary register as `unconfined` with an empty denied set. Recording them is load-bearing: the guard's ambiguity fallback (below) denies a class only when **all** live processes deny it, so an unregistered free-form subagent would otherwise inherit the strictest live role's denials.

## Role resolution inside a subagent context

The guard resolves the executing role in this order:

1. **`parent_tool_use_id` → process table** (exact; emitted by some harness builds).
2. **`-s=<slug>` role claim** — the playwright-cli session slug carries the same role prefix as the dispatch description ([`playwright-cli-protocol.md`](playwright-cli-protocol.md) §3.1; the 1:1 mapping is enforced by `playwright-cli-isolation-guard.sh`).
3. **Single live role class** in the process table → that role.
4. **Multiple live role classes** → intersection: a class is denied only if every live process denies it (sound under ambiguity — never stricter than the weakest live process).
5. **Empty/absent table** → unconfined (fail-open).

## OS-user execution mode

The hook layer above enforces role privileges heuristically (pattern-matched command classes). OS-user execution mode makes them **real user privileges**: each role maps to a dedicated system account, and every Bash command a dispatched subagent runs is re-executed under that account — the kernel, not a regex, decides what the process may touch.

**Provisioning (operator-run, root, Linux):**

```bash
sudo scripts/agentic-os/provision-role-users.sh provision \
  --session-user <claude-code-user> --project <project-root>
```

This creates, idempotently:

- **Users** — one `achl-*` system account per role (`role_os_user` in the privileges lib; the roster is generated from `list_privilege_roles` so it cannot drift from the role map). Nologin shells, homes under `/var/lib/achilles/`.
- **Tier groups** — `achl-agents` (read+traverse on the project, every role user), `achl-write` (rwX on the working surfaces: `tests/`, `.git/`, `test-results/`, `playwright-report/`, `.playwright-cli/`, `node_modules/`), `achl-read` (no write grants — the verifier tier). Tier membership is derived from the `mutate` denial (`role_os_tier`), so the kernel is never laxer than the hook policy.
- **Protected-artifact ACLs** — the ledgers, journey map, approver registry, integrity sidecar, findings ledger, and the process table are pinned `r--` for **both** tiers: no role user can mutate them by any command shape. The sanctioned Write/Edit paths run as the session user and are unaffected.
- **Sudoers drop-in** — `/etc/sudoers.d/achilles-agentic-os`: the session user may run commands as the `achl-*` users only, `NOPASSWD`, with `PATH`/`TMPDIR`/`PLAYWRIGHT_*` kept.
- **Enablement marker** — `/etc/achilles-agentic-os/enabled`, listing the provisioned users.

**Execution:** once the marker exists, [`agentic-user-exec.sh`](../../../hooks/agentic-user-exec.sh) (`PreToolUse:Bash`) rewrites each subagent command to `sudo -n --preserve-env=… --set-home -u achl-<role> -- bash -c '<command>'` via the documented `updatedInput` contract. It rewrites **only** on an exact role resolution (ladder steps 1–3) — the ambiguity intersection is sound to *deny* on but never to *pick a uid* from — and only to users listed in the marker. The orchestrator, unconfined, and ambiguous contexts keep the session user. Sibling PreToolUse hooks all see the original command, so the privilege guard's class enforcement is unchanged, and a deny from any hook still wins over the rewrite's allow.

**What this buys beyond the hook layer:** a reviewer-family subagent *cannot* write the project tree no matter how a mutation is spelled; no role user can touch the ledgers or the installed hook surface; and file ownership on everything a subagent writes attributes the artifact to its role (`ls -l` shows which role authored what; `ps -u achl-composer` shows what a role is doing right now).

`deprovision` reverses the accounts/sudoers/marker; `status` reports the current roster. On non-Linux hosts (or before provisioning) the mode is inert and the hook layer remains the enforcement floor.

## Escape hatches

- `AGENT_ROLE_PRIVILEGE_GUARD=off` disables the privilege guard (calibration / operator override).
- `AGENTIC_OS_USER_MODE=off` disables the role-user rewrite; deprovisioning (or deleting the marker) disables it host-wide.
- The registrar has no off switch — it never blocks.
