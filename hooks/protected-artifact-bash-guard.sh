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
# Bash sidesteps them all. This guard closes the obvious shell vectors:
# redirection, file-management commands, in-place editors, interpreter
# one-liners, and interpreters fed their program from stdin (heredoc,
# herestring, pipe, `-`) or a script file, when the command mentions a
# protected artifact.
#
# Known limit (by design): Bash filtering cannot be airtight — the agent
# shares the hook's privileges, and arbitrarily-encoded writes exist. The
# tamper-evident ledger chain (ledger-integrity-chain.sh) DETECTS whatever
# this guard fails to PREVENT. The two ship as a pair.
#
# False-positive tradeoff (accepted): any mutate verb (cp/mv/rm/tee/…) or
# interpreter one-liner (-c/-e) co-occurring with a protected name anywhere
# in the command is denied — even when the verb targets an unrelated path
# (e.g. `rm /tmp/junk && cat <ledger>` denies, as does `cp <ledger> /tmp`).
# The same holds for an interpreter whose program the guard cannot see: a
# script file (`python3 validate.py <ledger>`, `node x.mjs && cat <ledger>`)
# or a program piped in is denied even when it only reads. A heredoc or
# herestring program IS visible, so it is classified like a one-liner
# (read-shape allows; write-shape or no recognizable token denies). That
# rule covers the read-modify-write artifacts only (PROTECTED_LEDGERS): a
# sanctioned helper's script path under `.claude/hooks` (the selector
# pipeline's `node …/visual-diff.js`) is not a ledger mutation, and denying
# it would dead-end a documented workflow step. Rule 5 also matches whole
# commands, so an interpreter co-occurring with a ledger name in one command
# line is denied even when another part of the line owns the mention. The
# deny text names the sanctioned alternative.
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


JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[protected-artifact-bash-guard] FATAL: jq not found." >&2; exit 1; }

