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
# The line is split as the shell would (lib/shell-words.sh). It is ARMED when a command names <stateDir> or the stamp or
# marker file name (case folded, literal or as a glob that could match it, with expansions read as empty or `/`) in a
# word, an `=` value, a glued option value, an env -C directory, or a command string split again. On an armed line
# unrecognised = unsafe: a command touching <stateDir> passes only as a listed reader or a provable copy-out, a redirect
# into it or to a target that does not resolve is denied, and a `cd` the gate cannot resolve puts the rest of the line
# inside it. Any line that takes over 4 s to judge, cannot be split whole, or turns on extglob (or dotglob / nocaseglob
# / GLOBIGNORE beside a glob) is denied. Grammar, reader list and copy-out conditions: the canonical reference below.
#
# Why
# ---
# The files in <stateDir> — the verify stamp, the current-change marker — are trust anchors: the
# commit gate believes them. They are written only by the project's own tools (the verify step, the
# change-start command); an agent that writes one by hand has forged a receipt.
#
# What one line cannot show: skills/achilles-protocol/references/known-limits.md, KL-20.
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
STATE_TOKEN_RE="(^|[^[:alnum:]_.-])${STATE_DIR//./\\.}([^[:alnum:]_.-]|\$)"
IFS=/ read -r -a STATE_COMP <<< "$STATE_DIR"
# The stamp and the change marker are reached by file name too (`find . -name verify-stamp -delete`).
STAMP="$(rule_field process.evidence stamp)"; MARKER="$(rule_field process.evidence currentChange)"
STATE_NAMES=("$(basename "${STAMP:-verify-stamp}")" "$(basename "${MARKER:-current-change}")")
NAME_RE="(^|[^[:alnum:]_.-])(${STATE_NAMES[0]//./\\.}|${STATE_NAMES[1]//./\\.})([^[:alnum:]_.-]|\$)"
EXPANSION_RE='\$\{[^}]*\}|\$\([^)]*\)|`[^`]*`|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]'
# A hook that times out allows, so judging stops at a deadline (FACTORY_STATE_DEADLINE, tests, may only lower it).
DEADLINE="${FACTORY_STATE_DEADLINE:-4}"; case "$DEADLINE" in ''|*[!0-9]*) DEADLINE=4;; esac; [ "$DEADLINE" -le 4 ] || DEADLINE=4
WORD_SYNTAX=$'[\'" \t\n\\\\`;&|()<>{}]' SPLITS=0

