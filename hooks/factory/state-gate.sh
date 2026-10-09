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
# quoted text is an argument, never a redirect. A line is ARMED when a command on it mentions <stateDir>: as a path
# component, literal or as a glob that could match it (`.fact*`, `.f[a]ctory`; a leading dot needs a literal dot), case
# folded, in a whole word, an `=` value or a token cut at spaces, quotes and `;|&<>()` (`sh -c 'cp x .factory/y'`, an
# env value). Not mentions: a shell's `-c` script and eval's arguments (judged as commands of their own), and the message
# of git commit|tag|merge|notes add|append|stash push|save. `user.factory.ts` does not arm it. On an armed line
# unrecognised = unsafe:
#   * a segment that touches <stateDir> (names it, holds a non-literal word, or runs after a `cd` that may have entered
#     it) passes only when its command is
#       - a reader: cat head tail less grep rg jq ls stat wc diff cmp test [ [[ file md5 md5sum sha*sum shasum echo
#         printf; find without -delete -exec -execdir -ok -okdir -fprint* -fls; git diff|log|show|status|ls-files|blame
#         with no global option and no exec option; none with an assignment other than LC_* / LANG; or
#       - cp / install / rsync with <stateDir> provably a SOURCE: every option known and before the operands, the
#         target (last operand or -t directory) literal and outside <stateDir>;
#     everything else is denied, whatever it is;
#   * a redirect target (> >> >| &> n>) naming <stateDir>, or not literal, is denied;
#   * `cd` / `pushd` / `popd` the gate cannot resolve exactly (a state or non-literal target, several operands, `-`,
#     `~-`, a CDPATH naming it) makes every later segment of the line count as inside it: only readers pass, and a
#     redirect must go to an absolute path outside it;
#   * a wrapper option the splitter does not know, or a command word that is not literal, is denied;
#   * xargs feeding anything but a reader is denied;
#   * a line too long to split is denied when it names <stateDir>;
#   * a line that sets extglob, or dotglob / nocaseglob / GLOBIGNORE beside a glob, is denied whether armed or not.
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

# glob_names_state <word> — 0 when a window of the word's path components matches <stateDir>'s components under
# bash pattern matching. With dotglob off, a pattern component matches a dot name only if it starts with a literal dot.
glob_names_state() {
  local c i j ok p
  IFS=/ read -r -a c <<< "${1//$'\n'//}"
  for ((i = 0; i + ${#STATE_COMP[@]} <= ${#c[@]}; i++)); do
    ok=1
    for ((j = 0; j < ${#STATE_COMP[@]}; j++)); do
      p="${c[i+j]}"
      case "${STATE_COMP[j]}" in .*) case "$p" in .*) ;; *) ok=0; break;; esac;; esac
      [[ "${STATE_COMP[j]}" == $p ]] || { ok=0; break; }
    done
    [ "$ok" = 1 ] && return 0
  done
  return 1
}
# state_word <word> — 0 when the word, its `=` values or a path-like token of it names <stateDir>. Tokens are cut at
# characters a path cannot hold, so a command string (`sh -c 'rm .fact*/x'`, `rsync -e …`, LESSOPEN) is read too.
state_word() {
  local w="$1" cands t o
  case "$w" in *[*?[]*) ;; *) [[ "$w" == *"$STATE_DIR"* ]] || return 1;; esac
  w="${w//[\'\"\;\|\&\<\>\(\)\`=,@\\ $'\t'$'\n']/ }"
  read -r -a cands <<< "$w"
  for t in "$1" "${1#*=}" "${1##*=}" ${cands[@]+"${cands[@]}"}; do
    o=""
    case "$t" in -?*) o="${t#-}"; while [[ "$o" == [A-Za-z]* ]]; do o="${o#?}"; done;; esac
    for t in "$t" "$o"; do
      [[ "$t" == *"$STATE_DIR"* && "$t" =~ $STATE_TOKEN_RE ]] && return 0
      case "$t" in *[*?[]*) glob_names_state "$t" && return 0;; esac
    done
  done
  return 1
}
# refs_state <word> — state_word, case folded (APFS ignores case).
refs_state() {
  local r=1
  shopt -s nocasematch
  state_word "$1" && r=0
  shopt -u nocasematch
  return $r
}
deny_state() { local f="${2//$'\n'/ }"; emit_deny "$ID" "Bash command $1 (\`${f:0:80}\`) — its files are trust anchors written only by the project's own tools."; }

shell_words "$COMMAND"
if [ "$SW_OVERFLOW" = 1 ]; then
  shopt -s nocasematch
  [[ "$COMMAND" == *"$STATE_DIR"* ]] && deny_state "is too long to verify and names $STATE_DIR/" "$COMMAND"
  exit 0
fi
joined="${SW[*]-}"
case "$joined" in
  *extglob*) deny_state "turns on extglob, whose patterns the gate cannot read, so $STATE_DIR/ may hide in one" "$COMMAND";;
  *[*?[]*) case "$joined" in *dotglob*|*nocaseglob*|*GLOBIGNORE*) deny_state "changes how globs match while holding one, so $STATE_DIR/ may hide in it" "$COMMAND";; esac;;
