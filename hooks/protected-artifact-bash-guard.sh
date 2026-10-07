#!/bin/bash
# protected-artifact-bash-guard.sh — denies Bash commands that mutate the
#                                    pipeline-state artifacts out of band.
#
# Hook    : PreToolUse:Bash
# Mode    : DENY
# State   : none (stateless pattern check)
# Env     : none
#
# Why
# ---
# Every Write|Edit gate (ledger write-gate, sentinel gate, integrity chain)
# inspects ONLY the Write/Edit tools. A `cat > onboarding-status.json` from
# Bash sidesteps them all.
#
# Rule (fail closed): a command line that names a protected path, or a
# directory one lives in, is denied unless every command on it, as the shell
# would split it (lib/shell-words.sh), is provably safe:
#   - a read-only command (READERS, git log/show/diff/status/blame, sed and
#     yq without -i, find without an action) whose write redirections all
#     resolve to unprotected paths, or
#   - a recognised writer (tee, rm, unlink, rmdir, truncate, shred, sponge,
#     mv, cp, install, ln, dd, sed -i, yq -i, touch, mkdir) whose write
#     targets all resolve to unprotected paths outside every protected
#     directory (mkdir: outside every protected entry; it creates, never
#     alters, so `mkdir -p .claude` for the sanctioned early stop passes).
# Anything else on such a line (interpreters, awk, eval, sh -c, xargs,
# find -delete/-exec/-fprint, command substitution, a target behind a
# variable or glob, any other program) denies: the guard cannot prove it
# does not write. Nor is a command safe when something on the line can
# change what it runs: a command word outside the system bin dirs, an
# assignment or `env` before it, git's -c/--config-env/--exec-path or the
# options that name a program (--upload-pack, --ext-diff, --textconv, -O),
# `rg --pre`, `file -C`, `yq -s`, a sed script with a w/W/e command or flag,
# or an ln whose source is protected. Paths are normalised
# (lib/protected-paths.sh) first, so quoting, escapes, //, /./, .., ~ and
# case do not change the verdict; unquoted {a,b} is expanded as bash would.
# A line the splitter cannot finish (over 32 KB, 16 nested shells, 64
# brace words) denies as unverifiable; one with more than 40 paths to
# normalise counts as naming protected state.
#
# Independently of naming, a write target that is a protected path, the
# directory one lives in, or ANY ancestor of one (`~`, `/`, `.`, `..`, `tests`,
# resolved against the call's cwd) denies, for every writer whose targets the
# guard reads: rm, mv, cp/install/ln into, tee, truncate, dd of=, sed/yq -i,
# chmod/chown/chgrp/touch, tar -C, rsync, unzip -d, curl -o, wget -O. A copy,
# move or link INTO a directory writes <dir>/<basename src>; that path is
# judged, so `cp x .` passes and `cp -r somedir/.claude ~` does not.
#
# git commit, add, status, log, show, diff, blame, rev-parse, ls-files, grep,
# fetch, and branch/tag listing write only under .git and count as safe.
#
# The tamper-evident ledger chain (ledger-integrity-chain.sh) DETECTS
# whatever this guard fails to PREVENT. The two ship as a pair.
#
# settings.local.json: coverage is a deliberate superset of spec §A3's
# settings.json — local overrides carry the same mutation risk.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/harness-hooks.md

set -uo pipefail

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/achilles-protocol/references/harness-hooks.md §Bash\n  skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\""


# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_jq_init fatal

hook_lib hook-emit.sh protected-paths.sh shell-words.sh

hook_read_input

hook_lib achilles-activation.sh
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0
CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0
CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null || echo "")
[ -n "$CWD" ] || CWD="$PWD"
LOCATIONS=""  # protected_locations "$CWD", computed at the first write target

