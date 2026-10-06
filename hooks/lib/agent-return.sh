#!/bin/bash
# agent-return.sh — the text of a subagent's return, from a PostToolUse:Agent payload.
# Needs JQ (hook_jq_init) and INPUT (hook_read_input).
#
# One function, three variants, because the three consumers accept different
# tool_response shapes; unifying them would change which returns they see.

# _agent_return_primary — output/result/string, de-duplicated; shared by schema-guard and attestation.
_agent_return_primary() {
  echo "$INPUT" | "$JQ" -r '
    [
      (.tool_response.output? | if type == "array" then map(.text? // (. | tostring)) | join("\n") elif type == "string" then . else (. | tostring) end),
      (.tool_response.result? // empty | tostring),
      (if (.tool_response | type) == "string" then .tool_response else empty end)
    ] | map(select(. != null and . != "")) | unique | join("\n")
  ' 2>/dev/null || echo ""
}

# agent_return_text <schema-guard|attestation|judge>
#   schema-guard  output/result/string; falls back to the stringified response.
#   attestation   output/result/string (no fallback).
#   judge         output/content/string, newline-joined, not de-duplicated.
agent_return_text() {
  case "$1" in
    schema-guard)
      local text
      text=$(_agent_return_primary)
      if [ -z "$text" ]; then
        text=$(echo "$INPUT" | "$JQ" -r '
          if (.tool_response // null) == null then ""
          elif (.tool_response | type) == "string" then .tool_response
          else (.tool_response | tostring)
          end
        ' 2>/dev/null || echo "")
      fi
      printf '%s' "$text"
      ;;
    attestation) _agent_return_primary ;;
    judge)
      printf '%s' "$INPUT" | "$JQ" -r '
        [
          (.tool_response.output? | if type == "array" then map(.text? // (. | tostring)) | join("\n") elif type == "string" then . else (. | tostring) end),
          (.tool_response.content? // empty | if type == "array" then map(.text? // (. | tostring)) | join("\n") else (. | tostring) end),
          (if (.tool_response | type) == "string" then .tool_response else empty end)
        ] | map(select(. != null and . != "null")) | join("\n")
      ' 2>/dev/null || echo ""
      ;;
  esac
}
