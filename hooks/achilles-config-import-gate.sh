#!/bin/bash
# achilles-config-import-gate.sh — the root runner config runs nothing outside tests/.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY (a root playwright*.config.ts whose post-write content imports
#           outside the allowlist, or names a lifecycle file outside tests/)
# State   : none
#
# Rule
# ----
# The scaffolder authors playwright*.config.ts and the orchestrator runs
# `npx playwright test`, which loads that config and every file it names. The
# config may import only @playwright/test, @civitas-cerebrum/element-interactions,
# dotenv, dotenv/config and path/url (bare or node:), plus relative files under
# tests/. globalSetup, globalTeardown and testDir must resolve under tests/.
# A require/import() the screen cannot read is denied.
#
# Why
# ---
# The kernel cannot give the scaffolder an import list: a role with codeImports
# may not author runner, resolution or environment config at all, and that is
# the scaffolder's whole job. Without a screen, the config is the channel by
# which project source (src/**) executes under the orchestrator's run. dotenv
# stays allowed: wiring .env for the tests is the Phase 7 design.
#
# Not modelled: webServer.command (arbitrary shell; known-limits.md KL-03),
# eval / Function / process.binding / module.constructor. A static floor, not a sandbox.
#
# Failure → action
# ----------------
# - import outside the allowlist / relative import outside tests/ → DENY
# - globalSetup | globalTeardown | testDir outside tests/        → DENY
# - non-literal require / import() / createRequire               → DENY
# - any other file, nested config, non-Write/Edit, inactive      → silent allow

set -euo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
HOOK_LIB="$HOOK_DIR/lib"

input=$(cat)

. "$HOOK_DIR/lib/achilles-activation.sh"
achilles_require_active "$input"

tool_name=$(echo "$input" | "$JQ" -r '.tool_name // empty')
file_path=$(echo "$input" | "$JQ" -r '.tool_input.file_path // empty')
case "$tool_name" in Edit|Write) ;; *) exit 0 ;; esac
case "$(basename "$file_path")" in playwright*.config.ts) ;; *) exit 0 ;; esac

root=$(echo "$input" | "$JQ" -r '.cwd // empty')
[ -n "$root" ] || root="$PWD"
case "$file_path" in /*) ;; *) file_path="$root/$file_path" ;; esac
[ "$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -P)" = "$(cd "$root" 2>/dev/null && pwd -P)" ] || exit 0

# An Edit is screened against the file it would produce, so it needs the file.
[ "$tool_name" = "Write" ] || [ -f "$file_path" ] || exit 0

result=$(printf '%s' "$input" | node "$HOOK_LIB/config-import-scan.js" "$file_path" "$root" 2>/dev/null) || exit 0
offenders=$(echo "$result" | "$JQ" -r '.offenders[:6][] | "  • " + .')
[ -n "$offenders" ] || exit 0

reason="[BLOCKED] achilles-config-import-gate: the runner config reaches outside tests/

──────────────────────────
Do this instead:
──────────────────────────
  Import only @playwright/test, @civitas-cerebrum/element-interactions,
  dotenv / dotenv/config and path / url; name the reporter by string in
  reporter: [...]. Put globalSetup / globalTeardown under tests/ (e.g.
  './tests/e2e/playwright.setup.ts') and keep testDir under tests/.

──────────────────────────
What was wrong:
──────────────────────────
File: $file_path
$offenders

The orchestrator runs \`npx playwright test\`, which executes this config and
every file it names. A config that imports or points into src/** runs project
code under the orchestrator, outside every role's read scope.

References:
  skills/onboarding/SKILL.md (Phase 1 scaffold)
  skills/achilles-protocol/references/known-limits.md (KL-03)"

"$JQ" -n --arg r "$reason$(achilles_scope_notice)" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
