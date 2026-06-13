#!/bin/bash
# Tests for subagent-return-schema-guard.sh — JSON-Schema-backed validator
# (WARN mode). Validates subagent returns against schemas/subagent-returns/
# using Ajv. Hook fires on PostToolUse:Agent only.
H="$HOOK_DIR/subagent-return-schema-guard.sh"

section "subagent-return-schema: tool-name + description filtering"
assert_allow "$H" "$(payload tool_name=Bash command='echo hi')" "Bash tool → silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='phase1-root' response_text='free-form scaffold output')" "phase1- prefix → silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='stage2-cart' response_text='free-form page repo entries')" "stage2- prefix → silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='cleanup-ledger' response_text='free-form cleanup summary')" "cleanup- prefix → silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='unknown-role-x' response_text='whatever')" "unknown prefix → silent allow"

section "subagent-return-schema: empty / null responses are silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='composer-j-checkout' response_text='null')" "literal null → silent allow"

section "subagent-return-schema: well-formed composer return is silent allow"
GOOD_COMPOSER="handover:
  role: composer-j-checkout-1-c1
  cycle: 1
  status: new-tests-landed
  next-action: reviewer
journey: j-checkout
pass: 1
tests-added: 3
run-time: 42s
summary: Added three regression scenarios covering the checkout journey."
assert_allow "$H" "$(payload tool_name=Agent description='composer-j-checkout-1-c1' response_text="$GOOD_COMPOSER")" "well-formed composer → silent allow"

section "subagent-return-schema: composer missing handover envelope WARNs"
NO_ENVELOPE="journey: j-checkout
tests-added: 2
run-time: 30s
summary: some tests"
assert_warn "$H" "$(payload tool_name=Agent description='composer-j-checkout-1-c1' response_text="$NO_ENVELOPE")" "missing envelope → WARN" "must have required property 'handover'"

section "subagent-return-schema: composer status=new-tests-landed missing tests-added WARNs"
MISSING_FIELD="handover:
  role: composer-j-x-1-c1
  cycle: 1
  status: new-tests-landed
  next-action: reviewer
journey: j-x
pass: 1"
assert_warn "$H" "$(payload tool_name=Agent description='composer-j-x-1-c1' response_text="$MISSING_FIELD")" "missing tests-added → WARN" "tests-added"

section "subagent-return-schema: composer invalid status enum WARNs"
INVALID_STATUS="handover:
  role: composer-j-x-1-c1
  cycle: 1
  status: no-new-tests-by-rationalisation
  next-action: reviewer
journey: j-x
pass: 1"
assert_warn "$H" "$(payload tool_name=Agent description='composer-j-x-1-c1' response_text="$INVALID_STATUS")" "invalid status enum → WARN" "allowed values"

section "subagent-return-schema: reviewer improvements-needed without finding arrays WARNs"
IMPROVEMENTS_NO_FINDINGS="handover:
  role: reviewer-j-x-1-c1
  cycle: 1
  status: improvements-needed
  next-action: composer
journey: j-x
pass: 1
cycle: 1
summary: improvements needed but no finding arrays"
assert_warn "$H" "$(payload tool_name=Agent description='reviewer-j-x-1-c1' response_text="$IMPROVEMENTS_NO_FINDINGS")" "improvements-needed without findings → WARN" "missing-scenarios"

section "subagent-return-schema: well-formed reviewer return is silent allow"
GOOD_REVIEWER="handover:
  role: reviewer-j-checkout-1-c1
  cycle: 1
  status: greenlight
  next-action: orchestrator
journey: j-checkout
pass: 1
cycle: 1
summary: all expectations covered"
assert_allow "$H" "$(payload tool_name=Agent description='reviewer-j-checkout-1-c1' response_text="$GOOD_REVIEWER")" "well-formed reviewer → silent allow"

section "subagent-return-schema: probe findings-emitted without count WARNs"
PROBE_NO_COUNT="handover:
  role: probe-j-checkout-4-c1
  cycle: 1
  status: findings-emitted
  next-action: orchestrator
