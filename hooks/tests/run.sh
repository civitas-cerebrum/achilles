#!/bin/bash
# run.sh — pipe-test runner for every hook in ../
#
# Usage:
#   bash hooks/tests/run.sh                 # run all
#   bash hooks/tests/run.sh dispatch-guard  # run a single test file (matches cases/*<arg>*.sh)
#
# Exit code: 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CASES_DIR="$SCRIPT_DIR/cases"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Locate test files. If an arg is given, filter by substring.
filter="${1:-}"
shopt -s nullglob
case_files=("$CASES_DIR"/*.sh "$CASES_DIR"/*/*.sh)
if [ "${#case_files[@]}" -eq 0 ]; then
  echo "No test files found under $CASES_DIR" >&2
  exit 1
fi

selected=()
for f in "${case_files[@]}"; do
  if [ -z "$filter" ] || [[ "$(basename "$f")" == *"$filter"* ]]; then
    selected+=("$f")
  fi
done

if [ "${#selected[@]}" -eq 0 ] && [[ "install-simulation.sh" != *"$filter"* ]]; then
  echo "No test files match filter '$filter'" >&2
  exit 1
fi

echo "Running ${#selected[@]} test file(s) against hooks under $HOOKS_DIR"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Each cases file uses $HOOKS_DIR via the HOOK_DIR variable.
HOOK_DIR="$HOOKS_DIR"

# HARNESS CONTROL. The counters below only move when an assert_* helper is CALLED, so a case file
# that dies on a typo'd helper name contributes nothing and the run still reports green. That is
# not hypothetical: a block of seven new cases once called helpers that do not exist, every line
# errored, and the suite printed "all 28 tests passed".
#
# Exit 127 is `command not found`. In a test file that means a mistyped or out-of-scope helper —
# never a legitimate outcome — so it fails the run outright and names the file.
HARNESS_ERRORS=()
# Record only the CASE file, not run.sh's own `source` line — errtrace propagates the failure up
# and the outer frame is noise that inflates the count.
trap 'if [ $? -eq 127 ] && [ "$(basename "${BASH_SOURCE[0]}")" != "run.sh" ]; then HARNESS_ERRORS+=("$(basename "${BASH_SOURCE[0]}"):${LINENO}: command not found — a helper is mistyped or out of scope"); fi' ERR
set -o errtrace

for f in "${selected[@]}"; do
  echo
  echo "=== $(basename "$f") ==="
  # shellcheck source=/dev/null
  source "$f"
done

trap - ERR
if [ ${#HARNESS_ERRORS[@]} -gt 0 ]; then
  echo
  echo "${CLR_FAIL}✖ HARNESS ERRORS — these lines never ran, so their assertions were never counted:${CLR_RST}"
  printf '  %s\n' "${HARNESS_ERRORS[@]}"
  echo "  A green tally below does NOT cover them."
  # Feed the shared list, not just the counter: the summary printer reads FAIL_DETAILS, and
  # bumping the count alone left it with failures it could not name.
  for e in "${HARNESS_ERRORS[@]}"; do
    FAIL_DETAILS+=("HARNESS: $e")
    TESTS_FAILED=$((TESTS_FAILED + 1))
  done
fi

# Install simulation — proves the gates fire from a consumer-style install
# (HOOK_MANIFEST scripts + lib/ + bin/jq copied to a fake home, no repo
# context). Sourced so its assertions share the counters above and land in
# the final tally. Respects the filter like any case file.
if [ -z "$filter" ] || [[ "install-simulation.sh" == *"$filter"* ]]; then
  echo
  echo "=== install-simulation.sh ==="
  # shellcheck source=install-simulation.sh
  source "$SCRIPT_DIR/install-simulation.sh"
fi

# Summary.
echo
echo "──────────────────────────────────────"
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "${CLR_PASS}✓ all ${TESTS_RUN} tests passed${CLR_RST}"
  exit 0
else
  echo "${CLR_FAIL}✗ ${TESTS_FAILED} of ${TESTS_RUN} tests failed${CLR_RST}"
  echo
  echo "Failures:"
  for d in "${FAIL_DETAILS[@]}"; do
    echo "  - $d"
  done
  exit 1
fi
