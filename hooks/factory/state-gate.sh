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
# The command is split as the shell would (lib/shell-words.sh: quotes, `sh -c`, `eval`, `$( )`, braces, wrappers), so
# quoted text is an argument, never a redirect. A line is ARMED when a word names <stateDir> as a path component
# (`.factory`, `./.factory/x`, `/abs/.factory/x`, `of=.factory/x`); `user.factory.ts` does not arm it. On an armed line
# unrecognised = unsafe:
#   * a segment whose words touch <stateDir> (or run after a `cd` into it) passes only when its command is
#       - a reader: cat head tail less grep rg jq ls stat wc diff cmp test [ [[ file md5 md5sum sha*sum shasum echo
#         printf, or find without -delete -exec -execdir -ok -okdir -fprint* -fls; or
#       - cp / install / rsync with <stateDir> provably a SOURCE: every option known and before the operands, the
#         target (last operand or -t directory) literal and outside <stateDir>;
#     everything else is denied, whatever it is (find -delete, curl -o, tar -C, git checkout, patch, python3 …);
#   * a redirect target (> >> >| &> n>) naming <stateDir>, or not literal (`$VAR`, `$( )`, a glob), is denied;
#   * `cd` / `pushd` into <stateDir>, or to a target the gate cannot resolve, makes every later segment count as
#     inside it: only readers pass, and a redirect must go to an absolute path outside it;
#   * a wrapper option the splitter does not know, or a command word that is not literal, is denied;
#   * a `$VAR`, `$( )` or path glob in a word of a writer (tee rm touch truncate unlink shred ln mv dd cp install rsync,
#     sed -i, perl -i) is denied wherever on the line it is, because the variable may hold the state path;
#   * a line too long to split is denied when it names <stateDir>.
#
# Why
# ---
# The files in <stateDir> — the verify stamp, the current-change marker — are trust anchors: the
# commit gate believes them. They are written only by the project's own tools (the verify step, the
# change-start command); an agent that writes one by hand has forged a receipt.
#
# Known limit (by design): a static floor on one command line. Not seen: a state path staged by an earlier call (a
# symlink, an alias, a variable or `cd` from a previous Bash call); a path built at run time that the line never
# names; text fed to an interpreter (`echo … | sh`, `python3 -c`, `node -e`, a script file); a glob in the state
# directory's own name (`.fact*`); a reader the allowlist leaves out is denied, not judged. The commit gate still
# recomputes the content hash at commit time, so a forged stamp only passes if it carries the hash of the current tree;
# the two ship as a pair.
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
# A word names the state dir as a path component, alone or as an option value (of=X, --out=X, -oX).
refs_state() {
  [[ "$1" =~ $STATE_RE ]] && return 0
  [[ "$1" == *=* ]] && [[ "${1#*=}" =~ $STATE_RE ]] && return 0
  [[ "$1" == -[A-Za-z]?* ]] && [[ "${1:2}" =~ $STATE_RE ]]
}
unresolved() { case "$1" in *'$'*|*'`'*) return 0;; */*) case "$1" in *[*?[]*) return 0;; esac;; esac; return 1; }
deny_state() { emit_deny "$ID" "Bash command $1 (\`${2:0:80}\`) — its files are trust anchors written only by the project's own tools."; }

shell_words "$COMMAND"
if [ "$SW_OVERFLOW" = 1 ]; then
  [[ "$COMMAND" == *"$STATE_DIR"* ]] && deny_state "is too long to verify and names $STATE_DIR/" "$COMMAND"
  exit 0
fi
[[ "${SW[*]-}" == *"$STATE_DIR"* ]] || exit 0
armed=0
for w in ${SW[@]+"${SW[@]}"}; do refs_state "$w" && { armed=1; break; }; done
[ "$armed" = 1 ] || exit 0

# reader_ok — 0 when CMD_ARGS is a read-only command.
reader_ok() {
  local cmd="${CMD_ARGS[0]}" i a
  [ -z "$CMD_PATH" ] || return 1
  case "$cmd" in
    cat|head|tail|grep|jq|ls|stat|wc|diff|cmp|test|'['|'[['|md5|md5sum|shasum|sha*sum|echo|printf) return 0;;
    less|rg|file|find) ;;
    *) return 1;;
  esac
  for ((i = 1; i < ${#CMD_ARGS[@]}; i++)); do
    a="${CMD_ARGS[i]}"
    case "$cmd:$a" in
      find:-delete|find:-exec|find:-execdir|find:-ok|find:-okdir|find:-fprint*|find:-fls) return 1;;
      rg:--pre*|rg:--hostname-bin*|less:-o|less:-O|less:--log-file*|less:--LOG-FILE*) return 1;;
      file:-*C*) return 1;;
    esac
  done
  return 0
}

# copy_option <option> — classifies one cp / install / rsync option word: sets COPT to none (consumes nothing),
# next (its value is the next word) or bad (unknown: the copy cannot be judged), and TDIR_SET / TDIR for -t.
copy_option() {
  local o="$1" cmd="${CMD_ARGS[0]}" name letters ch rest noval val longs longval
  COPT=bad
  case "$cmd" in
    cp)      noval=abdfHiLnPpRrTuvxZ;  val=St;    longs=" archive attributes-only backup copy-contents debug dereference force interactive no-clobber no-dereference no-preserve no-target-directory one-file-system parents preserve recursive reflink remove-destination sparse strip-trailing-slashes suffix target-directory update verbose "; longval=" suffix target-directory ";;
    install) noval=bCDpTUv;            val=mogSt; longs=" backup compare create-leading debug group mode owner preserve-timestamps suffix target-directory no-target-directory verbose "; longval=" group mode owner suffix target-directory ";;
    rsync)   noval=acdDgHilLnoOpPqrRtuvxzh; val=;  longs=" archive checksum compress dirs dry-run exclude human-readable include itemize-changes links one-file-system partial perms progress quiet recursive stats times update verbose "; longval=" exclude include ";;
  esac
  case "$o" in
    --*) name="${o#--}"; name="${name%%=*}"
         case "$longs" in *" $name "*) ;; *) return 0;; esac
         if [ "$name" = target-directory ]; then
           TDIR_SET=1; case "$o" in *=*) TDIR="${o#*=}";; *) TDIR="${CMD_ARGS[CI+1]:-}"; CI=$((CI + 1));; esac
         elif [[ "$o" != *=* ]]; then
           case "$longval" in *" $name "*) CI=$((CI + 1)); refs_state "${CMD_ARGS[CI]:-}" && return 0;; esac
         fi
         refs_state "$o" && return 0
         COPT=none; return 0;;
  esac
  letters="${o#-}"
  while [ -n "$letters" ]; do
    ch="${letters:0:1}"; letters="${letters:1}"
    case "$ch" in
      [$noval]) ;;
      [$val]) if [ -n "$letters" ]; then rest="$letters"; else CI=$((CI + 1)); rest="${CMD_ARGS[CI]:-}"; fi
              if [ "$ch" = t ]; then TDIR_SET=1; TDIR="$rest"; elif refs_state "$rest"; then return 0; fi
              letters="";;
      *) return 0;;
    esac
  done
  COPT=none
}

# cp_source_only — 0 when <stateDir> can only be a source of the cp / install / rsync in CMD_ARGS.
cp_source_only() {
  local ops=() target a
  TDIR=""; TDIR_SET=0; CI=1
  [ "$IN_STATE" = 0 ] && [ "$CMD_XARGS" = 0 ] && [ -z "$CMD_PATH" ] || return 1
  while [ "$CI" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[CI]}"
    case "$a" in
      --) while [ $((++CI)) -lt "${#CMD_ARGS[@]}" ]; do ops+=("${CMD_ARGS[CI]}"); done; break;;
      -?*) [ "${#ops[@]}" -eq 0 ] || return 1
           copy_option "$a"; [ "$COPT" = none ] || return 1;;
      *) ops+=("$a");;
    esac
    CI=$((CI + 1))
  done
  if [ "$TDIR_SET" = 1 ]; then target="$TDIR"; [ "${#ops[@]}" -ge 1 ] || return 1
  else [ "${#ops[@]}" -ge 2 ] || return 1; target="${ops[${#ops[@]}-1]}"; unset 'ops[${#ops[@]}-1]'; fi
  [ -n "$target" ] && shell_word_literal "$target" && ! refs_state "$target" || return 1
  for a in ${ops[@]+"${ops[@]}"}; do shell_word_literal "$a" || return 1; done
  return 0
}

is_writer() {
  local cmd="${CMD_ARGS[0]}" a
  case "$cmd" in
    tee|rm|touch|truncate|unlink|shred|ln|mv|dd|cp|install|rsync) return 0;;
    sed|perl) for a in "${CMD_ARGS[@]:1}"; do case "$a" in --in-place*) return 0;; --*) ;; -*i*) return 0;; esac; done;;
  esac
  return 1
}

IN_STATE=0
judge_command() {
  local cmd="${CMD_ARGS[0]:-}" n=${#CMD_ARGS[@]} frag="${CMD_ARGS[*]-}" a t touches=0
  [ "$CMD_WRAP_BAD" = 0 ] || deny_state "runs behind a wrapper option the gate cannot read while naming $STATE_DIR/" "${frag:-$COMMAND}"
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do
    refs_state "$t" && deny_state "redirects output into $STATE_DIR/" "$t"
    shell_word_literal "$t" || deny_state "redirects output to a target it cannot resolve ($t) while naming $STATE_DIR/" "$t"
    [ "$IN_STATE" = 0 ] || case "$t" in /*) ;; *) deny_state "redirects output from inside $STATE_DIR/" "$t";; esac
  done
  [ -n "$cmd" ] || return 0
  case "$cmd" in '['|'[[') ;; *) shell_word_literal "$cmd" || deny_state "runs a command word it cannot resolve ($cmd) while naming $STATE_DIR/" "$frag";; esac
  if [ "$cmd" = cd ] || [ "$cmd" = pushd ]; then
    t="${CMD_ARGS[n-1]}"
    if [ "$n" -eq 1 ]; then [ "$cmd" = pushd ] && IN_STATE=1 || IN_STATE=0
    elif refs_state "$t" || [ "$t" = - ] || ! shell_word_literal "$t"; then IN_STATE=1
    elif [ "$IN_STATE" = 1 ]; then case "$t" in /*) IN_STATE=0;; esac
    else IN_STATE=0; fi
    return 0
  fi
  [ "$IN_STATE" = 0 ] || touches=1
  [ -z "$CMD_PATH" ] || ! refs_state "$CMD_PATH" || touches=1
  for ((t = 1; t < n; t++)); do refs_state "${CMD_ARGS[t]}" && touches=1; done
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"}; do refs_state "$a" && touches=1; done
  if [ "$touches" = 1 ]; then
    reader_ok && return 0
    case "$cmd" in cp|install|rsync) cp_source_only && return 0;; esac
    deny_state "runs $cmd on $STATE_DIR/, which only readers and copying out of it may do" "$frag"
  fi
  is_writer || return 0
  [ "$CMD_XARGS" = 0 ] || deny_state "runs $cmd on operands from stdin while naming $STATE_DIR/" "$frag"
  for ((t = 1; t < n; t++)); do
    a="${CMD_ARGS[t]}"
    [ "$cmd" != dd ] || case "$a" in of=*) a="${a#of=}";; *) continue;; esac
    unresolved "$a" && deny_state "writes a path it cannot resolve ($a) while naming $STATE_DIR/" "$frag"
  done
  return 0
}
shell_each_command judge_command
exit 0
