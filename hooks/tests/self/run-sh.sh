#!/bin/bash
# Self-test for run.sh: a case file or install-simulation that exits early must fail the run
# and be named as a harness error, never reported as green.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/../run.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-sh-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cases"
printf 'exit 3\n' > "$WORK/early.sh"
printf ":\n" > "$WORK/cases/ok.sh"
printf ":\n" > "$WORK/sim-ok.sh"
fail=0
check() { # name expected_rc output_pattern
  local name="$1" want_rc="$2" pat="$3" out rc
  out="$(HOOKTESTS_CASES_DIR="$WORK/cases" HOOKTESTS_INSTALL_SIM="$4" bash "$RUN" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -q -- "$pat" <<<"$out"; then echo "ok   $name"
  else echo "FAIL $name (rc=$rc, want $want_rc, pattern '$pat')"; echo "$out" | tail -8; fail=1; fi
}
cp "$WORK/early.sh" "$WORK/cases/early.sh"
check "early-exit case file fails the run" 1 "early.sh: exited before finishing" "$WORK/sim-ok.sh"
rm "$WORK/cases/early.sh"
check "early-exit install-simulation fails the run" 1 "early.sh: exited before finishing" "$WORK/early.sh"
check "clean case file and simulation pass" 0 "all .* tests passed" "$WORK/sim-ok.sh"
exit "$fail"
