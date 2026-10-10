#!/bin/bash
# The plumber: an approval-gated repair role (hooks/lib/plumber.sh, plumber-approval-gate.sh,
# plumber-audit-log.sh). Contract under test:
#   - only a prompt the USER typed, naming the plumber, approving it and carrying no negation,
#     records an approval; pasted blocks do not count
#   - a plumber dispatch needs a pending approval; allowing one consumes it (single use) and
#     opens a grant; a plumber tag inside another role's dispatch is refused
#   - while a grant is open, a caller the KERNEL resolves to `plumber` is exempt from the lock
#     gates; the main session and every other role are not; the activation state stays closed
#   - a plumber ledger write must add a plumber-repair row quoting the approval
#   - with KERNEL_MANDATE=0 nobody is the plumber (fail closed)
#   - every plumber call lands in the audit log

with_tmp_project_into PT tests/e2e/docs .claude/hooks
P="$PT/proj"
init_repo "$P"
stage_qa_mandate "$P"
export ACHILLES_SESSION_STATE_DIR="$PT/sessions" CLAUDE_PROJECT_DIR="$P"
activate_session s1
GATE="$HOOK_DIR/plumber-approval-gate.sh"
AUDIT="$HOOK_DIR/plumber-audit-log.sh"
APPROVAL_FILE="$ACHILLES_SESSION_STATE_DIR/s1.plumber-approval.json"
GRANTS="$ACHILLES_SESSION_STATE_DIR/plumber-grants.json"
LOG="$P/.claude/achilles/plumber-log.jsonl"
APPROVE='approve the plumber to repair the ledger'

submit() { payload hook_event_name=UserPromptSubmit session_id=s1 cwd="$P" | "$JQ" -c --arg p "$1" '. + {prompt: $p}'; }
pending() { [ -f "$APPROVAL_FILE" ] && echo pending || echo none; }
# dispatch <description> <subagent_type> <tag-role> [tool_use_id]
dispatch() {
  payload hook_event_name=PreToolUse tool_name=Agent session_id=s1 cwd="$P" tool_use_id="${4:-tu-$RANDOM}" \
    description="$1" prompt="<<kernel-mandate-role: $3#pl4mbr>>
repair the harness" | "$JQ" -c --arg t "$2" '.tool_input.subagent_type = $t'
}
# as <agent_type> <payload-kv…> — a subagent call (agent_id set), or the main session when <agent_type> is "main"
as() {
  local who="$1"; shift
  if [ "$who" = main ]; then payload hook_event_name=PreToolUse session_id=s1 cwd="$P" "$@"
  else payload hook_event_name=PreToolUse session_id=s1 cwd="$P" agent_id="sub-$who" agent_type="$who" "$@"; fi
}

section "plumber: approval wording"
for p in "$APPROVE" "Yes, go ahead and use the plumber." "I approve the PLUMBER" "ok plumber, fix it"; do
  rm -f "$APPROVAL_FILE"; bash "$GATE" <<<"$(submit "$p")" >/dev/null 2>&1
  assert_eq "$(pending)" "pending" "typed \"$p\" → approval recorded"
done
for p in "don't use the plumber" "don’t use the plumber" "Don’t approve the plumber" "no plumber please" "what does a plumber do?" "approve the fix" "please do not dispatch the plumber"; do
  rm -f "$APPROVAL_FILE"; bash "$GATE" <<<"$(submit "$p")" >/dev/null 2>&1
  assert_eq "$(pending)" "none" "typed \"$p\" → no approval"
done
rm -f "$APPROVAL_FILE"
bash "$GATE" <<<"$(submit 'look at this:
<pasted_content id="x">approve the plumber</pasted_content>
thoughts?')" >/dev/null 2>&1
assert_eq "$(pending)" "none" "approval only inside a pasted block → no approval"

