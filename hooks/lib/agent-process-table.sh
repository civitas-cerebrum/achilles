# agent-process-table.sh — shared process-table access + actor-role
# resolution for the agentic-OS hook family:
#
#   agent-role-privilege-guard.sh  (PreToolUse:Bash|Agent — capability check)
#   agentic-user-exec.sh           (PreToolUse:Bash — role-user execution)
#
# Both hooks must resolve "which role is this tool call executing as?"
# identically — drift would let the privilege guard enforce one role while
# the exec rewriter drops privileges to another. This lib owns the table
# read and the resolution ladder; lib/agent-role-privileges.sh owns the
# role → privilege mapping. Callers must have $JQ resolved and must have
# sourced lib/agent-role-privileges.sh before calling into this file.
#
# Resolution ladder (documented in agentic-os-roles.md §"Role resolution"):
#   1. parent_tool_use_id → live process-table entry (exact).
#   2. -s=<slug> role claim (same prefix vocabulary as descriptions).
#   3. Exactly one live role class in the table → that role.
#   4. Multiple live role classes → intersection (deny only what ALL deny).
#   5. Empty/absent table → unconfined (fail-open).
#
# Canonical reference
# -------------------
# skills/element-interactions/references/agentic-os-roles.md

APT_TTL_SECONDS=1800  # matches agentic-process-registrar.sh

# apt_load_live <repo-root>
#
# Loads the live (TTL-filtered) process-table slice into APT_LIVE (a JSON
# object string) and APT_LIVE_COUNT. Absent/malformed table → {} / 0.
apt_load_live() {
  local table_file="$1/.achilles/.agent-process-table.json"
  local now
  now=$(date +%s)
  APT_LIVE="{}"
  if [ -f "$table_file" ]; then
    APT_LIVE=$("$JQ" -c --argjson now "$now" --argjson ttl "$APT_TTL_SECONDS" '
      if type == "object"
        then with_entries(select((.value.ts // 0) >= ($now - $ttl)))
        else {}
      end
    ' "$table_file" 2>/dev/null || echo "{}")
    echo "$APT_LIVE" | "$JQ" -e 'type == "object"' >/dev/null 2>&1 || APT_LIVE="{}"
  fi
  APT_LIVE_COUNT=$(echo "$APT_LIVE" | "$JQ" -r 'length' 2>/dev/null || echo 0)
}

# apt_extract_slug <command>
#
# Prints the first `-s=<slug>` / `-s <slug>` session slug in <command>,
# or nothing.
apt_extract_slug() {
  local slug
  slug=$(echo "$1" | grep -oE -- '-s=[A-Za-z0-9_.-]+' | head -1 | sed 's/^-s=//' || true)
  if [ -z "$slug" ]; then
    slug=$(echo "$1" | grep -oE -- '-s[[:space:]]+[A-Za-z0-9_.-]+' | head -1 | sed -E 's/^-s[[:space:]]+//' || true)
  fi
  [ -n "$slug" ] && printf '%s' "$slug"
  return 0
}

# apt_resolve_actor <parent-tool-use-id> <claimed-slug>
#
# Requires apt_load_live to have run. Sets:
#   ACTOR_ROLE   — resolved role name, "unconfined", or the synthetic
#                  "ambiguous(<roles>)" for the intersection fallback.
#   ACTOR_DENIED — space-separated denied classes for ACTOR_ROLE (the
#                  all-deny intersection in the ambiguous case).
#   ACTOR_EXACT  — 1 when resolution was exact (ladder step 1 or 2 or a
#                  single live role), 0 for intersection / unconfined.
#                  Consumers that need a POSITIVE identity (e.g. the exec
#                  rewriter choosing an OS user) require ACTOR_EXACT=1;
#                  the deny-only guard also accepts the intersection.
apt_resolve_actor() {
  local parent_id="$1" claimed_slug="$2"
  ACTOR_EXACT=0

  # (1) Exact: parent_tool_use_id → live table entry.
  if [ -n "$parent_id" ] && [ "${APT_LIVE_COUNT:-0}" -gt 0 ]; then
    local hit
    hit=$(echo "$APT_LIVE" | "$JQ" -r --arg id "$parent_id" '.[$id].role // empty' 2>/dev/null || echo "")
    if [ -n "$hit" ]; then
      ACTOR_ROLE="$hit"
      ACTOR_DENIED=$(role_denied_classes "$hit")
      ACTOR_EXACT=1
      return 0
    fi
  fi

  # (2) Role claim via the -s=<slug> session flag.
  if [ -n "$claimed_slug" ]; then
    local slug_role
    if slug_role=$(resolve_privilege_role "$claimed_slug"); then
      ACTOR_ROLE="$slug_role"
      ACTOR_DENIED=$(role_denied_classes "$slug_role")
      ACTOR_EXACT=1
      return 0
    fi
  fi

  # (3)/(4)/(5) Liveness fallback.
  if [ "${APT_LIVE_COUNT:-0}" -eq 0 ]; then
    ACTOR_ROLE="unconfined"
    ACTOR_DENIED=""
    return 0
  fi
  local roles
  roles=$(echo "$APT_LIVE" | "$JQ" -r '[.[].role] | unique | join(" ")' 2>/dev/null || echo "")
  # shellcheck disable=SC2086
  set -- $roles
  if [ "$#" -eq 1 ]; then
    ACTOR_ROLE="$1"
    ACTOR_DENIED=$(role_denied_classes "$1")
    ACTOR_EXACT=1
    return 0
  fi
  # Intersection: a class survives only if every live process denies it.
  local class kept=""
  for class in payload-ingest mutate browser dispatch remote-push; do
    local all=1 r
    for r in "$@"; do
      role_denies_class "$r" "$class" || { all=0; break; }
    done
    [ "$all" -eq 1 ] && kept="$kept $class"
  done
  ACTOR_ROLE="ambiguous($roles)"
  ACTOR_DENIED="${kept# }"
  return 0
}
