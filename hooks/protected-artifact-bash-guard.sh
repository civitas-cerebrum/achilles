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
# Scope: a write shape is correlated with a protected path WITHIN ONE SIMPLE
# COMMAND (see the splitter below), not across the whole command line. A
# read-only inspection that ends in an unrelated cleanup — `jq -r
# .currentPhase <ledger> && rm -f /tmp/v`, or a multi-line read-only
# `node -e "…" && rm /tmp/scratch` — is therefore allowed, while `rm -f
# <ledger> && echo done` and `ls /tmp && mv /tmp/x <ledger>` still deny.
# Quotes, `$( … )`, backticks and heredoc bodies are opaque to the splitter,
# so a write cannot hide inside them; a pipeline counts as ONE scope, because
# the program feeding an interpreter's stdin sits in the segment before it.
#
# False-positive tradeoff (accepted): within a simple command, any mutate
# verb (cp/mv/rm/tee/…) or interpreter one-liner (-c/-e) co-occurring with a
# protected name is denied even when the verb targets an unrelated path
# (`cp <ledger> /tmp` denies; so does `rm /tmp/junk <ledger>`). The verb is
# matched as a WHOLE WORD but not at command position — `xargs rm` and
# `find … -exec rm {}` are the shapes the rule exists for — so a bare verb
# name used as an argument (`grep -rn cp <ledger>`) over-denies, while a path
# that merely contains one (`/tmp/rm-old`, `x.tee`) does not. Both forms of
# the command, as written and with the quotes stripped, are checked, so a
# shell wrapper cannot hide the verb (`bash -c "rm <ledger>"`); the cost is
# that grepping a protected file for the literal text of a verb over-denies
# too. Option words (`-i`, `of=`) are matched as options, never substrings. The same
# holds for an interpreter whose program the guard cannot see: a script file
# (`python3 validate.py <ledger>`) or a program piped in is denied even when
# it only reads. A heredoc or herestring program IS visible, so it is
# classified like a one-liner (read-shape allows; write-shape or no
# recognizable token denies). That rule covers the read-modify-write
# artifacts only (PROTECTED_LEDGERS): a sanctioned helper's script path under
# `.claude/hooks` (the selector pipeline's `node …/visual-diff.js`) is not a
# ledger mutation, and denying it would dead-end a documented workflow step.
# The deny text names the sanctioned alternative.
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

