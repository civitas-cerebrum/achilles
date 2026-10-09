#!/bin/bash
# protected-artifact-bash-guard.sh — denies Bash commands that write the pipeline-state artifacts out of
# band. The Write|Edit gates (ledger write-gate, sentinel gate, integrity chain) never see a
# `cat > onboarding-status.json`.
#
# Hook: PreToolUse:Bash   Mode: DENY   State: none
#
# Rule (fail closed), per command as lib/shell-words.sh splits the line:
#   - A write target that is a protected path, the directory one lives in, or any ancestor of one
#     (against the call's cwd, under a literal env -C / git -C directory) denies. Targets: redirections;
#     the operands of tee rm unlink rmdir truncate shred sponge touch chmod chown chgrp, sed -i, yq -i;
#     dd of=; cp mv install ln destinations (mv and ln sources too); git checkout restore reset clean rm
#     mv switch stash operands, or the work tree when there is none; find -delete start paths.
#     mkdir hits only a protected entry, so `mkdir -p .claude` for the sanctioned early stop passes.
#   - On a line that names protected state, any other command denies unless it only reads
#     (shell_is_reader, git reads, sed and yq without -i): the guard cannot prove it does not write.
#     A write target holding $, a backtick or a glob is unproved; so is a command substitution.
#   - A line too long to split denies.
# Obfuscated or exotic shell forms are out of scope (known-limits.md KL-15).
#
# ledger-integrity-chain.sh detects what this guard fails to prevent; the two ship as a pair.
# settings.local.json is covered as well as settings.json: local overrides carry the same risk.
#
# Canonical reference: skills/achilles-protocol/references/harness-hooks.md
# Size: one target rule and a judge per writer family (git, sed/yq, find, cp/mv/install/ln, the rest).

set -uo pipefail

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

NAMED=""    # protected entries and directories the line names, one per line
HITS=""     # protected entries or directories a write reaches
UNSAFE=""   # why a command on the line cannot be proved safe
OVERFLOW="" # 1 when the line could not be split whole
TGT_BASE="" # the directory relative operands of the command being judged resolve in

# unresolved <word> — 0 when <word> holds an unexpanded variable, substitution or glob.
unresolved() { case "$1" in *'$'*|*'`'*|*'*'*|*'?'*|*'['*) return 0 ;; esac; return 1; }

# names <word> — record the protected entry or directory <word> (or its --opt= value) names.
names() {
  local w e
  for w in "$1" "${1#*=}"; do
    e=$(protected_bash_match "$w") || e=$(protected_parent_match "$w") || continue
    NAMED="$NAMED$e"$'\n'; return 0
  done
}

