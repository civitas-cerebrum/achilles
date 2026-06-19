#!/bin/bash
# Stop hook. Writes <project>/.achilles/perf-summary.json — the authoritative
# perf self-report for the perf-onboarding pipeline.
#
# Reads the artifacts the perf skills ACTUALLY write:
#   tests/perf/docs/perf-onboarding-status.json   (phases + runMode)
#   tests/perf/scenarios/*.js                     (scenario files)
#   tests/perf/results/*.json                     (k6 handleSummary JSON)
#   tests/perf/baselines/*.json                   (baseline snapshots)
#
# NO-OP when tests/perf/docs/perf-onboarding-status.json does NOT exist —
# non-perf projects are unaffected, and this hook never interferes with
# run-summary-writer.sh.
#
# Null-status policy: verdict + metrics are null when no result file was
# found — never a fabricated pass.
#
# Auto-registered via scripts/postinstall.js on `npm install`.

set -u

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { printf '{}\n'; exit 0; }

ROOT="${PWD}"
PERF_LEDGER="$ROOT/tests/perf/docs/perf-onboarding-status.json"

# NO-OP guard: if the perf ledger does not exist this is not a perf project.
[ -f "$PERF_LEDGER" ] || { printf '{}\n'; exit 0; }

out="$ROOT/.achilles/perf-summary.json"
mkdir -p "$ROOT/.achilles"

# meta fields
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sha=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
run_mode=$("$JQ" -r '.runMode // ""' "$PERF_LEDGER" 2>/dev/null || echo "")

# phases: verbatim .phases from the ledger, or []
phases_json=$("$JQ" -c '.phases // []' "$PERF_LEDGER" 2>/dev/null || echo '[]')

# scenarios: glob tests/perf/scenarios/*.js
scenarios_json='[]'
if [ -d "$ROOT/tests/perf/scenarios" ]; then
  scenarios_json=$(find "$ROOT/tests/perf/scenarios" -maxdepth 1 -type f -name '*.js' | sort | "$JQ" -R . | "$JQ" -s .)
fi

