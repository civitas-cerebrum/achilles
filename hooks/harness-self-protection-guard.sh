#!/bin/bash
# harness-self-protection-guard.sh — denies Write|Edit to the installed
#                                    harness surface (hooks + settings).
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY
# State   : none (stateless path check)
# Env     : none
#
# Why
# ---
# The harness hooks live at ~/.claude/hooks/* and are registered in
# ~/.claude/settings.json. An agent that can Write|Edit those files can
# disable any gate in the suite — including this one. The bash vector is
# already covered by protected-artifact-bash-guard.sh (which lists
# `.claude/hooks` and `.claude/settings(.local)?.json`); this guard closes
# the Write|Edit vector that the bash guard never sees.
#
# What it gates
# -------------
# Any Write|Edit whose file_path matches:
#   */.claude/hooks/*                     (any installed hook or lib file)
#   */.claude/settings.json
#   */.claude/settings.local.json
# is DENIED. Hook changes must go through the repo (edit hooks/<file>.sh)
# and `npm run sync-hooks`, never by editing the installed copy directly —
# direct edits drift from source and are silently lost on the next install.
#
# What it does NOT gate
# ---------------------
# Project-local `.claude/skills/*` writes (and any non-hook, non-settings
# path under .claude/) are ALLOWED — installing/refreshing skills is a
# legitimate Write target. Only the hooks dir and the two settings files
# are protected here.
#
# Residual self-edit race (documented, accepted)
# ----------------------------------------------
# This guard protects the INSTALLED copy. The guard file itself is one of
# the installed hooks, so in principle a single tool call that the harness
# routes AROUND this hook (e.g. if this hook is not yet registered, or is
# edited in the same batch that disables it) could still land. The pairing
# with protected-artifact-bash-guard.sh (bash vector) + the install-time
# re-copy (postinstall overwrites the installed hook from source on every
# install) bounds the window: a tampered installed hook is restored on the
# next `npm install` / `sync-hooks`. The repo copy under hooks/ is the
# source of truth; this guard makes the installed copy effectively
# read-only to the agent between installs.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/harness-hooks.md

set -uo pipefail

HOOK_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/guard-common.sh
if [ -f "$HOOK_LIB_DIR/guard-common.sh" ]; then source "$HOOK_LIB_DIR/guard-common.sh"; fi

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
# Fail CLOSED: a guard that protects the harness surface must never allow a
# write through just because jq is missing (see guard-common.sh).
if [ -z "$JQ" ]; then
  if command -v guard_emit_deny_no_jq >/dev/null 2>&1; then
    guard_emit_deny_no_jq "harness-self-protection"
  else
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] harness-self-protection guard cannot run: jq not found. Fails closed. Reinstall @civitas-cerebrum/achilles or install jq."}}'
  fi
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in Write|Edit) ;; *) exit 0 ;; esac

FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

# Lexically normalise (leading slash, collapse //, resolve . and ..) so a
# bare relative path (.claude/hooks/x.sh) AND evasion forms that resolve to
# a protected file (.claude/./settings.json, .claude/hooks/../settings.json,
# .claude//settings.json) all match the same case patterns. The Write/Edit
# tool resolves those forms before writing, so the guard must too.
if command -v normalize_path >/dev/null 2>&1; then
  NORM="$(normalize_path "$FILE_PATH")"
else
  NORM="/${FILE_PATH#/}"
fi

case "$NORM" in
  */.claude/hooks/*|*/.claude/settings.json|*/.claude/settings.local.json) ;;
  *) exit 0 ;;
esac

"$JQ" -n --arg r "[BLOCKED] Write|Edit to the installed harness surface is forbidden.

File: ${FILE_PATH}

This path is an installed harness hook or settings file under .claude/.
Editing the INSTALLED copy directly drifts it from the repo source and is
silently overwritten on the next install — and a writable hook surface
lets any gate in the suite be disabled.

Fix: change the hook in the REPO (edit hooks/<file>.sh in
@civitas-cerebrum/achilles), then run \`npm run sync-hooks\` (or reinstall)
to propagate the change to ~/.claude/hooks/. To change harness settings,
edit them in your own terminal — settings.json is operator-owned state,
not an agent Write target.

Project-local .claude/skills/* writes are NOT gated by this guard.

See: skills/element-interactions/references/harness-hooks.md" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
