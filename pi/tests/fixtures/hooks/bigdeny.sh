#!/bin/bash
cat >/dev/null
BIG=$(head -c 120000 /dev/zero | tr '\0' 'x')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$BIG"
