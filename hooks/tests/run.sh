#!/bin/bash
# run.sh — pipe-test runner for every hook in ../
#
# Usage:
#   bash hooks/tests/run.sh                 # run all
#   bash hooks/tests/run.sh dispatch-guard  # run a single test file (matches cases/*<arg>*.sh)
#
# Exit code: 0 if all tests pass, 1 otherwise.
# Harness self-test: bash hooks/tests/self/run-sh.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CASES_DIR="${HOOKTESTS_CASES_DIR:-$SCRIPT_DIR/cases}"  # overridable for self/run-sh.sh
INSTALL_SIM="${HOOKTESTS_INSTALL_SIM:-$SCRIPT_DIR/install-simulation.sh}"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Locate test files. If an arg is given, filter by substring.
filter="${1:-}"
shopt -s nullglob
case_files=("$CASES_DIR"/*.sh)
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

# Per-run sandbox: cases never touch the operator's ~/.claude, and two runs on one
# machine never share session markers or temp files.
RUN_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/achilles-hooktests.XXXXXX")"
trap 'rm -rf "$RUN_SANDBOX"' EXIT
export HOME="$RUN_SANDBOX/home"
export TMPDIR="$RUN_SANDBOX/tmp"
export ACHILLES_SESSION_STATE_DIR="$HOME/.claude/achilles/sessions"
mkdir -p "$HOME" "$TMPDIR" "$ACHILLES_SESSION_STATE_DIR"

# Runs one case file in a subshell so exports, cwd and counters cannot leak into the next file;
# results come back through $RUN_SANDBOX. A file that exits before finishing is a harness error.
run_case_file() {
  local file="$1" name f_run f_pass f_fail d
  name="$(basename "$file")"
  rm -f "$RUN_SANDBOX/counts" "$RUN_SANDBOX/details" "$RUN_SANDBOX/harness"
  (
    TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0; FAIL_DETAILS=(); HARNESS_ERRORS=()
    # shellcheck source=/dev/null
    source "$file"
    printf '%s %s %s\n' "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED" > "$RUN_SANDBOX/counts"
    printf '%s\n' "${FAIL_DETAILS[@]+"${FAIL_DETAILS[@]}"}" > "$RUN_SANDBOX/details"
    printf '%s\n' "${HARNESS_ERRORS[@]+"${HARNESS_ERRORS[@]}"}" > "$RUN_SANDBOX/harness"
  )
  if [ ! -s "$RUN_SANDBOX/counts" ]; then
    HARNESS_ERRORS+=("$name: exited before finishing — its remaining assertions never ran")
    return
  fi
  read -r f_run f_pass f_fail < "$RUN_SANDBOX/counts"
  TESTS_RUN=$((TESTS_RUN + f_run)); TESTS_PASSED=$((TESTS_PASSED + f_pass)); TESTS_FAILED=$((TESTS_FAILED + f_fail))
  while IFS= read -r d; do [ -n "$d" ] && FAIL_DETAILS+=("$d"); done < "$RUN_SANDBOX/details"
  while IFS= read -r d; do [ -n "$d" ] && HARNESS_ERRORS+=("$d"); done < "$RUN_SANDBOX/harness"
}

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

for f in ${selected[@]+"${selected[@]}"}; do
  echo
  echo "=== $(basename "$f") ==="
  run_case_file "$f"
done

# A case file that only ever asserts ALLOW cannot detect a hook that dies early (a crashed hook
# also emits nothing). Files below are exempt, each for a stated reason.
ALLOW_ONLY_OK=(
  44-playwright-cli-cleanup-on-stop.sh    # recorder: always exits 0, side-effects only
  52-workflow-approver-registry.sh        # recorder: always silent-allows, writes the registry
  59-run-summary-writer.sh                # recorder: Stop hook, never denies
  67-perf-summary-writer.sh               # recorder: Stop hook, never denies
  80-playwright-artifact-archiver.sh      # recorder: "never fails the run: no deny under any input"
  47-public-package-contamination-scan.sh # not a hook: the scan's verdict is the assertion
  62-postinstall-prune-dangling.sh        # not a hook: installer behaviour, checked by state
  75-self-repair-known-defect.sh          # not a hook: classifier output
  82-postinstall-install-scope.sh         # not a hook: installer behaviour, checked by state
)
for f in ${selected[@]+"${selected[@]}"}; do
  name="$(basename "$f")"
  case " ${ALLOW_ONLY_OK[*]} " in *" $name "*) continue ;; esac
  # A statement that starts with the helper, after any VAR=value prefixes; a mention in a
  # comment or inside a string argument does not count.
  grep -qE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|[^[:space:]"]*)+[[:space:]]+)*assert_(deny|warn|stop_block|block_subagent|ask)([[:space:]]|$)' "$f" ||
    HARNESS_ERRORS+=("$name: no assert_deny/assert_warn/assert_stop_block/assert_block_subagent — allow-only files cannot detect a hook that dies early")
done

# Install simulation — proves the gates fire from a consumer-style install
# (hook-manifest.json scripts + lib/ + bin/jq copied to a fake home, no repo
# context). Runs like a case file, before the harness-error report so its
# early exits count. Respects the filter like any case file.
if [ -z "$filter" ] || [[ "install-simulation.sh" == *"$filter"* ]]; then
  echo
  echo "=== install-simulation.sh ==="
  run_case_file "$INSTALL_SIM"
fi

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