journey: j-checkout"
assert_warn "$H" "$(payload tool_name=Agent description='probe-j-checkout-4-c1' response_text="$PROBE_NO_COUNT")" "probe findings-emitted without count → WARN" "findings-emitted"

section "subagent-return-schema: well-formed probe return is silent allow"
GOOD_PROBE="handover:
  role: probe-j-checkout-4-c1
  cycle: 1
  status: clean
  next-action: orchestrator
journey: j-checkout
summary: No adversarial findings discovered."
assert_allow "$H" "$(payload tool_name=Agent description='probe-j-checkout-4-c1' response_text="$GOOD_PROBE")" "well-formed probe → silent allow"

section "subagent-return-schema: phase-validator greenlight without exit-criteria-checked WARNs"
PV_NO_EXIT_CRITERIA="handover:
  role: phase-validator-2
  cycle: 1
  status: greenlight
  next-action: orchestrator
phase: 2
summary: phase 2 complete"
assert_warn "$H" "$(payload tool_name=Agent description='phase-validator-2' response_text="$PV_NO_EXIT_CRITERIA")" "phase-validator greenlight no exit-criteria-checked → WARN" "exit-criteria-checked"

section "subagent-return-schema: well-formed phase-validator greenlight is silent allow"
GOOD_PV="handover:
  role: phase-validator-3
  cycle: 1
  status: greenlight
  next-action: orchestrator
phase: 3
exit-criteria-checked:
  - criterion: happy-path spec exists
    satisfied: true
summary: phase 3 complete"
assert_allow "$H" "$(payload tool_name=Agent description='phase-validator-3' response_text="$GOOD_PV")" "well-formed phase-validator greenlight → silent allow"

# Installed-layout (packaged node_modules) behavior is covered by Task 9's
# install simulation, not here.
section "subagent-return-schema: workflow-reviewer schema-invalid return WARNs"
BAD_WORKFLOW_REVIEWER="handover:
  role: workflow-reviewer-phase3
  cycle: 1
  status: approved
  next-action: orchestrator
verdict: maybe
phase: 3
summary: probably fine"
assert_warn "$H" "$(payload tool_name=Agent description='workflow-reviewer-phase3: review Phase 3 exit criteria' response_text="$BAD_WORKFLOW_REVIEWER")" "workflow-reviewer verdict: maybe → WARN" "workflow-reviewer"

section "subagent-return-schema: well-formed workflow-reviewer approve is silent allow"
GOOD_WORKFLOW_REVIEWER="handover:
  role: workflow-reviewer-phase3
  cycle: 1
  status: approved
  next-action: orchestrator may advance to Phase 4
verdict: approve
phase: 3
reviewerCycle: 1
attestation: Phase 3 exit criteria verified on disk
summary: Approved."
assert_allow "$H" "$(payload tool_name=Agent description='workflow-reviewer-phase3: review Phase 3 exit criteria' response_text="$GOOD_WORKFLOW_REVIEWER")" "well-formed workflow-reviewer approve → silent allow"

# ---------------------------------------------------------------------------
# §9 new prefixes: phase4-prioritise-author → phase4-prioritise-author schema,
# phase4-cycle-* → section-agent schema; companion-*/fd- → no schema (envelope
# sanity only).
section "subagent-return-schema: phase4-prioritise-author schema-invalid return WARNs (§9)"
# Non-object scalar return → schema fail ('/ must be object').
assert_warn "$H" "$(payload tool_name=Agent description='phase4-prioritise-author: rank journeys' response_text='just a bare string with no envelope')" \
  "phase4-prioritise-author bare scalar → WARN" "phase4-prioritise-author"

section "subagent-return-schema: well-formed phase4-prioritise-author is silent allow (§9)"
GOOD_AUTHOR="handover:
  role: phase4-prioritise-author
  cycle: 2
  status: complete
  next-action: orchestrator
summary: Authored the journey map from cycle returns."
assert_allow "$H" "$(payload tool_name=Agent description='phase4-prioritise-author: rank journeys' response_text="$GOOD_AUTHOR")" \
  "well-formed phase4-prioritise-author → silent allow"

