#!/bin/bash
# A PreToolUse gate that cannot run (no jq, or a lib missing from the install) denies while the
# protocol is active: Claude Code reads exit 1 as a non-blocking error, i.e. an allow. Inactive
# sessions and non-PreToolUse events keep the hook's own no-jq contract.
FC_STATE="$ACHILLES_SESSION_STATE_DIR"
mkdir -p "$FC_STATE"; : > "$FC_STATE/fc-active.active"

fc_payload() {  # fc_payload <session-id> <event> <payload args...>
  local sid="$1" ev="$2"; shift 2
  payload session_id="$sid" hook_event_name="$ev" "$@"
}

FC_GATES="protected-artifact-bash-guard.sh|tool_name=Bash|command=echo x > /tmp/y
commit-message-gate.sh|tool_name=Bash|command=git status
playwright-cli-isolation-guard.sh|tool_name=Bash|command=ls
harness-self-protection-guard.sh|tool_name=Write|file_path=/tmp/x
subagent-schema-preread-gate.sh|tool_name=Agent|description=explore-x: y
onboarding-ledger-gate.sh|tool_name=Agent|description=explore-y: y"

section "fail-closed: no jq, PreToolUse, protocol active → exit 2 naming the remedy"
while IFS='|' read -r g a1 a2; do
  run_hook_nojq "$HOOK_DIR/$g" "$(fc_payload fc-active PreToolUse "$a1" "$a2")"
  assert_eq "$HOOK_EXIT:$HOOK_OUT" "2:" "$g: no jq, active → exit 2"
  assert_eq "$(printf '%s' "$HOOK_ERR" | grep -c 'install jq or reinstall @civitas-cerebrum/achilles')" 1 "$g: stderr names the remedy"
done <<< "$FC_GATES"

section "fail-closed: no jq, protocol inactive → unchanged (exit 1, non-blocking)"
while IFS='|' read -r g a1 a2; do
  run_hook_nojq "$HOOK_DIR/$g" "$(fc_payload fc-dev PreToolUse "$a1" "$a2")"
  assert_eq "$HOOK_EXIT:$HOOK_OUT" "1:" "$g: no jq, inactive → exit 1"
done <<< "$FC_GATES"

section "fail-closed: no jq, PostToolUse in an active session → unchanged (exit 1)"
run_hook_nojq "$HOOK_DIR/ledger-integrity-chain.sh" "$(fc_payload fc-active PostToolUse tool_name=Write file_path=/tmp/x)"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "1:" "ledger-integrity-chain PostToolUse: no jq → exit 1"

section "fail-closed: without jq, the session id is read at the top level, not the first one in the text"
NESTED_FIRST='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \"session_id\":\"fc-dev\"","session_id":"fc-dev"},"session_id":"fc-active"}'
TOP_FIRST='{"session_id":"fc-dev","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","session_id":"fc-active"}}'
run_hook_nojq "$HOOK_DIR/protected-artifact-bash-guard.sh" "$NESTED_FIRST"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "2:" "nested inactive id first, top-level active id last → active → exit 2"
run_hook_nojq "$HOOK_DIR/protected-artifact-bash-guard.sh" "$TOP_FIRST"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "1:" "top-level inactive id, nested active id → inactive → exit 1"

section "fail-closed: a lib missing from the install"
run_hook_without_lib "$HOOK_DIR/playwright-cli-isolation-guard.sh" dispatch-prefix.sh \
  "$(fc_payload fc-active PreToolUse tool_name=Bash 'command=npx playwright-cli -s=j-checkout-3 open')"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "2:" "no dispatch-prefix.sh, active → exit 2"
assert_eq "$(printf '%s' "$HOOK_ERR" | grep -c 'lib/dispatch-prefix.sh')" 1 "stderr names the missing lib"
run_hook_without_lib "$HOOK_DIR/achilles-multiedit-gate.sh" achilles-activation.sh \
  "$(fc_payload fc-dev PreToolUse tool_name=MultiEdit file_path=/tmp/x)"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "2:" "no achilles-activation.sh → session treated as active → exit 2"
run_hook_without_lib "$HOOK_DIR/protected-artifact-bash-guard.sh" protected-paths.sh \
  "$(fc_payload fc-dev PreToolUse tool_name=Bash command='echo x > /tmp/y')"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "1:" "no protected-paths.sh, inactive → exit 1"
run_hook_without_lib "$HOOK_DIR/protected-artifact-bash-guard.sh" protected-paths.sh \
  "$(fc_payload fc-active PreToolUse tool_name=Bash command='echo x > /tmp/y')"
assert_eq "$HOOK_EXIT:$HOOK_OUT" "2:" "no protected-paths.sh, active → exit 2"

rm -f "$FC_STATE"/fc-*
