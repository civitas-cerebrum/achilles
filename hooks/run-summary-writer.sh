#!/bin/sh
# Stop hook. Writes <project>/.achilles/run-summary.json — the authoritative
# self-report consumed by Feyzabora/bookhive-benchmark to cross-check what the
# Claude Code transcript saw.
#
# Auto-registered via scripts/sync-hooks.js on `npm install`.

set -eu

ROOT="${PWD}"
out="${ROOT}/.achilles/run-summary.json"
mkdir -p "${ROOT}/.achilles"

if [ -f "${ROOT}/.achilles/onboarding-ledger.json" ]; then
  phases_json=$(jq -c '.phases // []' "${ROOT}/.achilles/onboarding-ledger.json" 2>/dev/null || echo '[]')
else
  phases_json='[]'
fi

scenarios_json='[]'
if [ -d "${ROOT}/tests" ]; then
  scenarios_json=$(find "${ROOT}/tests" -type f \( -name '*.spec.ts' -o -name '*.spec.js' -o -name '*.spec.mjs' \) | jq -R . | jq -s .)
fi

bugs_ids='[]'
bugs_high=0; bugs_med=0; bugs_low=0
if [ -d "${ROOT}/.bug-ledger" ]; then
  bugs_ids=$(find "${ROOT}/.bug-ledger" -name '*.json' -exec jq -r '.id // empty' {} \; | jq -R . | jq -s .)
  bugs_high=$(find "${ROOT}/.bug-ledger" -name '*.json' -exec jq -r 'select(.severity=="high") | .id' {} \; | wc -l | tr -d ' ')
  bugs_med=$(find "${ROOT}/.bug-ledger" -name '*.json' -exec jq -r 'select(.severity=="med") | .id' {} \; | wc -l | tr -d ' ')
  bugs_low=$(find "${ROOT}/.bug-ledger" -name '*.json' -exec jq -r 'select(.severity=="low") | .id' {} \; | wc -l | tr -d ' ')
fi

pw_exit=0
passing=0
total=0
if [ -f "${ROOT}/test-results/results.json" ]; then
  passing=$(jq '[.suites[]?.specs[]? | select(.tests[0].results[0].status=="passed")] | length' "${ROOT}/test-results/results.json" 2>/dev/null || echo 0)
  total=$(jq '[.suites[]?.specs[]?] | length' "${ROOT}/test-results/results.json" 2>/dev/null || echo 0)
fi

pages=0
if [ -f "${ROOT}/.achilles/journey-map.json" ]; then
  pages=$(jq '.pages | length' "${ROOT}/.achilles/journey-map.json" 2>/dev/null || echo 0)
fi

jq -n \
  --argjson phases "$phases_json" \
  --argjson scenarios "$scenarios_json" \
  --argjson ids "$bugs_ids" \
  --argjson high "$bugs_high" --argjson med "$bugs_med" --argjson low "$bugs_low" \
  --argjson passing "$passing" --argjson total "$total" --argjson pw_exit "$pw_exit" \
  --argjson pages "$pages" \
  '{
    phases: $phases,
    scenarios: { files: $scenarios },
    bugs: { ids: $ids, by_severity: { high: $high, med: $med, low: $low } },
    tests: { passing: $passing, total: $total, playwright_exit_code: $pw_exit },
    journey_map: { pages: $pages }
  }' > "$out"

printf '{}\n'
