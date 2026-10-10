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

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/contributing-to-achilles-protocol/SKILL.md §\"AI assistants don't get Co-Authored-By trailers\"\n  skills/achilles-protocol/references/harness-hooks.md §Bash"


# Resolve jq: prefer the binary bundled with the hook install, fall back to
# system jq for in-repo testing before postinstall has run.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_jq_init fatal

# --- input ---
hook_read_input

# Session-scope gate: this hook applies only to achilles-activated
# sessions; plain dev sessions silent-allow (lib/achilles-activation.sh).
hook_lib achilles-activation.sh
achilles_require_active "$INPUT"
hook_lib hook-emit.sh shell-words.sh

TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty')
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""')

# Only fire on the two gh subcommands that author a PR description, judged on the words the shell
# runs (lib/shell-words.sh): global --flags may sit between gh and pr. The scan covers the whole
# command and every resolvable --body-file / -F, so a body written to a temp file first is checked
# the same as an inline --body.
PR=0; BODY_FILES=()
pr_judge() {
  local k=1 a want=0
  [ "${CMD_ARGS[0]:-}" = gh ] || return 0
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in --*) ;; pr) break ;; *) return 0 ;; esac
  done
  [ "$a" = pr ] || return 0
  case "${CMD_ARGS[k]:-}" in create|edit) PR=1 ;; *) return 0 ;; esac
  for a in "${CMD_ARGS[@]:k+1}"; do
    [ "$want" = 0 ] || { BODY_FILES+=("$a"); want=0; continue; }
    case "$a" in --body-file|-F) want=1 ;; --body-file=*|-F=*) BODY_FILES+=("${a#*=}") ;; esac
  done
}
shell_words "$CMD"
[ "$SW_OVERFLOW" = 0 ] || case "$CMD" in *gh*pr*create*|*gh*pr*edit*) PR=1 ;; esac
shell_each_command pr_judge
[ "$PR" = 1 ] || exit 0

ATTRIB_SCAN="$CMD"
for af in ${BODY_FILES[@]+"${BODY_FILES[@]}"}; do
  [ "$af" != "-" ] && [ -f "$af" ] && ATTRIB_SCAN="${ATTRIB_SCAN}
$(cat "$af" 2>/dev/null || true)"
done

# Same pattern as commit-message-gate.sh, deliberately: one rule, one shape.
# The co-authored-by alternative matches the trailer at a line start OR
# immediately after a quote (covers an inline single-line `--body`). The
# generated-with / claude.ai-code alternatives are markers/URLs that are never
# legitimate in a PR description, so they match anywhere.
if echo "$ATTRIB_SCAN" | grep -qiE '(^|['"'"'"])[[:space:]]*co-authored-by:.*(claude|anthropic|noreply@anthropic\.com)|generated with.*claude([[:space:]]+code)?\b|claude\.ai/code'; then
  emit_pre_deny_bare "[BLOCKED] pull request carries AI-attribution metadata.

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
by hand on every PR.${HOOK_REFS}"
  exit 0
fi

exit 0
