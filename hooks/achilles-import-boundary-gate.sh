#!/bin/bash
# achilles-import-boundary-gate.sh — code the orchestrator's playwright run loads stays inside tests/.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY (root playwright*.config.ts, root package.json or any file under
#           tests/ whose post-write content reaches outside tests/; DENY also
#           when the screen cannot run)
# State   : none
#
# A static floor, not a sandbox: the scanner parses with @babel/parser, and a
# file that does not parse, a construct it cannot evaluate, or a scan over its
# time budget is a deny.
#
# Rule
# ----
# Root playwright*.config.ts: imports only @playwright/test,
# @civitas-cerebrum/element-interactions, dotenv, dotenv/config and path/url
# (bare or node:), plus relative files under tests/. The exported config must
# be an object literal (or defineConfig of them). globalSetup, globalTeardown,
# testDir and file reporters, wherever they appear as properties, evaluate
# statically from string literals and path helpers to paths under tests/.
# Computed keys, member assignment of those keys, object spreads other than
# ...devices[…], and eval / Function / process.binding / module.constructor
# are denied.
# Every file under tests/, whatever its extension (node's CJS loader runs any
# extension as JS): every loader call (import, require, require.resolve,
# import(), .require, ._load, createRequire) takes one string literal with no
# escapes; relative ones resolve under tests/ and load code or JSON; no `#`
# imports and no self-reference to the project's package. A non-code file that
# does not parse is prose, unless a code twin makes node load it. package.json
# and tsconfig/jsconfig under tests/ (JSONC) point inside it; tsconfig extends
# and references are denied. No .git file under tests/.
# Root package.json: name, exports and imports do not change.
# Root: $CLAUDE_PROJECT_DIR, else the file's git toplevel unless it sits under a
# tests/ segment, else cwd cut above tests/. Paths compare case-insensitively
# on macOS and Windows. Content over 256KB is denied.
#
# Why
# ---
# `npx playwright test` runs under the orchestrator and executes the config,
# every file it names and every test file with its imports. A path from there
# into src/** is one channel by which project code runs under the orchestrator.
# The kernel cannot give the scaffolder an import list (a role with
# codeImports may not author runner, resolution or environment config at all,
# which is the scaffolder's job), and its codeImports screen lets relative
# specifiers through wherever they point. dotenv stays allowed: wiring .env is
# the Phase 7 design.
#
# Not modelled (known-limits.md KL-03): webServer.command,
# use.launchOptions.executablePath, the config's tsconfig: key, the root
# tsconfig's paths, NODE_OPTIONS supplied through .env.
#
# Failure → action
# ----------------
# - config import outside the allowlist, unparsable or unreadable → DENY
# - lifecycle path / file reporter outside tests/, or non-literal → DENY
# - tests/** specifier outside tests/, non-literal, #, self-ref,
#   or loading a non-code file                                   → DENY
# - root package.json name / exports / imports changed           → DENY
# - content over 256KB; node missing, scanner failure, no verdict → DENY
# - any other file, Edit of a missing file, non-Write/Edit,
#   protocol inactive                                            → silent allow

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
  url; export an object literal (or defineConfig of one); name reporters by
  package, or by a file under tests/. Build globalSetup / globalTeardown /
  testDir from string literals and path.join / path.resolve /
  require.resolve / __dirname only, under tests/.
  Files under tests/: give every import / require one plain string literal
  (no +, templates or escapes); import relative code or JSON under tests/
  only, never # aliases or the project's own package; shared logic belongs
  in tests/e2e/fixtures/. Code must parse. package.json may change scripts,
  not name / exports / imports.

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

# Cheap prefilter; the scanner resolves the project root and the exact scope.
# Case-insensitive: macOS resolves Tests/ and Playwright.config.ts to the same files.
shopt -s nocasematch
case "$(basename "$file_path")" in
  playwright*.config.ts|package.json) ;;
  *) case "/$file_path" in */tests/*) ;; *) exit 0 ;; esac ;;
esac
shopt -u nocasematch

cwd=$(echo "$input" | "$JQ" -r '.cwd // empty')
[ -n "$cwd" ] || cwd="$PWD"

# An Edit is screened against the file it would produce, so it needs the file.
[ "$tool_name" = "Write" ] || [ -f "$file_path" ] || [ -f "$cwd/$file_path" ] || exit 0

command -v node >/dev/null 2>&1 || emit_deny "config screen could not run: node is not on PATH" "  • the screen needs node to read this file"
err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT
# stderr kept apart: a NODE_OPTIONS warning must not corrupt the verdict.
if ! result=$(printf '%s' "$input" | node "$HOOK_LIB/import-boundary-scan.js" "$file_path" "$cwd" 2>"$err_file"); then
  emit_deny "config screen could not run: the scanner failed" "  • $(tail -1 "$err_file")"
fi
echo "$result" | "$JQ" -e '(.scope | type == "string") and (.offenders | type == "array")' >/dev/null 2>&1 \
  || emit_deny "config screen could not run: the scanner returned no verdict" "  • $(printf '%s' "$result" | head -c 200)"

offenders=$(echo "$result" | "$JQ" -r '.offenders[:6][] | "  • " + .')
[ -n "$offenders" ] || exit 0
scope=$(echo "$result" | "$JQ" -r '.scope')
case "$scope" in
  config)  emit_deny "the runner config reaches outside tests/" "$offenders" ;;
  package) emit_deny "package.json would change what a bare or # specifier resolves to" "$offenders" ;;
  *)       emit_deny "a file under tests/ reaches outside tests/" "$offenders" ;;
esac
