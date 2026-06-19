# reviewer-prefix.sh — single source of truth for approver-role detection.
# is_reviewer_description <description> → 0 when the description carries an
# approver-role prefix (workflow-reviewer-*, phase-validator-*, or
# perf-reviewer-*).
is_reviewer_description() {
  echo "$1" | grep -qE '^[[:space:]]*(workflow-reviewer-[a-z0-9-]+|phase-validator-[0-9]+|perf-reviewer-[a-z0-9-]+)[:_-]'
}
