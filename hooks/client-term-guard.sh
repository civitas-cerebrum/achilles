#!/bin/bash
# client-term-guard.sh — universality guard: deny Write|Edit into this
#                        package's repo when the content matches an
#                        operator-local client-term denylist.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY (silent allow when no denylist file exists)
# State   : none (reads <repo-root>/.achilles/client-terms.local.txt, operator-authored)
# Env     : ACHILLES_CLIENT_TERMS_FILE=<path>  (denylist override, used by tests)
#
# Rule
# ----
# The achilles suite is a universal QA medium serving many clients.
# Nothing in this repository may reference a specific client's software,
# brand, product names, domain copy, selectors/test IDs, ticket
# prefixes, or engagement details (contributing-to-achilles-protocol
# SKILL.md §"Universality — no client references"). This hook scans
# every Write|Edit that targets a file inside this package's repo (a git
# tree whose nearest package.json "name" is @civitas-cerebrum/achilles or
# @civitas-cerebrum/element-interactions — rename-stable, unlike a skill path)
# against an OPERATOR-LOCAL denylist of client terms, one per line, at
# <repo-root>/.achilles/client-terms.local.txt. Matching content (or a
# matching target path) is denied with a genericisation redirect.
#
# The denylist itself must NEVER live in the repo — the terms ARE client
# references. `.achilles/` is gitignored at the repo root; the operator
# authors the file per machine, per engagement. No denylist → the hook
# is a silent no-op (the markdown rule still applies; reviewers enforce).
# Because creating the denylist is an explicit operator opt-in, this
# guard runs without the session-activation gate — its scope is already
# limited to writes inside this package's own repo tree.
#
# Why
# ---
# Client references leak into universal repos through the most innocent
# door: a worked example pasted from the engagement where the finding
# was made. Under context pressure the contributor rationalises ("it is
# just one product name in an example", "the client name makes the
# example clearer") — see anti-rationalizations.md §"Client-reference
# leakage". The mechanism is always expressible generically; the
# denylist makes the operator's known client vocabulary mechanically
# unwritable into the repo.
#
# Canonical reference
# -------------------
# skills/contributing-to-achilles-protocol/SKILL.md §"Universality — no client references"
# skills/coverage-expansion/references/anti-rationalizations.md §"Client-reference leakage"
#
# Failure → action
# ----------------
# - Write|Edit into this repo, content/path matches a denylist term → DENY
# - Write|Edit into this repo, no match                             → silent allow
# - No denylist file (operator has not opted in)                    → silent allow
# - Target file outside this package's repo tree                    → silent allow
# - Malformed input / jq missing                                    → silent allow (fail open)

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0

INPUT=$(cat 2>/dev/null || echo "{}")

TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in Write|Edit) : ;; *) exit 0 ;; esac

FILE_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

# Locate this package's repo root by walking up from the target file.
# The marker is the package.json "name" field — rename-stable, unlike any
# skills/<dir> path (the skill directories were renamed once already and
# a path-based probe would have gone silently dead).
DIR=$(dirname "$FILE_PATH")
ROOT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if [ -f "$DIR/package.json" ]; then
    PKG_NAME=$("$JQ" -r '.name // empty' "$DIR/package.json" 2>/dev/null || echo "")
    if [ "$PKG_NAME" = "@civitas-cerebrum/achilles" ] || [ "$PKG_NAME" = "@civitas-cerebrum/element-interactions" ]; then
      ROOT="$DIR"
      break
    fi
  fi
  [ "$DIR" = "/" ] && break
  DIR=$(dirname "$DIR")
done
[ -n "$ROOT" ] || exit 0   # write is not into this package's repo — out of scope

TERMS_FILE="${ACHILLES_CLIENT_TERMS_FILE:-$ROOT/.achilles/client-terms.local.txt}"
[ -f "$TERMS_FILE" ] || exit 0   # operator has not opted in — markdown rule only

CONTENT=$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_input.content // empty, .tool_input.new_string // empty] | join("\n")' 2>/dev/null || echo "")
SCAN=$(printf '%s\n%s' "$FILE_PATH" "$CONTENT")

MATCHED=""
while IFS= read -r TERM || [ -n "$TERM" ]; do
  # Strip comments and surrounding whitespace; skip blanks and short terms
  # (1-2 chars would false-positive on ordinary prose).
  TERM=$(printf '%s' "$TERM" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$TERM" ] || continue
  [ "${#TERM}" -ge 3 ] || continue
  if printf '%s' "$SCAN" | grep -qiF -- "$TERM"; then
    MATCHED="$TERM"
    break
  fi
done < "$TERMS_FILE"

[ -n "$MATCHED" ] || exit 0

read -r -d '' REASON <<EOF || true
[BLOCKED] Client reference detected in a write to the universal achilles repo — denylist term: "${MATCHED}"

──────────────────────────────────────────────────────────────────
Do this instead — genericise before writing:
──────────────────────────────────────────────────────────────────

  Option A — describe the MECHANISM, never the instance
    Rewrite the passage so it names the behaviour generically
    (e.g. "a controlled form resets its inputs on mount"), with the
    suite's «placeholder» convention for names, slugs, and selectors
    (e.g. «BASE_URL», j-<slug>, <resource-001>). Evidence lines read
    "observed in a production suite" — no client, page, or ticket.
  Option B — the term is a false positive on this machine
    The denylist is operator-local: edit
    ${TERMS_FILE}
    (it is gitignored and never ships) and retry the write.

──────────────────────────────────────────────────────────────────
What was wrong:
──────────────────────────────────────────────────────────────────
File: ${FILE_PATH}
The write's content or target path matches denylist term "${MATCHED}".

Achilles is a universal QA medium serving many clients. Client
software, brands, product names, domain copy, selectors/test IDs,
ticket prefixes, and engagement details must not appear anywhere in
this repository — skills, hooks, schemas, fixtures, examples, commit
messages, or PR bodies.

──────────────────────────────────────────────────────────────────
If the client name "makes the example clearer" — read this:
──────────────────────────────────────────────────────────────────
That is the client-reference-leakage pattern. The mechanism is always
expressible generically, and the generic form is what every OTHER
consumer of this suite can actually use.

References:
  skills/contributing-to-achilles-protocol/SKILL.md §"Universality — no client references"
  skills/coverage-expansion/references/anti-rationalizations.md §"Client-reference leakage"
EOF

"$JQ" -n --arg r "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
