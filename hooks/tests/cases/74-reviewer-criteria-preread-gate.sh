#!/bin/bash
# Tests for reviewer-criteria-preread-gate.sh — PreToolUse:Write|Edit gate
# that DENIES an onboarding-ledger approval write unless the approving
# context's transcript shows it Read the pinned criteria file. Fail-open on
# missing transcript; achilles projects only.
H="$HOOK_DIR/reviewer-criteria-preread-gate.sh"

TMPRC=$(mktemp -d)
trap 'rm -rf "$TMPRC"' EXIT
( cd "$TMPRC" && git init -q ) >/dev/null 2>&1
mkdir -p "$TMPRC/tests/e2e/docs"
LEDGER="$TMPRC/tests/e2e/docs/onboarding-status.json"
echo '{"phases":[{"id":1,"reviewerVerdict":"pending"},{"id":2,"reviewerVerdict":"pending"}]}' > "$LEDGER"

# Transcript with a Read of the pinned criteria file.
TRANS_READ=$(mktemp)
echo '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/root/.claude/hooks/data/reviewer-criteria.txt"}}]}}' > "$TRANS_READ"
# Transcript WITHOUT a criteria read.
TRANS_NONE=$(mktemp)
echo '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"tests/e2e/docs/onboarding-status.json"}}]}}' > "$TRANS_NONE"
# Transcript that read the criteria via Bash cat.
TRANS_BASH=$(mktemp)
echo '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat ~/.claude/hooks/data/reviewer-criteria.txt"}}]}}' > "$TRANS_BASH"

APPROVE_CONTENT='{"phases":[{"id":1,"reviewerVerdict":"approved"},{"id":2,"reviewerVerdict":"pending"}]}'

wpayload() { # <content> <transcript>
  "$JQ" -nc --arg f "$LEDGER" --arg c "$1" --arg cw "$TMPRC" --arg tp "$2" \
    '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:$cw,transcript_path:$tp,agent_id:"sub_rev"}'
}

section "reviewer-criteria-preread: tool + path filtering"
assert_allow "$H" "$(payload tool_name=Bash command='ls')" "Bash → silent allow"
assert_allow "$H" "$("$JQ" -nc --arg cw "$TMPRC" '{tool_name:"Write",tool_input:{file_path:"/tmp/other.json",content:"{}"},cwd:$cw}')" \
  "Write to a non-ledger path → silent allow"

section "reviewer-criteria-preread: approval write requires a criteria read"
assert_deny "$H" "$(wpayload "$APPROVE_CONTENT" "$TRANS_NONE")" \
  "approval, transcript has no criteria read → DENY" "without reading the pinned criteria"
assert_allow "$H" "$(wpayload "$APPROVE_CONTENT" "$TRANS_READ")" \
  "approval, transcript shows Read of criteria → allow"
assert_allow "$H" "$(wpayload "$APPROVE_CONTENT" "$TRANS_BASH")" \
  "approval, transcript shows cat of criteria → allow"

section "reviewer-criteria-preread: non-approval writes are ignored"
assert_allow "$H" "$(wpayload '{"phases":[{"id":1,"reviewerVerdict":"pending"}]}' "$TRANS_NONE")" \
  "write with no new approval → allow"
assert_allow "$H" "$(wpayload '{"phases":[{"id":1,"reviewerVerdict":"rejected"}]}' "$TRANS_NONE")" \
  "write transitioning to rejected → allow"

section "reviewer-criteria-preread: fail-open on missing transcript"
assert_allow "$H" "$("$JQ" -nc --arg f "$LEDGER" --arg c "$APPROVE_CONTENT" --arg cw "$TMPRC" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:$cw,agent_id:"sub_rev"}')" \
  "approval, no transcript_path → allow (fail-open)"
assert_allow "$H" "$("$JQ" -nc --arg f "$LEDGER" --arg c "$APPROVE_CONTENT" --arg cw "$TMPRC" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:$cw,transcript_path:"/nonexistent/x.jsonl",agent_id:"sub_rev"}')" \
  "approval, bogus transcript_path → allow (fail-open)"

section "reviewer-criteria-preread: Edit introducing an approved verdict is gated"
assert_deny "$H" "$("$JQ" -nc --arg f "$LEDGER" --arg cw "$TMPRC" --arg tp "$TRANS_NONE" \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"\"reviewerVerdict\":\"pending\"",new_string:"\"reviewerVerdict\": \"approved\""},cwd:$cw,transcript_path:$tp,agent_id:"sub_rev"}')" \
  "Edit introducing reviewerVerdict approved, no criteria read → DENY" "without reading the pinned criteria"
assert_allow "$H" "$("$JQ" -nc --arg f "$LEDGER" --arg cw "$TMPRC" --arg tp "$TRANS_READ" \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"\"reviewerVerdict\":\"pending\"",new_string:"\"reviewerVerdict\": \"approved\""},cwd:$cw,transcript_path:$tp,agent_id:"sub_rev"}')" \
  "Edit introducing approved, criteria read present → allow"

section "reviewer-criteria-preread: non-achilles project → inert"
PLAINRC=$(mktemp -d)
( cd "$PLAINRC" && git init -q ) >/dev/null 2>&1
mkdir -p "$PLAINRC/tests/e2e/docs"
echo '{}' > "$PLAINRC/tests/e2e/docs/onboarding-status.json"
# Make it NOT an achilles project (no .achilles, no deps) — but tests/e2e/docs
# IS an achilles marker, so this dir DOES qualify; instead use a path with no
# achilles markers by pointing the ledger elsewhere is not possible (path is
# fixed). So assert the escape hatch instead.
OFF_OUT=$(printf '%s' "$(wpayload "$APPROVE_CONTENT" "$TRANS_NONE")" | REVIEWER_CRITERIA_PREREAD_GATE=off bash "$H" 2>/dev/null)
assert_eq "$OFF_OUT" "" "REVIEWER_CRITERIA_PREREAD_GATE=off → silent allow"
rm -rf "$PLAINRC"

rm -f "$TRANS_READ" "$TRANS_NONE" "$TRANS_BASH"
