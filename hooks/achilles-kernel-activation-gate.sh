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
JQ_BIN="$(achilles__jq)"

# True when this project has staged a manifest, i.e. the kernel is expected to govern it.
manifest_staged() {
  local cwd="" top="" root
  if [ -n "$JQ_BIN" ]; then
    cwd=$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.cwd // empty' 2>/dev/null)
  else
    cwd=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  fi
  [ -n "$cwd" ] && [ -d "$cwd" ] && top=$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
  [ -n "${KERNEL_MANDATE_MANIFEST:-}" ] && [ -f "$KERNEL_MANDATE_MANIFEST" ] && return 0
  for root in "${CLAUDE_PROJECT_DIR:-}" "$cwd" "$top" "$PWD"; do
    [ -n "$root" ] && [ -f "$root/.claude/kernel-mandate.json" ] && return 0
  done
  return 1
}

# $1: what is wrong with the kernel, as a sentence fragment.
deny_cannot_run() {
  local reason="[BLOCKED] kernel-mandate cannot run: $1, so no role is enforced.

──────────────────────────
What to do:
──────────────────────────
Reinstall @civitas-cerebrum/achilles. To work without the kernel on purpose, set KERNEL_MANDATE=0 in your own shell.

References:
  skills/achilles-protocol/references/known-limits.md
  skills/achilles-protocol/references/opt-in-surfaces.md (KERNEL_MANDATE)"
  if [ -n "$JQ_BIN" ]; then
    "$JQ_BIN" -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    # No jq to escape with, so the reason here is static.
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] kernel-mandate cannot run: the kernel gate file is missing or unrunnable, so no role is enforced. Reinstall @civitas-cerebrum/achilles, or set KERNEL_MANDATE=0 in your own shell.\\n\\nReferences:\\n  skills/achilles-protocol/references/known-limits.md"}}\n'
  fi
  exit 0
}

# An empty file exits 0 with no output and an unreadable one exits 126; both would read as allow.
if [ ! -f "$KERNEL" ] || [ ! -s "$KERNEL" ] || [ ! -r "$KERNEL" ]; then
  manifest_staged || exit 0
  deny_cannot_run "this project has a kernel-mandate.json but $KERNEL is missing, empty or unreadable"
fi

# Relay: stdout and exit status pass through unchanged, except that an exit other than
# 0 (allow) or 2 (block) is non-blocking to the harness, so with a manifest staged it is refused.
OUT=$(printf '%s' "$INPUT" | bash "$KERNEL"; printf 'x%s' "$?")
RC=${OUT##*x}
OUT=${OUT%x*}
if [ "$RC" != 0 ] && [ "$RC" != 2 ] && manifest_staged; then
  deny_cannot_run "the kernel exited $RC before deciding"
fi
printf '%s' "$OUT"
exit "$RC"
