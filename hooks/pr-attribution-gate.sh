#!/bin/bash
# pr-attribution-gate.sh — denies pull requests carrying AI-attribution metadata.
#
# Hook    : PreToolUse:Bash  (filters to `gh pr create` / `gh pr edit` only)
# Mode    : DENY (high-confidence anti-pattern) — no WARN path
# State   : none (stateless scan of the command surface)
# Env     : ACHILLES_PROTOCOL (via lib/achilles-activation.sh)
# Scope   : achilles-activated sessions only — plain dev sessions silent-allow
#
# Rule
# ----
# A pull-request title or body must NOT carry AI-attribution metadata: a
# `Co-Authored-By:` trailer naming claude / anthropic / noreply@anthropic.com,
# a "Generated with [Claude Code]" marker, or a claude.ai/code URL → DENY.
#
# Why
# ---
# `commit-message-gate.sh` already denies these artifacts on `git commit`, but
# its trigger is scoped to git — a PR description never passes through git, so
# `gh pr create --body "…🤖 Generated with [Claude Code]…"` sails past the whole
# suite. The attribution rule is about the project's public record; the PR body
# IS that record, arguably more visible than any single commit message. This
# gate closes the surface the commit gate structurally cannot see.
#
# Kept as a separate hook rather than widening commit-message-gate because that
# gate's other checks (conventional-commit type, multi-journey scope, hook-bypass
# flags) are commit-shaped and meaningless for a PR. One concern per hook.
#
# What it gates
# -------------
#   gh pr create …      (any form, including `command`/`env` wrappers)
#   gh pr edit …
# The scan covers the ENTIRE command string plus the contents of every
# resolvable `--body-file <path>` / `-F <path>` argument, so a body passed via
# file or heredoc is checked the same as an inline `--body`.
#
# What it does NOT gate
# ---------------------
# `gh pr view` / `list` / `checkout` / `merge` / `comment` — none of them author
# the PR description. A prose mention of "claude" in a normal PR body still
# ALLOWs; the match targets attribution trailers / markers / URLs, not any
# mention of the word.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/harness-hooks.md §Bash
#
# Outcomes
# --------
# - Co-Authored-By: trailer naming an AI identity                 → DENY
# - "Generated with [Claude Code]" marker                         → DENY
# - claude.ai/code URL                                            → DENY
# - Anything else                                                 → silent allow

set -euo pipefail

# Resolve jq: prefer the binary bundled with the hook install, fall back to
# system jq for in-repo testing before postinstall has run.
JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH. Reinstall the package or install jq manually." >&2
  exit 1
fi

# --- helpers ---
emit_deny() {
  "$JQ" -n --arg r "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

# --- input ---
INPUT=$(cat)

# Session-scope gate: this hook applies only to achilles-activated
# sessions; plain dev sessions silent-allow (lib/achilles-activation.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
achilles_require_active "$INPUT"

TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty')
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""')

# Only fire on the two gh subcommands that author a PR description. The
# trigger tolerates `command` / `env` wrappers so `command gh pr create` is
# gated, and allows global flags between `gh` and `pr`.
GH_PR_TRIGGER='(^|[;&|][[:space:]]*)((command|env)[[:space:]]+)?gh([[:space:]]+--[a-z-]+(=[^[:space:]]+)?)*[[:space:]]+pr[[:space:]]+(create|edit)([[:space:]]|$)'
if ! echo "$CMD" | grep -qE "$GH_PR_TRIGGER"; then
  exit 0
fi

# --- AI-attribution scan (full-surface) ---
# Scans the ENTIRE command string plus the contents of every resolvable
# `--body-file <file>` / `-F <file>` argument, so a body written to a temp
# file first is checked the same as an inline `--body`.
ATTRIB_SCAN="$CMD"
ATTRIB_FILES=$(echo "$CMD" | grep -oE -- "(--body-file|-F)[[:space:]=][[:space:]]*[^[:space:]]+" \
  | sed -E "s/^(--body-file|-F)[[:space:]=][[:space:]]*//;s/^['\"]//;s/['\"]\$//" || true)
if [ -n "$ATTRIB_FILES" ]; then
  while IFS= read -r af; do
    [ -z "$af" ] && continue
    [ "$af" = "-" ] && continue
    if [ -f "$af" ]; then
      ATTRIB_SCAN="${ATTRIB_SCAN}
$(cat "$af" 2>/dev/null || true)"
    fi
  done <<EOF
$ATTRIB_FILES
EOF
fi

# Same pattern as commit-message-gate.sh, deliberately: one rule, one shape.
# The co-authored-by alternative matches the trailer at a line start OR
# immediately after a quote (covers an inline single-line `--body`). The
# generated-with / claude.ai-code alternatives are markers/URLs that are never
# legitimate in a PR description, so they match anywhere.
if echo "$ATTRIB_SCAN" | grep -qiE '(^|['"'"'"])[[:space:]]*co-authored-by:.*(claude|anthropic|noreply@anthropic\.com)|generated with.*claude([[:space:]]+code)?\b|claude\.ai/code'; then
  emit_deny "[BLOCKED] pull request carries AI-attribution metadata.

Command/body surface contains one of:
  - a \`Co-Authored-By:\` trailer naming claude / anthropic / noreply@anthropic.com
  - a \"Generated with [Claude Code]\" marker
  - a claude.ai/code URL

A pull-request description is the project's public record of a change. AI
tooling is not a co-author and the PR should not advertise the tool that
produced it — the same rule commit-message-gate.sh enforces on \`git commit\`,
applied to the surface git never sees.

Fix: re-issue the command with the attribution trailer / marker / URL removed
from the title and body. The upstream fix is to remove the attribution
instruction from CLAUDE.md (or set \`attribution.pr\` to an empty string in
settings.json) so it stops being added in the first place — do not strip it
by hand on every PR."
  exit 0
fi

exit 0