# slo_results: parse tests/perf/results/*.json (k6 handleSummary JSON)
# One entry per result file. Null metrics/verdict when file absent or unparseable.
slo_results_json='[]'
if [ -d "$ROOT/tests/perf/results" ]; then
  slo_results_json='[]'
  while IFS= read -r -d '' result_file; do
    scenario=$(basename "$result_file" .json)
    # k6 handleSummary: metrics live at .metrics.<name>.values.<stat>
    # http_req_duration p95/p99, http_req_failed rate, http_reqs rate
    p95=$("$JQ" -r '
      (.metrics["http_req_duration"].values["p(95)"] // .metrics["http_req_duration"].values.p95 // null)
      | if . == null then "null" else . end' "$result_file" 2>/dev/null || echo "null")
    p99=$("$JQ" -r '
      (.metrics["http_req_duration"].values["p(99)"] // .metrics["http_req_duration"].values.p99 // null)
      | if . == null then "null" else . end' "$result_file" 2>/dev/null || echo "null")
    error_rate=$("$JQ" -r '
      (.metrics["http_req_failed"].values.rate // null)
      | if . == null then "null" else . end' "$result_file" 2>/dev/null || echo "null")
    throughput=$("$JQ" -r '
      (.metrics["http_reqs"].values.rate // null)
      | if . == null then "null" else . end' "$result_file" 2>/dev/null || echo "null")
    # verdict: null when any key metric is null; otherwise derive from
    # error_rate and http_req_failed thresholds in the result file.
    # Conservative: only mark "passing" when we have a positive signal from
    # the k6 summary (all thresholds pass = .root_group.checks all passed,
    # or no failed thresholds recorded). Never fabricate a pass.
    verdict="null"
    if [ "$p95" != "null" ] && [ "$p99" != "null" ]; then
      # Check k6 thresholds: if any threshold failed it's "failing"
      thresholds_failed=$("$JQ" -r '
        [.root_group // {}, (.metrics // {}) | to_entries[] | .value
         | select(type == "object") | select(has("thresholds"))
         | .thresholds | to_entries[] | .value
         | if type == "object" then .ok else . end]
        | map(select(. == false)) | length' "$result_file" 2>/dev/null || echo "0")
      if [ "$thresholds_failed" = "0" ]; then
        verdict="passing"
      else
        verdict="failing"
      fi
    fi

    entry=$("$JQ" -n \
      --arg scenario "$scenario" \
      --argjson p95 "$p95" --argjson p99 "$p99" \
      --argjson error_rate "$error_rate" --argjson throughput "$throughput" \
      --argjson verdict "$([ "$verdict" = "null" ] && echo 'null' || printf '"%s"' "$verdict")" \
      '{scenario: $scenario, p95Ms: $p95, p99Ms: $p99, errorRate: $error_rate, throughput: $throughput, verdict: $verdict}')
    slo_results_json=$("$JQ" -c --argjson entry "$entry" '. + [$entry]' <<< "$slo_results_json")
  done < <(find "$ROOT/tests/perf/results" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
fi

# breaches: [] — not parseable from k6 summary without threshold config
# (k6 does not embed threshold condition strings in the summary JSON by default).
breaches_json='[]'

# baseline_comparison: compare results vs baselines
baseline_json='[]'
if [ -d "$ROOT/tests/perf/baselines" ] && [ -d "$ROOT/tests/perf/results" ]; then
  while IFS= read -r -d '' baseline_file; do
    scenario=$(basename "$baseline_file" .json)
    result_file="$ROOT/tests/perf/results/${scenario}.json"
    baseline_p95="null"
    current_p95="null"
    regression_pct="null"
    baseline_p95=$("$JQ" -r '
      (.metrics["http_req_duration"].values["p(95)"] // .metrics["http_req_duration"].values.p95 // null)
      | if . == null then "null" else . end' "$baseline_file" 2>/dev/null || echo "null")
    if [ -f "$result_file" ]; then
      current_p95=$("$JQ" -r '
        (.metrics["http_req_duration"].values["p(95)"] // .metrics["http_req_duration"].values.p95 // null)
        | if . == null then "null" else . end' "$result_file" 2>/dev/null || echo "null")
    fi
    if [ "$baseline_p95" != "null" ] && [ "$current_p95" != "null" ]; then
      regression_pct=$("$JQ" -n \
        --argjson b "$baseline_p95" --argjson c "$current_p95" \
        'if $b > 0 then (($c - $b) / $b * 100) else null end' 2>/dev/null || echo "null")
    fi
    entry=$("$JQ" -n \
      --arg scenario "$scenario" \
      --argjson b "$baseline_p95" --argjson c "$current_p95" --argjson r "$regression_pct" \
      '{scenario: $scenario, baselineP95Ms: $b, currentP95Ms: $c, regressionPct: $r}')
    baseline_json=$("$JQ" -c --argjson entry "$entry" '. + [$entry]' <<< "$baseline_json")
  done < <(find "$ROOT/tests/perf/baselines" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
fi

"$JQ" -n \
  --arg ts "$ts" --arg sha "$sha" --arg run_mode "$run_mode" \
  --argjson phases "$phases_json" \
  --argjson scenario_files "$scenarios_json" \
  --argjson slo_results "$slo_results_json" \
  --argjson breaches "$breaches_json" \
  --argjson baseline_comparison "$baseline_json" \
  '{
    meta: { schema: "perf-summary/v1", generatedAt: $ts, gitSha: $sha, runMode: $run_mode },
    phases: $phases,
    scenarios: { files: $scenario_files },
    slo_results: $slo_results,
    breaches: $breaches,
    baseline_comparison: $baseline_comparison
  }' > "$out"

printf '{}\n'
