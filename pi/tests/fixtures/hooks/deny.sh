#!/bin/bash
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] nope\n\nReferences:\n  skills/orch-skill/SKILL.md"}}'
