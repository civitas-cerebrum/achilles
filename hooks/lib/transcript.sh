#!/bin/bash
# transcript.sh — scans of the session transcript (JSONL) the stop/write gates run.
# Needs JQ (hook_jq_init). Each takes the transcript path as $1 and fails soft
# (empty output) on an unreadable file.

# transcript_last_spec_write_line <t> — transcript line of the last Write/Edit of a spec-shaped file.
transcript_last_spec_write_line() {
  "$JQ" -r '
    (input_line_number) as $n |
    if (.message?.content? | type) == "array" then
      .message.content[]
      | select(.type? == "tool_use")
      | select(.name? == "Write" or .name? == "Edit")
      | (.input.file_path // "")
      | select(test("\\.(spec|test|setup)\\.(m|c)?(t|j)sx?$"))
      | "\($n)"
    else empty end
  ' "$1" 2>/dev/null | tail -1
}

# transcript_last_sweep_line <t> — transcript line of the last assistant prose naming the compliance sweep.
transcript_last_sweep_line() {
  "$JQ" -r '
    (input_line_number) as $n |
    if (.message?.content? | type) == "array" then
      .message.content[]
      | select(.type? == "text")
      | (.text // "")
      | select(test("api compliance review|stage=4b|compliance sweep"; "i"))
      | "\($n)"
    else empty end
  ' "$1" 2>/dev/null | tail -1
}

# transcript_spec_write_files <t> — up to 8 spec files written, indented for a deny message.
transcript_spec_write_files() {
  "$JQ" -r '
    if (.message?.content? | type) == "array" then
      .message.content[]
      | select(.type? == "tool_use")
      | select(.name? == "Write" or .name? == "Edit")
      | (.input.file_path // "")
      | select(test("\\.(spec|test|setup)\\.(m|c)?(t|j)sx?$"))
    else empty end
  ' "$1" 2>/dev/null | sort -u | head -8 | sed 's/^/    /'
}

# transcript_tool_uses <t> — one "<SKILL|READ|BASH|AGENT> <value>" line per tool_use.
transcript_tool_uses() {
  "$JQ" -r '
    if (.message? | type) == "object" and (.message.content? | type) == "array" then
      .message.content[] |
        select(.type? == "tool_use") |
        (
          (select(.name? == "Skill") | "SKILL " + (.input.skill // "")),
          (select(.name? == "Read")  | "READ "  + (.input.file_path // "")),
          (select(.name? == "Bash")  | "BASH "  + (.input.command // "")),
          (select(.name? == "Agent") | "AGENT " + (.input.description // ""))
        )
    else empty end
  ' "$1" 2>/dev/null || true
}

# transcript_skill_read_targets <t> — the Skill names and Read paths, one per line.
transcript_skill_read_targets() {
  "$JQ" -r '
    if (.message? | type) == "object" and (.message.content? | type) == "array" then
      .message.content[] |
        select(.type? == "tool_use") |
        (
          (select(.name? == "Skill") | (.input.skill // "") ),
          (select(.name? == "Read")  | (.input.file_path // "") )
        )
    else empty end
  ' "$1" 2>/dev/null
}