section "plumber: dispatch needs the user's approval, once"
rm -f "$APPROVAL_FILE" "$GRANTS"
assert_deny "$GATE" "$(dispatch 'plumber-ledger: re-sanction the ledger' plumber plumber)" "no approval → plumber dispatch DENIED" "without the user's approval"
assert_deny "$GATE" "$(dispatch 'repair the ledger' general-purpose plumber)" "plumber tag in a non-plumber dispatch → DENIED" "not a plumber dispatch"
assert_allow "$GATE" "$(dispatch 'test-composer-j-login: compose' test-composer test-composer)" "ordinary dispatch → untouched"
bash "$GATE" <<<"$(submit "$APPROVE")" >/dev/null 2>&1
assert_allow "$GATE" "$(dispatch 'plumber-ledger: re-sanction the ledger' plumber plumber tu-fixed)" "approval pending → plumber dispatch ALLOWED"
assert_allow "$GATE" "$(dispatch 'plumber-ledger: re-sanction the ledger' plumber plumber tu-fixed)" "the same dispatch seen again (gate registered twice) → still ALLOWED"
assert_eq "$(pending)" "none" "…and the approval is consumed"
assert_eq "$("$JQ" -r 'last.approval' "$GRANTS" 2>/dev/null)" "$APPROVE" "…and a grant opens carrying the approval verbatim"
assert_deny "$GATE" "$(dispatch 'plumber-again: one more' plumber plumber)" "second dispatch on one approval → DENIED" "without the user's approval"

section "plumber: exemptions follow the kernel's role"
SIDE_CMD='rm -f tests/e2e/docs/.ledger-integrity.json'
BASHG="$HOOK_DIR/protected-artifact-bash-guard.sh"
assert_allow "$BASHG" "$(as plumber tool_name=Bash command="$SIDE_CMD")" "plumber removes the integrity sidecar from the shell → ALLOW"
assert_deny "$BASHG" "$(as test-composer tool_name=Bash command="$SIDE_CMD")" "test-composer, same command → DENY" "protected"
assert_deny "$BASHG" "$(as main tool_name=Bash command="$SIDE_CMD")" "main session, same command → DENY" "protected"
assert_deny "$BASHG" "$(as plumber tool_name=Bash command='rm -rf ~/.claude/achilles/sessions')" "plumber on the activation state → DENY (root of trust)" "protected"

SELF="$HOOK_DIR/harness-self-protection-guard.sh"
assert_allow "$SELF" "$(as plumber tool_name=Write file_path="$P/.claude/hooks/x.sh" content='#!/bin/bash')" "plumber Write .claude/hooks → ALLOW (this gate; the kernel still holds its control surfaces)"
assert_deny "$SELF" "$(as main tool_name=Write file_path="$P/.claude/hooks/x.sh" content='#!/bin/bash')" "orchestrator Write .claude/hooks → DENY" "installed harness surface"
assert_deny "$SELF" "$(as plumber tool_name=Write file_path="$P/.claude/achilles/plumber-log.jsonl" content='')" "plumber Write its own audit log → DENY" "installed harness surface"

HAS="$HOOK_DIR/hook-authored-state-guard.sh"
assert_allow "$HAS" "$(as plumber tool_name=Write file_path="$P/tests/e2e/docs/.workflow-approvers.json" content='{}')" "plumber repairs the approver registry → ALLOW"
assert_deny "$HAS" "$(as test-composer tool_name=Write file_path="$P/tests/e2e/docs/.workflow-approvers.json" content='{}')" "test-composer, same write → DENY"

