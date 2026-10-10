#!/bin/bash
# plumber-audit-log.sh — record every tool call the approved plumber makes.
#
# Hook    : PostToolUse:Bash|Write|Edit
# Mode    : RECORD (never blocks)
# State   : <project>/.claude/achilles/plumber-log.jsonl (append-only; the plumber cannot write it)
# Env     : none
#
# Why
# ---
# The plumber is exempt from the lock gates. The audit log is the other half of that bargain:
# every file it wrote and every command it ran is on record, next to the user's approval that
# opened the grant. Cheap when no grant is open: plumber_caller_is_plumber checks the grant
# before it asks the kernel for the caller's role.
#
# Canonical reference: skills/achilles-protocol/references/harness-hooks.md §"Plumber"

set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_jq_init silent
hook_read_input
hook_lib achilles-activation.sh plumber.sh

case "$(hook_field .tool_name)" in Bash|Write|Edit) ;; *) exit 0 ;; esac
plumber_caller_is_plumber "$INPUT" || exit 0
plumber_audit "$INPUT" tool-call
exit 0