esac

# mark_inert — INERT lists the indices of CMD_ARGS that are text another command judges or that no path can come from:
# the -c script of a shell and the arguments of eval (split and judged as commands of their own), and the message of
# git commit / tag / merge / notes add|append / stash push|save. -F and --file stay: their value is a path.
mark_inert() {
  local cmd="${CMD_ARGS[0]:-}" n=${#CMD_ARGS[@]} i=2 a
  INERT=" "
  case "$cmd" in
    sh|bash|zsh|dash|ksh) shell_script_arg; [ "$SW_SCRIPT_C" = 0 ] || INERT="$INERT$SW_SCRIPT ";;
    eval) for ((i = 1; i < n; i++)); do INERT="$INERT$i "; done;;
    git)
      case "${CMD_ARGS[1]:-}" in
        commit|tag|merge) ;;
        notes|stash) case "${CMD_ARGS[2]:-}" in add|append|push|save) i=3;; *) return 0;; esac;;
        *) return 0;;
      esac
      for ((; i < n; i++)); do
        a="${CMD_ARGS[i]}"
        case "$a" in
          --message=*|-m?*) INERT="$INERT$i ";;
          --message|-m|-[!-]*m) i=$((i + 1)); INERT="$INERT$i ";;
        esac
      done;;
  esac
  return 0
}
is_inert() { [[ "$INERT" == *" $1 "* ]]; }

ARMED=0
arm_command() {
  local a i
  [ "$ARMED" = 0 ] || return 0
  mark_inert
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"} ${CMD_WRITES[@]+"${CMD_WRITES[@]}"} ${CMD_PATH:+"$CMD_PATH"}; do
    refs_state "$a" && ARMED=1
  done
  for ((i = 0; i < ${#CMD_ARGS[@]}; i++)); do
    is_inert "$i" || ! refs_state "${CMD_ARGS[i]}" || ARMED=1
  done
  return 0
}
shell_each_command arm_command
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

CDPATH_BAD=0
IN_STATE=0
# cd_into_state — 0 when the cd / pushd / popd in CMD_ARGS may leave the shell inside <stateDir>.
cd_into_state() {
  local i a operands=0
  [ "$CDPATH_BAD" = 0 ] || return 0
  [ "${CMD_ARGS[0]}" != popd ] || return 0
  for ((i = 1; i < ${#CMD_ARGS[@]}; i++)); do
    a="${CMD_ARGS[i]}"
    case "$a" in --) continue;; -?*) continue;; esac
    operands=$((operands + 1))
    refs_state "$a" && return 0
    shell_word_literal "$a" || return 0
    case "$a" in -|\~-*|\~+*|\~[0-9]*|+*) return 0;; esac
  done
  [ "$operands" -le 1 ] || return 0
  [ "$operands" -eq 1 ] || [ "${CMD_ARGS[0]}" != pushd ] || return 0
  return 1
}

judge_command() {
  local cmd="${CMD_ARGS[0]:-}" n=${#CMD_ARGS[@]} frag="${CMD_ARGS[*]-}" a t touches=0
  [ "$CMD_WRAP_BAD" = 0 ] || deny_state "runs behind a wrapper option the gate cannot read while naming $STATE_DIR/" "${frag:-$COMMAND}"
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do
    refs_state "$t" && deny_state "redirects output into $STATE_DIR/" "$t"
    shell_word_literal "$t" || deny_state "redirects output to a target it cannot resolve ($t) while naming $STATE_DIR/" "$t"
    [ "$IN_STATE" = 0 ] || case "$t" in /*) ;; *) deny_state "redirects output from inside $STATE_DIR/" "$t";; esac
  done
  for a in ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"} ${CMD_ARGS[@]+"${CMD_ARGS[@]}"}; do
    case "$a" in CDPATH=*) { refs_state "$a" || ! shell_word_literal "$a"; } && CDPATH_BAD=1;; esac
  done
  [ -n "$cmd" ] || return 0
  case "$cmd" in '['|'[[') ;; *) shell_word_literal "$cmd" || deny_state "runs a command word it cannot resolve ($cmd) while naming $STATE_DIR/" "$frag";; esac
  case "$cmd" in
    cd|pushd|popd) ! cd_into_state || IN_STATE=1; return 0;;
  esac
  [ "$IN_STATE" = 0 ] || touches=1
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
  case "$cmd" in cp|install|rsync) cp_source_only && return 0;; esac
  deny_state "runs $cmd on $STATE_DIR/, which only readers and copying out of it may do" "$frag"
}
shell_each_command judge_command
exit 0
