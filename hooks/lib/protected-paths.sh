#!/bin/bash
# protected-paths.sh — the pipeline-state artifacts the guards refuse to mutate, and how a path is
# matched against them: protected_bash_match for protected-artifact-bash-guard.sh,
# protected_write_match for hook-authored-state-guard.sh. Needs lib/hook-io.sh; loads lib/ledger.sh.
# hooks/tests/cases/90-protected-paths-equivalence.sh denies every entry through the guard its tag names.

hook_lib ledger.sh

# "<path>|<bash|write|both>". A `bash` entry protects every path that contains it as whole
# components; a `write` entry protects that file under the ledger docs dirs, where the pipeline
# keeps hook-authored state; `both` is both. Entries are literal: no glob, no regex.
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

# Entries whose tag is <want> or both, lower-cased like the paths they are matched against.
protected__entries() {
  local e
  for e in "${PROTECTED_PATHS[@]}"; do
    case "${e##*|}" in "$1"|both) printf '%s\n' "${e%|*}" ;; esac
  done | tr '[:upper:]' '[:lower:]'
}

# protected_path_normalise <path> — the file <path> names, spelled one way: ~ and $HOME expanded,
# // and /./ collapsed, .. resolved lexically, lower-cased (darwin and Windows file systems fold
# case; on Linux this over-protects only paths that differ from a protected one by case).
protected_path_normalise() {
  local p="$1" seg out="" n=0 abs=""
  case "$p" in
    '~'|'~/'*) p="$HOME${p#\~}" ;;
    '$HOME'|'$HOME/'*) p="$HOME${p#\$HOME}" ;;
    '${HOME}'|'${HOME}/'*) p="$HOME${p#\$\{HOME\}}" ;;
  esac
  case "$p" in /*) abs=/ ;; esac
  while IFS= read -r -d / seg; do
    case "$seg" in
      ''|.) ;;
      ..) if [ "$n" -gt 0 ]; then out="${out%/*}"; n=$((n - 1)); elif [ -z "$abs" ]; then out="$out/.."; fi ;;
      *) out="$out/$seg"; n=$((n + 1)) ;;
    esac
  done <<< "$p/"
  if [ -n "$abs" ]; then p="${out:-/}"; else p="${out#/}"; fi
  printf '%s' "$p" | tr '[:upper:]' '[:lower:]'
}

# protected_bash_match <path> — prints the entry and returns 0 when a Bash write to <path> must be denied.
protected_bash_match() {
  local norm e
  norm="$(protected_path_normalise "$1")"
  norm="/${norm#/}/"
  while IFS= read -r e; do
    case "$norm" in *"/$e/"*) printf '%s' "$e"; return 0 ;; esac
  done < <(protected__entries bash)
  return 1
}

# protected_parent_match <path> — prints the directory and returns 0 when <path> is a directory a
# protected entry lives in: a leading part of a multi-component entry (.claude), or a ledger docs
# dir, where the single-name entries live. Ancestors above those (the home dir, tests/) are not counted.
protected_parent_match() {
  local norm e p
  norm="$(protected_path_normalise "$1")"
  norm="/${norm#/}"
  while IFS= read -r e; do
    p="$e"
    while [ "${p%/*}" != "$p" ]; do
      p="${p%/*}"
      case "$norm" in */"$p") printf '%s' "$p"; return 0 ;; esac
    done
  done < <(protected__entries bash)
  for p in "${LEDGER_ONBOARDING_REL%/*}" "${LEDGER_PERF_REL%/*}"; do
    case "$norm" in */"$p") printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}

# protected_bash_mention <text> — prints the first bash entry <text> contains, case-folded, as a substring.
protected_bash_mention() {
  local text e
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r e; do
    case "$text" in *"$e"*) printf '%s' "$e"; return 0 ;; esac
  done < <(protected__entries bash)
  return 1
}

# protected_write_match <path> — 0 when a Write|Edit to <path> must be denied outright.
protected_write_match() {
  local norm e dir
  norm="$(protected_path_normalise "$1")"
  norm="/${norm#/}"
  while IFS= read -r e; do
    for dir in "${LEDGER_ONBOARDING_REL%/*}" "${LEDGER_PERF_REL%/*}"; do
      case "$norm" in */"$dir/$e") return 0 ;; esac
    done
  done < <(protected__entries write)
  return 1
}