# No pagers: less and more run $LESSOPEN.
READERS=' cat head tail grep egrep fgrep rg ls stat wc diff cmp file sha256sum shasum md5 md5sum jq echo printf test [ '
NAMED=""    # protected entries and directories the line names, one per line
HITS=""     # protected entries or directories a write reaches
UNSAFE=""   # why a command on the line cannot be proved safe
OVERFLOW="" # 1 when the line could not be split whole

# names <word> — record the protected entry or directory <word> (or its --opt= value) names.
names() {
  local w e
  for w in "$1" "${1#*=}"; do
    e=$(protected_bash_match "$w") || e=$(protected_parent_match "$w") || continue
    NAMED="$NAMED$e"$'\n'; return 0
  done
}

# target <word> — a write target: unresolvable (variable, substitution, glob) is unsafe;
# a protected entry or a protected directory is a hit.
target() {
  local e
  case "$1" in
    '~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) ;;
    *'$'*|*'`'*) UNSAFE="$UNSAFE${CMD_ARGS[0]:-redirect}: write target $1 does not resolve"$'\n'; return 0 ;;
    *'*'*|*'?'*|*'['*) UNSAFE="$UNSAFE${CMD_ARGS[0]:-redirect}: write target $1 is a glob"$'\n' ;;
  esac
  [ -n "$LOCATIONS" ] || LOCATIONS=$(protected_locations "$CWD")
  e=$(protected_bash_match "$1") || e=$(protected_parent_match "$1") ||
    e=$(protected_ancestor_match "$1" "$CWD" "$LOCATIONS") || return 0
  HITS="$HITS$e"$'\n'
}

# optval <short> <long> — target every value of -<short> X, -<short>X, --<long> X, --<long>=X.
optval() {
  local a last=""
  for a in "${CMD_ARGS[@]:1}"; do
    case "$last" in "-$1"|"--$2") target "$a" ;; esac
    case "$a" in "--$2="*) target "${a#*=}" ;; "-$1"?*) target "${a#-$1}" ;; esac
    last="$a"
  done
}

# operands [letters] — OPERANDS: the arguments after the command word that are not options;
# -<letter> options whose value is the next word are skipped with it.
operands() {
  local a opts=1 skip=0
  OPERANDS=()
  for a in "${CMD_ARGS[@]:1}"; do
    if [ "$opts" = 1 ]; then
      [ "$skip" = 0 ] || { skip=0; continue; }
      case "$a" in --) opts=0; continue ;; -?*) [ -z "${1:-}" ] || case "$a" in -[$1]) skip=1 ;; esac; continue ;; esac
    fi
    OPERANDS+=("$a")
  done
}

# sed / yq: OPERANDS gets the files an in-place edit writes (empty without -i); SCRIPTS the
# expressions. 1 when a script cannot be read (-f, --from-file).
editor_parse() {
  local a k=1 inplace=0 script=0
  OPERANDS=(); SCRIPTS=()
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      -f|--file|--from-file|-f*|--file=*|--from-file=*) return 1 ;;
      --in-place*|--inplace) inplace=1 ;;
      -e|--expression) script=1; SCRIPTS+=("${CMD_ARGS[k]:-}"); k=$((k + 1)) ;;
      --expression=*) script=1; SCRIPTS+=("${a#*=}") ;;
      --) ;;
      -[!-]*) case "$a" in -*i*) inplace=1 ;; esac
              case "$a" in -*e) script=1; SCRIPTS+=("${CMD_ARGS[k]:-}"); k=$((k + 1)) ;; esac ;;
      -*) ;;
      '') ;;
      *) if [ "$script" = 0 ]; then script=1; SCRIPTS+=("$a"); else OPERANDS+=("$a"); fi ;;
    esac
  done
  [ "$inplace" = 1 ] || OPERANDS=()
  return 0
}

