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
this line is not json and must be counted as skipped, never silently dropped
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

section "harness-atelier: honest sizing — chars in, estimated tokens out"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.schema_version')" "2" "aggregate carries schema_version"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.sizing.unit')" "chars" "sizing declares the collected unit is chars"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.sizing.chars_per_token_estimate')" "4" "token estimator divisor declared"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.total_brief_tokens_est')" "1750" "brief token estimate (7000 chars / 4)"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.total_return_tokens_est')" "2600" "return token estimate (10400 chars / 4)"

section "harness-atelier: per-actor ingest is complete (bash + tools + skills)"
OCTX=$(echo "$JSON_OUT" | "$JQ" -r '.contexts[] | select(.actor=="orchestrator")')
assert_eq "$(echo "$OCTX" | "$JQ" -r '.tool_calls')" "2" "orchestrator tool calls counted per-context"
assert_eq "$(echo "$OCTX" | "$JQ" -r '.tool_bytes_out')" "1800" "orchestrator tool ingest attributed per-context (1500+300)"
assert_eq "$(echo "$OCTX" | "$JQ" -r '.skill_bytes_out')" "5000" "orchestrator skill injections attributed per-context"
assert_eq "$(echo "$OCTX" | "$JQ" -r '.total_ingest_bytes')" "8848" "total per-context ingest (2048 bash + 1800 tools + 5000 skill)"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.orchestrator_total_ingest_bytes')" "8848" "orchestrator total ingest surfaced in summary"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.telemetry_skipped_lines')" "1" "malformed telemetry line surfaced, not silently dropped"

section "harness-atelier: context budget & waste"
# Window = briefs authored (7000) + returns ingested (10400) + bash (2048)
# + tools (1800) + skill injections (5000) = 26248 chars.
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.orchestrator_window_bytes')" "26248" "orchestrator window load summed"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.orchestrator_window_tokens_est')" "6562" "window token estimate"
# Waste = leaking transfers: oversized return (9500) + dumped stdout (2048).
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.leaked_bytes')" "11548" "leaked chars = full size of each leaking transfer"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.leak_waste_share * 1000 | round')" "440" "waste share = leaked / window (~44%)"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.worst_offenders.returns[0].role')" "probe" "worst return offender ranked first"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.worst_offenders.returns[0].leak_channel')" "oversized-return" "offender carries its leak channel"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '.worst_offenders.ingest[0].actor')" "orchestrator" "worst ingest offender ranked first"
assert_eq "$(echo "$JSON_OUT" | "$JQ" -r '[.leaks_detail[].remediation | length > 40] | all')" "true" "every leak carries a concrete remediation"

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

