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
printf '%s' '{"ticket":"ABC-1","negativeControl":{"failed":5,"passed":1,"skipped":0},"review":{"reviewer":"probe-rigour-x","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":3,"R2":2,"R3":2,"R4":2,"R5":2,"R6":2},"total":13}}' \
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
printf '%s' '{"ticket":"ABC-1","negativeControl":{"failed":5},"review":{"reviewer":"probe-rigour-x","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":3,"R2":2,"R3":2,"R4":2,"R5":2,"R6":2},"total":13}}' \
  > "$WS/.achilles/adversarial-verification/ABC-1.json"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done OTHER-99)" \
  "another ticket's receipt does NOT unlock this one" "No adversarial-verification receipt"
assert_deny "$H" "$("$JQ" -nc '{tool_name:"mcp__linear__save_issue", tool_input:{state:"Done"}}')" \
  "payload with no ticket key → DENY (cannot verify whose receipt)"

section "adversarial-gate: UUID ids resolve via the receipt's recorded ticket"
# Linear's save_issue commonly carries a UUID in .id, not a human key. Matching the FILENAME alone
# produced a permanent, unrecoverable DENY with the correct receipt on disk.
printf '%s' '{"ticket":"e0265f67-8efb-4d41-9310-557456c73b1e","negativeControl":{"failed":5},"review":{"reviewer":"probe-rigour-x","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":3,"R2":2,"R3":2,"R4":2,"R5":2,"R6":2},"total":13}}' \
  > "$WS/.achilles/adversarial-verification/QRS-1.json"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done e0265f67-8efb-4d41-9310-557456c73b1e)" \
  "UUID id matched via receipt's recorded ticket → ALLOW"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done 99999999-0000-0000-0000-000000000000)" \
  "unrelated UUID → DENY (cross-ticket hole stays closed)"

section "adversarial-gate: key binding is EXACT, not substring"
# Each of these was a working bypass on an ordinary, unshaped payload.
printf '%s' '{"ticket":"ABC-15","negativeControl":{"failed":5},"review":{"reviewer":"probe-rigour-x","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":3,"R2":2,"R3":2,"R4":2,"R5":2,"R6":2},"total":13}}' > "$WS/.achilles/adversarial-verification/ABC-15.json"
rm -f "$WS/.achilles/adversarial-verification/ABC-1.json" "$WS/.achilles/adversarial-verification/QRS-1.json"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ABC-1)" \
  "prefix collision: ABC-15's receipt must NOT sign off ABC-1"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done json)" \
  "skeleton key 'json' matches every receipt filename → DENY"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ---)" \
  "degenerate key → DENY"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-15)" \
  "exact key still ALLOWs"

section "adversarial-gate: the reviewer must green-light the coverage"

# A receipt says the AUTHOR ran the checks. These pin the second requirement: someone independent
# judged the coverage adequate, having looked at the UI and not only the specs. Each case is a
# distinct way a review can be PRESENT and still not a green light.
mk_review() {  # $1 = the .review object
  printf '%s' "{\"ticket\":\"ABC-1\",\"negativeControl\":{\"failed\":5},\"review\":$1}" \
    > "$WS/.achilles/adversarial-verification/ABC-1.json"
}

mk_review '{"reviewer":"r","uiReviewed":true,"coverageSufficient":false,"scores":{"R1":3},"total":15}'
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "reviewer says coverage insufficient → DENY" "did not conclude the coverage is sufficient"

# The one that matters most in practice: a reviewer who reads only specs can certify that every
# assertion is well-formed while the feature is visibly broken in a browser.
mk_review '{"reviewer":"r","uiReviewed":false,"coverageSufficient":true,"scores":{"R1":3},"total":15}'
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "specs-only review, UI never looked at → DENY" "did not review the UI"

mk_review '{"reviewer":"","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":3},"total":15}'
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "unnamed reviewer → DENY" "no reviewer is named"

# A zero blocks whatever the total says. 17/18 with one dimension at 0 is exactly the shape that
# ships a suite with excellent assertions and no negative control.
mk_review '{"reviewer":"r","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":3,"R2":0,"R3":3,"R4":3,"R5":3,"R6":3},"total":17}'
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "one dimension at 0 despite a 17/18 total → DENY" "scored 0"

