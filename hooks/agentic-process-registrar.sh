#!/bin/bash
# agentic-process-registrar.sh — agentic-OS process table: record every
#                                subagent dispatch with the privilege
#                                snapshot of its assigned role.
#
# Hook    : PreToolUse:Agent
# Mode    : silent allow (this is a registration hook, never blocks)
# State   : writes <project>/.achilles/.agent-process-table.json
# Env     : none
#
# Why
# ---
# The agentic-OS model treats a subagent dispatch as PROCESS CREATION:
# the Agent description prefix is the login name, and the role resolved
# from it (lib/agent-role-privileges.sh — the passwd/sudoers of the
# harness) fixes the process's privilege set for its whole lifetime.
# Enforcement lives in agent-role-privilege-guard.sh, which fires inside
# the subagent's own tool calls (they carry a non-empty `agent_id`; the
# orchestrator's carry none) — but a PreToolUse:Bash hook has no direct
# view of WHICH dispatch its context belongs to. This table closes that
# gap: it records every dispatch by tool_use_id with {role, denied[], ts},
# so the guard can resolve the executing role by parent_tool_use_id when
# the build emits it, by liveness set-intersection when it does not
# (current builds — same fallback posture as workflow-approver-registry).
#
# EVERY Agent dispatch is recorded — known role prefixes with their
# privilege snapshot, free-form prefixes as role "unconfined" with an
# empty denied set. Recording unconfined processes is load-bearing: the
# guard's ambiguity fallback denies a class only when ALL live processes
# deny it, so an unrecorded free-form subagent would inherit the strictest
# live role's denials instead of its own (none).
#
# Entries expire after a 30-minute TTL (matches .workflow-approvers.json)
# so the table tracks LIVE processes, not dispatch history.
#
# Pairs with:
#   hooks/agent-role-privilege-guard.sh   (PreToolUse:Bash|Agent DENY — enforcement)
#   hooks/lib/agent-role-privileges.sh    (role → privilege mapping, shared)
#
# Canonical reference
# -------------------
# skills/element-interactions/references/agentic-os-roles.md

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found." >&2; exit 1; }

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Agent" ] || exit 0

DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")

AGENT_TOOL_USE_ID=$(echo "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null || echo "")
[ -n "$AGENT_TOOL_USE_ID" ] || exit 0  # no id, can't register — silent allow

# Role assignment. Unknown prefixes register as "unconfined" (empty denied
# set) — see header for why that is load-bearing, not cosmetic.
# shellcheck source=lib/agent-role-privileges.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-role-privileges.sh"
DESC_TRIMMED=$(echo "$DESCRIPTION" | sed -E 's/^[[:space:]]+//')
if ! ROLE=$(resolve_privilege_role "$DESC_TRIMMED"); then
  ROLE="unconfined"
fi
DENIED=$(role_denied_classes "$ROLE")

GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
REPO_ROOT=$(cd "$GUARD_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")
TABLE_DIR="$REPO_ROOT/.achilles"
TABLE_FILE="$TABLE_DIR/.agent-process-table.json"

mkdir -p "$TABLE_DIR" 2>/dev/null || exit 0

NOW=$(date +%s)
TTL_SECONDS=1800  # 30 minutes — matches .workflow-approvers.json

# Read existing table (or start empty), expire stale entries, add the new
# process record. Atomic via temp + mv.
EXISTING="{}"
if [ -f "$TABLE_FILE" ]; then
  EXISTING=$(cat "$TABLE_FILE" 2>/dev/null || echo "{}")
  if ! echo "$EXISTING" | "$JQ" -e 'type == "object"' >/dev/null 2>&1; then
    EXISTING="{}"
  fi
fi

UPDATED=$(echo "$EXISTING" | "$JQ" -c \
  --arg id "$AGENT_TOOL_USE_ID" \
  --arg role "$ROLE" \
  --arg denied "$DENIED" \
  --arg desc "$DESCRIPTION" \
  --argjson now "$NOW" \
  --argjson ttl "$TTL_SECONDS" \
  '
    . as $tbl
    | reduce keys[] as $k ({};
        if ($tbl[$k].ts // 0) >= ($now - $ttl)
          then . + { ($k): $tbl[$k] }
          else .
        end
      )
    | . + { ($id): {
        role: $role,
        denied: ($denied | split(" ") | map(select(length > 0))),
        description: $desc,
        ts: $now
      } }
  ' 2>/dev/null || echo "")

if [ -n "$UPDATED" ]; then
  TMP="$TABLE_FILE.tmp"
  echo "$UPDATED" > "$TMP" 2>/dev/null && mv "$TMP" "$TABLE_FILE" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
fi

exit 0
