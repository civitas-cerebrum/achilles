#!/bin/bash
# Tests for run-summary-writer.sh — Stop hook that writes
# <project>/.achilles/run-summary.json (schema run-summary/v2) from the
# artifacts the skills actually write:
#   tests/e2e/docs/onboarding-status.json
#   tests/e2e/docs/adversarial-findings.md
#   tests/e2e/docs/journey-map.md
#   playwright-report/results.json | test-results/results.json
H="$HOOK_DIR/run-summary-writer.sh"
FIXTURE="$HOOK_DIR/tests/fixtures/run-summary-project"
STOP_PAYLOAD='{"hook_event_name":"Stop"}'

# Run the hook from a given project dir in a subshell so the runner's
# cwd is untouched. Captures stdout into RSW_OUT.
rsw_run() {
  local dir="$1"
  RSW_OUT=$( cd "$dir" && printf '%s' "$STOP_PAYLOAD" | bash "$H" 2>/dev/null )
}

# ---------------------------------------------------------------------------
section "run-summary-writer: full fixture project"
RSW_TMP_A=$(mktemp -d /tmp/run-summary-a-XXXXXX)
cp -R "$FIXTURE/." "$RSW_TMP_A/"
rsw_run "$RSW_TMP_A"
SUMMARY="$RSW_TMP_A/.achilles/run-summary.json"

assert_eq "$RSW_OUT" "{}" "hook stdout is {}"
assert_eq "$("$JQ" -r '.tests.passing' "$SUMMARY")" "2" "passing from stats.expected"
assert_eq "$("$JQ" -r '.tests.flaky' "$SUMMARY")" "1" "flaky counted"
assert_eq "$("$JQ" -r '.tests.status' "$SUMMARY")" "failing" "real status, not hardcoded pass"
assert_eq "$("$JQ" -r '.bugs.by_severity.critical' "$SUMMARY")" "1" "critical findings counted"
assert_eq "$("$JQ" -r '.bugs.by_severity.high' "$SUMMARY")" "1" "high findings counted"
assert_eq "$("$JQ" -r '.bugs.by_severity.medium' "$SUMMARY")" "1" "medium findings counted"
assert_eq "$("$JQ" -r '.bugs.by_severity.low' "$SUMMARY")" "0" "low findings zero"
assert_eq "$("$JQ" -r '.bugs.by_severity.info' "$SUMMARY")" "0" "info findings zero"
assert_eq "$("$JQ" -r '.bugs.ids | length' "$SUMMARY")" "3" "finding ids listed"
assert_eq "$("$JQ" -r '.bugs.ids[0]' "$SUMMARY")" "j-login-4-01" "first finding id verbatim"
assert_eq "$("$JQ" -r '.phases | length' "$SUMMARY")" "8" "phases from real ledger path"
assert_eq "$("$JQ" -r '.journey_map.journeys' "$SUMMARY")" "2" "journeys counted from journey-map headings"
assert_eq "$("$JQ" -r '.meta.timestamp | length > 0' "$SUMMARY")" "true" "meta.timestamp nonempty"
assert_eq "$("$JQ" -r '.meta.schema' "$SUMMARY")" "run-summary/v2" "schema is run-summary/v2"

# ---------------------------------------------------------------------------
section "run-summary-writer: output validates against run-summary schema (#18)"
# The writer's output must conform to schemas/run-summary.schema.json
# (authored + bundled by P7). Validate the produced file through the same
# bundle the other gates use. Skip gracefully if the schema isn't in the
# bundle yet (P7 dependency).
RSW_VALIDATOR="$HOOK_DIR/lib/validator.bundle.mjs"
RSW_NODE=$(command -v node 2>/dev/null || true)
if [ -n "$RSW_NODE" ] && [ -f "$RSW_VALIDATOR" ] \
   && ! "$RSW_NODE" "$RSW_VALIDATOR" validate run-summary "$SUMMARY" 2>&1 | grep -q 'No schema for id'; then
  TESTS_RUN=$((TESTS_RUN + 1))
  RSW_VAL_OUT=$("$RSW_NODE" "$RSW_VALIDATOR" validate run-summary "$SUMMARY" 2>&1)
  RSW_VAL_EC=$?
  if [ "$RSW_VAL_EC" = "0" ] && [ -z "$RSW_VAL_OUT" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "${CLR_PASS}  ✓${CLR_RST} run-summary output validates against run-summary schema"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("run-summary schema validation: ${RSW_VAL_OUT:0:200}")
    echo "${CLR_FAIL}  ✗${CLR_RST} run-summary output validates against run-summary schema ${CLR_DIM}(${RSW_VAL_OUT:0:120})${CLR_RST}"
  fi
else
  echo "${CLR_DIM}  (run-summary schema not in validator bundle — skipping schema validation; ships with P7)${CLR_RST}"
fi

# ---------------------------------------------------------------------------
section "run-summary-writer: empty project never fakes a pass"
RSW_TMP_B=$(mktemp -d /tmp/run-summary-b-XXXXXX)
rsw_run "$RSW_TMP_B"
SUMMARY="$RSW_TMP_B/.achilles/run-summary.json"

assert_eq "$("$JQ" -r '.tests.status' "$SUMMARY")" "null" "no results file → status null"
assert_eq "$("$JQ" -r '.tests.passing' "$SUMMARY")" "null" "no results file → passing null"
assert_eq "$("$JQ" -c '.bugs.ids' "$SUMMARY")" "[]" "no findings ledger → empty ids"

# ---------------------------------------------------------------------------
section "run-summary-writer: stats-less results.json falls back to per-test walk"
RSW_TMP_C=$(mktemp -d /tmp/run-summary-c-XXXXXX)
cp -R "$FIXTURE/." "$RSW_TMP_C/"
"$JQ" 'del(.stats)' "$FIXTURE/playwright-report/results.json" \
  > "$RSW_TMP_C/playwright-report/results.json"
rsw_run "$RSW_TMP_C"
SUMMARY="$RSW_TMP_C/.achilles/run-summary.json"

assert_eq "$("$JQ" -r '.tests.passing' "$SUMMARY")" "2" "fallback: last-result-per-test passing"
assert_eq "$("$JQ" -r '.tests.failing' "$SUMMARY")" "1" "fallback: last-result-per-test failing"
assert_eq "$("$JQ" -r '.tests.status' "$SUMMARY")" "failing" "fallback: status from failing count"
assert_eq "$("$JQ" -r '.tests.flaky' "$SUMMARY")" "null" "fallback: flaky unknowable → null"
assert_eq "$("$JQ" -r '.tests.total' "$SUMMARY")" "3" "fallback: total from test count"

rm -rf "$RSW_TMP_A" "$RSW_TMP_B" "$RSW_TMP_C"
