#!/bin/bash
# 69-adversarial-verification-gate.sh — no QA sign-off without an adversarial
# review receipt.
#
# The gate's whole job is to be un-skippable, so these cases pin both halves:
# it must fire on the two actions that constitute sign-off, and it must stay
# silent everywhere else. A gate that over-fires gets disabled by the first
# person it annoys, which is the same outcome as not having one.

H="$HOOK_DIR/adversarial-verification-gate.sh"

# Tracker payloads carry fields the shared payload() helper does not model
# (state, body), so build them directly.
# Payloads carry a ticket id: the gate binds a receipt to the ticket being signed off, so a
# payload with no identifiable key cannot be verified and is denied by design (pinned below).
tracker() {
  local tool="$1" key="$2" val="$3" id="${4:-ABC-1}"
  "$JQ" -nc --arg t "$tool" --arg k "$key" --arg v "$val" --arg id "$id" \
    '{tool_name: $t, tool_input: {($k): $v, id: $id}}'
}

# Isolated workspace per phase: a git repo with one spec, so the gate's
# staleness comparison has something real to compare against.
WS="$(mktemp -d)"
git init -q "$WS" 2>/dev/null || true
mkdir -p "$WS/tests" "$WS/.achilles/adversarial-verification"
echo "test('x', () => {})" > "$WS/tests/a.spec.ts"
export WORKSPACE_ROOT="$WS"
export ACHILLES_PROTOCOL=1

section "adversarial-gate: sign-off without a receipt is denied"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "transition to Done, no receipt → DENY" "Sign-off blocked"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Completed)" \
  "transition to Completed → DENY"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Closed)" \
  "transition to Closed → DENY"
assert_deny "$H" "$(tracker mcp__atlassian__transitionJiraIssue transition Resolved)" \
  "Jira transition to Resolved → DENY"

section "adversarial-gate: non-terminal transitions are none of its business"
assert_allow "$H" "$(tracker mcp__linear__save_issue state 'In Progress')" \
  "transition to In Progress → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__save_issue state 'QA Testing')" \
  "transition to QA Testing → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Backlog)" \
  "transition to Backlog → ALLOW"

section "adversarial-gate: only tracker mutations are gated"
assert_allow "$H" "$(tracker mcp__slack__send_message text 'shipped')" \
  "unrelated MCP tool → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__get_issue id ABC-1)" \
  "tracker READ → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git commit -m x')" \
  "Bash → ALLOW"
assert_allow "$H" "$(payload tool_name=Read file_path=/tmp/x)" \
  "Read → ALLOW"

section "adversarial-gate: verdict-shaped comments WARN, never block"
assert_warn "$H" "$(tracker mcp__linear__save_comment body 'QA Test Report: all AC-1 checks pass')" \
  "QA report comment → WARN" "no adversarial verification"
assert_warn "$H" "$(tracker mcp__linear__save_comment body 'Verdict: PASSED')" \
  "verdict comment → WARN"
assert_allow "$H" "$(tracker mcp__linear__save_comment body 'rebased onto main, retriggering CI')" \
  "ordinary comment → ALLOW"

section "adversarial-gate: a valid, fresh receipt unlocks sign-off"
printf '%s' '{"ticket":"ABC-1","negativeControl":{"failed":5,"passed":1,"skipped":0}}' \
  > "$WS/.achilles/adversarial-verification/ABC-1.json"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "receipt newer than specs → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__save_comment body 'QA Test Report: AC-1 pass')" \
  "receipt present → comment no longer warns"

section "adversarial-gate: a receipt older than the tests it vouches for is not a receipt"
sleep 1
touch "$WS/tests/a.spec.ts"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "spec edited after receipt → DENY" "OLDER than the most recently edited spec"

section "adversarial-gate: a receipt missing negativeControl does not count"
printf '%s' '{"ticket":"ABC-1","mutations":[]}' \
  > "$WS/.achilles/adversarial-verification/ABC-1.json"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "receipt without negativeControl → DENY" "No adversarial-verification receipt"

section "adversarial-gate: a receipt belongs to ONE ticket"
printf '%s' '{"ticket":"ABC-1","negativeControl":{"failed":5}}' \
  > "$WS/.achilles/adversarial-verification/ABC-1.json"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done OTHER-99)" \
  "another ticket's receipt does NOT unlock this one" "No adversarial-verification receipt"
assert_deny "$H" "$("$JQ" -nc '{tool_name:"mcp__linear__save_issue", tool_input:{state:"Done"}}')" \
  "payload with no ticket key → DENY (cannot verify whose receipt)"

section "adversarial-gate: escape hatches"
CIVITAS_DISABLE_ADVERSARIAL_GATE=1 \
  assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "kill-switch set → ALLOW"
ACHILLES_PROTOCOL=0 \
  assert_allow "$H" "$("$JQ" -nc '{tool_name:"mcp__linear__save_issue", session_id:"plain-dev-session", tool_input:{state:"Done"}}')" \
  "protocol inactive → ALLOW (plain dev sessions never feel this)"

unset WORKSPACE_ROOT ACHILLES_PROTOCOL
rm -rf "$WS"
