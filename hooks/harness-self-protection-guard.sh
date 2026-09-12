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
# skills/achilles-protocol/references/harness-hooks.md

set -uo pipefail

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/achilles-protocol/references/harness-hooks.md\n  skills/contributing-to-achilles-protocol/SKILL.md §\"Workflow: adding a harness hook\""


JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[harness-self-protection-guard] FATAL: jq not found." >&2; exit 1; }

INPUT=$(cat)

. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in Write|Edit) ;; *) exit 0 ;; esac

FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

# Normalise to a leading-slash form so a bare relative path
# (.claude/hooks/x.sh) matches the same case patterns as an absolute one.
NORM="/${FILE_PATH#/}"

case "$NORM" in
  # Session-activation state: protected UNCONDITIONALLY (no session-scope
  # gate) — the marker dir is the root of trust for every other gate, so
  # even an inactive session may not Write/Edit it.
  */.claude/achilles/*) ;;
  */.claude/hooks/*|*/.claude/settings.json|*/.claude/settings.local.json)
    # Session-scope gate: this surface is protected only in
    # achilles-activated sessions; plain dev sessions manage their own
    # hooks/settings freely (lib/achilles-activation.sh).
    achilles_require_active "$INPUT"
    ;;
  *) exit 0 ;;
esac

"$JQ" -n --arg r "[BLOCKED] Write|Edit to the installed harness surface is forbidden.

File: ${FILE_PATH}

This path is an installed harness hook, a settings file, or the achilles
session-activation state under .claude/. Editing an INSTALLED hook copy
directly drifts it from the repo source and is silently overwritten on
the next install — and a writable hook/state surface lets any gate in
the suite be disabled.

Fix: change the hook in the REPO (edit hooks/<file>.sh in
@civitas-cerebrum/achilles), then run \`npm run sync-hooks\` (or reinstall)
to propagate the change to ~/.claude/hooks/. To change harness settings,
edit them in your own terminal — settings.json is operator-owned state,
not an agent Write target. The session-activation state
(~/.claude/achilles/) is hook-authored only: it retires itself when the
pipeline completes, or dies with the session.

Project-local .claude/skills/* writes are NOT gated by this guard.

See: skills/achilles-protocol/references/harness-hooks.md${HOOK_REFS}$(achilles_scope_notice)" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
