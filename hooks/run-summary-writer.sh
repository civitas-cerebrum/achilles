#!/bin/bash
# Stop hook. Writes <project>/.achilles/run-summary.json — the authoritative
# self-report consumed by Feyzabora/bookhive-benchmark.
#
# Reads the artifacts the skills ACTUALLY write:
#   tests/e2e/docs/onboarding-status.json   (phases)
#   tests/e2e/docs/adversarial-findings.md  (findings ledger, '#### <ID> [sev] — title')
#   tests/e2e/docs/journey-map.md           (journey count = level-3 journey headings)
#   playwright-report/results.json | test-results/results.json (whichever is newer)
#
# Severity vocabulary: the canonical five (critical/high/medium/low/info).
# No result file → tests block is null-statused, never a fake pass.
#
# Auto-registered via scripts/sync-hooks.js on `npm install`.

set -u

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { printf '{}\n'; exit 0; }

ROOT="${PWD}"
DOCS="$ROOT/tests/e2e/docs"
out="$ROOT/.achilles/run-summary.json"
mkdir -p "$ROOT/.achilles"

phases_json='[]'
[ -f "$DOCS/onboarding-status.json" ] && phases_json=$("$JQ" -c '.phases // []' "$DOCS/onboarding-status.json" 2>/dev/null || echo '[]')

scenarios_json='[]'
[ -d "$ROOT/tests" ] && scenarios_json=$(find "$ROOT/tests" -type f \( -name '*.spec.ts' -o -name '*.spec.js' -o -name '*.spec.mjs' \) | "$JQ" -R . | "$JQ" -s .)

bugs_ids='[]'; sev_counts='{"critical":0,"high":0,"medium":0,"low":0,"info":0}'
if [ -f "$DOCS/adversarial-findings.md" ]; then
  bugs_ids=$(grep -E '^#### ' "$DOCS/adversarial-findings.md" | sed -E 's/^#### ([^ ]+) .*/\1/' | "$JQ" -R . | "$JQ" -s .)
  sev_counts=$(grep -E '^#### ' "$DOCS/adversarial-findings.md" | sed -E 's/^#### [^ ]+ \[([A-Za-z]+)\].*/\1/' | tr '[:upper:]' '[:lower:]' | "$JQ" -R . | "$JQ" -s '
    reduce .[] as $s ({"critical":0,"high":0,"medium":0,"low":0,"info":0};
      if has($s) then .[$s] += 1 else . end)')
fi

# Newest results file wins.
RESULTS=""
for cand in "$ROOT/playwright-report/results.json" "$ROOT/test-results/results.json"; do
  [ -f "$cand" ] || continue
  if [ -z "$RESULTS" ] || [ "$cand" -nt "$RESULTS" ]; then RESULTS="$cand"; fi
done

tests_json='{"passing":null,"failing":null,"flaky":null,"skipped":null,"total":null,"status":null}'
if [ -n "$RESULTS" ]; then
  tests_json=$("$JQ" -c '
    (.stats // {}) as $s |
    if ($s | has("expected")) then
      { passing: $s.expected, failing: ($s.unexpected // 0),
        flaky: ($s.flaky // 0), skipped: ($s.skipped // 0),
        total: (($s.expected // 0) + ($s.unexpected // 0) + ($s.flaky // 0) + ($s.skipped // 0)),
        status: (if ($s.unexpected // 0) > 0 then "failing" else "passing" end) }
    else
      # Best-effort for non-standard report shapes; .results[-1] = LAST retry result per test.
      ([.. | objects | select(has("tests")) | .tests[]?] ) as $tests |
      ($tests | map(.results[-1].status // "unknown")) as $st |
      { passing: ($st | map(select(. == "passed")) | length),
        failing: ($st | map(select(. == "failed" or . == "timedOut" or . == "interrupted")) | length),
        flaky: null, skipped: ($st | map(select(. == "skipped")) | length),
        total: ($st | length),
        status: (if ($st | map(select(. == "failed" or . == "timedOut" or . == "interrupted")) | length) > 0 then "failing" else "passing" end) }
    end' "$RESULTS" 2>/dev/null || echo "$tests_json")
fi

journeys=0
if [ -f "$DOCS/journey-map.md" ]; then
  journeys=$(grep -cE '^### j-' "$DOCS/journey-map.md" 2>/dev/null) || journeys=0
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sha=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
ach_ver=$("$JQ" -r '.version // ""' "$ROOT/node_modules/@civitas-cerebrum/achilles/package.json" 2>/dev/null || echo "")

"$JQ" -n \
  --argjson phases "$phases_json" --argjson scenarios "$scenarios_json" \
  --argjson ids "$bugs_ids" --argjson sev "$sev_counts" \
  --argjson tests "$tests_json" --argjson journeys "$journeys" \
  --arg ts "$ts" --arg sha "$sha" --arg ver "$ach_ver" \
  '{ meta: { timestamp: $ts, git_sha: $sha, achilles_version: $ver, schema: "run-summary/v2" },
     phases: $phases,
     scenarios: { files: $scenarios },
     bugs: { ids: $ids, by_severity: $sev },
     tests: $tests,
     journey_map: { journeys: $journeys } }' > "$out"

printf '{}\n'
