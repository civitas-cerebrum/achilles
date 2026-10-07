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
# Bash sidesteps them all. This guard closes the obvious shell vectors by
# judging what the command WRITES, as the shell would split it
# (lib/shell-words.sh): redirect targets, the operands tee / rm / mv /
# truncate / sponge / shred / unlink / rmdir mutate, the destination of
# cp / install / ln, the files of an in-place sed / perl / yq, dd's of=,
# find with -delete or -exec, and interpreter one-liners (-c/-e) whose code
# names a protected path. Each target is normalised (lib/protected-paths.sh)
# before it is matched, so quoting, escapes, //, /./, .., ~ and case do not
# change the verdict. Reading or mentioning a protected name is not a write.
#
# Known limits (by design): Bash filtering cannot be airtight — the agent
# shares the hook's privileges. Not seen: a target behind a variable, glob,
# alias, function or `cd`; a write by any other program (git, curl -o, tar,
# rsync, a script file); an interpreter one-liner that builds the path at run
# time. The tamper-evident ledger chain (ledger-integrity-chain.sh) DETECTS
# whatever this guard fails to PREVENT. The two ship as a pair.
#
# Over-deny (accepted): xargs feeding a mutating command denies when the
# command line names a protected path anywhere, since the operands arrive on
# stdin; so does a command line past SHELL_WORDS_MAX or nested past
# SHELL_WORDS_NEST_CAP (lib/shell-words.sh) that names a protected path.
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

HITS=""            # protected entries a write reaches, one per line
INTERP_VERDICT=""  # write | ask: an interpreter one-liner names a protected path

hit() { local e; e=$(protected_bash_match "$1") && HITS="$HITS$e"$'\n'; return 0; }
hit_all() { local a; for a in "$@"; do hit "$a"; done; }

# OPERANDS: the arguments after the command word that are not options.
operands() {
  local a opts=1
  OPERANDS=()
  for a in ${CMD_ARGS[@]+"${CMD_ARGS[@]:1}"}; do
    if [ "$opts" = 1 ]; then
      case "$a" in --) opts=0; continue ;; -?*) continue ;; esac
    fi
    OPERANDS+=("$a")
  done
}

# 0 for an in-place sed / perl / yq; OPERANDS then holds its files: the operands after the
# script, which is the first operand unless -e / -f / -E carried it. BSD's `-i ''` suffix is skipped.
inplace_files() {
  local a k=1 inplace=0 script=0
  OPERANDS=()
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      --in-place*|--inplace) inplace=1 ;;
      -e|-f|-E|--expression|--file|--from-file) script=1; k=$((k + 1)) ;;
      --expression=*|--file=*|--from-file=*) script=1 ;;
      -[!-]*) case "$a" in -*i*) inplace=1 ;; esac
              case "$a" in -*[eEf]) script=1; k=$((k + 1)) ;; esac ;;
      '') ;;
      *) if [ "$script" = 0 ]; then script=1; else OPERANDS+=("$a"); fi ;;
    esac
  done
  [ "$inplace" = 1 ]
}

# The code of an interpreter one-liner (-c / -e, alone or in a flag cluster).
interp_code() {
  local k=1
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    case "${CMD_ARGS[k]}" in -*[ce]) printf '%s' "${CMD_ARGS[k+1]:-}"; return 0 ;; esac
    k=$((k + 1))
  done
  return 1
}

# Write-shape tokens: open(…, 'w'/'a'/'x'), .write(), .write_text(),
# json.dump(), fs.write/append/rm/unlink/rename, writeFileSync,
# os.remove/unlink/rename/truncate, shutil.*, File.write/delete, unlink(.
WRITE_SHAPE_RE="open\\([^)]*,[[:space:]]*[\"'][wax]|\\.write\\(|\\.write_text\\(|json\\.dump\\(|fs\\.(write|append|rm|unlink|rename)|writeFileSync|os\\.(remove|unlink|rename|truncate)|shutil\\.|File\\.(write|delete)|unlink\\("
# Read-shape tokens: anything that reads (open(…, 'r')/default, readFileSync,
# json.load, .read(), .read_text(), File.read, require(<json>) — the Node
# load+parse idiom). Used only to decide ask-vs-allow on a one-liner with no
# write-shape; write-shape is classified first, so a read token never
# launders a write.
READ_SHAPE_RE="open\\(|readFileSync|readFile\\(|json\\.load|\\.read\\(|\\.read_text\\(|File\\.read|require\\(|cat\\("

