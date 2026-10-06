#!/bin/bash
# hook-io.sh — jq bootstrap and hook-input access shared by every Achilles hook.

# hook_jq_init <fatal|silent|empty|continue> — set JQ (bundled, else PATH); when
# neither exists, act per the hook's contract:
#   fatal    stderr message, exit 1 (Claude Code treats it as a non-blocking error)
#   silent   exit 0
#   empty    print {} and exit 0 (summary writers)
#   continue return with JQ empty (hook tolerates failing jq calls)
hook_jq_init() {
  local caller; caller="$(basename "${BASH_SOURCE[1]}")"
  JQ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/jq"
  [ -x "$JQ" ] || JQ="$(command -v jq || true)"
  [ -n "$JQ" ] && return 0
  case "$1" in
    fatal)  echo "[$caller] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH. Reinstall the package or install jq manually." >&2; exit 1 ;;
    silent) exit 0 ;;
    empty)  printf '{}\n'; exit 0 ;;
  esac
}

# hook_read_input — INPUT holds the whole hook payload.
hook_read_input() { INPUT=$(cat); }

# hook_field <jq-path> — e.g. hook_field .tool_input.file_path
hook_field() { printf '%s' "$INPUT" | "$JQ" -r "$1 // empty" 2>/dev/null || true; }
