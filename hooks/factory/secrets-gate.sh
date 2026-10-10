#!/bin/bash
# secrets-gate.sh — denies writing an email address, phone number or token
#                   into committed project files (rule secrets.none).
#
# Hook    : PreToolUse:Write|Edit|MultiEdit
# Mode    : DENY (silent allow without a rule file; allow-with-warning when it cannot run)
# State   : none (reads the rule file)
# Env     : FACTORY_RULES=<path> (rule-file override), FACTORY_JQ=<path> (jq override, tests)
# Needs   : grep, tr (and jq). Any of them absent → allow-with-warning, never a silent pass: an
#           empty `grep -oE` result is indistinguishable from "this file holds no secret".
#
# Rule
# ----
# A file under a `scope` glob must not receive content matching a `patterns` entry (POSIX ERE; \d is
# rewritten to [0-9]). `allowlist` entries: one ending in "/" is a path prefix (files under it are
# exempt); any other entry is a literal — a file whose path equals it is exempt, and a match that
# contains it (case-insensitively) is allowed. The pattern floor (email, E.164 phone, JWT) ships in
# the schema; a project adds patterns, never removes them.
#
# Why
# ---
# Test suites attract real account data: the address that worked in a manual run, a token copied
# from a network tab. Once committed it is in every clone. The sanctioned shape is the NAME of the
# environment variable that holds the value (process.env.SHOPPER_A_EMAIL), never the value.
#
# Known limit: pattern based, so an unusual secret shape passes; the deny quotes only the first three
# characters of a match so the value never lands in the transcript.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/factory-gates.md#secrets.none

source "$([[ ${BASH_SOURCE[0]} == */* ]] && echo "${BASH_SOURCE[0]%/*}" || echo .)/../lib/factory-common.sh"
factory_guard_ready; factory_read_input
ID=secrets.none
rule_enabled "$ID"
[ -n "$FILE_PATH" ] && [ -n "$CONTENT" ] || exit 0
[ -n "$(rule_array "$ID" scope)" ] && [ -n "$(rule_array "$ID" patterns)" ] \
  || emit_allow_warn "$ID scope/patterns missing in $(rules_rel) — secrets gate skipped; the project's verify step is the detector"
REL="$(rel_path "$FILE_PATH")"
in_scope "$REL" "$ID" || exit 0
factory_require_tools grep tr   # an empty `grep -oE` result reads as "no secret here" — see factory-common.sh
LITERALS=()
while IFS= read -r a; do
  [ -z "$a" ] && continue
  case "$a" in */) case "$REL" in "$a"*) exit 0;; esac;; *) [ "$REL" = "$a" ] && exit 0; LITERALS+=("$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')");; esac
done < <(rule_array "$ID" allowlist)
while IFS= read -r p; do
  [ -z "$p" ] && continue
  ere="${p//\\d/[0-9]}"   # POSIX ERE has no \d
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    lm="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"; ok=0
    for l in ${LITERALS[@]+"${LITERALS[@]}"}; do case "$lm" in *"$l"*) ok=1; break;; esac; done
    [ "$ok" = 1 ] && continue
    emit_deny "$ID" "$(tool_verb) $REL contains a secret-shaped value \`${m:0:3}…\` (pattern $p)."
  done < <(printf '%s\n' "$CONTENT" | grep -oE -- "$ere" || true)
done < <(rule_array "$ID" patterns)
exit 0
