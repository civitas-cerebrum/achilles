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
{"ts":"2026-07-26T09:58:00Z","event":"skill","actor":"orchestrator","role":"orchestrator","skill":"coverage-expansion","bytes_in":40,"bytes_out":5000}
{"ts":"2026-07-26T10:00:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_c1","dispatch_role":"composer","brief_bytes":4000,"description":"composer-j-checkout-1-c1: compose"}
{"ts":"2026-07-26T10:05:00Z","event":"return","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_c1","dispatch_role":"composer","return_bytes":900,"description":"composer-j-checkout-1-c1: compose"}
{"ts":"2026-07-26T10:06:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_p1","dispatch_role":"probe","brief_bytes":3000,"description":"probe-j-checkout-4: adversarial probe"}
{"ts":"2026-07-26T10:12:00Z","event":"return","actor":"orchestrator","role":"orchestrator","tool_use_id":"toolu_p1","dispatch_role":"probe","return_bytes":9500,"description":"probe-j-checkout-4: adversarial probe","leak":{"channel":"oversized-return","evidence":"return is 9500 bytes (budget 8000)"}}
{"ts":"2026-07-26T10:13:00Z","event":"command","actor":"orchestrator","role":"orchestrator","tool":"Bash","bytes_out":2048,"command_head":"cat tests/e2e/journeys/checkout.spec.ts","leak":{"channel":"bash-ingest","evidence":"payload dump executed in orchestrator context: cat tests/e2e/journeys/checkout.spec.ts"}}
{"ts":"2026-07-26T10:14:00Z","event":"command","actor":"sub_c1","role":"composer","tool":"Bash","bytes_out":512,"command_head":"npx playwright test"}
{"ts":"2026-07-26T10:15:00Z","event":"tool","actor":"orchestrator","role":"orchestrator","tool":"Read","bytes_in":60,"bytes_out":1500}
{"ts":"2026-07-26T10:28:00Z","event":"tool","actor":"orchestrator","role":"orchestrator","tool":"Grep","bytes_in":80,"bytes_out":300}
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
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '[.leaks_detail[].line] | sort | join(",")')" "5,6" "leak pointers cite exact telemetry lines"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.agents_detail[] | select(.role=="composer") | (.return_bytes / .brief_bytes * 1000 | round)')" "225" "composer compression ratio computed (0.225)"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.schema_validity[] | select(.role=="probe") | .invalid')" "1" "schema-guard log joined per role"

section "harness-atelier: general metrics — skills, roles, tools, session"
SK=$(echo "$JSON_OUT" | "$JQ" -r '.skills[] | select(.skill=="coverage-expansion")')
assert_eq "$(echo "$SK" | "$JQ" -r '.invocations')" "1" "skill invocation counted"
assert_eq "$(echo "$SK" | "$JQ" -r '.injected_bytes')" "5000" "skill injected bytes recorded"
# Attributed to the orchestrator's coverage-expansion segment: both briefs
# (4000+3000) + both returns (900+9500) + orchestrator command (2048) +
# Read (1500) + Grep (300) = 21248.
assert_eq "$(echo "$SK" | "$JQ" -r '.attributed_bytes')" "21248" "context attributed to the skill segment"
assert_eq "$(echo "$SK" | "$JQ" -r '.dispatches')" "2" "dispatches attributed to the skill segment"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.roles[] | select(.role=="probe") | .leaks')" "1" "per-role (stage) leak tally"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.roles[] | select(.role=="composer") | .brief_bytes')" "4000" "per-role brief bytes"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.tools[] | select(.tool=="Read") | .bytes_out')" "1500" "tool-mix Read bytes"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.session.duration_seconds')" "1800" "session span computed (09:58 → 10:28 = 30m)"

section "harness-atelier: --telemetry points at any agent's log (harness-agnostic)"
ALT=$(mktemp -d)
printf '%s\n' '{"ts":"2026-07-26T12:00:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"t1","dispatch_role":"unconfined","brief_bytes":100,"description":"other-agent worker"}' > "$ALT/custom.jsonl"
ALT_OUT=$("$NODE_BIN" "$ATELIER" --project "$ALT" --telemetry "$ALT/custom.jsonl" --json 2>&1)
assert_eq "$?" "0" "--telemetry run exits 0"
assert_eq "$(echo "$ALT_OUT" | "$JQ" -r '.dispatches')" "1" "external telemetry file aggregated"
rm -rf "$ALT"

section "harness-atelier: HTML report"
HTML_OUT=$("$NODE_BIN" "$ATELIER" --project "$TMPHA" 2>&1)
assert_eq "$?" "0" "HTML render exits 0"
REPORT="$TMPHA/.achilles/harness-atelier.html"
TESTS_RUN=$((TESTS_RUN+1))
if [ -f "$REPORT" ]; then TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} report written to .achilles/harness-atelier.html"; else TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("report missing: $HTML_OUT"); echo "${CLR_FAIL}  ✗${CLR_RST} report missing"; fi
for sub in "harness-atelier" "Context-transfer map" "Leak panel" "bash-ingest" "oversized-return" "composer" "svg" "Context by skill" "coverage-expansion" "Context impact by role" "Tool mix" "session 2026-07-26T09:58:00"; do
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