# ── Scope: one simple command at a time ──────────────────────────────────────
# Every rule below correlates a write shape with a protected path. Correlating
# over the WHOLE command string denied read-only traffic that merely ended in an
# unrelated cleanup: `jq -r .currentPhase <ledger> && rm -f /tmp/v` (a real
# workflow-reviewer inspection) tripped the `rm` rule, and a multi-line
# `node -e "…require(<ledger>)…" && rm /tmp/scratch` did the same. The command is
# therefore split into simple commands first, and a rule fires only when the
# write shape and the protected path sit in the SAME one.
#
# The splitter (awk, single pass) honours what a shell honours: `&&`, `||`, `;`,
# `&` and newline separate; `|` separates but keeps the pipeline grouped (see
# below); quotes, backslash escapes, `$( … )`, backticks and heredoc BODIES are
# opaque, so a separator inside them does not split and a heredoc's program
# stays attached to the interpreter that reads it. `2>&1`, `>&2` and `&>f` are
# redirections, not separators.
#
# Two scopes come out of it:
#   - a SIMPLE COMMAND for the redirect / mutate-verb / in-place / dd rules;
#   - a PIPELINE (simple commands joined by `|`) for the interpreter rules,
#     because a pipeline is one data flow: `printf … | python3` feeds the
#     interpreter a program from the segment before it.
# If awk is unavailable the whole command is treated as one segment — the old
# behaviour, which over-denies rather than under-denies.
SEG_SEP=$(printf '\036')
PIPE_MARK=$(printf '\002')
split_simple_commands() {
  printf '%s' "$1" | awk -v SEP="$SEG_SEP" -v PIPE="$PIPE_MARK" '
    { s = (NR == 1 ? $0 : s "\n" $0) }
    function emit(cont) {
      if (out ~ /[^ \t\n]/) printf "%s%s%s", (cont ? PIPE : ""), out, SEP
      out = ""
    }
    END {
      len = length(s); i = 1; sq = 0; dq = 0; bt = 0; sub_depth = 0; nhd = 0; cont = 0
      while (i <= len) {
        ch = substr(s, i, 1)
        # Backslash escape (not inside single quotes, where it is literal).
        if (ch == "\\" && !sq) { out = out substr(s, i, 2); i += 2; continue }
        if (sq) { out = out ch; if (ch == "\047") sq = 0; i++; continue }
        if (dq) { out = out ch; if (ch == "\"") dq = 0; i++; continue }
        if (ch == "\047") { sq = 1; out = out ch; i++; continue }
        if (ch == "\"")   { dq = 1; out = out ch; i++; continue }
        # `$( … )` and `` ` … ` ``: opaque, so `rm -f $(… <ledger>)` stays one command.
        if (substr(s, i, 2) == "$(") { sub_depth++; out = out "$("; i += 2; continue }
        if (sub_depth > 0) {
          if (ch == "(") sub_depth++
          else if (ch == ")") sub_depth--
          out = out ch; i++; continue
        }
        if (ch == "`") { bt = !bt; out = out ch; i++; continue }
        if (bt) { out = out ch; i++; continue }
        # Heredoc: remember the delimiter; the body is consumed at the newline.
        if (substr(s, i, 2) == "<<" && substr(s, i, 3) != "<<<") {
          out = out "<<"; i += 2
          if (substr(s, i, 1) == "-") { out = out "-"; i++ }
          while (i <= len && substr(s, i, 1) ~ /[ \t]/) { out = out substr(s, i, 1); i++ }
          raw = ""
          while (i <= len) {
            c2 = substr(s, i, 1)
            if (c2 ~ /[ \t\n;&|<>()]/) break
            raw = raw c2; out = out c2; i++
          }
          gsub(/["\047\\]/, "", raw)
          if (raw != "") hd[++nhd] = raw
          continue
        }
        if (ch == "\n") {
          out = out "\n"; i++
          for (k = 1; k <= nhd; k++) {
            while (i <= len) {
              p = index(substr(s, i), "\n")
              if (p == 0) { line = substr(s, i); i = len + 1 } else { line = substr(s, i, p - 1); i = i + p }
              out = out line "\n"
              t = line; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t)
              if (t == hd[k]) break
            }
          }
          nhd = 0
          emit(cont); cont = 0; continue
        }
        if (substr(s, i, 2) == "&&") { emit(cont); cont = 0; i += 2; continue }
        if (substr(s, i, 2) == "||") { emit(cont); cont = 0; i += 2; continue }
        if (ch == "|") {
          if (substr(out, length(out), 1) == ">") { out = out ch; i++; continue }       # >| clobber redirect
          if (substr(s, i + 1, 1) == "&") { emit(cont); cont = 1; i += 2; continue }   # |& (pipe + stderr)
          emit(cont); cont = 1; i++; continue
        }
        if (ch == "&") {
          if (substr(s, i + 1, 1) == ">") { out = out "&>"; i += 2; continue }          # &>file
          if (substr(out, length(out), 1) == ">") { out = out ch; i++; continue }        # 2>&1, >&2
          emit(cont); cont = 0; i++; continue
        }
        if (ch == ";") { emit(cont); cont = 0; i++; continue }
        out = out ch; i++
      }
      emit(cont)
    }' 2>/dev/null
}

SEGMENTS=()
while IFS= read -r -d "$SEG_SEP" seg; do SEGMENTS+=("$seg"); done < <(split_simple_commands "$CMD")
[ "${#SEGMENTS[@]}" -gt 0 ] || SEGMENTS=("$CMD")   # no awk / nothing parsed: fail closed on the whole command

# Pipeline groups: a segment marked as a pipe continuation joins the previous one.
PIPELINES=()
for seg in "${SEGMENTS[@]}"; do
  if [ "${seg:0:1}" = "$PIPE_MARK" ] && [ "${#PIPELINES[@]}" -gt 0 ]; then
    PIPELINES[$(( ${#PIPELINES[@]} - 1 ))]="${PIPELINES[$(( ${#PIPELINES[@]} - 1 ))]}"$'\n'"${seg#"$PIPE_MARK"}"
  else
    PIPELINES+=("${seg#"$PIPE_MARK"}")
  fi
done

# The text under test, in the forms the shape rules need.
#   SEG_CMD          — as written
#   SEG_NQ           — quotes stripped (idiom: commit-message-gate.sh), so
#                      `bash -c "python3 …"` shows its inner interpreter to both
#                      rule 4's `(^|[;&|[:space:]])` anchor and rule 5's scan
#   *_NO_SINKS       — output sinks neutralised (see strip_sinks)
SEG_CMD=""; SEG_NQ=""; SEG_NO_SINKS=""; SEG_NQ_NO_SINKS=""
set_seg_text() {
  SEG_CMD=$1
  SEG_NQ=${1//\"/ }
  SEG_NQ=${SEG_NQ//\'/ }
  SEG_NO_SINKS=$(strip_sinks "$SEG_CMD")
  SEG_NQ_NO_SINKS=$(strip_sinks "$SEG_NQ")
}

# Write-shape detection must not fire on an output SINK: `sys.stdout.write(…)`
# and `process.stdout.write(…)` are how a read-only probe PRINTS what it read,
# and `\.write\(` matched them. Neutralise the sinks first, then test.
strip_sinks() {
  printf '%s' "$1" | sed -E 's/(sys|os|process)\.(stdout|stderr)\.write\(/PRINT(/g; s/(STDOUT|STDERR|\$stdout|\$stderr)\.write\(/PRINT(/g; s/console\.(log|error|warn|info)\(/PRINT(/g'
}

# Write shape is looked for in BOTH forms. The quoted form carries the mode
# quote `open(f,'w')`; in the quote-stripped form that quote is a space, so the
# stripped form is matched with one extra alternative for a bare mode token.
# (WRITE_SHAPE_RE / WRITE_SHAPE_NQ_RE are defined with rule 4 below; these
# functions are only ever called after that point.)
has_write_shape() {
  echo "$SEG_NO_SINKS" | grep -qE "$WRITE_SHAPE_RE" && return 0
  echo "$SEG_NQ_NO_SINKS" | grep -qE "$WRITE_SHAPE_NQ_RE" && return 0
  return 1
}
has_read_shape() {
  echo "$SEG_NQ" | grep -qE "$READ_SHAPE_RE"
}

# In-place-edit option words for sed/perl/yq (see rule 3 below).
INPLACE_RE="(^|[;&|[:space:]])(sed|perl|yq)[[:space:]]+([^;|&]*[[:space:]])?(-[a-zA-Z]*i([[:space:]=.'\"]|$)|--in-place([[:space:]=]|$))"

REDIR_HIT=0
MUTATE_HIT=0
INPLACE_HIT=0
DD_HIT=0
INTERP_WRITE_HIT=0
INTERP_AMBIG_HIT=0
INTERP_PROG_HIT=0

# Rules 1-3 + dd, per SIMPLE COMMAND: each needs the protected path in the very
# command that carries the write shape.
# True when either form of the current segment matches $1 (see seg_matches below).
seg_matches() {
  echo "$SEG_RAW" | grep -qE "$1" && return 0
  echo "$SEG_RAW_NQ" | grep -qE "$1"
}
for seg in "${SEGMENTS[@]}"; do
  seg=${seg#"$PIPE_MARK"}
  echo "$seg" | grep -qE "$PROTECTED" || continue
  # Both forms, as in rules 4-5: a quote is not a shield. `bash -c "rm <ledger>"`
  # and `bash -c "sed -i … <ledger>"` used to pass, because the opening quote is
  # not one of the word-boundary characters these patterns anchor on.
  SEG_RAW=$seg
  SEG_RAW_NQ=${seg//\"/ }
  SEG_RAW_NQ=${SEG_RAW_NQ//\'/ }

  # 1. Redirection targeting a protected path (including >| clobber redirect).
  seg_matches ">>?\|?[[:space:]]*[^[:space:];|&]*(${PROTECTED})" && REDIR_HIT=1

  # 2. Mutation commands co-occurring with a protected name in this command.
  #    The verb has to be a whole word, so `/tmp/rm-old` and `x.tee` do not match;
  #    it is NOT required to be at command position, because `xargs rm` and
  #    `find … -exec rm {}` are the shapes this rule exists for.
  seg_matches "(^|[;&|[:space:]])(tee|cp|mv|rm|install|ln|truncate|sponge|shred)([[:space:]]|$)" && MUTATE_HIT=1

  # 3. In-place editors (sed, perl, yq -i). Note: jq has no -i flag; redirects already cover jq writes.
  #    `-i` is matched as an OPTION WORD, never as a substring: the old
  #    `[^;|&]*-i` fired on the `-i` inside a FILENAME, so `sed -n '80,160p'
  #    .claude/hooks/playwright-cli-isolation-guard.sh` — a read of a hook, which
  #    is exactly what a model does to understand a rule — was denied. The option
  #    must start at a word boundary and end at one: `-i`, `-i.bak`, `-i ''`, a
  #    bundled `-ni`/`-pi`, `--in-place`, `--in-place=bak`.
  seg_matches "$INPLACE_RE" && INPLACE_HIT=1
  # `of=` likewise has to start a word, so `--prof=…` is not a dd output file.
  seg_matches "(^|[;&|[:space:]])dd[[:space:]][^;|&]*[[:space:]]of=" && DD_HIT=1
done

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

# 5. Interpreters that take their program from stdin or a script file.
#    Rule 4 only sees -c/-e one-liners. `python3 - <<'EOF' … json.dump(…)`
#    feeds the program on stdin and slipped past it (a real bypass), as does
#    `python3 fix.py <ledger>`. The pipeline is scanned for an interpreter
#    (python*, node, perl, ruby, php, deno, bun, and the shells
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
INTERP_NAME_RE='^(python[0-9.]*|node|nodejs|perl|ruby|php|deno|bun|bash|sh|zsh|dash|ksh)$'
interp_rules() {
  local prog_hit=0 inline=0 state=start name="" words w
  # One word per token; a pipe inside the group and fd duplications (2>&1, >&2)
  # are flattened so they cannot look like a program argument.
  words=$(printf '%s' "$SEG_NQ" | tr '\n' ';' | sed -E 's/[0-9]*[<>]&[0-9-]*/ /g; s/(\|\||&&|\|&|[;|&()`])/ ; /g')
  end_segment() {
    # An interpreter left waiting for its program (no script argument) reads it
    # from stdin: a pipe, a redirect, or `-`.
    case "$state" in args|stdin) prog_hit=1 ;; esac
    state=start; name=""
  }
  # shellcheck disable=SC2086
  set -f   # no globbing while word-splitting the command
  for w in $words; do
    if [ "$w" = ";" ]; then end_segment; continue; fi
    case "$state" in
      start)
        case "$w" in
          *=*|sudo|env|exec|command|time|nice|nohup|timeout|-*) continue ;;
        esac
        [[ "$w" =~ ^[0-9.]+[smhd]?$ ]] && continue   # timeout's duration
        if [[ "${w##*/}" =~ $INTERP_NAME_RE ]]; then name="${w##*/}"; state=args; else state=done; fi ;;
      args|stdin)
        case "$w" in
          '<<'*|'-<<'*)
            case "$name" in bash|sh|zsh|dash|ksh) ;; *) inline=1 ;; esac
            state=done ;;
          '<'*) prog_hit=1; state=done ;;
          '>'*|[0-9]'>'*) ;;
          -) state=stdin ;;
          -c|-lc|-ic|-lic|-cl|-e|-E|-p|-r|-m|-[A-Za-z]*[ce]|--eval|--eval=*|--print|--print=*|--version|-V|--help|-h|eval)
            # A shell's -c/-lc/-ic takes a COMMAND, not a program to classify: rescan
            # from command position so `bash -c "python3 - <<EOF …"` is seen.
            case "$name" in
              bash|sh|zsh|dash|ksh) state=start; name="" ;;
              *) [ "$state" = args ] && state=done ;;
            esac ;;
          -*) ;;
          run) [ "$name" = deno ] || [ "$name" = bun ] || { prog_hit=1; state=done; } ;;
          *) [ "$state" = args ] && { prog_hit=1; state=done; } ;;
        esac ;;
    esac
  done
  set +f
  end_segment
  if [ "$inline" = "1" ]; then
    if has_write_shape; then prog_hit=1
    elif ! has_read_shape; then prog_hit=1   # inline program with no recognizable read/write token — fail closed
    fi
  fi
  # Scoped to the read-modify-write artifacts: a sanctioned helper's script path
  # under .claude/hooks is not a ledger mutation (see PROTECTED_LEDGERS above).
  echo "$SEG_CMD" | grep -qE "$PROTECTED_LEDGERS" || prog_hit=0
  [ "$prog_hit" = "1" ] && INTERP_PROG_HIT=1

  # Rule 4, same scope: a one-liner whose program is right there in the command.
  if echo "$SEG_NQ" | grep -qE "(^|[;&|[:space:]])(python3?|node|ruby|perl)[[:space:]][^;|&]*-[ce]([[:space:]]|$)"; then
    if has_write_shape; then INTERP_WRITE_HIT=1
    elif has_read_shape; then :   # recognizably read-only — allow
    else INTERP_AMBIG_HIT=1       # no recognizable read/write token — ask
    fi
  fi
}

# Rules 4-5, per PIPELINE: `printf … | python3` is one data flow, so the
# program's text and the interpreter reading it belong to the same scope.
for grp in "${PIPELINES[@]}"; do
  echo "$grp" | grep -qE "$PROTECTED" || continue
  set_seg_text "$grp"
  interp_rules
done

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
    program inline ('python3 -c …', 'node -e …', or a heredoc) so the
    harness can see it is a read. A program it cannot see — a script file,
    a pipe into the interpreter, 'python3 -' — is denied on principle.
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