# target <word> — a write target: one holding a variable or substitution is unsafe, a glob is unsafe
# and matched as a pattern; a protected entry, its directory or an ancestor is a hit.
target() {
  local e loc
  case "$1" in
    /*|'~'*|'$HOME'*|'${HOME}'*) ;;
    *) [ -z "$TGT_BASE" ] || set -- "$TGT_BASE/$1" ;;
  esac
  case "$1" in
    '~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) ;;
    *'$'*|*'`'*) UNSAFE="$UNSAFE${CMD_ARGS[0]:-redirect}: write target $1 does not resolve"$'\n'; return 0 ;;
    *'*'*|*'?'*|*'['*) UNSAFE="$UNSAFE${CMD_ARGS[0]:-redirect}: write target $1 is a glob"$'\n' ;;
  esac
  [ -n "$LOCATIONS" ] || LOCATIONS=$(protected_locations "$CWD")
  loc="$LOCATIONS"; [ -z "$TGT_BASE" ] || loc="$loc"$'\n'"$(base_locations)"
  e=$(protected_bash_match "$1") || e=$(protected_parent_match "$1") ||
    e=$(protected_ancestor_match "$1" "$CWD" "$loc") || return 0
  HITS="$HITS$e"$'\n'
}

# base_locations — the protected locations under TGT_BASE when protected state lives there: a literal
# env -C / git -C directory is judged by what it holds, not only by the cwd's layout.
base_locations() {
  local b d
  case "$TGT_BASE" in /*) b="$TGT_BASE" ;; '~'|'~/'*) b="$HOME${TGT_BASE#\~}" ;; *) b="$CWD/$TGT_BASE" ;; esac
  for d in "${LEDGER_ONBOARDING_REL%/*}" "${LEDGER_PERF_REL%/*}" .claude; do
    [ -e "$b/$d" ] && { protected_locations "$b"; return 0; }
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

target_operands() { local t; for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done; }

# judge_git — `git [-C DIR] [-c k=v] <sub>`: a read passes; checkout restore reset clean rm mv switch stash
# write their operands, or the work tree when there are none (and on reset --hard, checkout|switch -f, stash).
judge_git() {
  local gi=1 a sub="" whole=0 base="$CMD_CHDIR"
  while [ "$gi" -lt "${#CMD_ARGS[@]}" ] && [ -z "$sub" ]; do
    a="${CMD_ARGS[gi]}"; gi=$((gi + 1))
    case "$a" in
      -C) case "${CMD_ARGS[gi]:-}" in /*|'~'*) base="${CMD_ARGS[gi]}" ;; *) base="${base:+$base/}${CMD_ARGS[gi]:-}" ;; esac; gi=$((gi + 1)) ;;
      -c|--git-dir|--work-tree|--namespace) gi=$((gi + 1)) ;;
      -*) ;;
      *) sub="$a" ;;
    esac
  done
  case "$SHELL_GIT_READS" in *" $sub "*) return 0 ;; esac
  [ "$sub:${CMD_ARGS[gi]:-}" = stash:list ] || [ "$sub:${CMD_ARGS[gi]:-}" = stash:show ] && return 0
  UNSAFE="${UNSAFE}git $sub"$'\n'
  case "$sub" in checkout|restore|reset|clean|rm|mv|switch|stash) ;; *) return 0 ;; esac
  CMD_ARGS=("$sub" "${CMD_ARGS[@]:gi}"); operands
  # reset --hard and a forced checkout or switch overwrite the whole work tree.
  case "$sub: ${CMD_ARGS[*]:1} " in *" --hard "*|checkout:*" -f "*|checkout:*" --force "*|switch:*" -f "*|switch:*" --force "*) whole=1 ;; esac
  [ "$sub" != stash ] && [ "${#OPERANDS[@]}" -gt 0 ] || whole=1
  TGT_BASE="$base"; target_operands
  [ "$whole" = 1 ] || return 0
  # Only clean, rm, mv and restore stay inside a relative -C directory; the rest act from the top.
  case "$sub:$base" in clean:*|rm:*|mv:*|restore:*|*:/*|*:'~'*) ;; *) TGT_BASE="" ;; esac
  target .
}

# sed / yq: -i… or --in-place makes the operands after the script write targets; otherwise they read.
judge_in_place() {
  local a inplace=0 script=0 skip=0
  OPERANDS=()
  for a in "${CMD_ARGS[@]:1}"; do
    [ "$skip" = 0 ] || { skip=0; continue; }
    case "$a" in
      --in-place*|--inplace|-i*|-[!-]*i*) inplace=1 ;;
      -e|--expression) script=1; skip=1 ;;
      --expression=*) script=1 ;;
      -*|'') ;;
      *) if [ "$script" = 0 ]; then script=1; else OPERANDS+=("$a"); fi ;;
    esac
  done
  [ "$inplace" = 0 ] || target_operands
}

# is_dir <path> — <path>, against CWD, names an existing directory (or says so with a trailing /).
is_dir() {
  local p="$1"
  case "$p" in */|.|..|'~') return 0 ;; '~/'*) p="$HOME/${p#\~/}" ;; /*) ;; *) p="$CWD/$p" ;; esac
  [ -d "$p" ]
}

# cp / mv / install / ln. Into a directory each source lands at <dir>/<basename>, and that path is
# judged; a source that does not resolve could land anywhere, so the directory is judged. mv also
# removes its sources; ln makes them reachable under another name.
copy_targets() {
  local a dir="" notdir=0 skip="" dest src srcs=()
  for a in "${CMD_ARGS[@]:1}"; do
    case "$skip" in t) dir="$a"; skip=""; continue ;; v) skip=""; continue ;; esac
    case "$a" in
      --target-dir*=*) dir="${a#*=}" ;;
      --target-dir*|-t) skip=t ;;
      -T|--no-target-directory) notdir=1 ;;
      -t?*) dir="${a#-t}" ;;
      -m|-o|-g|-S) skip=v ;;
      -[!-]*t) skip=t ;;
      -[!-]*T*) notdir=1 ;;
      -?*) ;;
      *) srcs+=("$a") ;;
    esac
  done
  if [ -z "$dir" ]; then
    [ "${#srcs[@]}" -gt 0 ] || return 0
    dest="${srcs[${#srcs[@]}-1]}"
    srcs=("${srcs[@]:0:${#srcs[@]}-1}")
    if [ "$notdir" = 1 ] || { [ "${#srcs[@]}" -le 1 ] && ! is_dir "$dest"; }; then
      target "$dest"
    else
      dir="${dest%/}"; [ -n "$dir" ] || dir=/
    fi
  fi
  case "${CMD_ARGS[0]}" in mv|ln) for src in ${srcs[@]+"${srcs[@]}"}; do target "$src"; done ;; esac
  [ -n "$dir" ] || return 0
  if e=$(protected_parent_match "$dir"); then HITS="$HITS$e"$'\n'; return 0; fi
  for src in ${srcs[@]+"${srcs[@]}"}; do
    if unresolved "$src"; then target "$dir"; else src="${src%/}"; target "$dir/${src##*/}"; fi
  done
}