HOOK_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
if [ -f "$HOOK_LIB_DIR/no-skip-messaging.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOOK_LIB_DIR/no-skip-messaging.sh"
else
  no_skip_messaging_block() { echo ""; }
fi

INPUT=$(cat)

. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0
CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

# Session-scope gate: this guard applies only to achilles-activated
# sessions (lib/achilles-activation.sh) — EXCEPT for commands touching the
# session-activation state dir itself (.claude/achilles). That dir is the
# root of trust for every gate in the suite, so its protection is
# unconditional: an inactive session must not be able to strip another
# session's activation marker, and an active session must not deactivate
# itself by deleting its own.
if ! echo "$CMD" | grep -qE '\.claude/achilles'; then
  achilles_require_active "$INPUT"
fi

# Protected artifact patterns (extended regex).
PROTECTED='onboarding-status\.json|perf-onboarding-status\.json|journey-map\.md|\.phase4-cycle-state\.json|coverage-expansion-state\.json|\.workflow-approvers\.json|adversarial-findings\.md|\.ledger-integrity\.json|flake-quarantine\.md|\.claude/achilles|\.claude/hooks|\.claude/settings(\.local)?\.json'

# The subset rule 5 (interpreters whose program is not a one-liner) applies to:
# the read-modify-write pipeline-state artifacts only. The code/config members
# of PROTECTED (`.claude/hooks`, `.claude/settings*.json`, `.claude/achilles`)
# are deliberately excluded: those paths appear as the SCRIPT PATH of sanctioned
# helpers — `node .claude/hooks/lib/visual-diff.js a.png b.png` is step 7 of
# skills/selector-development/SKILL.md, and the pipeline stepper advances only
# on it. Denying that dead-ends a documented workflow with no escape hatch.
# Writes to those paths stay covered by rules 1-4 and, for Write|Edit, by
# harness-self-protection-guard.sh.
PROTECTED_LEDGERS='onboarding-status\.json|perf-onboarding-status\.json|journey-map\.md|\.phase4-cycle-state\.json|coverage-expansion-state\.json|\.workflow-approvers\.json|adversarial-findings\.md|\.ledger-integrity\.json|flake-quarantine\.md'

echo "$CMD" | grep -qE "$PROTECTED" || exit 0

# A quote-stripped copy (idiom: commit-message-gate.sh). `bash -c "python3 …"`
# hides the inner interpreter from both rule 4's `(^|[;&|[:space:]])` anchor and
# rule 5's word scan; with the quotes gone, the wrapped command is plain words.
CMD_NO_QUOTES=${CMD//\"/ }
CMD_NO_QUOTES=${CMD_NO_QUOTES//\'/ }

# Write-shape detection must not fire on an output SINK: `sys.stdout.write(…)`
# and `process.stdout.write(…)` are how a read-only probe PRINTS what it read,
# and `\.write\(` matched them. Neutralise the sinks first, then test.
strip_sinks() {
  printf '%s' "$1" | sed -E 's/(sys|os|process)\.(stdout|stderr)\.write\(/PRINT(/g; s/(STDOUT|STDERR|\$stdout|\$stderr)\.write\(/PRINT(/g; s/console\.(log|error|warn|info)\(/PRINT(/g'
}
CMD_NO_SINKS=$(strip_sinks "$CMD")
CMD_NQ_NO_SINKS=$(strip_sinks "$CMD_NO_QUOTES")

# Write shape is looked for in BOTH forms. The quoted form carries the mode
# quote `open(f,'w')`; in the quote-stripped form that quote is a space, so the
# stripped form is matched with one extra alternative for a bare mode token.
# (WRITE_SHAPE_RE / WRITE_SHAPE_NQ_RE are defined with rule 4 below; this
# function is only ever called after that point.)
has_write_shape() {
  echo "$CMD_NO_SINKS" | grep -qE "$WRITE_SHAPE_RE" && return 0
  echo "$CMD_NQ_NO_SINKS" | grep -qE "$WRITE_SHAPE_NQ_RE" && return 0
  return 1
}
has_read_shape() {
  echo "$CMD_NO_QUOTES" | grep -qE "$READ_SHAPE_RE"
}

# 1. Redirection targeting a protected path (including >| clobber redirect).
REDIR_HIT=$(echo "$CMD" | grep -cE ">>?\|?[[:space:]]*[^[:space:];|&]*(${PROTECTED})" || true)

# 2. Mutation commands co-occurring with a protected name anywhere.
MUTATE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(tee|cp|mv|rm|install|ln|truncate|sponge|shred)([[:space:]]|$)" || true)

# 3. In-place editors (sed, perl, yq -i). Note: jq has no -i flag; redirects already cover jq writes.
INPLACE_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])(sed|perl|yq)[[:space:]][^;|&]*-i" || true)
DD_HIT=$(echo "$CMD" | grep -cE "(^|[;&|[:space:]])dd[[:space:]][^;|&]*of=" || true)

# 4. Interpreter one-liners (-c/-e) mentioning a protected path.
#    A bare interpreter one-liner is NOT itself a write — `python3 -c
#    json.load(...)` and `node -e readFileSync(...)` are read-only and must
#    NOT be denied (the prior unconditional INTERP_HIT denied every
#    interpreter that mentioned a protected name, a high-volume false
#    positive on legitimate reads). We split the signal:
#      - INTERP_WRITE_HIT: interpreter one-liner that ALSO carries a
#        recognizable write-shape token → DENY (fail-closed, the real risk).
#      - INTERP_AMBIG_HIT: interpreter one-liner with NO recognizable
#        read/write token → permissionDecision "ask" (can't classify it;
#        defer to the operator rather than deny a possibly-read).
INTERP_ANY_HIT=$(echo "$CMD_NO_QUOTES" | grep -cE "(^|[;&|[:space:]])(python3?|node|ruby|perl)[[:space:]][^;|&]*-[ce]([[:space:]]|$)" || true)

# Write-shape tokens: open(…, 'w'/'a'/'x'), .write(), .write_text(),
# json.dump(), fs.write/append/rm/unlink/rename, writeFileSync,
# os.remove/unlink/rename/truncate, shutil.*, File.write/delete, unlink(.
WRITE_SHAPE_RE="open\\([^)]*,[[:space:]]*[\"'][wax]|\\.write\\(|\\.write_text\\(|json\\.dump\\(|fs\\.(write|append|rm|unlink|rename)|writeFileSync|os\\.(remove|unlink|rename|truncate)|shutil\\.|File\\.(write|delete)|unlink\\("
# Read-shape tokens: anything that reads (open(…, 'r')/default, readFileSync,
# json.load, .read(), .read_text(), File.read, require(<json>) — the Node
# load+parse idiom). Used only to decide ask-vs-deny on an interpreter
# one-liner with no write-shape. require() is read-only for a JSON file; a
# require() that also writes still carries a write-shape, which is classified
# first (above), so this can never launder a write into an allow.
READ_SHAPE_RE="open\\(|readFileSync|readFile\\(|json\\.load|\\.read\\(|\\.read_text\\(|File\\.read|require\\(|cat\\("
# The quote-stripped variant: `open(f,'w')` reads as `open( f , w )` once the
# quotes become spaces, so a bare mode token counts as a write there.
WRITE_SHAPE_NQ_RE="${WRITE_SHAPE_RE}|open\\([^)]*,[[:space:]]+[wax][[:space:]]*\\)"

INTERP_WRITE_HIT=0
INTERP_AMBIG_HIT=0
if [ "$INTERP_ANY_HIT" != "0" ]; then
  if has_write_shape; then
    INTERP_WRITE_HIT=1
  elif has_read_shape; then
    INTERP_WRITE_HIT=0   # recognizably read-only — allow
  else
    INTERP_AMBIG_HIT=1   # no recognizable read/write token — ask
  fi
fi

# 5. Interpreters that take their program from stdin or a script file.
#    Rule 4 only sees -c/-e one-liners. `python3 - <<'EOF' … json.dump(…)`
#    feeds the program on stdin and slipped past it (a real bypass), as does
#    `python3 fix.py <ledger>`. Each simple command is scanned for an
#    interpreter (python*, node, perl, ruby, php, deno, bun, and the shells
#    bash/sh/zsh/dash/ksh) at command position (after env assignments and
#    sudo/env/exec/command/time/nice/nohup/timeout), then its arguments:
#      - a heredoc/herestring (`<<`, `<<<`) into a NON-shell interpreter:
#        the program is inline, so it is classified like a one-liner —
#        write-shape → deny, read-shape → allow, neither → deny (fail
#        closed). A shell's heredoc body is ordinary shell and rules 1-4
#        already scan it, so it adds nothing here.
#      - `-`, `< file`, or no program argument at all (so it reads a pipe
#        or stdin): the program is not visible → deny.
#      - a script-file argument (`python3 x.py`, `deno run x.ts`): the
#        program is not visible → deny.
#      - a one-liner / module / info flag (-c -e -E -p -r -m --eval --print
#        --version -V --help -h, `deno eval`): not this rule's business.
#    A shell's -c/-lc/-ic carries a COMMAND, so the scan restarts at command
#    position there and `bash -c "python3 …"` is seen through.
#    The scan is word-based, not a shell parser: quotes are stripped rather
#    than honoured, so it errs toward seeing more interpreter invocations,
#    never fewer. It applies to PROTECTED_LEDGERS only (see above).
INTERP_PROG_HIT=0
INTERP_INLINE=0
INTERP_NAME_RE='^(python[0-9.]*|node|nodejs|perl|ruby|php|deno|bun|bash|sh|zsh|dash|ksh)$'
# One word per token; every command separator (; && || | & ( ) ` newline)
# becomes a standalone ";". fd duplications (2>&1, >&2) are dropped first so
# their "&" does not split a command.
INTERP_WORDS=$(printf '%s' "$CMD_NO_QUOTES" | tr '\n' ';' | sed -E 's/[0-9]*[<>]&[0-9-]*/ /g; s/(\|\||&&|\|&|[;|&()`])/ ; /g')
interp_state=start   # start | args | stdin | done
interp_name=""
interp_end_segment() {
  # An interpreter left waiting for its program (no script argument) reads it
  # from stdin: a pipe, a redirect, or `-`.
  case "$interp_state" in args|stdin) INTERP_PROG_HIT=1 ;; esac
  interp_state=start; interp_name=""
}
# shellcheck disable=SC2086
set -f   # no globbing while word-splitting the command
for w in $INTERP_WORDS; do
  if [ "$w" = ";" ]; then interp_end_segment; continue; fi
  case "$interp_state" in
    start)
      case "$w" in
        *=*|sudo|env|exec|command|time|nice|nohup|timeout|-*) continue ;;
      esac
      [[ "$w" =~ ^[0-9.]+[smhd]?$ ]] && continue   # timeout's duration
      if [[ "${w##*/}" =~ $INTERP_NAME_RE ]]; then interp_name="${w##*/}"; interp_state=args; else interp_state=done; fi ;;
    args|stdin)
      case "$w" in
        '<<'*|'-<<'*)
          case "$interp_name" in bash|sh|zsh|dash|ksh) ;; *) INTERP_INLINE=1 ;; esac
          interp_state=done ;;
        '<'*) INTERP_PROG_HIT=1; interp_state=done ;;
        '>'*|[0-9]'>'*) ;;
        -) interp_state=stdin ;;
        -c|-lc|-ic|-lic|-cl|-e|-E|-p|-r|-m|-[A-Za-z]*[ce]|--eval|--eval=*|--print|--print=*|--version|-V|--help|-h|eval)
          # A shell's -c/-lc/-ic takes a COMMAND, not a program to classify: rescan
          # from command position so `bash -c "python3 - <<EOF …"` is seen.
          case "$interp_name" in
            bash|sh|zsh|dash|ksh) interp_state=start; interp_name="" ;;
            *) [ "$interp_state" = args ] && interp_state=done ;;
          esac ;;
        -*) ;;
        run) [ "$interp_name" = deno ] || [ "$interp_name" = bun ] || { INTERP_PROG_HIT=1; interp_state=done; } ;;
        *) [ "$interp_state" = args ] && { INTERP_PROG_HIT=1; interp_state=done; } ;;
      esac ;;
  esac
