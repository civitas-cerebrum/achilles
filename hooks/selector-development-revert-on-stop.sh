#!/bin/bash
# selector-development-revert-on-stop.sh — Stop-time cleanup.
#
# Hook    : Stop
# Mode    : WARN (initial release; flips to DENY in a follow-up after FP calibration)
# State   : reads tests/e2e/.selector-development/.current-scope + receipt
# Env     : WORKSPACE_ROOT (defaults to git toplevel of cwd)
#
# Rule
# ----
# If a scope is active (.current-scope exists) and the receipt's last passing
# step is not `visual_diff` or `commit`, the skill stopped mid-pipeline —
# surface a WARN with the recovery instruction.

set -euo pipefail

# Stop hooks receive a payload; we only need the session-identity fields
# for the session-scope gate below.
INPUT=$(cat 2>/dev/null || echo "{}")

# Session-scope gate: this hook applies only to achilles-activated
# sessions; plain dev sessions silent-allow (lib/achilles-activation.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
achilles_require_active "$INPUT"

ws="${WORKSPACE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
state_dir="$ws/tests/e2e/.selector-development"
scope_file="$state_dir/.current-scope"

[ -f "$scope_file" ] || exit 0
scope=$(cat "$scope_file")
receipt="$state_dir/${scope}.receipt.json"
[ -f "$receipt" ] || exit 0

last=$(jq -r '[.steps[] | select(.status=="pass")] | (last // {}) | .name // ""' "$receipt")
case "$last" in
  visual_diff|commit) exit 0 ;;
esac

files=$(jq -r '.files[]?' "$receipt" | tr '\n' ' ')
if [ -n "${files// /}" ]; then
  message="selector-development: incomplete patch detected for scope '${scope}' (last step: ${last:-<none>}). Run: git checkout -- ${files} && rm '${receipt}' '${scope_file}'. Otherwise the next selector-development invocation will refuse to start."
else
  message="selector-development: incomplete patch detected for scope '${scope}' (last step: ${last:-<none>}). Run: rm '${receipt}' '${scope_file}'. Otherwise the next selector-development invocation will refuse to start."
fi

jq -n --arg msg "$message" '{systemMessage:$msg}'
exit 0
