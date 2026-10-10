#!/bin/bash
# plumber-approval-gate.sh — the plumber role runs only on the user's explicit approval.
#
# Hook    : UserPromptSubmit (record) + PreToolUse:Agent (DENY)
# Mode    : DENY on an unapproved plumber dispatch
# State   : <session-state>/<session>.plumber-approval.json (one pending approval),
#           <session-state>/plumber-grants.json (open grants), <project>/.claude/achilles/plumber-log.jsonl
# Env     : none
#
# Why
# ---
# The plumber is the one role exempt from the lock gates (ledger integrity chain, dispatch
# ledger gate, protected-artifact guards, harness self-protection). That exemption is only safe
# when a human asked for it. UserPromptSubmit fires only for what the user typed, so an approval
# recorded there cannot come from an agent, a subagent hand-back or a tool result.
#
# What it gates
# -------------
# UserPromptSubmit: a prompt that names the plumber and approves it, with no negation
#   (lib/plumber.sh plumber_prompt_is_approval), records ONE pending approval for the session.
# PreToolUse:Agent: a plumber dispatch (description `plumber-…:`, subagent_type plumber, or a
#   plumber role tag in the brief) is DENIED unless a pending approval exists. Allowing it
#   consumes the approval and opens a grant (lib/plumber.sh PLUMBER_TTL_S). A plumber role tag
#   inside any other dispatch is DENIED: the plumber is dispatched as itself or not at all.
#
# Canonical reference: skills/achilles-protocol/references/harness-hooks.md §"Plumber"

set -uo pipefail
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/plumber/SKILL.md\n  skills/achilles-protocol/references/harness-hooks.md §\"Plumber\""

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_jq_init fatal
hook_read_input
hook_lib achilles-activation.sh hook-emit.sh plumber.sh

EVENT=$(hook_field .hook_event_name)
SESSION_ID=$(hook_field .session_id)

if [ "$EVENT" = "UserPromptSubmit" ]; then
  PROMPT=$(hook_field .prompt)
  if plumber_prompt_is_approval "$PROMPT" && plumber_record_approval "$SESSION_ID" "$PROMPT"; then
    plumber_audit "$INPUT" approval-recorded "$PROMPT"
  fi
  exit 0
fi

[ "$(hook_field .tool_name)" = "Agent" ] || exit 0
achilles_require_active "$INPUT"

DESCRIPTION=$(hook_field .tool_input.description)
SUBAGENT_TYPE=$(hook_field .tool_input.subagent_type)
BRIEF=$(hook_field .tool_input.prompt)

IS_PLUMBER=0
printf '%s' "$DESCRIPTION" | grep -qE '^[[:space:]]*plumber-[a-z0-9-]+:' && IS_PLUMBER=1
[ "$SUBAGENT_TYPE" = "plumber" ] && IS_PLUMBER=1
HAS_TAG=0
printf '%s' "$BRIEF" | grep -qE '<<kernel-mandate-role:[[:space:]]*plumber([#>[:space:]])' && HAS_TAG=1

if [ "$IS_PLUMBER" = 0 ]; then
  [ "$HAS_TAG" = 1 ] || exit 0
  emit_pre_deny "[BLOCKED] This dispatch carries a plumber role tag but is not a plumber dispatch.

Description: \"${DESCRIPTION}\"

The plumber is dispatched as itself or not at all: description \`plumber-<slug>:\`,
subagent_type \`plumber\`, and the user's explicit approval. A plumber tag inside
another role's brief would bind that agent to the plumber's exemptions.

Fix: remove the plumber tag from this brief, or ask the user to approve a plumber
dispatch and dispatch it as \`plumber-<slug>:\`."
  exit 0
fi

PENDING=$(plumber_pending_approval "$SESSION_ID") || PENDING=""
if [ -z "$PENDING" ]; then
  emit_pre_deny "[BLOCKED] Plumber dispatch without the user's approval.

Description: \"${DESCRIPTION}\"

The plumber is exempt from the integrity chain, the dispatch lock, the protected-artifact
guards and the harness self-protection guard. It runs only after the USER approves it in
their own message; an agent's statement, a subagent's report or a tool result is not an
approval.

Fix: stop and ask the user. Say what is broken and what the plumber would change, and ask
them to reply with an explicit approval that names the plumber (for example \"approve the
plumber to repair the ledger\"). Then dispatch \`plumber-<slug>:\` with subagent_type
\`plumber\` and \`<<kernel-mandate-role: plumber#<nonce>>>\` as the brief's first line.
One approval covers one dispatch."
  exit 0
fi

ID=$(hook_field .tool_use_id)
[ -n "$ID" ] || ID="dispatch-$(date +%s)"
APPROVAL=$(plumber_consume_approval "$SESSION_ID" "$ID") || {
  emit_pre_deny "[BLOCKED] The user's plumber approval could not be recorded as a grant (session state not writable), so the plumber would run without its exemptions. Fix: check that $(plumber__dir) is writable, then retry the dispatch."
  exit 0
}
plumber_audit "$INPUT" dispatch-approved "$APPROVAL"
exit 0