section "harness-atelier: --baseline regression diff"
BASE_JSON="$TMPHA/baseline.json"
printf '%s' "$JSON_OUT" > "$BASE_JSON"
SAME_OUT=$("$NODE_BIN" "$ATELIER" --project "$TMPHA" --json --baseline "$BASE_JSON" 2>&1)
SAME_EC=$?
assert_eq "$SAME_EC" "0" "--baseline run exits 0"
assert_eq "$(echo "$SAME_OUT" | "$JQ" -r '.baseline_comparison.regressions | length')" "0" "identical run vs its own baseline → no regressions"
# A fresh bash-ingest leak appears → leaks / leaked_bytes / waste share /
# orchestrator ingest all regress against the pinned baseline.
cp "$TMPHA/.achilles/atelier-telemetry.jsonl" "$TMPHA/.achilles/telemetry.orig"
printf '%s\n' '{"ts":"2026-07-26T10:40:00Z","event":"command","actor":"orchestrator","role":"orchestrator","tool":"Bash","bytes_out":4096,"command_head":"cat tests/e2e/journeys/login.spec.ts","leak":{"channel":"bash-ingest","evidence":"payload dump executed in orchestrator context: cat tests/e2e/journeys/login.spec.ts"}}' >> "$TMPHA/.achilles/atelier-telemetry.jsonl"
REG_OUT=$("$NODE_BIN" "$ATELIER" --project "$TMPHA" --json --baseline "$BASE_JSON" 2>&1)
assert_eq "$(echo "$REG_OUT" | "$JQ" -r '.baseline_comparison.regressions | index("leaks") != null')" "true" "new leak → leaks flagged as regression"
assert_eq "$(echo "$REG_OUT" | "$JQ" -r '.baseline_comparison.metrics[] | select(.metric=="leaked_bytes") | .delta')" "4096" "leaked_bytes delta = the new dump's size"
assert_eq "$(echo "$REG_OUT" | "$JQ" -r '.baseline_comparison.metrics[] | select(.metric=="orchestrator_bash_ingest_bytes") | .regressed')" "true" "orchestrator ingest growth flagged"
assert_eq "$(echo "$REG_OUT" | "$JQ" -r '.baseline_comparison.metrics[] | select(.metric=="dispatches") | .regressed')" "false" "info metric (dispatches) never regresses"
"$NODE_BIN" "$ATELIER" --project "$TMPHA" --baseline "$BASE_JSON" --out "$TMPHA/baseline-report.html" >/dev/null 2>&1
for sub in "vs baseline" "regressed" "leaked_bytes"; do
  TESTS_RUN=$((TESTS_RUN+1))
  if grep -qF -- "$sub" "$TMPHA/baseline-report.html" 2>/dev/null; then
    TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} baseline report contains '$sub'"
  else
    TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("baseline report missing '$sub'"); echo "${CLR_FAIL}  ✗${CLR_RST} baseline report missing '$sub'"
  fi
done
mv "$TMPHA/.achilles/telemetry.orig" "$TMPHA/.achilles/atelier-telemetry.jsonl"
BAD_OUT=$("$NODE_BIN" "$ATELIER" --project "$TMPHA" --json --baseline "$TMPHA/nonexistent-baseline.json" 2>&1)
assert_eq "$?" "1" "unreadable baseline → hard error (exit 1), never a silent skip"

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
for sub in "harness-atelier" "Context-transfer map" "Leak panel" "bash-ingest" "oversized-return" "composer" "svg" "Context by skill" "coverage-expansion" "Context impact by role" "Tool mix" "session 2026-07-26T09:58:00" "Context budget" "Worst offenders" "estimated tokens" "waste share" "fix: " "malformed telemetry line"; do
  TESTS_RUN=$((TESTS_RUN+1))
  if grep -qF -- "$sub" "$REPORT" 2>/dev/null; then
    TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} report contains '$sub'"
  else
    TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("report missing substring '$sub'"); echo "${CLR_FAIL}  ✗${CLR_RST} report missing '$sub'"
  fi
done

section "harness-atelier: flow-map cap is stated, never silent"
CAPD=$(mktemp -d)
for i in $(seq 1 45); do
  printf '{"ts":"2026-07-26T13:00:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"cap%02d","dispatch_role":"probe","brief_bytes":%d,"description":"probe-cap"}\n' "$i" $((100 + i))
done > "$CAPD/t.jsonl"
"$NODE_BIN" "$ATELIER" --project "$CAPD" --telemetry "$CAPD/t.jsonl" --out "$CAPD/r.html" >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN+1))
if grep -qF "40 largest of 45 agents" "$CAPD/r.html" 2>/dev/null; then
  TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} >40 agents → map states the cap and the full count"
else
  TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("flow-map cap note missing for 45-agent telemetry"); echo "${CLR_FAIL}  ✗${CLR_RST} flow-map cap note missing"
fi
rm -rf "$CAPD"

section "harness-atelier: empty project degrades gracefully"
EMPTYP=$(mktemp -d)
EMPTY_OUT=$("$NODE_BIN" "$ATELIER" --project "$EMPTYP" --json 2>&1)
assert_eq "$?" "0" "no telemetry → still exits 0"
assert_eq "$(echo "$EMPTY_OUT" | "$JQ" -r '.events')" "0" "zero events reported"
rm -rf "$EMPTYP"

fi
