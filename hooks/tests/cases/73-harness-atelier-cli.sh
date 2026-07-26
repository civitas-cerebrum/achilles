#!/bin/bash
# Tests for scripts/atelier/harness-atelier.mjs — the harness-atelier
# visualizer. Feeds a fixture telemetry log and asserts the --json
# aggregate (metrics, leak pointers) and the HTML report artifacts.
ATELIER="$HOOK_DIR/../scripts/atelier/harness-atelier.mjs"
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  section "harness-atelier: skipped (node not on PATH)"
else

TMPHA=$(mktemp -d)
trap 'rm -rf "$TMPHA"' EXIT
mkdir -p "$TMPHA/.achilles"

cat > "$TMPHA/.achilles/atelier-telemetry.jsonl" <<'EOF'
{"ts":"2026-07-26T10:00:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_c1","dispatch_role":"composer","brief_bytes":4000,"description":"composer-j-checkout-1-c1: compose"}
{"ts":"2026-07-26T10:05:00Z","event":"return","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_c1","dispatch_role":"composer","return_bytes":900,"description":"composer-j-checkout-1-c1: compose"}
{"ts":"2026-07-26T10:06:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_p1","dispatch_role":"probe","brief_bytes":3000,"description":"probe-j-checkout-4: adversarial probe"}
{"ts":"2026-07-26T10:12:00Z","event":"return","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_p1","dispatch_role":"probe","return_bytes":9500,"description":"probe-j-checkout-4: adversarial probe","leak":{"channel":"oversized-return","evidence":"return is 9500 bytes (budget 8000)"}}
{"ts":"2026-07-26T10:13:00Z","event":"command","actor":"orchestrator","role":"orchestrator","tool":"Bash","bytes_out":2048,"command_head":"cat tests/e2e/journeys/checkout.spec.ts","leak":{"channel":"bash-ingest","evidence":"payload dump executed in orchestrator context: cat tests/e2e/journeys/checkout.spec.ts"}}
{"ts":"2026-07-26T10:14:00Z","event":"command","actor":"sub_c1","role":"composer","tool":"Bash","bytes_out":512,"command_head":"npx playwright test"}
EOF
cat > "$TMPHA/.achilles/schema-guard-log.jsonl" <<'EOF'
{"ts":"2026-07-26T10:05:01Z","role":"composer","valid":true,"errors":[]}
{"ts":"2026-07-26T10:12:01Z","role":"probe","valid":false,"errors":["missing handover"]}
EOF

section "harness-atelier: --json aggregate"
JSON_OUT=$("$NODE_BIN" "$ATELIER" --project "$TMPHA" --json 2>&1)
JSON_EC=$?
assert_eq "$JSON_EC" "0" "--json exits 0"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.dispatches')" "2" "2 dispatches aggregated"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.total_brief_bytes')" "7000" "brief bytes summed"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.total_return_bytes')" "10400" "return bytes summed"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.leaks')" "2" "both leaks counted"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.leak_channels["bash-ingest"]')" "1" "bash-ingest channel tallied"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.leak_channels["oversized-return"]')" "1" "oversized-return channel tallied"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.orchestrator_bash_ingest_bytes')" "2048" "orchestrator ingest volume"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '[.leaks_detail[].line] | sort | join(",")')" "4,5" "leak pointers cite exact telemetry lines"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.agents_detail[] | select(.role=="composer") | (.return_bytes / .brief_bytes * 1000 | round)')" "225" "composer compression ratio computed (0.225)"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.schema_validity[] | select(.role=="probe") | .invalid')" "1" "schema-guard log joined per role"

section "harness-atelier: HTML report"
HTML_OUT=$("$NODE_BIN" "$ATELIER" --project "$TMPHA" 2>&1)
assert_eq "$?" "0" "HTML render exits 0"
REPORT="$TMPHA/.achilles/harness-atelier.html"
TESTS_RUN=$((TESTS_RUN+1))
if [ -f "$REPORT" ]; then TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} report written to .achilles/harness-atelier.html"; else TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("report missing: $HTML_OUT"); echo "${CLR_FAIL}  ✗${CLR_RST} report missing"; fi
for sub in "harness-atelier" "Context-transfer map" "Leak panel" "bash-ingest" "oversized-return" "atelier-telemetry.jsonl:5" "composer" "svg"; do
  TESTS_RUN=$((TESTS_RUN+1))
  if grep -qF -- "$sub" "$REPORT" 2>/dev/null; then
    TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} report contains '$sub'"
  else
    TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("report missing substring '$sub'"); echo "${CLR_FAIL}  ✗${CLR_RST} report missing '$sub'"
  fi
done

section "harness-atelier: empty project degrades gracefully"
EMPTYP=$(mktemp -d)
EMPTY_OUT=$("$NODE_BIN" "$ATELIER" --project "$EMPTYP" --json 2>&1)
assert_eq "$?" "0" "no telemetry → still exits 0"
assert_eq "$(echo "$EMPTY_OUT" | "$JQ" -r '.events')" "0" "zero events reported"
rm -rf "$EMPTYP"

fi
