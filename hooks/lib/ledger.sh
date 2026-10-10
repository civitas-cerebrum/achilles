#!/bin/bash
# ledger.sh — where the pipeline ledgers live and how hooks read them.
LEDGER_ONBOARDING_REL='tests/e2e/docs/onboarding-status.json'
LEDGER_PERF_REL='tests/perf/docs/perf-onboarding-status.json'
LEDGER_APPROVERS_NAME='.workflow-approvers.json'

# ledger_path <project-root> <onboarding|perf>
# The root is joined verbatim: a trailing slash on the root stays visible in the path.
ledger_path() {
  case "$2" in
    onboarding) printf '%s/%s' "$1" "$LEDGER_ONBOARDING_REL" ;;
    perf)       printf '%s/%s' "$1" "$LEDGER_PERF_REL" ;;
    *)          return 1 ;;
  esac
}

# ledger_get <file> <jq-path> [default] — needs JQ (hook_jq_init).
ledger_get() { "$JQ" -r --arg d "${3:-}" "$2 // \$d" "$1" 2>/dev/null || printf '%s' "${3:-}"; }