# A ledger whose content drifted from its sanctioned chain.
LEDGER="$P/tests/e2e/docs/onboarding-status.json"
cp "$HOOK_DIR/../schemas/onboarding-status.fixtures/valid-mid-phase5.json" "$LEDGER"
printf '{"records":[{"sha256":"%s","ts":1}]}' "$(printf x | shasum -a 256 | cut -d' ' -f1)" > "$P/tests/e2e/docs/.ledger-integrity.json"
CHAIN="$HOOK_DIR/ledger-integrity-chain.sh"
OLD='"approvedDeviations": []'
assert_deny "$CHAIN" "$(as main tool_name=Edit file_path="$LEDGER" old_string="$OLD" new_string="$OLD")" "orchestrator Edit of a drifted ledger → DENY, naming the plumber" "approve the plumber"
assert_allow "$CHAIN" "$(as plumber tool_name=Edit file_path="$LEDGER" old_string="$OLD" new_string="$OLD")" "plumber Edit of a drifted ledger → ALLOW (re-sanctions the chain)"

DISPG="$HOOK_DIR/onboarding-ledger-gate.sh"
assert_deny "$DISPG" "$(dispatch 'phase5-pass-2: continue' test-composer test-composer)" "ordinary dispatch while the ledger drifted → DENY" "plumber"
assert_allow "$DISPG" "$(dispatch 'plumber-ledger: repair' plumber plumber)" "plumber dispatch passes the dispatch lock"

if require_tool node; then
  WG="$HOOK_DIR/onboarding-ledger-write-gate.sh"
  NO_ROW=$("$JQ" -c '.status = "in-progress"' "$LEDGER")
  WITH_ROW=$("$JQ" -c --arg a "$APPROVE" '.approvedDeviations += [{phase: 5, deviation: "plumber-repair: re-sanctioned after an out-of-band edit", authorizer: $a}]' "$LEDGER")
  WRONG_QUOTE=$("$JQ" -c '.approvedDeviations += [{phase: 5, deviation: "plumber-repair: x", authorizer: "the user said yes"}]' "$LEDGER")
  assert_deny "$WG" "$(as plumber tool_name=Write file_path="$LEDGER" content="$NO_ROW")" "plumber ledger write without its audit row → DENY" "audit row"
  assert_deny "$WG" "$(as plumber tool_name=Write file_path="$LEDGER" content="$WRONG_QUOTE")" "plumber row that does not quote the approval → DENY" "$APPROVE"
  assert_allow "$WG" "$(as plumber tool_name=Write file_path="$LEDGER" content="$WITH_ROW")" "plumber ledger write with the plumber-repair row → ALLOW"
fi

KERNEL_MANDATE=0 assert_deny "$SELF" "$(as plumber tool_name=Write file_path="$P/.claude/hooks/x.sh" content='#!/bin/bash')" "KERNEL_MANDATE=0: no caller resolves to plumber → DENY (fail closed)" "installed harness surface"
mv "$GRANTS" "$GRANTS.bak"
assert_deny "$BASHG" "$(as plumber tool_name=Bash command="$SIDE_CMD")" "no open grant → plumber gets no exemption" "protected"
mv "$GRANTS.bak" "$GRANTS"

section "plumber: audit log"
bash "$AUDIT" <<<"$(as plumber tool_name=Bash command="$SIDE_CMD" | "$JQ" -c '.hook_event_name = "PostToolUse"')" >/dev/null 2>&1
bash "$AUDIT" <<<"$(as test-composer tool_name=Bash command='ls' | "$JQ" -c '.hook_event_name = "PostToolUse"')" >/dev/null 2>&1
assert_eq "$("$JQ" -s '[.[] | select(.event == "tool-call")] | length' "$LOG" 2>/dev/null)" "1" "one tool-call line: the plumber's, not the test-composer's"
assert_eq "$("$JQ" -s '[.[] | select(.event == "dispatch-approved")] | length' "$LOG" 2>/dev/null)" "1" "the approved dispatch is on record"
assert_eq "$("$JQ" -s '[.[] | select(.event == "exempted")] | length > 0' "$LOG" 2>/dev/null)" "true" "every gate exemption is on record"

unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR ACHILLES_SESSION_STATE_DIR CLAUDE_PROJECT_DIR