section "subagent-return-schema: phase4-cycle-* maps to section-agent schema (§9)"
assert_warn "$H" "$(payload tool_name=Agent description='phase4-cycle-1-section-auth:' response_text='free text, no handover envelope')" \
  "phase4-cycle-1-section bare scalar → WARN" "section-agent"
GOOD_SECTION="handover:
  role: phase4-cycle-1-section-auth
  cycle: 1
  status: complete
  next-action: orchestrator
kind: section
section: auth
summary: Mapped the auth section."
assert_allow "$H" "$(payload tool_name=Agent description='phase4-cycle-1-section-auth:' response_text="$GOOD_SECTION")" \
  "well-formed section-agent return → silent allow"

section "subagent-return-schema: companion-* / fd-* are envelope-sanity (no schema)"
# Known prefix, no schema: a well-formed envelope silent-allows (the schema
# step is skipped; only the handover-cycle sanity check runs).
COMPANION_OK="handover:
  role: companion-verify-login
  cycle: 0
  status: complete
  next-action: orchestrator
summary: Verified login with evidence."
assert_allow "$H" "$(payload tool_name=Agent description='companion-verify-login' response_text="$COMPANION_OK")" \
  "companion-* well-formed envelope → silent allow (no schema)"
assert_allow "$H" "$(payload tool_name=Agent description='fd-flaky-cart' response_text='free-form diagnosis output')" \
  "fd-* free-form return → silent allow (no schema)"

# ---------------------------------------------------------------------------
# §13: calibration log + strict mode.
section "subagent-return-schema: calibration log captures a validation line"
SGUARD_REPO=$(mktemp -d /tmp/sguard-log-XXXXXX)
( cd "$SGUARD_REPO" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
# An invalid composer return (missing handover) — WARN path; should log
# valid:false to .achilles/schema-guard-log.jsonl.
BADCOMP="journey: j-x
tests-added: 1
summary: nope"
run_hook "$H" "$(payload tool_name=Agent description='composer-j-x-1-c1' response_text="$BADCOMP" cwd="$SGUARD_REPO")"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$SGUARD_REPO/.achilles/schema-guard-log.jsonl" ] \
   && "$JQ" -e 'select(.valid==false and .role=="composer")' "$SGUARD_REPO/.achilles/schema-guard-log.jsonl" >/dev/null 2>&1; then
  TESTS_PASSED=$((TESTS_PASSED + 1)); echo "${CLR_PASS}  ✓${CLR_RST} calibration log records {role,valid:false} line"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); echo "${CLR_FAIL}  ✗${CLR_RST} calibration log records {role,valid:false} line"
  FAIL_DETAILS+=("calibration log: expected a valid:false composer line in $SGUARD_REPO/.achilles/schema-guard-log.jsonl")
fi

section "subagent-return-schema: SCHEMA_RETURN_GUARD=strict BLOCKS (exit 2)"
TESTS_RUN=$((TESTS_RUN + 1))
STRICT_EC=0
printf '%s' "$(payload tool_name=Agent description='composer-j-x-1-c1' response_text="$BADCOMP" cwd="$SGUARD_REPO")" \
  | SCHEMA_RETURN_GUARD=strict bash "$H" >/dev/null 2>/tmp/sguard-strict-err.$$ || STRICT_EC=$?
if [ "$STRICT_EC" = "2" ] && grep -q 'SCHEMA_RETURN_GUARD=strict' /tmp/sguard-strict-err.$$; then
  TESTS_PASSED=$((TESTS_PASSED + 1)); echo "${CLR_PASS}  ✓${CLR_RST} strict mode → exit 2 with re-dispatch message"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); echo "${CLR_FAIL}  ✗${CLR_RST} strict mode → exit 2 with re-dispatch message"
  FAIL_DETAILS+=("strict mode: expected exit 2, got $STRICT_EC")
fi
rm -f /tmp/sguard-strict-err.$$
rm -rf "$SGUARD_REPO"
