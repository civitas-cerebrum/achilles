#!/bin/bash
# Tests for perf-summary-writer.sh — Stop hook that writes
# <project>/.achilles/perf-summary.json (schema perf-summary/v1) from the
# artifacts the perf skills actually write:
#   tests/perf/docs/perf-onboarding-status.json
#   tests/perf/scenarios/*.js
#   tests/perf/results/*.json
#   tests/perf/baselines/*.json
H="$HOOK_DIR/perf-summary-writer.sh"
FIXTURE="$HOOK_DIR/tests/fixtures/perf-summary-project"
STOP_PAYLOAD='{"hook_event_name":"Stop"}'

# Run the hook from a given project dir in a subshell so the runner's
# cwd is untouched. Captures stdout into PSW_OUT.
psw_run() {
  local dir="$1"
  PSW_OUT=$( cd "$dir" && printf '%s' "$STOP_PAYLOAD" | bash "$H" 2>/dev/null )
}

# ---------------------------------------------------------------------------
section "perf-summary-writer: no perf ledger → no-op (non-perf project)"
PSW_TMP_A=$(mktemp -d /tmp/perf-summary-a-XXXXXX)
psw_run "$PSW_TMP_A"

assert_eq "$PSW_OUT" "{}" "hook stdout is {} when no ledger"
assert_eq "$([ -f "$PSW_TMP_A/.achilles/perf-summary.json" ] && echo yes || echo no)" "no" "no perf-summary.json written for non-perf project"

# ---------------------------------------------------------------------------
section "perf-summary-writer: ledger present + results → summary written with correct schema const + phases passthrough"
PSW_TMP_B=$(mktemp -d /tmp/perf-summary-b-XXXXXX)
cp -R "$FIXTURE/." "$PSW_TMP_B/"
psw_run "$PSW_TMP_B"
SUMMARY="$PSW_TMP_B/.achilles/perf-summary.json"

assert_eq "$PSW_OUT" "{}" "hook stdout is {}"
assert_eq "$("$JQ" -r '.meta.schema' "$SUMMARY")" "perf-summary/v1" "meta.schema const is perf-summary/v1"
assert_eq "$("$JQ" -r '.meta.generatedAt | length > 0' "$SUMMARY")" "true" "meta.generatedAt nonempty"
assert_eq "$("$JQ" -r '.meta.runMode' "$SUMMARY")" "standard" "meta.runMode from ledger"
assert_eq "$("$JQ" -r '.phases | length' "$SUMMARY")" "2" "phases passthrough from ledger"
assert_eq "$("$JQ" -r '.phases[0].name' "$SUMMARY")" "Scaffold" "first phase name verbatim"
assert_eq "$("$JQ" -r '.scenarios.files | length' "$SUMMARY")" "1" "scenario file found"
assert_eq "$("$JQ" -r '.slo_results | length' "$SUMMARY")" "1" "one slo_result entry"
assert_eq "$("$JQ" -r '.slo_results[0].scenario' "$SUMMARY")" "load" "scenario name from result file"
assert_eq "$("$JQ" -r '.slo_results[0].p95Ms' "$SUMMARY")" "250.0" "p95Ms parsed from k6 summary"
assert_eq "$("$JQ" -r '.slo_results[0].p99Ms' "$SUMMARY")" "380.0" "p99Ms parsed from k6 summary"
assert_eq "$("$JQ" -r '.slo_results[0].verdict' "$SUMMARY")" "passing" "verdict passing when thresholds ok"
assert_eq "$("$JQ" -r '.baseline_comparison | length' "$SUMMARY")" "1" "one baseline_comparison entry"
assert_eq "$("$JQ" -r '.baseline_comparison[0].scenario' "$SUMMARY")" "load" "baseline scenario name"
assert_eq "$("$JQ" -r '.baseline_comparison[0].baselineP95Ms' "$SUMMARY")" "200.0" "baselineP95Ms from baseline file"
assert_eq "$("$JQ" -r '.baseline_comparison[0].currentP95Ms' "$SUMMARY")" "250.0" "currentP95Ms from result file"
assert_eq "$("$JQ" -r '.baseline_comparison[0].regressionPct != null' "$SUMMARY")" "true" "regressionPct computed"

# ---------------------------------------------------------------------------
section "perf-summary-writer: ledger present + NO results → slo_results verdicts are null (not fabricated passing)"
PSW_TMP_C=$(mktemp -d /tmp/perf-summary-c-XXXXXX)
cp -R "$FIXTURE/." "$PSW_TMP_C/"
# Remove the results directory so no result files are present
rm -rf "$PSW_TMP_C/tests/perf/results"
psw_run "$PSW_TMP_C"
SUMMARY="$PSW_TMP_C/.achilles/perf-summary.json"

assert_eq "$PSW_OUT" "{}" "hook stdout is {} even with no results"
assert_eq "$("$JQ" -r '.meta.schema' "$SUMMARY")" "perf-summary/v1" "schema const present"
assert_eq "$("$JQ" -c '.slo_results' "$SUMMARY")" "[]" "slo_results empty when no results dir"
assert_eq "$("$JQ" -c '.baseline_comparison' "$SUMMARY")" "[]" "baseline_comparison empty when no results"
assert_eq "$("$JQ" -r '.phases | length' "$SUMMARY")" "2" "phases still passthrough without results"

# ---------------------------------------------------------------------------
section "perf-summary-writer: output validates against perf-summary schema"
PSW_VALIDATOR="$HOOK_DIR/lib/validator.bundle.mjs"
PSW_NODE=$(command -v node 2>/dev/null || true)
if [ -n "$PSW_NODE" ] && [ -f "$PSW_VALIDATOR" ] \
   && ! "$PSW_NODE" "$PSW_VALIDATOR" validate perf-summary "$SUMMARY" 2>&1 | grep -q 'No schema for id'; then
  TESTS_RUN=$((TESTS_RUN + 1))
  PSW_VAL_OUT=$("$PSW_NODE" "$PSW_VALIDATOR" validate perf-summary "$PSW_TMP_B/.achilles/perf-summary.json" 2>&1)
  PSW_VAL_EC=$?
  if [ "$PSW_VAL_EC" = "0" ] && [ -z "$PSW_VAL_OUT" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "${CLR_PASS}  ✓${CLR_RST} perf-summary output validates against perf-summary schema"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("perf-summary schema validation: ${PSW_VAL_OUT:0:200}")
    echo "${CLR_FAIL}  ✗${CLR_RST} perf-summary output validates against perf-summary schema ${CLR_DIM}(${PSW_VAL_OUT:0:120})${CLR_RST}"
  fi
else
  echo "${CLR_DIM}  (perf-summary schema not in validator bundle — skipping)${CLR_RST}"
fi

rm -rf "$PSW_TMP_A" "$PSW_TMP_B" "$PSW_TMP_C"
