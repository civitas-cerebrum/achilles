#!/bin/bash
# project-root.sh — the project root and rule file every factory gate and the test-id gate read,
# the same resolution as bin/lib/project-root.mjs. Pure bash: it loads with PATH emptied.

# achilles_project_root — $CLAUDE_PROJECT_DIR, else the current directory, without a trailing slash.
achilles_project_root() { local r="${CLAUDE_PROJECT_DIR:-$PWD}"; printf '%s' "${r%/}"; }

# achilles_rules_file <root> — $FACTORY_RULES (absolute, or relative to <root>), else <root>/achilles-factory-rules.json.
achilles_rules_file() {
  local f="${FACTORY_RULES:-achilles-factory-rules.json}"
  case "$f" in /*) printf '%s' "$f";; *) printf '%s/%s' "$1" "$f";; esac
}