# find: -delete, or an -exec whose program is not a reader, rewrites files under the start paths.
judge_find() {
  local a k=1 n=0 writes=0 next=""
  for a in "${CMD_ARGS[@]:1}"; do
    case "$next" in
      file) target "$a" ;;
      exec) case "$SHELL_READERS" in *" $a "*) ;; *) writes=1 ;; esac ;;
    esac
    next=""
    case "$a" in
      -delete) writes=1; UNSAFE="${UNSAFE}find $a"$'\n' ;;
      -exec|-execdir|-ok|-okdir) next=exec; UNSAFE="${UNSAFE}find $a"$'\n' ;;
      -fprint|-fprint0|-fprintf|-fls) next=file; UNSAFE="${UNSAFE}find $a"$'\n' ;;
    esac
  done
  [ "$writes" = 1 ] || return 0
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in -H|-L|-P) ;; -*|'('|'!') break ;; *) target "$a"; n=$((n + 1)) ;; esac
  done
  [ "$n" -gt 0 ] || target .
}

judge_command() {
  local cmd="${CMD_ARGS[0]:-}" a t e
  TGT_BASE=""
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do target "$t"; done
  TGT_BASE="$CMD_CHDIR"
  for a in ${CMD_ARGS[@]+"${CMD_ARGS[@]}"} ${CMD_ASSIGN[@]+"${CMD_ASSIGN[@]}"}; do
    case "$a" in *'$('*|*'`'*) UNSAFE="$UNSAFE${cmd:-assignment}: command substitution"$'\n'; return 0 ;; esac
  done
  [ -n "$cmd" ] || return 0
  [ "$CMD_WRAP_BAD" = 0 ] || UNSAFE="${UNSAFE}$cmd: a wrapper carried an unrecognised option"$'\n'
  shell_is_reader && return 0
  case "$cmd" in
    git) judge_git ;;
    sed|yq) judge_in_place ;;
    find) judge_find ;;
    tee|rm|unlink|rmdir|truncate|shred|sponge) operands; target_operands ;;
    touch) operands rdt; target_operands ;;
    mkdir)
      operands m
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do
        if unresolved "$t"; then UNSAFE="${UNSAFE}mkdir: $t does not resolve"$'\n'
        else e=$(protected_bash_match "$t") && HITS="$HITS$e"$'\n'; fi
      done ;;
    cp|mv|install|ln) copy_targets ;;
    dd) for a in "${CMD_ARGS[@]}"; do case "$a" in of=*) target "${a#of=}" ;; esac; done ;;
    # Writers whose targets are read, but whose effect is not only on those.
    chmod|chown|chgrp) operands; [ "${#OPERANDS[@]}" = 0 ] || OPERANDS=("${OPERANDS[@]:1}"); target_operands; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    *) UNSAFE="$UNSAFE$cmd"$'\n' ;;
  esac
  return 0
}

shell_words "$CMD"
if [ "$SW_OVERFLOW" = 1 ]; then
  # Not split, so nothing on it is proved; the mention still keys the .claude/achilles rule.
  OVERFLOW=1
  e=$(protected_bash_mention "$CMD") && NAMED="$NAMED$e"$'\n'
else
  # The dequoted words, case-folded, catch every plain spelling at once. Words a substring test
  # can miss (//, /./, .., or a protected directory itself) are normalised one by one, a few
  # forks each; past 40 of them the line counts as naming protected state.
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

# Session scope (lib/achilles-activation.sh): a line naming the activation state dir (.claude/achilles)
# is judged in every session. It is the root of trust for every gate, so neither an inactive session
# nor the active one may strip a marker.
case "$NAMED$HITS" in *.claude/achilles*) ;; *) achilles_require_active "$INPUT" ;; esac

if [ -n "$HITS" ]; then
  WHY="Writes into: $(printf '%s' "$HITS" | sort -u | tr '\n' ' ')"
elif [ -n "$OVERFLOW" ]; then
  WHY="Command too long to verify (over 32 KB); split it."
else
  WHY="Cannot prove this command does not write: $(printf '%s' "$NAMED" | sort -u | tr '\n' ' ')
Because of: $(printf '%s' "$UNSAFE" | sort -u | tr '\n' ';')"
fi

emit_pre_deny "[BLOCKED] This Bash command would mutate (or could mutate) a protected pipeline-state artifact out of band.

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
exit 0
