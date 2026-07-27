#!/bin/bash
# Tests for atelier-report-renderer.sh — the Stop-time auto-render hook.
# Renders <project>/.achilles/harness-atelier.html when telemetry exists
# and is newer than the report; silent no-op otherwise; never blocks.
H="$HOOK_DIR/atelier-report-renderer.sh"
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  section "atelier-report-renderer: skipped (node not on PATH)"
else

RENDERER="$HOOK_DIR/../scripts/atelier/harness-atelier.mjs"
TMPAR=$(mktemp -d)
trap 'rm -rf "$TMPAR"' EXIT
( cd "$TMPAR" && git init -q ) >/dev/null 2>&1
mkdir -p "$TMPAR/.achilles"
printf '%s\n' '{"ts":"2026-07-26T10:00:00Z","event":"dispatch","actor":"orchestrator","role":"orchestrator","tool_use_id":"t1","dispatch_role":"probe","brief_bytes":1000,"description":"probe-x: probe"}' \
  > "$TMPAR/.achilles/atelier-telemetry.jsonl"
REPORT="$TMPAR/.achilles/harness-atelier.html"

stop_payload() { "$JQ" -nc --arg cw "$TMPAR" '{hook_event_name:"Stop", cwd:$cw}'; }

render_check() { # <label> — TESTS_* bookkeeping for a grep on the report
  local sub="$1" label="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  if grep -qF -- "$sub" "$REPORT" 2>/dev/null; then
    TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} $label"
  else
    TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("$label"); echo "${CLR_FAIL}  ✗${CLR_RST} $label"
  fi
}

section "atelier-report-renderer: renders at Stop"
OUT=$(printf '%s' "$(stop_payload)" | ATELIER_RENDERER="$RENDERER" bash "$H" 2>&1)
EC=$?
assert_eq "$EC" "0" "Stop hook exits 0"
assert_eq "$OUT" "" "silent — a Stop hook must emit nothing"
render_check "harness-atelier" "report rendered at Stop"

section "atelier-report-renderer: freshness — skips when report is newer"
echo "SENTINEL-DO-NOT-RERENDER" > "$REPORT"
touch -d '2020-01-01T00:00:00Z' "$TMPAR/.achilles/atelier-telemetry.jsonl"
printf '%s' "$(stop_payload)" | ATELIER_RENDERER="$RENDERER" bash "$H" >/dev/null 2>&1
render_check "SENTINEL-DO-NOT-RERENDER" "up-to-date report untouched (mtime skip)"
# Telemetry newer again → re-render replaces the sentinel.
touch -d '2020-01-02T00:00:00Z' "$REPORT"
touch "$TMPAR/.achilles/atelier-telemetry.jsonl"
printf '%s' "$(stop_payload)" | ATELIER_RENDERER="$RENDERER" bash "$H" >/dev/null 2>&1
render_check "harness-atelier" "stale report re-rendered when telemetry is newer"

section "atelier-report-renderer: escape hatch + inert scopes"
rm -f "$REPORT"
printf '%s' "$(stop_payload)" | ATELIER_AUTORENDER=off ATELIER_RENDERER="$RENDERER" bash "$H" >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN+1))
if [ ! -f "$REPORT" ]; then
  TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} ATELIER_AUTORENDER=off → no render"
else
  TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("off switch still rendered"); echo "${CLR_FAIL}  ✗${CLR_RST} off switch still rendered"
fi
NOTEL=$(mktemp -d)
( cd "$NOTEL" && git init -q ) >/dev/null 2>&1
printf '%s' "$("$JQ" -nc --arg cw "$NOTEL" '{hook_event_name:"Stop", cwd:$cw}')" | ATELIER_RENDERER="$RENDERER" bash "$H" >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN+1))
if [ ! -f "$NOTEL/.achilles/harness-atelier.html" ]; then
  TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} no telemetry → inert (opt-in signal is the log itself)"
else
  TESTS_FAILED=$((TESTS_FAILED+1)); FAIL_DETAILS+=("rendered without telemetry"); echo "${CLR_FAIL}  ✗${CLR_RST} rendered without telemetry"
fi
rm -rf "$NOTEL"

section "atelier-report-renderer: pinned baseline is picked up automatically"
"$NODE_BIN" "$RENDERER" --project "$TMPAR" --json > "$TMPAR/.achilles/atelier-baseline.json" 2>/dev/null
rm -f "$REPORT"
printf '%s' "$(stop_payload)" | ATELIER_RENDERER="$RENDERER" bash "$H" >/dev/null 2>&1
render_check "vs baseline" "auto-render includes the vs-baseline section"

fi
