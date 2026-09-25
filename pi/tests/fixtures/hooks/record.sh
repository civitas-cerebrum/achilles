#!/bin/bash
# Appends the payload as one line to $HOOK_RECORD_FILE (set by the test).
IN=$(cat)
printf '%s\n' "$IN" >> "${HOOK_RECORD_FILE:-/dev/null}"
