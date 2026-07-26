#!/bin/bash
# agentic-user-exec.sh — agentic-OS role-user execution: re-execute
#                        subagent Bash commands under the role-bound OS
#                        user, so privileges are kernel-enforced.
#
# Hook    : PreToolUse:Bash
# Mode    : rewrite (permissionDecision allow + updatedInput) when the
#           executing context resolves EXACTLY to a provisioned role;
#           silent allow otherwise. Never denies.
# State   : reads <project>/.achilles/.agent-process-table.json
#           reads the provision marker (see AGENTIC_OS_MARKER)
# Env     : AGENTIC_OS_USER_MODE=off → disable rewriting entirely
#           AGENTIC_OS_MARKER=<path> → marker file override (tests);
#                                      default /etc/achilles-agentic-os/enabled
#
# Model
# -----
# This is the "user powered" half of the agentic OS. The hook layer
# (agent-role-privilege-guard.sh) enforces role privileges heuristically;
# this hook makes them REAL user privileges: when the operator has
# provisioned the role-bound accounts (scripts/agentic-os/
# provision-role-users.sh — one `achl-*` system user per role, tiered
# filesystem ACLs, a scoped NOPASSWD sudoers drop-in), every Bash command
# from a dispatched subagent context is rewritten to
#
#   sudo -n --preserve-env=... --set-home -u achl-<role> -- bash -c '<cmd>'
#
# so the kernel — not a regex — decides what the process may touch. A
# reviewer-family subagent literally cannot write the project tree (its
# user holds only the read tier); no role user can write the ledgers or
# the hook surface regardless of command shape; file ownership on
# anything a subagent writes attributes the write to its role.
#
# Activation ladder (every rung must hold, else silent allow):
#   1. AGENTIC_OS_USER_MODE != off.
#   2. The provision marker exists (the operator ran the provisioner).
#   3. The tool call is a subagent's (non-empty agent_id) — the
#      orchestrator keeps the session user.
#   4. The context resolves EXACTLY (parent_tool_use_id → process table,
#      -s=<slug> role claim, or a single live role — ACTOR_EXACT=1). The
#      ambiguous-intersection fallback is good enough to DENY on, not to
#      pick a uid with: rewriting to the wrong user would misattribute
#      file ownership and grant the wrong tier.
#   5. The role maps to an OS user (role_os_user) AND that user is listed
#      in the marker (provisioned on THIS host).
#   6. The command is not already wrapped (no double-sudo).
#
# The rewrite is emitted as permissionDecision "allow" + updatedInput —
# the documented PreToolUse input-modification contract. Deny verdicts
# from sibling hooks still win (deny takes precedence over allow in the
# harness aggregation), and every sibling PreToolUse hook sees the
# ORIGINAL command, so the privilege guard's class enforcement is
# unaffected by the rewrite. On platforms whose harness build ignores
# updatedInput the command simply runs unwrapped as the session user —
# the hook-layer guard remains the enforcement floor.
#
# Pairs with:
#   scripts/agentic-os/provision-role-users.sh (operator-run provisioner)
#   hooks/agentic-process-registrar.sh         (process table)
#   hooks/agent-role-privilege-guard.sh        (hook-layer enforcement floor)
#   hooks/lib/agent-role-privileges.sh         (role → OS user mapping)
#
# Canonical reference
# -------------------
# skills/element-interactions/references/agentic-os-roles.md §"OS-user
# execution mode"

set -uo pipefail

[ "${AGENTIC_OS_USER_MODE:-auto}" = "off" ] && exit 0

MARKER="${AGENTIC_OS_MARKER:-/etc/achilles-agentic-os/enabled}"
[ -f "$MARKER" ] && [ -r "$MARKER" ] || exit 0

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

# shellcheck source=lib/agent-role-privileges.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-role-privileges.sh"
# shellcheck source=lib/agent-process-table.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-process-table.sh"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0

AGENT_ID=$(echo "$INPUT" | "$JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
[ -n "$AGENT_ID" ] || exit 0  # orchestrator keeps the session user

CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

# NO double-wrap skip. Earlier versions skipped rewriting a command that
# already looked like our `sudo -n … -u achl-…` wrapper — but the wrapper
# prefix is not secret, so that skip was a bypass: a subagent could
# hand-write `sudo -n -u achl-<laxer-role> -- bash -c '…'` and run
# UN-rewritten as the session user, whom the provisioned sudoers lets
# impersonate any achl-* role (U1). The skip is also unnecessary: this
# hook only ever sees the command the MODEL emitted, never its own output
# (the harness executes the rewrite, it doesn't re-feed it through
# PreToolUse). So we ALWAYS wrap. A hand-crafted inner `sudo -u achl-other`
# is thereby nested inside our wrapper and runs AS achl-<this-role>, who is
# NOT a sudoer (only the session user is) — the inner sudo fails closed.
# Legitimate commands never arrive pre-wrapped, so always-wrap has no
# real-traffic cost.

PARENT_ID=$(echo "$INPUT" | "$JQ" -r '.parent_tool_use_id // empty' 2>/dev/null || echo "")
GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
REPO_ROOT=$(cd "$GUARD_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")

# Project scoping: role-user execution only applies in achilles projects.
# shellcheck source=lib/achilles-project-gate.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-project-gate.sh"
achilles_hooks_active "$REPO_ROOT" || exit 0

apt_load_live "$REPO_ROOT"
apt_resolve_actor "$PARENT_ID" "$(apt_extract_slug "$CMD")"

# Exact identity only — never pick a uid from the intersection fallback.
[ "${ACTOR_EXACT:-0}" = "1" ] || exit 0

OS_USER=""
if ! OS_USER=$(role_os_user "$ACTOR_ROLE"); then
  exit 0  # unconfined / roles without an OS user stay on the session user
fi

# The user must be provisioned on THIS host (marker lists one user per
# line). Rewriting to an absent user would fail every command.
grep -qx "$OS_USER" "$MARKER" 2>/dev/null || exit 0

# Single-quote-safe wrap of the original command.
ESCAPED=$(printf '%s' "$CMD" | sed "s/'/'\\\\''/g")
WRAPPED="sudo -n --preserve-env=PATH,TMPDIR,PLAYWRIGHT_BROWSERS_PATH,PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD --set-home -u ${OS_USER} -- bash -c '${ESCAPED}'"

"$JQ" -n --arg c "$WRAPPED" --arg role "$ACTOR_ROLE" --arg user "$OS_USER" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": ("agentic-OS user mode: executing as role-bound user " + $user + " (role: " + $role + ")"),
    "updatedInput": { "command": $c }
  }
}'
exit 0
