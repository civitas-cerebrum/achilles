#!/bin/bash
# achilles-kernel-activation-gate.sh — consult the vendored kernel only while the achilles
# protocol is active in this session; relay its verdict and exit status unchanged.
#
# Hook : PreToolUse:.*   Env: ACHILLES_PROTOCOL, KERNEL_MANDATE (opt-in-surfaces.md)
# Why behind activation: skills/achilles-protocol/references/harness-hooks.md §"All tools (kernel mandate)".
# Kernel file missing: allowed with no manifest in the project, denied with one.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HOOK_DIR/lib/achilles-activation.sh"

INPUT=$(cat)

# Dormant: the achilles protocol is not in play in this session. The
# mandate exists on disk but binds nothing. Silent allow.
achilles_session_active "$INPUT" || exit 0

case "${KERNEL_MANDATE:-}" in 0|false|off) exit 0 ;; esac

KERNEL="$HOOK_DIR/kernel-mandate-role-gate.sh"
if [ ! -f "$KERNEL" ]; then
  JQ_BIN="$(achilles__jq)"
  CWD=""
  if [ -n "$JQ_BIN" ]; then
    CWD=$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.cwd // empty' 2>/dev/null)
  else
    CWD=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  fi
  TOP=""
  [ -n "$CWD" ] && [ -d "$CWD" ] && TOP=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
  STAGED=""
  [ -n "${KERNEL_MANDATE_MANIFEST:-}" ] && [ -f "$KERNEL_MANDATE_MANIFEST" ] && STAGED=1
  for root in "${CLAUDE_PROJECT_DIR:-}" "$CWD" "$TOP"; do
    [ -n "$root" ] && [ -f "$root/.claude/kernel-mandate.json" ] && STAGED=1
  done
  [ -n "$STAGED" ] || exit 0
  REASON="[BLOCKED] kernel-mandate cannot run: this project has a kernel-mandate.json but $KERNEL is missing, so no role is enforced.

──────────────────────────
What to do:
──────────────────────────
Reinstall @civitas-cerebrum/achilles. To work without the kernel on purpose, set KERNEL_MANDATE=0 in your own shell.

References:
  skills/achilles-protocol/references/known-limits.md
  skills/achilles-protocol/references/opt-in-surfaces.md (KERNEL_MANDATE)"
  if [ -n "$JQ_BIN" ]; then
    "$JQ_BIN" -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    # No jq to escape with, so the reason here omits the install path.
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] kernel-mandate cannot run: this project has a kernel-mandate.json but the kernel gate file is missing, so no role is enforced. Reinstall @civitas-cerebrum/achilles, or set KERNEL_MANDATE=0 in your own shell.\\n\\nReferences:\\n  skills/achilles-protocol/references/known-limits.md"}}\n'
  fi
  exit 0
fi

# Relay: stdout and exit status pass through unchanged; a non-zero exit must not become 0.
printf '%s' "$INPUT" | bash "$KERNEL"
exit $?