# glob_match <name> <pattern> — bash pattern matching with dotglob off: a dot name needs a literal leading dot.
glob_match() { case "$1" in .*) case "$2" in .*) ;; *) return 1;; esac;; esac; [[ "$1" == $2 ]]; }
# glob_names_state <word> — 0 when a window of the word's path components matches <stateDir>'s components, or a
# component holding a letter or digit (so `dist/*` does not) matches the stamp or marker name.
glob_names_state() {
  local c i j ok p
  IFS=/ read -r -a c <<< "${1//$'\n'//}"
  for ((i = 0; i + ${#STATE_COMP[@]} <= ${#c[@]}; i++)); do
    ok=1
    for ((j = 0; j < ${#STATE_COMP[@]}; j++)); do glob_match "${STATE_COMP[j]}" "${c[i+j]}" || { ok=0; break; }; done
    [ "$ok" = 1 ] && return 0
  done
  for p in ${c[@]+"${c[@]}"}; do
    case "$p" in *[[:alnum:]]*) glob_match "${STATE_NAMES[0]}" "$p" || glob_match "${STATE_NAMES[1]}" "$p" && return 0;; esac
  done
  return 1
}
# unexpand <word> <text> — UNX: the word with every expansion ($NAME, ${…}, $(…), backticks, $1, $@ …) replaced by
# <text>. An unset variable is empty and a set one may be a separator, so `$X.factory` and `${X}.fact*` name it.
unexpand() {
  local w="$1" m
  UNX=""
  while [[ "$w" =~ $EXPANSION_RE ]]; do m="${BASH_REMATCH[0]}"; UNX="$UNX${w%%"$m"*}$2"; w="${w#*"$m"}"; done
  UNX="$UNX$w"
}
# state_word <word> — 0 when the word, an `=` value or a glued option value (-o.factory/x) names <stateDir>, or the
# word holds shell syntax and names it once split (state_text).
state_word() {
  local t o
  in_time
  case "$1" in *[\$\`]*)
    unexpand "$1" ""; [ "$UNX" = "$1" ] || ! state_word "$UNX" || return 0
    unexpand "$1" /; [ "$UNX" = "$1" ] || ! state_word "$UNX" || return 0;;
  esac
  for t in "$1" "${1#*=}" "${1##*=}"; do
    o=""; case "$t" in -?*) o="${t#-}"; while [[ "$o" == [A-Za-z]* ]]; do o="${o#?}"; done;; esac
    for t in "$t" "$o"; do
      [[ "$t" =~ $STATE_TOKEN_RE || "$t" =~ $NAME_RE ]] && return 0
      case "$t" in *[*?[]*) glob_names_state "$t" && return 0;; esac
    done
  done
  case "$1" in *$WORD_SYNTAX*) state_text "$1";; *) return 1;; esac
}
# state_text <word> — 0 when the word, split as a command line of its own, holds a word that names <stateDir> or a
# glob-changing option, or cannot be split whole; past 64 splits a line (~1.6 ms each, and a hook that times out
# allows) every further one counts. The split fills locals, so the command being judged is kept.
state_text() {
  [ $((SPLITS += 1)) -le 64 ] && [ "${SPLIT_DEPTH:-0}" -lt "$SHELL_WORDS_NEST_CAP" ] || return 0
  local SW SW_NESTED SW_OVERFLOW CMD_ARGS CMD_ASSIGN CMD_WRITES CMD_HEREDOCS CMD_SNEST CMD_PATH CMD_CHDIR CMD_ENV \
    CMD_XARGS CMD_WRAP_BAD SPLIT_DEPTH=$((${SPLIT_DEPTH:-0} + 1)) w
  shopt -u nocasematch; shell_words "$1"; shopt -s nocasematch
  [ "$SW_OVERFLOW" = 0 ] || return 0
  for w in ${SW[@]+"${SW[@]}"}; do
    case "$w" in "$SW_SEP"|"$SW_OP"*|"$1") continue;; *extglob*|*dotglob*|*nocaseglob*|*GLOBIGNORE*) return 0;; esac
    state_word "$w" && return 0
  done
  return 1
}
# refs_state <word> — state_word, case folded (APFS ignores case).
refs_state() { local r; shopt -s nocasematch; state_word "$1"; r=$?; shopt -u nocasematch; return $r; }
# dir_unjudged <dir> — 0 when the shell may be inside <stateDir> after entering <dir>: it names it, is not literal, or
# is resolved at run time (-, ~…, +N).
dir_unjudged() {
  case "$1" in -|\~*|+*) return 0;; esac
  refs_state "$1" || ! shell_word_literal "$1"
}
in_time() { [ "$SECONDS" -lt "$DEADLINE" ] || deny_state "took over $DEADLINE s to verify (a hook that times out allows); split it" "$COMMAND"; }
deny_state() { local f="${2//$'\n'/ }"; emit_deny "$ID" "Bash command $1 (\`${f:0:80}\`) — its files are trust anchors written only by the project's own tools."; }

shell_words "$COMMAND"
[ "$SW_OVERFLOW" = 0 ] || deny_state "cannot be split whole (over 32 KB, 16 nested commands or 64 brace words), so it may reach $STATE_DIR/" "$COMMAND"

# mark_inert — INERT lists the indices of CMD_ARGS that are text another command judges or that no path can come from:
# the -c script of a shell and the arguments of eval (split and judged as commands of their own), and the message of
# git commit / tag / merge / notes add|append / stash push|save: --message, or a short cluster whose first value letter
# (per subcommand) is m. -F, -C and the other value letters name files or commits and stay.
mark_inert() {
  local n=${#CMD_ARGS[@]} i=2 a vl; INERT=" "
  case "${CMD_ARGS[0]:-}" in
    sh|bash|zsh|dash|ksh) shell_script_arg; [ "$SW_SCRIPT_C" = 0 ] || INERT="$INERT$SW_SCRIPT ";;
    eval) for ((i = 1; i < n; i++)); do INERT="$INERT$i "; done;;
    git)
      case "${CMD_ARGS[1]:-}:${CMD_ARGS[2]:-}" in
        commit:*) vl=CcFmStu;; tag:*) vl=Fmnu;; merge:*) vl=FmSsX;;
        notes:add|notes:append) vl=CcFm; i=3;; stash:push|stash:save) vl=m; i=3;;
        *) return 0;;
      esac
      for ((; i < n; i++)); do
        a="${CMD_ARGS[i]}"
        case "$a" in
          --) break;;
          --message=*) INERT="$INERT$i ";;
          --message) i=$((i + 1)); INERT="$INERT$i ";;
          -[!-]*) shell_opt_split "$a" "$vl"; [ "$SW_VOPT" = m ] || continue
                  [ -n "$SW_VAL" ] || i=$((i + 1)); INERT="$INERT$i ";;
        esac
      done;;
  esac
  return 0
}
is_inert() { [[ "$INERT" == *" $1 "* ]]; }

ARMED=0 GLOB_MODE=0
# scan_command — first pass: deny a command that turns extglob on (shopt -s, `-O` anywhere as in `find -exec bash -O`,
# BASHOPTS=; a name that is not literal counts), note dotglob / nocaseglob / GLOBIGNORE=, and arm the line on a mention.
scan_command() {
  local a i prev="" on=0 opts=":"
  in_time
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"} ${CMD_ARGS[@]+"${CMD_ARGS[@]}"}; do
    case "${CMD_ARGS[0]:-}:$a" in
      *:BASHOPTS=*) opts="$opts${a#*=}:";;
      *:GLOBIGNORE=*) opts="${opts}GLOBIGNORE:";;
      shopt:-*s*) on=1;;
      shopt:[!-]*) [ "$on" = 0 ] || opts="$opts$a:";;
      *) [ "$prev" != -O ] || opts="$opts$a:";;
    esac
    prev="$a"
  done
  case "$opts" in
    *:extglob:*|*[\$\`*?[]*) deny_state "turns on extglob, whose patterns the gate cannot read, so $STATE_DIR/ may hide in one" "${CMD_ASSIGN[*]+${CMD_ASSIGN[*]} }${CMD_ARGS[*]-}";;
    *:dotglob:*|*:nocaseglob:*|*:GLOBIGNORE:*) GLOB_MODE=1;;
  esac
  [ "$ARMED" = 0 ] || return 0
  mark_inert
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"} ${CMD_WRITES[@]+"${CMD_WRITES[@]}"} ${CMD_PATH:+"$CMD_PATH"} ${CMD_CHDIR:+"$CMD_CHDIR"}; do
    refs_state "$a" && ARMED=1
  done
  for ((i = 0; i < ${#CMD_ARGS[@]}; i++)); do
    is_inert "$i" || ! refs_state "${CMD_ARGS[i]}" || ARMED=1
  done
  return 0
}
shell_each_command scan_command
[ "$GLOB_MODE" = 0 ] || case "${SW[*]-}" in *[*?[]*) deny_state "changes how globs match while holding one, so $STATE_DIR/ may hide in it" "$COMMAND";; esac
[ "$ARMED" = 1 ] || exit 0

# reader_ok — 0 when CMD_ARGS is a read-only command.
reader_ok() {
  local cmd="${CMD_ARGS[0]}" i a sub=""
  [ -z "$CMD_PATH" ] || return 1
  case "$cmd" in
    cat|head|tail|grep|jq|ls|stat|wc|diff|cmp|test|'['|'[['|md5|md5sum|shasum|sha*sum|echo|printf) return 0;;
    less|rg|file|find) ;;
    git) sub="${CMD_ARGS[1]:-}"; case "$sub" in diff|log|show|status|ls-files|blame) ;; *) return 1;; esac;;
    *) return 1;;
  esac
  for ((i = 1; i < ${#CMD_ARGS[@]}; i++)); do
    a="${CMD_ARGS[i]}"
    case "$cmd:$a" in
      find:-delete|find:-exec|find:-execdir|find:-ok|find:-okdir|find:-fprint*|find:-fls) return 1;;
      rg:--pre*|rg:--hostname-bin*|less:--log-file*|less:--LOG-FILE*|less:-[oO]*|less:-[!-]*[oO]*) return 1;;
      file:--compile*|file:-C*|file:-[!-]*C*) return 1;;
    esac
    [ "$cmd" != git ] || ! shell_git_exec_option "$a" || return 1
  done
  return 0
}

# copy_option <option> — classifies one cp / install / rsync option word: sets COPT to none (consumes nothing or
# its value) or bad (unknown: the copy cannot be judged), and TDIR_SET / TDIR for -t.
copy_option() {
  local o="$1" name noval val longs longval
  COPT=bad
  case "${CMD_ARGS[0]}" in
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
  shell_opt_split "$o" "$val"
  case "$SW_FLAGS" in *[!$noval]*) return 0;; esac
  if [ -n "$SW_VOPT" ]; then
    [ -n "$SW_VAL" ] || { CI=$((CI + 1)); SW_VAL="${CMD_ARGS[CI]:-}"; }
    if [ "$SW_VOPT" = t ]; then TDIR_SET=1; TDIR="$SW_VAL"; elif refs_state "$SW_VAL"; then return 0; fi
  fi
  COPT=none
}

# cp_source_only — 0 when <stateDir> can only be a source of the cp / install / rsync in CMD_ARGS.
cp_source_only() {
  local ops=() target a
  TDIR=""; TDIR_SET=0; CI=1
  [ "$CMD_XARGS" = 0 ] && [ -z "$CMD_PATH" ] || return 1
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

CD_MOVED=0 IN_STATE=0
# cd_into_state — 0 when the cd / pushd / popd in CMD_ARGS may leave the shell inside <stateDir>: popd, no operand
# ($HOME, or pushd's swap), more than one, an unjudged one, or any after HOME / CDPATH / OLDPWD was assigned.
cd_into_state() {
  local i a operands=0
  [ "$CD_MOVED" = 0 ] && [ "${CMD_ARGS[0]}" != popd ] || return 0
  for ((i = 1; i < ${#CMD_ARGS[@]}; i++)); do
    a="${CMD_ARGS[i]}"
    case "$a" in -?*) continue;; esac
    operands=$((operands + 1))
    dir_unjudged "$a" && return 0
  done
  [ "$operands" != 1 ]
}

judge_command() {
  local cmd="${CMD_ARGS[0]:-}" n=${#CMD_ARGS[@]} frag="${CMD_ARGS[*]-}" a t touches=0 inside=$IN_STATE
  in_time
  [ "$CMD_WRAP_BAD" = 0 ] || deny_state "runs behind a wrapper option the gate cannot read while naming $STATE_DIR/" "${frag:-$COMMAND}"
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do
    refs_state "$t" && deny_state "redirects output into $STATE_DIR/" "$t"
    shell_word_literal "$t" || deny_state "redirects output to a target it cannot resolve ($t) while naming $STATE_DIR/" "$t"
    [ "$IN_STATE" = 0 ] || case "$t" in /*) ;; *) deny_state "redirects output from inside $STATE_DIR/" "$t";; esac
  done
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"} ${CMD_ARGS[@]+"${CMD_ARGS[@]}"}; do
    case "$a" in HOME=*|CDPATH=*|OLDPWD=*) CD_MOVED=1;; esac
  done
  [ -n "$cmd" ] || return 0
  case "$cmd" in '['|'[[') ;; *) shell_word_literal "$cmd" || deny_state "runs a command word it cannot resolve ($cmd) while naming $STATE_DIR/" "$frag";; esac
  case "$cmd" in
    cd|pushd|popd) ! cd_into_state || IN_STATE=1; return 0;;
  esac
  # env -C, sudo -D and a package manager's directory move only this command; its redirects are the caller's.
  [ -z "$CMD_CHDIR" ] || ! dir_unjudged "$CMD_CHDIR" || inside=1
  [ "$inside" = 0 ] || touches=1
  [ -z "$CMD_PATH" ] || touches=1
  mark_inert
  for ((t = 1; t < n; t++)); do
    is_inert "$t" && continue
    a="${CMD_ARGS[t]}"; refs_state "$a" && touches=1; shell_word_literal "$a" || touches=1
  done
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"}; do refs_state "$a" && touches=1; done
  if [ "$CMD_XARGS" = 1 ] && ! reader_ok; then
    deny_state "runs $cmd on operands from stdin while naming $STATE_DIR/" "$frag"
  fi
  [ "$touches" = 1 ] || return 0
  if reader_ok; then
    for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"}; do
      case "$a" in LC_*|LANG=*) ;; *) deny_state "runs $cmd on $STATE_DIR/ with an environment assignment ($a)" "$frag";; esac
    done
    return 0
  fi
  case "$cmd" in cp|install|rsync) [ "$inside" = 0 ] && cp_source_only && return 0;; esac
  deny_state "runs $cmd on $STATE_DIR/, which only readers and copying out of it may do" "$frag"
}
shell_each_command judge_command
exit 0
