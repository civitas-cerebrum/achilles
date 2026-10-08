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
# The command is split as the shell would (lib/shell-words.sh: quotes, `sh -c`, `eval`, `$( )`, braces), so quoted
# text is an argument, never a redirect. A command naming <stateDir> is denied when it:
#   * redirects output (> >> &> 2> >|) onto a path in it;
#   * runs tee / rm / touch / truncate / unlink / shred / ln / mv, sed -i / perl -i, or dd of=, naming a path in it;
#   * runs cp / install / rsync whose TARGET (last non-option argument, or the -t directory) is in it;
#   * runs any of those after a `cd` into it.
# Reading (cat <stateDir>/…) and copying OUT of it are allowed. Leading wrappers (`sudo`, `command`, `env`, `nice`,
# `xargs`, …) and VAR=value assignments are peeled before the command is identified.
# Fail closed, because the target cannot be judged: a line too long to split; a wrapper option the splitter does not
# know; `xargs` feeding a writer; a `$VAR`, `$( )` or path glob as the operand of a writer other than cp / install /
# rsync (a copy to a variable path is the common copy-out and passes).
#
# Why
# ---
# The files in <stateDir> — the verify stamp, the current-change marker — are trust anchors: the
# commit gate believes them. They are written only by the project's own tools (the verify step, the
# change-start command); an agent that writes one by hand has forged a receipt.
#
# Known limit (by design): not airtight — an interpreter one-liner (node -e …), an encoded path, a glob in the state
# directory's own name or a variable target of sed -i is not seen. The commit gate still recomputes the content hash
# at commit time, so a forged stamp only passes if it carries the hash of the current tree; the two ship as a pair.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#process.state

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
. "$HOOK_IO_DIR/shell-words.sh"
factory_guard_ready; factory_read_input
ID=process.state
rule_enabled "$ID"
[ -n "$COMMAND" ] || exit 0
STATE_DIR="$(rule_field "$ID" stateDir)"; STATE_DIR="${STATE_DIR%/}"
[ -n "$STATE_DIR" ] || emit_allow_warn "$ID.stateDir missing in $(rules_rel) — state gate skipped"
STATE_RE="(^|/)${STATE_DIR//./\\.}(/|\$)"
refs_state() { [[ "$1" =~ $STATE_RE ]] || { [[ "$1" == *=* ]] && [[ "${1#*=}" =~ $STATE_RE ]]; }; }
unresolved() { case "$1" in *'$'*|*'`'*) return 0;; */*) case "$1" in *[*?[]*) return 0;; esac;; esac; return 1; }
deny_state() { emit_deny "$ID" "Bash command $1 (\`$2\`) — its files are trust anchors written only by the project's own tools."; }

shell_words "$COMMAND"
if [ "$SW_OVERFLOW" = 1 ]; then
  [[ "$COMMAND" == *"$STATE_DIR"* ]] && deny_state "is too long to verify and names $STATE_DIR/" "${COMMAND:0:80}"
  exit 0
fi
[[ "${SW[*]-}" == *"$STATE_DIR"* ]] || exit 0

IN_STATE=0
judge_command() {
  local cmd="${CMD_ARGS[0]:-}" a t target="" tdir="" inplace=0 ops=() n
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do
    refs_state "$t" && deny_state "redirects output into $STATE_DIR/" "$t"
  done
  [ -n "$cmd" ] || return 0
  n=${#CMD_ARGS[@]}
  if [ "$cmd" = cd ]; then IN_STATE=0; [ "$n" -gt 1 ] && refs_state "${CMD_ARGS[n-1]}" && IN_STATE=1; return 0; fi
  case "$cmd" in tee|rm|touch|truncate|unlink|shred|ln|mv|dd|cp|install|rsync|sed|perl) ;; *) return 0;; esac
  if [ "$cmd" = sed ] || [ "$cmd" = perl ]; then
    for a in "${CMD_ARGS[@]:1}"; do case "$a" in --in-place*) inplace=1;; --*) ;; -*i*) inplace=1;; esac; done
    [ "$inplace" = 1 ] || return 0
  fi
  [ "$CMD_WRAP_BAD" = 0 ] || deny_state "runs $cmd behind a wrapper option the gate cannot read while naming $STATE_DIR/" "${CMD_ARGS[*]}"
  [ "$CMD_XARGS" = 0 ] || deny_state "runs $cmd on operands from stdin while naming $STATE_DIR/" "${CMD_ARGS[*]}"
  [ "$IN_STATE" = 0 ] || deny_state "runs $cmd inside $STATE_DIR/" "${CMD_ARGS[*]}"
  for ((t = 1; t < n; t++)); do
    a="${CMD_ARGS[t]}"
    case "$cmd:$a" in
      cp:--target-directory=*|install:--target-directory=*) tdir="${a#*=}";;
      cp:--target-directory|install:--target-directory) tdir="${CMD_ARGS[t+1]:-}";;
      cp:--*|install:--*) ;;
      cp:-*t*|install:-*t*) tdir="${a#*t}"; [ -n "$tdir" ] || tdir="${CMD_ARGS[t+1]:-}";;
      dd:of=*) ops+=("${a#of=}");;
      dd:*) ;;
      *:-*) ;;
      *) ops+=("$a");;
    esac
  done
  case "$cmd" in
    cp|install|rsync)
      if [ -n "$tdir" ]; then target="$tdir"; elif [ ${#ops[@]} -gt 0 ]; then target="${ops[${#ops[@]}-1]}"; fi
      [ -n "$target" ] && refs_state "$target" && deny_state "copies into $STATE_DIR/" "${CMD_ARGS[*]}";;
    *)
      for a in ${ops[@]+"${ops[@]}"}; do
        refs_state "$a" && deny_state "writes, moves or deletes a path in $STATE_DIR/" "${CMD_ARGS[*]}"
        case "$cmd" in sed|perl) ;; *) unresolved "$a" && deny_state "writes a path it cannot resolve ($a) while naming $STATE_DIR/" "${CMD_ARGS[*]}";; esac
      done;;
  esac
  return 0
}
shell_each_command judge_command
exit 0
