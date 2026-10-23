#!/bin/bash
# selector-write-gate.sh — denies inline selectors and raw locator calls in
#                          test code (rule selectors.no-inline).
#
# Hook    : PreToolUse:Write|Edit|MultiEdit
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : none (reads <project>/achilles-factory-rules.json)
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests)
# Needs   : sed, grep (and jq). Either absent → allow-with-warning, never a silent pass: without
#           sed the comment-masked body is EMPTY, so every forbidden literal looks absent.
#
# Rule
# ----
# A source file (.ts .mts .cts .js .mjs .cjs) under a `scope` glob must not contain any `forbidden`
# literal once comments are masked and every `allowed` literal is cut out: elements are named through
# the page repository — steps.<verb>('<element>', '<Page>') — never located inline. The floor lists
# ship in the schema; a project adds to them, never removes.
#
# Why
# ---
# An inline selector is the cheapest thing for an agent to write and the most expensive thing for a
# suite to keep: it bypasses the repository, its evidence and its review. The write is the last
# moment the agent still has the context to do it properly.
#
# Known limit: comment masking is line-based and best effort (see factory-common.sh mask_comments);
# the project's verify step is the detector.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#selectors.no-inline

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=selectors.no-inline
rule_enabled "$ID"
case "$FILE_PATH" in *.ts|*.mts|*.cts|*.js|*.mjs|*.cjs) ;; *) exit 0;; esac
REL="$(rel_path "$FILE_PATH")"
in_scope "$REL" "$ID" || exit 0
[ -n "$CONTENT" ] || exit 0
factory_require_tools sed grep   # without sed, mask_comments yields nothing and every literal "is absent"
BODY="$(printf '%s\n' "$CONTENT" | mask_comments)"
while IFS= read -r a; do [ -n "$a" ] && BODY="${BODY//"$a"/}"; done < <(rule_array "$ID" allowed)
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if printf '%s\n' "$BODY" | grep -F -q -- "$p"; then emit_deny "$ID" "$(tool_verb) $REL contains \`$p\`."; fi
done < <(rule_array "$ID" forbidden)
exit 0