# is_dir <path> — <path>, against CWD, names an existing directory (or says so with a trailing /).
is_dir() {
  local p="$1"
  case "$p" in */|.|..|'~') return 0 ;; '~/'*) p="$HOME/${p#\~/}" ;; /*) ;; *) p="$CWD/$p" ;; esac
  [ -d "$p" ]
}

# cp / mv / install / ln. Into a directory, each source lands at <dir>/<basename>, and that path is
# judged rather than the directory; a source ending in / copies its contents, each child judged.
# A directory that holds protected entries is itself a protected destination. mv also removes its
# sources; ln makes its sources reachable under another name, so they are judged too. A recursive
# source that cannot be resolved denies when the directory is above protected state.
copy_targets() {
  local a last="" dir="" notdir=0 recursive=0 dest src p
  local srcs=()
  [ "${CMD_ARGS[0]}" = mv ] && recursive=1
  for a in "${CMD_ARGS[@]:1}"; do
    case "$last" in -t|--target-directory) dir="$a"; last=""; continue ;; esac
    last="$a"
    case "$a" in
      --target-directory=*) dir="${a#*=}" ;;
      -T|--no-target-directory) notdir=1 ;;
      --recursive|--archive) recursive=1 ;;
      -t|--target-directory|--*) ;;
      -[!-]*) case "$a" in *[rRa]*) recursive=1 ;; esac ;;
      *) srcs+=("$a") ;;
    esac
  done
  if [ -z "$dir" ]; then
    [ "${#srcs[@]}" -gt 0 ] || return 0
    dest="${srcs[${#srcs[@]}-1]}"
    srcs=("${srcs[@]:0:${#srcs[@]}-1}")
    if [ "$notdir" = 1 ] || { [ "${#srcs[@]}" -le 1 ] && ! is_dir "$dest"; }; then
      target "$dest"; dir=""
    else
      # Several sources need a directory; what the program does with anything else is not known.
      is_dir "$dest" || UNSAFE="$UNSAFE${CMD_ARGS[0]}: destination $dest is not a directory"$'\n'
      dir="${dest%/}"; [ -n "$dir" ] || dir=/
    fi
  fi
  case "${CMD_ARGS[0]}" in mv|ln) for src in ${srcs[@]+"${srcs[@]}"}; do target "$src"; done ;; esac
  [ -n "$dir" ] || return 0
  if e=$(protected_parent_match "$dir"); then HITS="$HITS$e"$'\n'; return 0; fi
  for src in ${srcs[@]+"${srcs[@]}"}; do
    if [ "$recursive" = 1 ]; then
      case "$src" in
        *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*/)
          [ -n "$LOCATIONS" ] || LOCATIONS=$(protected_locations "$CWD")
          protected_ancestor_match "$dir" "$CWD" "$LOCATIONS" >/dev/null || continue
          case "$src" in
            */) p="$src"; case "$p" in '~/'*) p="$HOME/${p#\~/}" ;; /*) ;; *) p="$CWD/$p" ;; esac
                if [ -d "$p" ]; then
                  for p in "$p"* "$p".[!.]*; do [ -e "$p" ] && target "$dir/${p##*/}"; done
                  continue
                fi ;;
          esac
          HITS="${HITS}source tree of $src under $dir"$'\n'; continue ;;
      esac
    fi
    src="${src%/}"; target "$dir/${src##*/}"
  done
}

