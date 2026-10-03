#!/bin/bash
# commit-gate.sh — denies `git commit` in this project without a fresh
#                  content-hash verify stamp and, for the current change,
#                  its verification report (rule process.evidence).
#
# Hook    : PreToolUse:Bash (commands containing `commit`)
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : reads <stamp> = { "treeHash": "<hex>", … } (written by the project's verify step only),
#           <currentChange> (one line: the change folder name), <trailDir>/<change>/<required…>
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests),
#           FACTORY_NODE=<path> (node override when <hashCommand> starts with `node`, tests)
#
# Rule
# ----
# The command is split into shell segments (newline ; && || | & and parentheses; not quote-aware) and
# walked in order:
#   * a `cd <dir>` segment moves the working directory for the segments after it (`cd` alone → $HOME);
#   * a `[VAR=val …] git [--opt | -c k=v | -C <dir>]… commit` segment (--amend --no-edit included) is a
#     commit; its directory is the current one, moved by that SAME segment's `-C <dir>` options
#     (cumulative, as git does).
# A commit whose directory is inside this project is gated; a commit in another repository is not ours
# to gate. Then deny when:
#   (a) <stamp> is missing, has no treeHash, or its treeHash differs from what <hashCommand> prints now
#       (run from the project root) — the stamp is a CONTENT hash, so a touch keeps it and any added,
#       removed or changed file under the hashed roots invalidates it;
#   (b) <currentChange> exists and names a folder that is not <yyyy-mm-dd>-<slug>, or whose
#       <trailDir>/<change>/ lacks a `required` file.
# No <currentChange> marker = a maintenance commit: only the stamp is checked.
#
# Why
# ---
# "Verified" must mean the tree being committed is the tree that passed, not a tree that passed an
# hour and three edits ago. A timestamp cannot tell; a content hash can.
#
# Known limit: the stamp itself is protected by state-gate.sh (process.state); a forged stamp still has
# to carry the hash of the current tree, which only a real verify run produces honestly.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#process.evidence

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=process.evidence
rule_enabled "$ID"
[ -n "$COMMAND" ] || exit 0
[[ "$COMMAND" == *commit* ]] || exit 0
unquote() { local t="$1"; t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"; printf '%s' "$t"; }
ROOT_N="$(normalize_path "$FACTORY_ROOT")"
resolve_dir() {  # resolve_dir <base> <target> → normalized absolute path
  local t; t="$(unquote "$2")"
  case "$t" in "~") t="$HOME";; "~/"*) t="$HOME/${t#\~/}";; /*) ;; *) t="$1/$t";; esac
  normalize_path "$t"
}
NEWLINE=$'\n'
SEGS="$COMMAND"
SEGS="${SEGS//&&/$NEWLINE}"; SEGS="${SEGS//||/$NEWLINE}"; SEGS="${SEGS//;/$NEWLINE}"; SEGS="${SEGS//|/$NEWLINE}"; SEGS="${SEGS//&/$NEWLINE}"
SEGS="${SEGS//(/ }"; SEGS="${SEGS//)/ }"; SEGS="${SEGS//\{/ }"; SEGS="${SEGS//\}/ }"
CUR="$(normalize_path "${CWD:-$FACTORY_ROOT}")"
GATED=0
while IFS= read -r SEG; do
  read -r -a TOK <<< "$SEG" || true
  [ ${#TOK[@]} -gt 0 ] || continue
  if [ "${TOK[0]}" = cd ]; then
    if [ ${#TOK[@]} -gt 1 ] && [ "${TOK[1]}" != "-" ]; then CUR="$(resolve_dir "$CUR" "${TOK[1]}")"; else CUR="$(normalize_path "${HOME:-/}")"; fi
    continue
  fi
  i=0; while [ $i -lt ${#TOK[@]} ] && [[ "${TOK[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do i=$((i + 1)); done
  [ "${TOK[$i]:-}" = git ] || continue
  D="$CUR"; i=$((i + 1)); IS_COMMIT=0
  while [ $i -lt ${#TOK[@]} ]; do
    case "${TOK[$i]}" in
      -C) i=$((i + 1)); [ $i -lt ${#TOK[@]} ] && D="$(resolve_dir "$D" "${TOK[$i]}")";;
      -c) i=$((i + 1));;
      -*) ;;
      commit) IS_COMMIT=1; break;;
      *) break;;
    esac
    i=$((i + 1))
  done
  [ $IS_COMMIT = 1 ] || continue
  case "$D" in "$ROOT_N"|"$ROOT_N"/*) GATED=1;; esac
done <<< "$SEGS"
[ $GATED = 1 ] || exit 0

STAMP_REL="$(rule_field "$ID" stamp)"; TRAIL="$(rule_field "$ID" trailDir)"; CUR_REL="$(rule_field "$ID" currentChange)"
HASH_CMD=(); while IFS= read -r a; do [ -n "$a" ] && HASH_CMD+=("$a"); done < <(rule_array "$ID" hashCommand)
[ -n "$STAMP_REL" ] && [ -n "$TRAIL" ] && [ ${#HASH_CMD[@]} -gt 0 ] || emit_allow_warn "$ID stamp/trailDir/hashCommand missing in $(rules_rel) — commit gate skipped"
REQUIRED=(); while IFS= read -r a; do [ -n "$a" ] && REQUIRED+=("$a"); done < <(rule_array "$ID" required)
WHAT='Tree changed since the last verify (or no verify yet).'
STAMP="$ROOT_N/$STAMP_REL"
[ -f "$STAMP" ] || emit_deny "$ID" "$WHAT No verify stamp ($STAMP_REL missing)."

if [ -n "$CUR_REL" ] && [ -f "$ROOT_N/$CUR_REL" ]; then
  IFS= read -r CHANGE < "$ROOT_N/$CUR_REL" || true
  CHANGE="${CHANGE%%[[:space:]]*}"
  [[ "$CHANGE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] \
    || emit_deny "$ID" "$WHAT $CUR_REL names \"$CHANGE\", which is not a <yyyy-mm-dd>-<slug> change folder."
  for r in ${REQUIRED[@]+"${REQUIRED[@]}"}; do
    [ -f "$ROOT_N/$TRAIL/$CHANGE/$r" ] || emit_deny "$ID" "$WHAT The current change $TRAIL/$CHANGE/ has no $r."
  done
fi

PROG="${HASH_CMD[0]}"
if [ "$PROG" = node ]; then PROG="${FACTORY_NODE-$(command -v node || true)}"; else PROG="$(command -v "$PROG" || true)"; fi
[ -n "$PROG" ] && [ -x "$PROG" ] || emit_allow_warn "${HASH_CMD[0]} not found — commit gate cannot recompute the tree hash; run the verify step before committing"
WANT="$("$JQ" -r '.treeHash // empty' "$STAMP" 2>/dev/null)"
NOW="$(cd "$ROOT_N" && "$PROG" "${HASH_CMD[@]:1}" 2>/dev/null)" \
  || emit_allow_warn "could not recompute the tree hash — commit gate skipped; run the verify step before committing"
NOW="${NOW%%[[:space:]]*}"
[ -n "$WANT" ] || emit_deny "$ID" "$WHAT $STAMP_REL has no treeHash."
[ "$WANT" = "$NOW" ] || emit_deny "$ID" "$WHAT Stamp tree ${WANT:0:12} ≠ current tree ${NOW:0:12} (a file under the hashed roots changed after the verify step)."
exit 0
