#!/bin/bash
# achilles-multiedit-gate.sh — refuse MultiEdit while the achilles protocol is active.
#
# Hook  : PreToolUse:MultiEdit
# Why   : Achilles' Write|Edit gates (ledger, sentinel, integrity chain, test IDs, selector
#         pipeline) inspect Write and Edit payloads only. MultiEdit would reach the same files
#         unchecked. Edit and Write cover every MultiEdit use.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_lib achilles-activation.sh
INPUT=$(cat)
achilles_require_active "$INPUT"
JQ="$(achilles__jq)"
REASON="[BLOCKED] MultiEdit is not inspected by the Achilles Write/Edit gates while the protocol is active; use Edit or Write: re-issue the change as one Edit per replacement, or one Write with the full file.

References:
  skills/achilles-protocol/references/harness-hooks.md"
if [ -n "$JQ" ]; then
  "$JQ" -n --arg r "$REASON$(achilles_scope_notice)" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] MultiEdit is not inspected by the Achilles Write/Edit gates while the protocol is active. Use Edit or Write."}}\n'
fi
exit 0