judge_command() {
  local cmd="${CMD_ARGS[0]:-}" a t e sub="" pos=0 skip=0
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do target "$t"; done
  [ -n "$cmd" ] || return 0
  [ "$CMD_XARGS" = 1 ] && { UNSAFE="${UNSAFE}xargs $cmd: operands arrive on stdin"$'\n'; return 0; }
  for a in "${CMD_ARGS[@]}"; do
    case "$a" in *'$('*|*'`'*) UNSAFE="$UNSAFE$cmd: command substitution"$'\n'; return 0 ;; esac
  done
  # The allowlist names programs in the system bin dirs, run with the session's environment.
  [ -z "$CMD_PATH" ] || UNSAFE="$UNSAFE$cmd: run from $CMD_PATH"$'\n'
  [ "$CMD_ENV" = 0 ] || UNSAFE="$UNSAFE$cmd: environment set on the command line"$'\n'
  case "$cmd" in
    rg) for a in "${CMD_ARGS[@]:1}"; do case "$a" in --pre|--pre=*|--pre-glob|--pre-glob=*) UNSAFE="${UNSAFE}rg $a"$'\n'; return 0 ;; esac; done ;;
    file) for a in "${CMD_ARGS[@]:1}"; do case "$a" in --compile|-C*|-[!-]*C*) UNSAFE="${UNSAFE}file -C writes a magic file"$'\n'; return 0 ;; esac; done ;;
  esac
  case "$READERS" in *" $cmd "*) return 0 ;; esac
  case "$cmd" in
    git)
      for a in "${CMD_ARGS[@]:1}"; do
        [ "$skip" = 0 ] || { skip=0; continue; }
        case "$a" in
          --output*|--upload-pack*|--receive-pack*|--ext-diff|--textconv|-O*|--open-files-in-pager*) UNSAFE="${UNSAFE}git $a"$'\n'; return 0 ;;
        esac
        if [ -z "$sub" ]; then
          case "$a" in
            -c|--config-env*|--exec-path*) UNSAFE="${UNSAFE}git $a"$'\n'; return 0 ;;
            -C|--git-dir|--work-tree) skip=1; continue ;;
            -*) continue ;;
          esac
          sub="$a"
        else
          case "$a" in -*) continue ;; esac
          pos=$((pos + 1))
        fi
      done
      case "$sub" in
        commit|add|status|log|show|diff|blame|rev-parse|ls-files|grep|fetch) ;;
        branch|tag) case " ${CMD_ARGS[*]} " in *" -l "*|*" --list "*) ;; *) [ "$pos" = 0 ] || UNSAFE="${UNSAFE}git $sub creating"$'\n' ;; esac ;;
        *) UNSAFE="${UNSAFE}git $sub"$'\n' ;;
      esac ;;
    sed|yq)
      editor_parse || { UNSAFE="$UNSAFE$cmd: script read from a file"$'\n'; return 0; }
      if [ "$cmd" = sed ]; then
        # w/W write a file and e runs a command, as commands or as s/// flags, glued or not.
        for a in ${SCRIPTS[@]+"${SCRIPTS[@]}"}; do
          printf '%s' "$a" | grep -qE '(^|[;{}/,!$~+[:space:]])[0-9gpiImM]*[wWe]' &&
            { UNSAFE="${UNSAFE}sed: w/e command in $a"$'\n'; return 0; }
        done
      else
        for a in "${CMD_ARGS[@]:1}"; do case "$a" in -s|-s*|--split-exp*) UNSAFE="${UNSAFE}yq $a writes files"$'\n'; return 0 ;; esac; done
      fi
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    find)
      for a in "${CMD_ARGS[@]}"; do
        case "$a" in -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) UNSAFE="${UNSAFE}find $a"$'\n'; return 0 ;; esac
      done ;;
    tee|rm|unlink|rmdir|truncate|shred|sponge)
      operands; for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    touch) operands rdt; for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    mkdir)
      # Creates only the directory named: a protected entry or a path inside one is a hit; the
      # directories above (.claude, tests/e2e/docs) are not.
      operands m
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do
        case "$t" in
          *'$'*|*'`'*|*'*'*|*'?'*|*'['*) UNSAFE="${UNSAFE}mkdir: $t does not resolve"$'\n' ;;
          *) e=$(protected_bash_match "$t") && HITS="$HITS$e"$'\n' ;;
        esac
      done ;;
    cp|mv|install|ln) copy_targets ;;
    dd) for a in "${CMD_ARGS[@]}"; do case "$a" in of=*) target "${a#of=}" ;; esac; done ;;
    # Writers the guard reads targets from but cannot prove safe: what they write is not only those.
    chmod|chown|chgrp)
      operands
      [ "${#OPERANDS[@]}" = 0 ] || OPERANDS=("${OPERANDS[@]:1}")
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done
      UNSAFE="$UNSAFE$cmd"$'\n' ;;
    rsync) operands; [ "${#OPERANDS[@]}" -gt 0 ] && target "${OPERANDS[${#OPERANDS[@]}-1]}"; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    tar) optval C directory; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    unzip) optval d d; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    curl) optval o output; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    wget) optval O output-document; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    *) UNSAFE="$UNSAFE$cmd"$'\n' ;;
  esac
  return 0
}

