#!/bin/bash
# protected-artifact-bash-guard.sh — denies Bash commands that mutate the
#                                    pipeline-state artifacts out of band.
#
# Hook    : PreToolUse:Bash
# Mode    : DENY
# State   : none (stateless pattern check)
# Env     : none
#
# Why
# ---
# Every Write|Edit gate (ledger write-gate, sentinel gate, integrity chain)
# inspects ONLY the Write/Edit tools. A `cat > onboarding-status.json` from
# Bash sidesteps them all. This guard closes the obvious shell vectors:
# redirection, file-management commands, in-place editors, and interpreter
# one-liners that mention a protected artifact.
#
# Known limit (by design): Bash filtering cannot be airtight — the agent
# shares the hook's privileges, and arbitrarily-encoded writes exist. The
# tamper-evident ledger chain (ledger-integrity-chain.sh) DETECTS whatever
# this guard fails to PREVENT. The two ship as a pair.
#
# False-positive tradeoff (accepted): mutation commands (cp/mv/rm/tee/…)
# are denied on co-occurrence with a protected basename anywhere in the
# command — so `cp onboarding-status.json /tmp/backup` (a read-only use)
# is denied too. The deny text names the sanctioned alternative.
#
# Canonical reference
# -------------------
# docs/superpowers/specs/2026-06-12-phase1-harness-integrity-design.md §A3

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[protected-artifact-bash-guard] FATAL: jq not found." >&2; exit 1; }

HOOK_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
if [ -f "$HOOK_LIB_DIR/no-skip-messaging.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOOK_LIB_DIR/no-skip-messaging.sh"
else
  no_skip_messaging_block() { echo ""; }
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0
CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

# Protected artifact patterns (extended regex).
PROTECTED='onboarding-status\.json|journey-map\.md|\.phase4-cycle-state\.json|coverage-expansion-state\.json|\.workflow-approvers\.json|adversarial-findings\.md|\.ledger-integrity\.json|\.claude/hooks|\.claude/settings(\.local)?\.json'

echo "$CMD" | grep -qE "$PROTECTED" || exit 0

# 1. Redirection targeting a protected path.
REDIR_HIT=$(echo "$CMD" | grep -cE ">>?[[:space:]]*[^[:space:];|&]*(${PROTECTED})" || true)

# 2. Mutation commands co-occurring with a protected name anywhere.
MUTATE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(tee|cp|mv|rm|install|ln|truncate|sponge|shred)([[:space:]]|$)" || true)

# 3. In-place editors (sed, perl, yq -i). Note: jq has no -i flag; redirects already cover jq writes.
INPLACE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(sed|perl|yq)[[:space:]][^;|&]*-i" || true)
DD_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])dd[[:space:]][^;|&]*of=" || true)

# 4. Interpreter one-liners mentioning a protected path at all.
INTERP_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(python3?|node|ruby|perl)[[:space:]][^;|&]*-[ce]([[:space:]]|$)" || true)

if [ "$REDIR_HIT" = "0" ] && [ "$MUTATE_HIT" = "0" ] && [ "$INPLACE_HIT" = "0" ] && [ "$DD_HIT" = "0" ] && [ "$INTERP_HIT" = "0" ]; then
  exit 0   # read-only access to a protected artifact
fi

REASON="[BLOCKED] This Bash command would mutate (or could mutate) a protected pipeline-state artifact out of band.

Command: ${CMD}

Protected artifacts (ledger, journey map, cycle/coverage state, approver
registry, findings ledger, integrity sidecar, the hook installation) may
only change through the Write/Edit tools — that is where the harness
gates (schema validation, state-machine checks, separation-of-duties,
integrity chain) live. A shell write would bypass them all.

Fix:
  - To change the artifact: use the Write or Edit tool on the file.
  - To read it: drop the write-shaped construct (redirect into /tmp, not
    into the artifact; copy FROM it is blocked too — use cat/jq to read).
  - Deleting a pipeline-state artifact is an operator decision: ask the
    user to remove it in their own terminal if a reset is intended.

$(no_skip_messaging_block)"

"$JQ" -n --arg r "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
