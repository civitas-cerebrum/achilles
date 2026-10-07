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
#     mv, cp, install, ln, dd, sed -i, yq -i) whose write targets all resolve
#     to unprotected paths outside every protected directory.
# Anything else on such a line (interpreters, awk, eval, sh -c, xargs,
# find -delete/-exec/-fprint, command substitution, a target behind a
# variable or glob, any other program) denies: the guard cannot prove it
# does not write. Paths are normalised (lib/protected-paths.sh) first, so
# quoting, escapes, //, /./, .., ~ and case do not change the verdict.
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

READERS=' cat head tail less grep egrep fgrep rg ls stat wc diff cmp file sha256sum shasum md5 md5sum jq echo printf test [ '
NAMED=""    # protected entries and directories the line names, one per line
HITS=""     # protected entries or directories a write reaches
UNSAFE=""   # why a command on the line cannot be proved safe

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
    *'$'*|*'`'*|*'*'*|*'?'*|*'['*) UNSAFE="$UNSAFE${CMD_ARGS[0]:-redirect}: write target $1 does not resolve"$'\n'; return 0 ;;
  esac
  e=$(protected_bash_match "$1") || e=$(protected_parent_match "$1") || return 0
  HITS="$HITS$e"$'\n'
}

# OPERANDS: the arguments after the command word that are not options.
operands() {
  local a opts=1
  OPERANDS=()
  for a in "${CMD_ARGS[@]:1}"; do
    if [ "$opts" = 1 ]; then
      case "$a" in --) opts=0; continue ;; -?*) continue ;; esac
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

judge_command() {
  local cmd="${CMD_ARGS[0]:-}" a t last="" sub=""
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do target "$t"; done
  [ -n "$cmd" ] || return 0
  [ "$CMD_XARGS" = 1 ] && { UNSAFE="${UNSAFE}xargs $cmd: operands arrive on stdin"$'\n'; return 0; }
  for a in "${CMD_ARGS[@]}"; do
    case "$a" in *'$('*|*'`'*) UNSAFE="$UNSAFE$cmd: command substitution"$'\n'; return 0 ;; esac
  done
  case "$READERS" in *" $cmd "*) return 0 ;; esac
  case "$cmd" in
    git)
      for a in "${CMD_ARGS[@]:1}"; do
        case "$last" in -C|-c|--git-dir|--work-tree) last=""; continue ;; esac
        last="$a"
        case "$a" in --output*) UNSAFE="${UNSAFE}git: $a"$'\n'; return 0 ;; -*) continue ;; esac
        [ -n "$sub" ] || sub="$a"
      done
      case "$sub" in log|show|diff|status|blame) ;; *) UNSAFE="${UNSAFE}git $sub"$'\n' ;; esac ;;
    sed|yq)
      editor_parse || { UNSAFE="$UNSAFE$cmd: script read from a file"$'\n'; return 0; }
      if [ "$cmd" = sed ]; then
        # w/W write a file and e runs a command, as commands or as s/// flags.
        for a in ${SCRIPTS[@]+"${SCRIPTS[@]}"}; do
          printf '%s' "$a" | grep -qE '(^|[;{}/[:space:]])[0-9gpiImM]*[wWe]([[:space:]]|$)' &&
            { UNSAFE="${UNSAFE}sed: w/e command in $a"$'\n'; return 0; }
        done
      fi
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    find)
      for a in "${CMD_ARGS[@]}"; do
        case "$a" in -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) UNSAFE="${UNSAFE}find $a"$'\n'; return 0 ;; esac
      done ;;
    tee|rm|unlink|rmdir|truncate|shred|sponge|mv)
      operands; for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    cp|install|ln)
      operands; [ "${#OPERANDS[@]}" -gt 0 ] && target "${OPERANDS[${#OPERANDS[@]}-1]}"
      for a in "${CMD_ARGS[@]}"; do
        case "$last" in -t|--target-directory) target "$a" ;; esac
        case "$a" in --target-directory=*) target "${a#*=}" ;; esac
        last="$a"
      done ;;
    dd) for a in "${CMD_ARGS[@]}"; do case "$a" in of=*) target "${a#of=}" ;; esac; done ;;
    *) UNSAFE="$UNSAFE$cmd"$'\n' ;;
  esac
  return 0
}

shell_words "$CMD"
if [ "$SW_OVERFLOW" = 1 ]; then
  # Too long or too deeply nested to split whole: any protected name on the line denies.
  e=$(protected_bash_mention "$CMD") && { NAMED="$NAMED$e"$'\n'; UNSAFE="${UNSAFE}command line too long or too deeply nested to split"$'\n'; }
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
  [ "$n" -le 40 ] || UNSAFE="${UNSAFE}too many paths on the line to normalise"$'\n'
  [ -n "$NAMED" ] && shell_each_command judge_command
fi
[ -n "$HITS" ] || [ -n "$UNSAFE" ] || exit 0

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
