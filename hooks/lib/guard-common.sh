#!/bin/bash
# guard-common.sh — shared primitives for path-matching DENY guards.
#
# Library  : sourced by other hooks; not registered in the manifest.
# Mode     : N/A (pure helpers, no side effects)
# State    : none
# Env      : GUARD_COMMON_SELFTEST=1 → run the built-in self-test and exit
#
# Why
# ---
# Two failure classes recurred across the path-matching guards:
#
#   1. Path-normalisation bypass. A guard that matches the raw `file_path`
#      with a `case */.claude/settings.json)` glob is defeated by any
#      path that resolves to the same file without the literal substring:
#        /home/u/.claude/./settings.json      (dot segment)
#        /home/u/.claude//settings.json       (double slash)
#        /home/u/.claude/hooks/../settings.json  (parent segment)
#      The Write/Edit tools resolve `.`, `//`, and `..` before writing, so
#      the file lands on the protected target while the glob misses. Every
#      such guard must match on a LEXICALLY NORMALISED path.
#
#   2. Fail-open on missing jq. A DENY guard that does `exit 1` when jq is
#      absent fails OPEN — in the Claude Code hook protocol only exit code
#      2 (or an explicit deny decision) blocks a PreToolUse call; any other
#      non-zero exit is a non-blocking error and the tool proceeds. So
#      deleting the bundled jq disables every guard that keys its block on
#      jq being present. Security-critical guards must fail CLOSED.
#
# This library centralises the fix for both.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/harness-hooks.md

# normalize_path <path>
# Lexically normalise a filesystem path WITHOUT touching the filesystem:
#   - force a single leading slash (so a bare relative path compares the
#     same as its absolute form)
#   - collapse repeated slashes
#   - drop "." segments
#   - resolve ".." against the preceding segment
# Prints the normalised path on stdout. Purely lexical (does NOT resolve
# symlinks) — that is the correct semantic for a guard: we want to know
# which file the write LANDS on, matching how the Write tool resolves the
# path, not where a symlink might redirect it. Implemented with parameter
# expansion only (no word-splitting) so paths containing shell globs
# (`*`, `?`, `[`) are handled literally.
normalize_path() {
  local p="/${1#/}"
  local -a out=()
  local seg remainder="${p#/}"
  while [ -n "$remainder" ]; do
    seg="${remainder%%/*}"
    if [ "$seg" = "$remainder" ]; then
      remainder=""
    else
      remainder="${remainder#*/}"
    fi
    case "$seg" in
      ''|.) ;;
      ..) [ "${#out[@]}" -gt 0 ] && out=("${out[@]:0:${#out[@]}-1}") ;;
      *) out+=("$seg") ;;
    esac
  done
  if [ "${#out[@]}" -eq 0 ]; then
    printf '/'
  else
    local joined
    printf -v joined '/%s' "${out[@]}"
    printf '%s' "$joined"
  fi
}

# guard_emit_deny_no_jq <hook-label>
# Emit a minimal PreToolUse deny decision as raw JSON (no jq required) and
# return 0. Callers use this to FAIL CLOSED when jq cannot be resolved:
#
#   [ -n "$JQ" ] || { guard_emit_deny_no_jq "my-guard"; exit 0; }
#
# The payload is a static, well-formed JSON object — no interpolation of
# untrusted input — so it needs no escaping engine.
guard_emit_deny_no_jq() {
  local label="${1:-guard}"
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] The '"${label}"' harness guard cannot run because jq is not available (neither the bundled ~/.claude/hooks/bin/jq nor a system jq on PATH). This guard protects pipeline-state integrity and fails CLOSED rather than allow an unchecked write. Fix: reinstall @civitas-cerebrum/achilles (restores the bundled jq) or install jq on PATH, then retry."}}'
}

# --- self-test ----------------------------------------------------------------
# Run as `GUARD_COMMON_SELFTEST=1 bash hooks/lib/guard-common.sh`.
if [ "${GUARD_COMMON_SELFTEST:-0}" = "1" ]; then
  fail=0
  check() {
    local got exp="$2"
    got="$(normalize_path "$1")"
    if [ "$got" = "$exp" ]; then
      echo "ok   normalize_path '$1' -> '$got'"
    else
      echo "FAIL normalize_path '$1' -> '$got' (expected '$exp')"
      fail=1
    fi
  }
  check "/home/u/.claude/settings.json"            "/home/u/.claude/settings.json"
  check "/home/u/.claude/./settings.json"          "/home/u/.claude/settings.json"
  check "/home/u/.claude//settings.json"           "/home/u/.claude/settings.json"
  check "/home/u/.claude/hooks/../settings.json"   "/home/u/.claude/settings.json"
  check ".claude/hooks/x.sh"                        "/.claude/hooks/x.sh"
  check "tests/e2e//docs/./onboarding-status.json" "/tests/e2e/docs/onboarding-status.json"
  check "a/b/c/../../d"                             "/a/d"
  check "/*/glob/[weird]/path"                      "/*/glob/[weird]/path"
  check "/"                                         "/"
  if [ "$fail" = "0" ]; then echo "guard-common self-test: all passed"; exit 0; else exit 1; fi
fi