shell_words "$CMD"
if [ "$SW_OVERFLOW" = 1 ]; then
  # Not split whole, so nothing on it is proved; the mention still keys the .claude/achilles rule.
  OVERFLOW=1
  e=$(protected_bash_mention "$CMD") && NAMED="$NAMED$e"$'\n'
else
  # The dequoted words, case-folded, catch every plain spelling at once. Words a substring test
  # can miss (//, /./, .., or a protected directory itself) are normalised one by one, a few
  # forks each; past 40 of them the line counts as unprovable.
  e=$(protected_bash_mention "${SW[*]}") && NAMED="$NAMED$e"$'\n'
  n=0
  for w in "${SW[@]}"; do
    case "$w" in
      *//*|*/./*|*..*|*[cC][lL][aA][uU][dD][eE]|*[cC][lL][aA][uU][dD][eE]/|*[dD][oO][cC][sS]|*[dD][oO][cC][sS]/)
        n=$((n + 1)); [ "$n" -le 40 ] && names "$w" ;;
    esac
  done
  [ "$n" -le 40 ] || NAMED="${NAMED}(over 40 paths: not every one was checked)"$'\n'
  shell_each_command judge_command
fi
# A protected write target or an unsplittable line denies; anything unprovable denies only on a
# line naming protected state.
[ -n "$HITS" ] || [ -n "$OVERFLOW" ] || { [ -n "$NAMED" ] && [ -n "$UNSAFE" ]; } || exit 0

# Session-scope gate: this guard applies only to achilles-activated
# sessions (lib/achilles-activation.sh) — EXCEPT for lines that name the
# session-activation state dir itself (.claude/achilles). That dir is the
# root of trust for every gate in the suite, so its protection is
# unconditional: an inactive session must not be able to strip another
# session's activation marker, and an active session must not deactivate
# itself by deleting its own.
case "$NAMED$HITS" in *.claude/achilles*) ;; *) achilles_require_active "$INPUT" ;; esac

if [ -n "$HITS" ]; then
  WHY="Writes into: $(printf '%s' "$HITS" | sort -u | tr '\n' ' ')"
elif [ -n "$OVERFLOW" ]; then
  WHY="Command too long to verify (over 32 KB, 16 nested shells or 64 brace expansions); split it."
else
  WHY="Cannot prove this command does not write: $(printf '%s' "$NAMED" | sort -u | tr '\n' ' ')
Because of: $(printf '%s' "$UNSAFE" | sort -u | tr '\n' ';')"
fi

REASON="[BLOCKED] This Bash command would mutate (or could mutate) a protected pipeline-state artifact out of band.

Command: ${CMD}
${WHY}

Protected artifacts (ledger, journey map, cycle/coverage state, approver
registry, findings ledger, integrity sidecar, the hook installation) may
only change through the Write/Edit tools — that is where the harness
gates (schema validation, state-machine checks, separation-of-duties,
integrity chain) live. A shell write would bypass them all.

Fix:
  - To change the artifact: use the Write or Edit tool on the file.
  - To read it: use a read-only command (cat, grep, jq, head, git diff …)
    on a line without interpreters, awk, eval or other programs.
  - Deleting a pipeline-state artifact is an operator decision: ask the
    user to remove it in their own terminal if a reset is intended.

$(no_skip_messaging_block)"

"$JQ" -n --arg r "$REASON${HOOK_REFS}$(achilles_scope_notice)" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