# An interpreter one-liner whose code names a protected path: a write-shape denies, a read-shape
# allows, neither asks (the harness cannot tell, so the operator decides).
judge_interp() {
  local code t e
  code=$(interp_code) || return 0
  while IFS= read -r t; do
    e=$(protected_bash_match "$t") || continue
    if printf '%s' "$code" | grep -qE "$WRITE_SHAPE_RE"; then
      HITS="$HITS$e"$'\n'
    elif ! printf '%s' "$code" | grep -qE "$READ_SHAPE_RE"; then
      INTERP_VERDICT=ask
    fi
    return 0
  done < <(printf '%s' "$code" | tr -s "\"'(),;+= \t" '\n')
}

judge_command() {
  local cmd="${CMD_ARGS[0]:-}" t last=""
  hit_all ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}
  case "$cmd" in
    tee|rm|mv|truncate|sponge|shred|unlink|rmdir)
      operands; hit_all ${OPERANDS[@]+"${OPERANDS[@]}"} ;;
    cp|install|ln)
      operands; [ "${#OPERANDS[@]}" -gt 0 ] && hit "${OPERANDS[${#OPERANDS[@]}-1]}"
      for t in "${CMD_ARGS[@]}"; do
        case "$last" in -t|--target-directory) hit "$t" ;; esac
        case "$t" in --target-directory=*) hit "${t#*=}" ;; esac
        last="$t"
      done ;;
    sed|yq) inplace_files && hit_all ${OPERANDS[@]+"${OPERANDS[@]}"} ;;
    perl) if inplace_files; then hit_all ${OPERANDS[@]+"${OPERANDS[@]}"}; else judge_interp; fi ;;
    python|python3|node|ruby) judge_interp ;;
    dd) for t in "${CMD_ARGS[@]}"; do case "$t" in of=*) hit "${t#of=}" ;; esac; done ;;
    find) case " ${CMD_ARGS[*]} " in *" -delete "*|*" -exec "*|*" -execdir "*|*" -ok "*|*" -okdir "*) hit_all "${CMD_ARGS[@]}" ;; esac ;;
  esac
  # xargs supplies the operands from stdin: any protected path on the line may be one.
  if [ "$CMD_XARGS" = 1 ]; then
    case "$cmd" in tee|rm|mv|truncate|sponge|shred|unlink|rmdir|cp|install|ln|sed|perl|yq|dd) hit_all "${SW[@]}" ;; esac
  fi
  return 0
}

shell_words "$CMD"
shell_each_command judge_command
# A line too long or too deeply nested to split whole: any protected name on it denies.
if [ "$SW_OVERFLOW" = 1 ] && OVERFLOW_HIT=$(protected_bash_mention "$CMD"); then HITS="$HITS$OVERFLOW_HIT"$'\n'; fi
[ -n "$HITS" ] || [ -n "$INTERP_VERDICT" ] || exit 0

# Session-scope gate: this guard applies only to achilles-activated
# sessions (lib/achilles-activation.sh) — EXCEPT for writes into the
# session-activation state dir itself (.claude/achilles). That dir is the
# root of trust for every gate in the suite, so its protection is
# unconditional: an inactive session must not be able to strip another
# session's activation marker, and an active session must not deactivate
# itself by deleting its own.
case "$HITS" in *.claude/achilles*) ;; *) achilles_require_active "$INPUT" ;; esac

if [ -z "$HITS" ]; then
  "$JQ" -n --arg r "[ASK] This Bash command runs an interpreter one-liner that mentions a protected pipeline-state artifact, but the harness cannot tell whether it reads or writes it.

Command: ${CMD}

If this only READS the artifact, approve it. If it WRITES the artifact, cancel and use the Write/Edit tool instead (that is where the harness gates live).

See: skills/achilles-protocol/references/harness-hooks.md${HOOK_REFS}" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": $r
    }
  }'
  exit 0
fi

REASON="[BLOCKED] This Bash command would mutate (or could mutate) a protected pipeline-state artifact out of band.

Command: ${CMD}
Writes into: $(printf '%s' "$HITS" | sort -u | tr '\n' ' ')

Protected artifacts (ledger, journey map, cycle/coverage state, approver
registry, findings ledger, integrity sidecar, the hook installation) may
only change through the Write/Edit tools — that is where the harness
gates (schema validation, state-machine checks, separation-of-duties,
integrity chain) live. A shell write would bypass them all.

Fix:
  - To change the artifact: use the Write or Edit tool on the file.
  - To read it: drop the write-shaped construct (redirect into /tmp, not
    into the artifact; copying FROM it is fine).
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
