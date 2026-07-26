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

# A fully-covered phase-1 approval (every pinned [phase1] criterion id in
# criteriaCovered) — so these fixtures isolate the transcript READ check.
P1_COVERED='["list-zero-specs-clean","config-present","scaffold-dirs-present","gitignore-covers-artifacts"]'
APPROVE_CONTENT="$("$JQ" -nc --argjson c "$P1_COVERED" '{phases:[{id:1,reviewerVerdict:"approved",criteriaCovered:$c},{id:2,reviewerVerdict:"pending"}]}')"

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

section "reviewer-criteria-preread: coverage — approval must cover every pinned criterion"
# Partial coverage (drops a pinned [phase1] criterion) → DENY, even with the
# criteria read present (coverage is the transcript-independent hard gate).
PARTIAL=$("$JQ" -nc '{phases:[{id:1,reviewerVerdict:"approved",criteriaCovered:["list-zero-specs-clean","config-present"]},{id:2,reviewerVerdict:"pending"}]}')
assert_deny "$H" "$(wpayload "$PARTIAL" "$TRANS_READ")" \
  "approval covering only 2 of 4 pinned criteria → DENY" "does not cover every pinned criterion"
# No criteriaCovered field at all → DENY.
NOCOV=$("$JQ" -nc '{phases:[{id:1,reviewerVerdict:"approved"},{id:2,reviewerVerdict:"pending"}]}')
assert_deny "$H" "$(wpayload "$NOCOV" "$TRANS_READ")" \
  "approval with no criteriaCovered → DENY" "does not cover every pinned criterion"
# Full coverage but NO criteria read → still DENY (read check), different reason.
FULL_NOREAD=$("$JQ" -nc --argjson c "$P1_COVERED" '{phases:[{id:1,reviewerVerdict:"approved",criteriaCovered:$c},{id:2,reviewerVerdict:"pending"}]}')
assert_deny "$H" "$(wpayload "$FULL_NOREAD" "$TRANS_NONE")" \
  "full coverage but no criteria read → DENY (read check)" "without reading the pinned criteria"
# Coverage is transcript-INDEPENDENT: partial coverage denies even with NO transcript.
assert_deny "$H" "$("$JQ" -nc --arg f "$LEDGER" --arg c "$PARTIAL" --arg cw "$TMPRC" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:$cw,agent_id:"sub_rev"}')" \
  "partial coverage, no transcript → DENY (coverage is transcript-independent)" "does not cover every pinned criterion"

section "reviewer-criteria-preread: substage coverage (pass/cycle)"
# A pass approval must cover the [pass] pinned criteria.
PASS_IDS='["roster-dispatched-and-returned","dedup-commit-landed","stage-a-and-b-ran","pass1-per-journey-mode"]'
PASS_FULL=$("$JQ" -nc --argjson c "$PASS_IDS" '{phases:[{id:5,reviewerVerdict:"pending","subStages":[{id:"pass-2",reviewerVerdict:"approved",criteriaCovered:$c}]}]}')
assert_allow "$H" "$(wpayload "$PASS_FULL" "$TRANS_READ")" \
  "pass-2 approval covering all [pass] criteria + read → allow"
PASS_PARTIAL=$("$JQ" -nc '{phases:[{id:5,reviewerVerdict:"pending","subStages":[{id:"pass-2",reviewerVerdict:"approved",criteriaCovered:["dedup-commit-landed"]}]}]}')
assert_deny "$H" "$(wpayload "$PASS_PARTIAL" "$TRANS_READ")" \
  "pass-2 approval covering 1 of 4 [pass] criteria → DENY" "does not cover every pinned criterion"

rm -f "$TRANS_READ" "$TRANS_NONE" "$TRANS_BASH"