done
set +f
interp_end_segment
if [ "$INTERP_INLINE" = "1" ]; then
  if has_write_shape; then
    INTERP_PROG_HIT=1
  elif ! has_read_shape; then
    INTERP_PROG_HIT=1   # inline program with no recognizable read/write token — fail closed
  fi
fi
# Scoped to the read-modify-write artifacts: a sanctioned helper's script path
# under .claude/hooks is not a ledger mutation (see PROTECTED_LEDGERS above).
echo "$CMD" | grep -qE "$PROTECTED_LEDGERS" || INTERP_PROG_HIT=0

# Ambiguous interpreter one-liner (protected path mentioned, but no
# recognizable read or write token) → ask the operator rather than deny.
if [ "$REDIR_HIT" = "0" ] && [ "$MUTATE_HIT" = "0" ] && [ "$INPLACE_HIT" = "0" ] && [ "$DD_HIT" = "0" ] && [ "$INTERP_WRITE_HIT" = "0" ] && [ "$INTERP_PROG_HIT" = "0" ] && [ "$INTERP_AMBIG_HIT" = "1" ]; then
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

if [ "$REDIR_HIT" = "0" ] && [ "$MUTATE_HIT" = "0" ] && [ "$INPLACE_HIT" = "0" ] && [ "$DD_HIT" = "0" ] && [ "$INTERP_WRITE_HIT" = "0" ] && [ "$INTERP_PROG_HIT" = "0" ]; then
  exit 0   # read-only access to a protected artifact
fi

REASON="[BLOCKED] This Bash command would mutate (or could mutate) a protected pipeline-state artifact out of band.

Command: ${CMD}

Protected artifacts (ledger, journey map, cycle/coverage state, approver
registry, findings ledger, integrity sidecar, the hook installation) may
only change through the Write/Edit tools — that is where the harness
gates (schema validation, state-machine checks, separation-of-duties,
integrity chain) live. A shell write would bypass them all.

Fix:
  - To change the artifact: use the Write or Edit tool on the file.
  - To read it: drop the write-shaped construct (redirect into /tmp, not
    into the artifact; copy FROM it is blocked too — use cat/jq to read).
  - To run an interpreter that only READS a protected artifact: pass the
    program inline (`python3 -c …`, `node -e …`, or a heredoc) so the
    harness can see it is a read. A program it cannot see — a script file,
    a pipe into the interpreter, `python3 -` — is denied on principle.
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
