#!/bin/bash
# state-gate.sh — denies Bash commands that write, move or delete files in
#                 the project's process-state directory (rule process.state).
#
# Hook    : PreToolUse:Bash (commands naming <stateDir>)
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : none (stateless pattern check; reads the rule file)
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests)
#
# Rule
# ----
# Every Bash command naming <stateDir> is checked for a write into it:
#   * a redirect (> >> &> 2> >|) onto a path in it;
#   * tee / rm / touch / truncate / unlink / shred / ln / mv / dd naming a path in it, and sed -i /
#     perl -i naming one;
#   * cp / install / rsync whose TARGET (last non-option argument) is in it;
#   * any of those commands after a `cd` into it.
# Reading (cat <stateDir>/…) and copying OUT of it are allowed. Leading `sudo`, `command`, `env`,
# `builtin`, `exec`, `xargs` and VAR=value assignments are peeled before the command is identified.
#
# Why
# ---
# The files in <stateDir> — the verify stamp, the current-change marker — are trust anchors: the
# commit gate believes them. They are written only by the project's own tools (the verify step, the
# change-start command); an agent that writes one by hand has forged a receipt.
#
# Known limit (by design): not quote-aware and not airtight — an interpreter one-liner (node -e …) or an
# encoded path is not seen. The commit gate still recomputes the content hash at commit time, so a
# forged stamp only passes if it carries the hash of the current tree; the two ship as a pair.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#process.state

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=process.state
rule_enabled "$ID"
[ -n "$COMMAND" ] || exit 0
STATE_DIR="$(rule_field "$ID" stateDir)"; STATE_DIR="${STATE_DIR%/}"
[ -n "$STATE_DIR" ] || emit_allow_warn "$ID.stateDir missing in $(rules_rel) — state gate skipped"
[[ "$COMMAND" == *"$STATE_DIR"* ]] || exit 0
unquote() { local t="$1"; t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"; printf '%s' "$t"; }
SD_RE="${STATE_DIR//./\\.}"
refs_state() { local t; t="$(unquote "$1")"; t="${t#*=}"; [[ "$t" =~ (^|/)$SD_RE(/|$) ]]; }
DENY_STATE() { emit_deny "$ID" "Bash command $1 $STATE_DIR/ (\`$2\`) — its files are trust anchors written only by the project's own tools."; }
RD_RE=">[>|]?[[:space:]]*[\"']?([^[:space:];&|<>\"']*/)?$SD_RE(/|[\"'[:space:];&|]|$)"
[[ "$COMMAND" =~ $RD_RE ]] && DENY_STATE "redirects output into" "${BASH_REMATCH[0]}"
NEWLINE=$'\n'; S0="$COMMAND"
S0="${S0//&&/$NEWLINE}"; S0="${S0//||/$NEWLINE}"; S0="${S0//;/$NEWLINE}"; S0="${S0//|/$NEWLINE}"; S0="${S0//&/$NEWLINE}"; S0="${S0//(/ }"; S0="${S0//)/ }"
IN_STATE=0
while IFS= read -r SEG0; do
  read -r -a T0 <<< "$SEG0" || true
  j=0; while [ $j -lt ${#T0[@]} ] && { [[ "${T0[$j]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || [[ "${T0[$j]}" =~ ^(sudo|command|env|builtin|exec|xargs)$ ]]; }; do j=$((j + 1)); done
  [ $j -lt ${#T0[@]} ] || continue
  C0="${T0[$j]##*/}"; ARGS0=("${T0[@]:$((j + 1))}")
  if [ "$C0" = cd ]; then IN_STATE=0; [ ${#ARGS0[@]} -gt 0 ] && refs_state "${ARGS0[0]}" && IN_STATE=1; continue; fi
  case "$C0" in
    tee|rm|touch|truncate|unlink|shred|ln|mv|dd|cp|install|rsync|sed|perl) ;;
    *) continue;;
  esac
  [ "$C0" = sed ] || [ "$C0" = perl ] && { [[ " ${ARGS0[*]-} " == *" -i"* ]] || continue; }
  [ $IN_STATE = 1 ] && DENY_STATE "runs $C0 inside" "$SEG0"
  NONOPT=(); for a in ${ARGS0[@]+"${ARGS0[@]}"}; do case "$a" in -*) ;; *) NONOPT+=("$a");; esac; done
  [ ${#NONOPT[@]} -gt 0 ] || continue
  case "$C0" in
    cp|install|rsync) refs_state "${NONOPT[${#NONOPT[@]}-1]}" && DENY_STATE "copies into" "$SEG0";;
    *) for a in "${NONOPT[@]}"; do refs_state "$a" && DENY_STATE "writes, moves or deletes a path in" "$SEG0"; done;;
  esac
done <<< "$S0"
exit 0
