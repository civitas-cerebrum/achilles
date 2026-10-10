#!/bin/bash
# commit-gate.sh — denies `git commit` in this project without a fresh
#                  content-hash verify stamp and, for the current change,
#                  its verification report (rule process.evidence).
#
# Hook    : PreToolUse:Bash (commands containing `commit`)
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : reads <stamp> = { "treeHash": "<hex>", … } (written by the project's verify step only),
#           <currentChange> (one line: the change folder name), <trailDir>/<change>/<required…>
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests),
#           FACTORY_NODE=<path> (node override, tests)
# Needs   : node (and jq). Absent → allow-with-warning: both the commit classification
#           (hooks/lib/commit-classify.cjs) and the tree hash run under it.
#
# Rule
# ----
# The command is classified by hooks/lib/commit-classify.cjs, which uses the quote-aware splitter
# hooks/lib/shell-segments.cjs — the same one the sibling spend gate uses — and walks the segments in
# order:
#   * leading `VAR=val` assignments and the pass-through prefixes (`env`, `command`, `sudo`, `exec`, …)
#     are peeled before the command word is read;
#   * one level of `bash|sh|zsh|dash|ksh -c '<string>'` and `eval '<string>'` is classified too, so a
#     commit wrapped in a quoted string is still a commit;
#   * a `cd <dir>` segment moves the working directory for the segments after it (`cd` alone → $HOME);
#   * a `git [--opt | -c k=v | -C <dir>]… commit` segment (--amend --no-edit included) is a commit; its
#     directory is the current one, moved by that SAME segment's `-C <dir>` options (cumulative, as git
#     does).
# A commit whose directory is inside this project is gated; a commit in another repository is not ours
# to gate. Then deny when:
#   (a) <stamp> is missing, has no treeHash, or its treeHash differs from what <hashCommand> prints now
#       (run from the project root) — the stamp is a CONTENT hash, so a touch keeps it and any added,
#       removed or changed file under the hashed roots invalidates it;
#   (b) <currentChange> exists and names a folder that is not <yyyy-mm-dd>-<slug>, or whose
#       <trailDir>/<change>/ lacks a `required` file.
# No <currentChange> marker = a maintenance commit: only the stamp is checked.
#
# Why
# ---
# "Verified" must mean the tree being committed is the tree that passed, not a tree that passed an
# hour and three edits ago. A timestamp cannot tell; a content hash can.
#
# Known limit: the stamp is protected only by state-gate.sh (process.state). <hashCommand> is a repo script
# anyone can run, so a hand-written stamp can carry the current tree's hash. Shell expansions are not resolved, so
# `$GIT commit` is not seen, and nesting deeper than one level is not followed.
#
# Command splitting is shared with the spend gate (hooks/lib/shell-segments.cjs), so `sh -c 'git commit'`
# and `env git commit` are seen as commits.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#process.evidence

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=process.evidence
rule_enabled "$ID"
[ -n "$COMMAND" ] || exit 0
[[ "$COMMAND" == *commit* ]] || exit 0
ROOT_N="$(normalize_path "$FACTORY_ROOT")"
NODE="${FACTORY_NODE-$(command -v node || true)}"
[ -n "$NODE" ] && [ -x "$NODE" ] || emit_allow_warn "node not found — commit gate cannot classify the command; run the verify step before committing"
GATED="$("$NODE" "$_FACTORY_LIB/commit-classify.cjs" "$COMMAND" "$ROOT_N" "${CWD:-$ROOT_N}" 2>/dev/null)" \
  || emit_allow_warn "could not classify the command — commit gate skipped; run the verify step before committing"
[ "$GATED" = gated ] || exit 0

STAMP_REL="$(rule_field "$ID" stamp)"; TRAIL="$(rule_field "$ID" trailDir)"; CUR_REL="$(rule_field "$ID" currentChange)"
HASH_CMD=(); while IFS= read -r a; do [ -n "$a" ] && HASH_CMD+=("$a"); done < <(rule_array "$ID" hashCommand)
[ -n "$STAMP_REL" ] && [ -n "$TRAIL" ] && [ ${#HASH_CMD[@]} -gt 0 ] || emit_allow_warn "$ID stamp/trailDir/hashCommand missing in $(rules_rel) — commit gate skipped"
REQUIRED=(); while IFS= read -r a; do [ -n "$a" ] && REQUIRED+=("$a"); done < <(rule_array "$ID" required)
WHAT='Tree changed since the last verify (or no verify yet).'
STAMP="$ROOT_N/$STAMP_REL"
[ -f "$STAMP" ] || emit_deny "$ID" "$WHAT No verify stamp ($STAMP_REL missing)."

if [ -n "$CUR_REL" ] && [ -f "$ROOT_N/$CUR_REL" ]; then
  IFS= read -r CHANGE < "$ROOT_N/$CUR_REL" || true
  CHANGE="${CHANGE%%[[:space:]]*}"
  [[ "$CHANGE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] \
    || emit_deny "$ID" "$WHAT $CUR_REL names \"$CHANGE\", which is not a <yyyy-mm-dd>-<slug> change folder."
  for r in ${REQUIRED[@]+"${REQUIRED[@]}"}; do
    [ -f "$ROOT_N/$TRAIL/$CHANGE/$r" ] || emit_deny "$ID" "$WHAT The current change $TRAIL/$CHANGE/ has no $r."
  done
fi

PROG="${HASH_CMD[0]}"
if [ "$PROG" = node ]; then PROG="${FACTORY_NODE-$(command -v node || true)}"; else PROG="$(command -v "$PROG" || true)"; fi
[ -n "$PROG" ] && [ -x "$PROG" ] || emit_allow_warn "${HASH_CMD[0]} not found — commit gate cannot recompute the tree hash; run the verify step before committing"
WANT="$("$JQ" -r '.treeHash // empty' "$STAMP" 2>/dev/null)"
NOW="$(cd "$ROOT_N" && "$PROG" "${HASH_CMD[@]:1}" 2>/dev/null)" \
  || emit_allow_warn "could not recompute the tree hash — commit gate skipped; run the verify step before committing"
NOW="${NOW%%[[:space:]]*}"
[ -n "$WANT" ] || emit_deny "$ID" "$WHAT $STAMP_REL has no treeHash."
[ "$WANT" = "$NOW" ] || emit_deny "$ID" "$WHAT Stamp tree ${WANT:0:12} ≠ current tree ${NOW:0:12} (a file under the hashed roots changed after the verify step)."
exit 0
