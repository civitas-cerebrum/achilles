#!/bin/bash
# repository-evidence-gate.sh — denies a new or changed page-repository
#                                selector that has no live evidence note
#                                (rule selectors.evidence).
#
# Hook    : PreToolUse:Write|Edit|MultiEdit (the page repository only)
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : none (reads the rule file, the on-disk repository and <evidenceDir>/<Page>.<element>.md)
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests)
#
# Rule
# ----
# The gate builds the post-write repository (Write content, or the on-disk file with the Edit /
# MultiEdit replacements applied), compares it with the on-disk repository and judges only entries
# whose selector is new or changed. Each must either carry "<provisionalKey>": true, or have
# <evidenceDir>/<Page>.<element>.md whose first "- selector: <JSON>" line equals the NEW selector
# (deep-equal after JSON parse, key order irrelevant) and which carries a "- source:" line (written by
# the evidence tool, not by hand). A note left over from the old selector is stale. Adding the
# provisional flag alone, removing an entry or reordering entries is never judged.
#
# Why
# ---
# A selector written from memory or from a screenshot is a guess. The note is the receipt that the
# selector was read off the live page; the provisional flag is the honest alternative while the page
# cannot be inspected (it must be dropped in the same change once evidence exists).
#
# Known limit: an edit whose old_string does not occur in the on-disk file, or a result that is not
# JSON, cannot be judged → allow-with-warning (the project's verify step parses the file).
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#selectors.evidence

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=selectors.evidence
rule_enabled "$ID"
REPO_REL="$(rule_field "$ID" repository)"
EVDIR="$(rule_field "$ID" evidenceDir)"; EVDIR="${EVDIR:-docs/evidence/selectors}"
PKEY="$(rule_field "$ID" provisionalKey)"; PKEY="${PKEY:-provisional}"
[ -n "$FILE_PATH" ] || exit 0
[ -n "$REPO_REL" ] || emit_allow_warn "$ID.repository missing in $(rules_rel) — gate skipped"
[ "$(rel_path "$FILE_PATH")" = "$REPO_REL" ] || exit 0
DISK_FILE="$FACTORY_ROOT/$REPO_REL"; [ -f "$DISK_FILE" ] || DISK_FILE=/dev/null
CHANGED="$(printf '%s' "$INPUT" | "$JQ" -r --rawfile disk "$DISK_FILE" --arg pk "$PKEY" '
  def entries: [ .pages[]? as $p | ($p.elements // [])[] | select(type == "object")
                 | {k: "\($p.name)\u001f\(.elementName)", page: $p.name, el: .elementName, sel: .selector, prov: (.[$pk] == true)} ];
  def apply($e): if . == null or ($e.old_string | type) != "string" or $e.old_string == "" or ($e.new_string | type) != "string" then null
    else split($e.old_string) as $parts
      | if ($parts | length) < 2 then null
        elif $e.replace_all == true then $parts | join($e.new_string)
        else $parts[0] + $e.new_string + ($parts[1:] | join($e.old_string)) end end;
  .tool_input as $ti
  | (if (.tool_name == "Write") then $ti.content
     else reduce (if ($ti.edits | type) == "array" then $ti.edits[] else $ti end) as $e ($disk; apply($e)) end) as $text
  | if ($text | type) != "string" then "!UNAPPLIED"
    else ($text | try fromjson catch null) as $new
    | if ($new | type) != "object" then "!PARSE"
      else (($disk | try fromjson catch {}) | entries | map({(.k): .sel}) | add // {}) as $old
      | $new | entries[] | select(.prov | not) | select($old[.k] != .sel) | "\(.page)\u001f\(.el)\u001f\(.sel | tojson)" end end' 2>/dev/null)" \
  || emit_allow_warn "could not evaluate the $REPO_REL change — $ID gate skipped; the project's verify step is the detector"
case "$CHANGED" in
  '!UNAPPLIED') emit_allow_warn "edit to $REPO_REL does not apply to the on-disk file — $ID gate skipped";;
  '!PARSE') emit_allow_warn "the resulting $REPO_REL is not valid JSON — $ID gate skipped; the project's verify step is the detector";;
esac
while IFS=$'\x1f' read -r page el sel; do
  [ -z "$page" ] && continue
  k="$page.$el"   # the note name; page and element arrive separately, so a page name with a dot is fine
  action="$(rule_field "$ID" action)"; action="${action//<Page>/$page}"; action="${action//<element>/$el}"
  [ -n "$action" ] || action="Insert the entry with \"$PKEY\": true, record live evidence for $page.$el, then drop the flag in the same change."
  NOTE="$FACTORY_ROOT/$EVDIR/$k.md"
  [ -f "$NOTE" ] || emit_deny "$ID" "Repository entry $page.$el has no evidence note." "$action"
  NOTE_SEL=""; HAS_SOURCE=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- selector: "*) [ -z "$NOTE_SEL" ] && NOTE_SEL="${line#- selector: }";; "- source: "*) HAS_SOURCE=1;; esac
  done < "$NOTE"
  [ "$HAS_SOURCE" = 1 ] || emit_deny "$ID" "Evidence note $EVDIR/$k.md has no \"- source:\" line (not written by the evidence tool)." "$action"
  SAME="$("$JQ" -n --arg a "$NOTE_SEL" --argjson b "$sel" '($a | try fromjson catch null) as $n | ($n != null and $n == $b)' 2>/dev/null)"
  [ "$SAME" = true ] || emit_deny "$ID" "Evidence note $EVDIR/$k.md is stale: its \"- selector:\" line does not describe the new selector of $page.$el." "$action"
done <<< "$CHANGED"
exit 0
