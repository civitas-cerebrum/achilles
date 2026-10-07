#!/bin/bash
# protected-paths.sh — the pipeline-state artifacts the guards refuse to mutate, and the
# two forms the guards match them in: an ERE for protected-artifact-bash-guard.sh and a
# path test for hook-authored-state-guard.sh. Needs lib/hook-io.sh; loads lib/ledger.sh.
# hooks/tests/cases/90-protected-paths-equivalence.sh pins every path each form protects.

hook_lib ledger.sh

# "<glob>|<bash|write|both>". `bash` entries are matched anywhere in a shell command; a
# `write` entry is matched as a file under the ledger docs dirs, which is where the pipeline
# keeps hook-authored state; `both` is both. The glob uses * (one path segment) and ** (any).
PROTECTED_PATHS=(
  'onboarding-status.json|bash'
  'perf-onboarding-status.json|bash'
  'journey-map.md|bash'
  '.phase4-cycle-state.json|bash'
  'coverage-expansion-state.json|bash'
  "$LEDGER_APPROVERS_NAME|both"
  'adversarial-findings.md|bash'
  '.ledger-integrity.json|both'
  'flake-quarantine.md|bash'
  '.claude/achilles|bash'
  '.claude/hooks|bash'
  '.claude/settings.json|bash'
  '.claude/settings.local.json|bash'
)

# Entries whose tag is <want> or both.
protected__globs() {
  local e
  for e in "${PROTECTED_PATHS[@]}"; do
    case "${e##*|}" in "$1"|both) printf '%s\n' "${e%|*}" ;; esac
  done
}

# protected_bash_regex — ERE alternation; the caller greps it unanchored.
protected_bash_regex() {
  local g r out=""
  while IFS= read -r g; do
    r=${g//./\\.}
    r=${r//\*\*/$'\001'}
    r=${r//\*/[^/]*}
    out="${out:+$out|}${r//$'\001'/.*}"
  done < <(protected__globs bash)
  printf '%s' "$out"
}

# protected_write_match <path> — 0 when a Write|Edit to <path> must be denied outright.
protected_write_match() {
  local norm="/${1#/}" g dir
  while IFS= read -r g; do
    for dir in "${LEDGER_ONBOARDING_REL%/*}" "${LEDGER_PERF_REL%/*}"; do
      # shellcheck disable=SC2254 # the glob is the pattern
      case "$norm" in */$dir/$g) return 0 ;; esac
    done
  done < <(protected__globs write)
  return 1
}
