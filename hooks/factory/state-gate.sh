#!/bin/bash
# state-gate.sh — denies Bash commands that write, move or delete files in
#                 the project's process-state directory (rule process.state).
#
# Hook    : PreToolUse:Bash (commands naming <stateDir>)
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : none (stateless pattern check; reads the rule file)
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests)
#
# A line is ARMED when a word names <stateDir>, the stamp or the change marker (lib/shell-words.sh split,
# case folded). On an armed line a command touching them passes only as a reader or a copy out of the
# directory; redirects into it, a `cd` into it followed by a write, and unreadable lines are denied.
# Rule, reader list and scope: the canonical reference below; what is out of scope: known-limits.md KL-20.
#
# Why: the stamp and the change marker are trust anchors the commit gate believes. Only the project's
# own tools write them; an agent that writes one by hand has forged a receipt.
#
# Canonical reference: skills/achilles-protocol/references/factory-gates.md#process.state

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=process.state
rule_enabled "$ID"
[ -n "$COMMAND" ] || exit 0
STATE_DIR="$(rule_field "$ID" stateDir)"; STATE_DIR="${STATE_DIR%/}"
[ -n "$STATE_DIR" ] || emit_allow_warn "$ID.stateDir missing in $(rules_rel) — state gate skipped"
[ -r "$HOOK_IO_DIR/shell-words.sh" ] || { emit_pre_deny_bare "[factory] lib/shell-words.sh is missing, so the state gate cannot read Bash commands.
→ Do: Reinstall @civitas-cerebrum/achilles (npm install), then retry.
→ Why/how: skills/achilles-protocol/references/factory-gates.md#process.state"; exit 0; }
. "$HOOK_IO_DIR/shell-words.sh"
STAMP="$(rule_field process.evidence stamp)"; MARKER="$(rule_field process.evidence currentChange)"
STAMP="${STAMP:-verify-stamp}"; STAMP="${STAMP##*/}"; MARKER="${MARKER:-current-change}"; MARKER="${MARKER##*/}"
NAME_RE="(^|[^[:alnum:]_.-])(${STATE_DIR//./\\.}|${STAMP//./\\.}|${MARKER//./\\.})([^[:alnum:]_.-]|\$)"

# names_state <word> — 0 when the word names <stateDir>, the stamp or the marker (APFS ignores case).
names_state() { local r; shopt -s nocasematch; [[ "$1" =~ $NAME_RE ]]; r=$?; shopt -u nocasematch; return $r; }
# literal <word> — 0 when the shell uses the word as written: no variable, substitution or glob.
literal() { case "$1" in *[\$\`*?[]*) return 1;; esac; }
deny_state() { local f="${2//$'\n'/ }"; emit_deny "$ID" "Bash command $1 (\`${f:0:80}\`) — its files are trust anchors written only by the project's own tools."; }

shell_words "$COMMAND"
[ "$SW_OVERFLOW" = 0 ] || deny_state "is too long to split (over 32 KB), so it may reach $STATE_DIR/" "$COMMAND"

# mark_inert — INERT: indices of CMD_ARGS holding a git commit / tag / merge message, which names no file.
mark_inert() {
  local i
  INERT=" "
  case "${CMD_ARGS[0]:-}:${CMD_ARGS[1]:-}" in git:commit|git:tag|git:merge) ;; *) return 0;; esac
  for ((i = 2; i < ${#CMD_ARGS[@]}; i++)); do
    case "${CMD_ARGS[i]}" in
      --message=*|-m?*) INERT="$INERT$i ";;
      --message|-m|-[!-]*m) i=$((i + 1)); INERT="$INERT$i ";;
    esac
  done
}
is_inert() { [[ "$INERT" == *" $1 "* ]]; }

ARMED=0
arm_command() {
  local a i
  mark_inert
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"} ${CMD_WRITES[@]+"${CMD_WRITES[@]}"} ${CMD_CHDIR:+"$CMD_CHDIR"}; do
    names_state "$a" && ARMED=1
  done
  for ((i = 0; i < ${#CMD_ARGS[@]}; i++)); do is_inert "$i" || ! names_state "${CMD_ARGS[i]}" || ARMED=1; done
  return 0
}
shell_each_command arm_command
[ "$ARMED" = 1 ] || exit 0

# reader_ok — 0 for a command that only reads: the shared reader list, or find without an action.
reader_ok() {
  local a
  if [ "${CMD_ARGS[0]}" = find ]; then
    for a in "${CMD_ARGS[@]}"; do case "$a" in -delete|-exec*|-ok*|-fprint*|-fls) return 1;; esac; done
    return 0
  fi
  shell_is_reader
}

# copy_out_ok — 0 when a cp / install copies out of <stateDir>: its target (-t DIR, or the last operand)
# is literal and names nothing in it, and no option follows an operand (it could take the last word as its value).
copy_out_ok() {
  local i a target="" ops=0
  for ((i = 1; i < ${#CMD_ARGS[@]}; i++)); do
    a="${CMD_ARGS[i]}"
    case "$a" in
      -t|--target-directory|-[!-]*t) i=$((i + 1)); target="${CMD_ARGS[i]:-}";;
      --target-directory=*) target="${a#*=}";;
      -*) [ "$ops" = 0 ] || return 1;;
      *) ops=$((ops + 1)); [ -n "${CMD_ARGS[i+1]+x}" ] || [ -n "$target" ] || target="$a";;
    esac
  done
  [ "$ops" -ge 1 ] && [ -n "$target" ] && literal "$target" && ! names_state "$target"
}

IN_STATE=0
judge_command() {
  local cmd="${CMD_ARGS[0]:-}" frag="${CMD_ARGS[*]-}" a t touches=$IN_STATE
  [ "$CMD_WRAP_BAD" = 0 ] || deny_state "runs behind a wrapper option the gate cannot read while naming $STATE_DIR/" "${frag:-$COMMAND}"
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do
    names_state "$t" && deny_state "redirects output into $STATE_DIR/" "$t"
    literal "$t" || deny_state "redirects output to a target it cannot resolve ($t) while naming $STATE_DIR/" "$t"
    [ "$IN_STATE" = 0 ] || case "$t" in /*) ;; *) deny_state "redirects output from inside $STATE_DIR/" "$t";; esac
  done
  [ -n "$cmd" ] || return 0
  case "$cmd" in
    cd|pushd) { names_state "${CMD_ARGS[1]:-}" || ! literal "${CMD_ARGS[1]:-}"; } && IN_STATE=1; return 0;;
    xargs) touches=1;;
  esac
  # env -C moves only this command; its redirects are the caller's.
  if [ -n "$CMD_CHDIR" ] && { names_state "$CMD_CHDIR" || ! literal "$CMD_CHDIR"; }; then touches=1; fi
  mark_inert
  for ((t = 1; t < ${#CMD_ARGS[@]}; t++)); do
    is_inert "$t" && continue
    a="${CMD_ARGS[t]}"
    case "$a" in *'$('*|*'`'*) deny_state "runs a command substitution the gate cannot read while naming $STATE_DIR/" "$frag";; esac
    names_state "$a" && touches=1; literal "$a" || touches=1
  done
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"}; do names_state "$a" && touches=1; done
  [ "$touches" = 1 ] || return 0
  reader_ok && return 0
  case "$cmd" in cp|install) [ "$IN_STATE" = 0 ] && copy_out_ok && return 0;; esac
  deny_state "runs $cmd on $STATE_DIR/, which only readers and copying out of it may do" "$frag"
}
shell_each_command judge_command
exit 0
