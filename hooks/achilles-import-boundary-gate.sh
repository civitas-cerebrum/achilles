#!/bin/bash
# achilles-import-boundary-gate.sh — code the orchestrator's playwright run loads stays inside tests/.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY (root playwright*.config.ts or tests/** code whose post-write
#           content reaches outside tests/; DENY also when the screen cannot run)
# State   : none
#
# Rule
# ----
# Root playwright*.config.ts: imports only @playwright/test,
# @civitas-cerebrum/element-interactions, dotenv, dotenv/config and path/url
# (bare or node:), plus relative files under tests/. globalSetup,
# globalTeardown, testDir and file reporters resolve under tests/ and are built
# from string literals and path helpers only. A require/import(), computed key
# or reflective call the screen cannot read is denied.
# tests/** code: every relative import/require/import() resolves under tests/.
# Bare package specifiers there are the kernel's codeImports screen.
#
# Why
# ---
# `npx playwright test` runs under the orchestrator and executes the config,
# every file it names and every test file with its imports. A path from there
# into src/** is one channel by which project code runs under the orchestrator.
# The kernel cannot give the scaffolder an import list (a role with
# codeImports may not author runner, resolution or environment config at all,
# which is the scaffolder's job), and its codeImports screen lets relative
# specifiers through wherever they point. dotenv stays allowed: wiring .env is the Phase 7 design.
#
# Not modelled: webServer.command (arbitrary shell; known-limits.md KL-03),
# tsconfig `paths` aliasing. A static floor, not a sandbox.
#
# Failure → action
# ----------------
# - config import outside the allowlist                         → DENY
# - lifecycle path / file reporter outside tests/, or non-literal → DENY
# - tests/** relative import outside tests/                     → DENY
# - node missing, scanner failure, no verdict                   → DENY
# - any other file, Edit of a missing file, non-Write/Edit,
#   protocol inactive                                           → silent allow

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

emit_deny() {
  local reason="[BLOCKED] achilles-import-boundary-gate: $1

──────────────────────────
Do this instead:
──────────────────────────
  Runner config (root playwright*.config.ts): import only @playwright/test,
  @civitas-cerebrum/element-interactions, dotenv / dotenv/config and path /
  url; name reporters by package, or by a file under tests/. Build
  globalSetup / globalTeardown / testDir from string literals and
  path.join / path.resolve / require.resolve / __dirname only, under tests/.
  Comments are screened as code: drop comments that name require,
  globalSetup, globalTeardown or testDir.
  Test code (tests/**): import relative files under tests/ only; shared
  logic the suite needs belongs in tests/e2e/fixtures/.

──────────────────────────
What was wrong:
──────────────────────────
File: $file_path
$2

The orchestrator runs \`npx playwright test\`, which executes the config,
every file it names and every test file with its imports. A path from there
into src/** runs project code under the orchestrator, outside every role's
read scope.

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
}

tool_name=$(echo "$input" | "$JQ" -r '.tool_name // empty')
file_path=$(echo "$input" | "$JQ" -r '.tool_input.file_path // empty')
case "$tool_name" in Edit|Write) ;; *) exit 0 ;; esac

# Cheap prefilter; the scanner decides the exact scope on resolved paths.
case "$(basename "$file_path")" in
  playwright*.config.ts) ;;
  *.ts|*.js|*.mjs|*.cjs|*.mts|*.cts|*.tsx|*.jsx)
    case "/$file_path" in */tests/*) ;; *) exit 0 ;; esac ;;
  *) exit 0 ;;
esac

root=$(echo "$input" | "$JQ" -r '.cwd // empty')
[ -n "$root" ] || root="$PWD"

# An Edit is screened against the file it would produce, so it needs the file.
[ "$tool_name" = "Write" ] || [ -f "$file_path" ] || [ -f "$root/$file_path" ] || exit 0

command -v node >/dev/null 2>&1 || emit_deny "config screen could not run: node is not on PATH" "  • the screen needs node to read this file"
if ! result=$(printf '%s' "$input" | node "$HOOK_LIB/import-boundary-scan.js" "$file_path" "$root" 2>&1); then
  emit_deny "config screen could not run: the scanner failed" "  • $(printf '%s' "$result" | tail -1)"
fi
echo "$result" | "$JQ" -e '(.scope | type == "string") and (.offenders | type == "array")' >/dev/null 2>&1 \
  || emit_deny "config screen could not run: the scanner returned no verdict" "  • $(printf '%s' "$result" | head -c 200)"

offenders=$(echo "$result" | "$JQ" -r '.offenders[:6][] | "  • " + .')
[ -n "$offenders" ] || exit 0
scope=$(echo "$result" | "$JQ" -r '.scope')
if [ "$scope" = "config" ]; then
  emit_deny "the runner config reaches outside tests/" "$offenders"
fi
emit_deny "test code imports from outside tests/" "$offenders"
