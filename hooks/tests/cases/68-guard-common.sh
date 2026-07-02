#!/bin/bash
# Tests for lib/guard-common.sh — the shared path-normalisation + fail-closed
# primitives used by the Write|Edit path-matching DENY guards.
LIB="$HOOK_DIR/lib/guard-common.sh"

section "guard-common: normalize_path self-test passes"
run_selftest_ec=0
GUARD_COMMON_SELFTEST=1 bash "$LIB" >/dev/null 2>&1 || run_selftest_ec=$?
assert_eq "$run_selftest_ec" "0" "GUARD_COMMON_SELFTEST exits 0 (all normalize_path cases pass)"

section "guard-common: normalize_path collapses evasion forms"
# shellcheck source=/dev/null
source "$LIB"
assert_eq "$(normalize_path '/h/.claude/./settings.json')"           "/h/.claude/settings.json"          "dot segment collapsed"
assert_eq "$(normalize_path '/h/.claude//settings.json')"            "/h/.claude/settings.json"          "double slash collapsed"
assert_eq "$(normalize_path '/h/.claude/hooks/../settings.json')"    "/h/.claude/settings.json"          "parent segment resolved"
assert_eq "$(normalize_path 'tests/e2e//docs/./onboarding-status.json')" "/tests/e2e/docs/onboarding-status.json" "relative + mixed collapsed"
assert_eq "$(normalize_path '/*/glob/[weird]/p')"                    "/*/glob/[weird]/p"                 "glob chars left literal (no word-split)"

section "guard-common: fail-closed helper emits a well-formed deny"
DENY_JSON="$(guard_emit_deny_no_jq 'unit-test-guard')"
DECISION="$(printf '%s' "$DENY_JSON" | "$JQ" -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
assert_eq "$DECISION" "deny" "guard_emit_deny_no_jq → permissionDecision:deny"
REASON="$(printf '%s' "$DENY_JSON" | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
if echo "$REASON" | grep -qF "unit-test-guard"; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} deny reason names the guard label"
else
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("guard_emit_deny_no_jq: reason missing label"); echo "${CLR_FAIL}  ✗${CLR_RST} deny reason names the guard label"
fi
