# achilles-project-gate.sh — project-scope gate for the agentic-OS hook
# family. The harness hooks are installed globally (~/.claude/hooks) and
# therefore fire in EVERY Claude Code session; the achilles methodology
# must only be enforced in projects that actually use achilles. This lib
# is the single answer to "is this an achilles project?" — sourced by the
# agentic-OS hooks (registrar, privilege guard, user-exec) so they no-op
# everywhere else instead of policing unrelated repos.
#
# The legacy pipeline hooks self-scope by artifact (they key on ledger
# files, spec paths, playwright-cli invocations); new hooks with a
# broader firing surface must call this gate explicitly.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/agentic-os-roles.md §"Project scoping"

# achilles_hooks_active <repo-root>
#
# Returns 0 iff <repo-root> is an achilles project:
#   - the package is installed (node_modules/@civitas-cerebrum/achilles), or
#   - package.json depends on @civitas-cerebrum/achilles or
#     @civitas-cerebrum/element-interactions (covers pre-install and the
#     harness repo itself), or
#   - achilles pipeline surfaces exist (tests/e2e/docs, tests/perf/docs,
#     .achilles).
achilles_hooks_active() {
  local root="$1"
  [ -n "$root" ] || return 1
  [ -d "$root/node_modules/@civitas-cerebrum/achilles" ] && return 0
  [ -d "$root/.achilles" ] && return 0
  [ -d "$root/tests/e2e/docs" ] && return 0
  [ -d "$root/tests/perf/docs" ] && return 0
  if [ -f "$root/package.json" ] \
    && grep -qE '@civitas-cerebrum/(achilles|element-interactions)' "$root/package.json" 2>/dev/null; then
    return 0
  fi
  return 1
}
