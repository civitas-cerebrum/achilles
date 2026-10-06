#!/bin/bash
# achilles-multiedit-gate.sh: MultiEdit bypasses every Write|Edit gate, so it is refused while active.
H="$HOOK_DIR/achilles-multiedit-gate.sh"
ME_TMP=$(mktemp -d)
me() { payload tool_name=MultiEdit file_path="$ME_TMP/tests/e2e/docs/onboarding-status.json" session_id="$1" cwd="$ME_TMP" | "$JQ" -c '.tool_input.edits = [{"old_string":"a","new_string":"b"}]'; }

section "achilles-multiedit-gate"
export ACHILLES_PROTOCOL=1
assert_deny "$H" "$(me me-1)" "active session: MultiEdit on the ledger → DENY" "use Edit"
assert_deny "$H" "$(payload tool_name=MultiEdit file_path="$ME_TMP/README.md" cwd="$ME_TMP")" "active session: MultiEdit anywhere → DENY" "MultiEdit"
unset ACHILLES_PROTOCOL
export ACHILLES_PROTOCOL=0
assert_allow "$H" "$(me me-2)" "protocol suppressed for a fresh session → ALLOW"
unset ACHILLES_PROTOCOL
rm -rf "$ME_TMP"