mk_review '{"reviewer":"r","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":2,"R2":2,"R3":2,"R4":2,"R5":2,"R6":2},"total":12}'
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "total exactly at the 12 boundary → DENY" "rework before the report ships"

mk_review '{"reviewer":"r","uiReviewed":true,"coverageSufficient":true,"scores":{"R1":3,"R2":2,"R3":2,"R4":2,"R5":2,"R6":2},"total":13}'
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "13/18, no zeros, UI reviewed → ALLOW"

# Migration: a receipt written before this requirement existed must NOT keep passing silently.
printf '%s' '{"ticket":"ABC-1","negativeControl":{"failed":5}}' \
  > "$WS/.achilles/adversarial-verification/ABC-1.json"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "pre-existing receipt with no review block → DENY" "No adversarial-verification receipt"

section "adversarial-gate: the developer path — opening a PR is sign-off"

# A dev-triggered run never touches a tracker, so the gate also watches `gh pr create`. That means
# it now sees EVERY Bash call, which is the dangerous part: a gate that fires on ordinary shell use
# gets switched off the same day, and then it protects nothing. These cases pin silence far harder
# than they pin the denial.
bash_cmd() { "$JQ" -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

rm -f "$WS/.achilles/adversarial-verification"/*.json
BR="$(git -C "$WS" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"

assert_deny "$H" "$(bash_cmd 'gh pr create --title "feat: thing" --body "done"')" \
  "gh pr create with no receipt → DENY" "Sign-off blocked"

# Sharing work in progress is not a claim that it is verified.
assert_allow "$H" "$(bash_cmd 'gh pr create --draft --title "wip"')" \
  "gh pr create --draft → ALLOW (not a sign-off)"

# Reads, and everything else a developer types all day.
assert_allow "$H" "$(bash_cmd 'gh pr view 42')"            "gh pr view → ALLOW"
assert_allow "$H" "$(bash_cmd 'gh pr list')"               "gh pr list → ALLOW"
assert_allow "$H" "$(bash_cmd 'gh pr checkout 42')"        "gh pr checkout → ALLOW"
assert_allow "$H" "$(bash_cmd 'git status')"               "git status → ALLOW"
assert_allow "$H" "$(bash_cmd 'npm test')"                 "npm test → ALLOW"
assert_allow "$H" "$(bash_cmd 'ls -la')"                   "plain ls → ALLOW"
assert_allow "$H" "$(bash_cmd 'echo gh pr create')"        "the words inside an echo → ALLOW"
assert_allow "$H" "$(bash_cmd 'grep -r "gh pr create" .')" "the words inside a grep → ALLOW"

# With a green receipt bound to the BRANCH — entry B has no ticket key to bind to.
if [ -n "$BR" ]; then
  printf '%s' "{\"negativeControl\":{\"failed\":5},\"review\":{\"reviewer\":\"probe-rigour-x\",\"uiReviewed\":true,\"coverageSufficient\":true,\"scores\":{\"R1\":3,\"R2\":2,\"R3\":2,\"R4\":2,\"R5\":2,\"R6\":2},\"total\":13}}" \
    > "$WS/.achilles/adversarial-verification/${BR}.json"
  assert_allow "$H" "$(bash_cmd 'gh pr create --title "feat: thing"')" \
    "gh pr create with a branch-bound green receipt → ALLOW"

  # The binding must be exact here too: another branch's receipt must not sign off this one.
  mv "$WS/.achilles/adversarial-verification/${BR}.json" "$WS/.achilles/adversarial-verification/some-other-branch.json"
  assert_deny "$H" "$(bash_cmd 'gh pr create --title "feat: thing"')" \
    "another branch's receipt must NOT sign off this branch → DENY" "Sign-off blocked"
  rm -f "$WS/.achilles/adversarial-verification"/*.json
fi

section "adversarial-gate: escape hatches"
CIVITAS_DISABLE_ADVERSARIAL_GATE=1 \
  assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "kill-switch set → ALLOW"
ACHILLES_PROTOCOL=0 \
  assert_allow "$H" "$("$JQ" -nc '{tool_name:"mcp__linear__save_issue", session_id:"plain-dev-session", tool_input:{state:"Done"}}')" \
  "protocol inactive → ALLOW (plain dev sessions never feel this)"

unset WORKSPACE_ROOT ACHILLES_PROTOCOL
rm -rf "$WS"
