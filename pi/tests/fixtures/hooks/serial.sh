#!/bin/bash
# Records "start <tool_use_id>", sleeps briefly, records "end <tool_use_id>" in $HOOK_RECORD_FILE.
IN=$(cat)
ID=$(printf '%s' "$IN" | sed -n 's/.*"tool_use_id":"\([^"]*\)".*/\1/p')
printf 'start %s\n' "$ID" >> "${HOOK_RECORD_FILE:-/dev/null}"
sleep 0.15
printf 'end %s\n' "$ID" >> "${HOOK_RECORD_FILE:-/dev/null}"
