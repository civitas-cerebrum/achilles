# harness-os.sh — shared kernel library for the harness OS role gate.
#
# CANONICAL HOME: github.com/civitas-cerebrum/harness-os
# Copies of this file in consumer repos (e.g. achilles) are vendored
# verbatim — edit upstream, then run the consumer's sync.
#
# The harness OS is the generic role-based operating layer described in
# skills/harness-designer/references/architecture.md: a consumer project
# declares agent roles and their grants in .claude/harness-os.json, and
# hooks/harness-os-role-gate.sh enforces them at tool-call time. This lib
# owns everything the gate needs that is not per-axis policy:
#
#   - activation      (manifest discovery; HARNESS_OS=0 operator kill-switch)
#   - role resolution (the identity ladder: main-session role → cached
#                      binding → parent_tool_use_id → transcript tag →
#                      registry claim → unbound policy)
#   - glob matching   (manifest path scopes → POSIX ERE)
#   - state           (dispatch registry, agent bindings, decision log)
#   - deny emission   (repo-standard permissionDecision JSON)
#
# Deliberately NOT sourced: lib/achilles-activation.sh. The achilles
# activation lib scopes the METHODOLOGY gates to methodology sessions;
# the harness OS scopes itself by manifest presence in the project. The
# two compose but neither depends on the other.
#
# Caller contract
# ---------------
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/harness-os.sh"
#   harness_os_load "$INPUT" || exit 0     # inactive project → silent allow
#   harness_os_resolve_role                # sets HOS_ROLE / HOS_ROLE_STATE
#
# Globals set by harness_os_load:
#   HOS_JQ HOS_INPUT HOS_CWD HOS_ROOT HOS_MANIFEST HOS_MANIFEST_JSON
#   HOS_MANIFEST_BROKEN HOS_STATE_DIR HOS_TOOL HOS_AGENT_ID
#   HOS_TOOL_USE_ID HOS_PARENT_TOOL_USE_ID HOS_TRANSCRIPT HOS_TTL
# Globals set by harness_os_resolve_role:
#   HOS_ROLE        role name ('' when none applies)
#   HOS_ROLE_STATE  governed | ungoverned | unbound
#
# Test seams (env):
#   HARNESS_OS          0|false|off → inactive (operator kill-switch; set
#                       in the OPERATOR's shell before launching the
#                       session — agents cannot alter hook env from inside)
#   HARNESS_OS_MANIFEST explicit manifest path (bypasses discovery)
#   HARNESS_OS_STATE_DIR explicit state dir

HOS_ROLE_TAG_RE='<<harness-os-role: [a-z][a-z0-9-]*>>'

harness_os__jq() {
  if [ -n "${JQ:-}" ] && [ -x "${JQ:-}" ]; then printf '%s' "$JQ"; return 0; fi
  local candidate
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/jq"
  if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  command -v jq || true
}

# harness_os_load <input-json>
# Returns 1 (caller should silent-allow) when the harness OS is not in
# play: kill-switch set, no manifest found, or unknown manifest version.
# A PRESENT but unparseable manifest is a distinct state (fail closed):
# HOS_MANIFEST_BROKEN=1 and the function returns 0 so the gate can deny
# mutating tools while leaving the read path open for repair.
harness_os_load() {
  HOS_INPUT="$1"
  HOS_JQ="$(harness_os__jq)"
  [ -n "$HOS_JQ" ] || return 1

  case "${HARNESS_OS:-}" in
    0|false|off) return 1 ;;
  esac

  HOS_TOOL=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
  HOS_CWD=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
  HOS_AGENT_ID=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
  HOS_TOOL_USE_ID=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.tool_use_id // empty' 2>/dev/null || echo "")
  HOS_PARENT_TOOL_USE_ID=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.parent_tool_use_id // empty' 2>/dev/null || echo "")
  HOS_TRANSCRIPT=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.transcript_path // empty' 2>/dev/null || echo "")

  HOS_ROOT=$(cd "$HOS_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$HOS_CWD")

  if [ -n "${HARNESS_OS_MANIFEST:-}" ]; then
    HOS_MANIFEST="$HARNESS_OS_MANIFEST"
  else
    HOS_MANIFEST="$HOS_ROOT/.claude/harness-os.json"
  fi
  [ -f "$HOS_MANIFEST" ] || return 1

  HOS_MANIFEST_BROKEN=0
  HOS_MANIFEST_JSON=$(cat "$HOS_MANIFEST" 2>/dev/null || echo "")
  if ! printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -e 'type == "object" and (.roles | type == "object")' >/dev/null 2>&1; then
    HOS_MANIFEST_BROKEN=1
    HOS_MANIFEST_JSON="{}"
  else
    local version
    version=$(printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -r '.harnessOsVersion // empty' 2>/dev/null || echo "")
    # Unknown future version: this kernel cannot enforce grants it does
    # not understand — treat as inactive rather than half-enforce.
    [ "$version" = "1" ] || return 1
  fi

  HOS_STATE_DIR="${HARNESS_OS_STATE_DIR:-$HOS_ROOT/.claude/harness-os.state}"
  HOS_TTL=$(printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -r '.settings.dispatchTtlSeconds // 1800' 2>/dev/null || echo 1800)
  case "$HOS_TTL" in ''|*[!0-9]*) HOS_TTL=1800 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# Role resolution ladder
# ---------------------------------------------------------------------------

harness_os__sanitize_id() {
  printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_'
}

harness_os__binding_file() {
  printf '%s/agents/%s' "$HOS_STATE_DIR" "$(harness_os__sanitize_id "$1")"
}

harness_os__role_exists() {
  printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -e --arg r "$1" '.roles[$r] | type == "object"' >/dev/null 2>&1
}

# harness_os__bind <agent_id> <role> — persist the binding (atomic, best-effort).
harness_os__bind() {
  local file
  file="$(harness_os__binding_file "$1")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  printf '%s\n' "$2" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || rm -f "$file.tmp" 2>/dev/null || true
}

# harness_os__registry_claim <agent_id>
# Prints a role name iff every fresh, unclaimed dispatch-registry entry
# names the SAME role (unambiguous), and marks the oldest such entry
# claimed by this agent. Mixed roles in flight → prints nothing.
harness_os__registry_claim() {
  local agent_id="$1" reg="$HOS_STATE_DIR/dispatch-registry.json" now existing distinct role
  [ -f "$reg" ] || return 0
  now=$(date +%s)
  existing=$(cat "$reg" 2>/dev/null || echo "{}")
  printf '%s' "$existing" | "$HOS_JQ" -e 'type == "object"' >/dev/null 2>&1 || return 0

  distinct=$(printf '%s' "$existing" | "$HOS_JQ" -r --argjson now "$now" --argjson ttl "$HOS_TTL" '
    [ to_entries[]
      | select((.value.ts // 0) >= ($now - $ttl))
      | select((.value.claimed_by // "") == "")
      | .value.role ] | unique | if length == 1 then .[0] else empty end
  ' 2>/dev/null || echo "")
  [ -n "$distinct" ] || return 0
  role="$distinct"

  local updated
  updated=$(printf '%s' "$existing" | "$HOS_JQ" -c --argjson now "$now" --argjson ttl "$HOS_TTL" --arg who "$agent_id" '
    ( [ to_entries[]
        | select((.value.ts // 0) >= ($now - $ttl))
        | select((.value.claimed_by // "") == "")
        | .key ] | sort_by(.) | first ) as $victim
    | if $victim == null then . else .[$victim].claimed_by = $who end
  ' 2>/dev/null || echo "")
  if [ -n "$updated" ]; then
    printf '%s' "$updated" > "$reg.tmp" 2>/dev/null && mv "$reg.tmp" "$reg" 2>/dev/null || rm -f "$reg.tmp" 2>/dev/null || true
  fi
  printf '%s' "$role"
}

harness_os_resolve_role() {
  HOS_ROLE=""
  HOS_ROLE_STATE="ungoverned"

  # Rung 1 — no agent_id: this is the top-level session.
  if [ -z "$HOS_AGENT_ID" ]; then
    HOS_ROLE=$(printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -r '.settings.mainSessionRole // empty' 2>/dev/null || echo "")
    if [ -n "$HOS_ROLE" ] && harness_os__role_exists "$HOS_ROLE"; then
      HOS_ROLE_STATE="governed"
    else
      HOS_ROLE=""
      HOS_ROLE_STATE="ungoverned"
    fi
    return 0
  fi

  # Rung 2 — cached binding for this agent_id.
  local binding
  binding="$(harness_os__binding_file "$HOS_AGENT_ID")"
  if [ -f "$binding" ]; then
    HOS_ROLE=$(head -n1 "$binding" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$HOS_ROLE" ] && harness_os__role_exists "$HOS_ROLE"; then
      HOS_ROLE_STATE="governed"
      return 0
    fi
    HOS_ROLE=""
  fi

  # Rung 3 — parent_tool_use_id → exact registry match (older builds).
  if [ -n "$HOS_PARENT_TOOL_USE_ID" ] && [ -f "$HOS_STATE_DIR/dispatch-registry.json" ]; then
    HOS_ROLE=$("$HOS_JQ" -r --arg id "$HOS_PARENT_TOOL_USE_ID" '.[$id].role // empty' \
      "$HOS_STATE_DIR/dispatch-registry.json" 2>/dev/null || echo "")
    if [ -n "$HOS_ROLE" ] && harness_os__role_exists "$HOS_ROLE"; then
      harness_os__bind "$HOS_AGENT_ID" "$HOS_ROLE"
      HOS_ROLE_STATE="governed"
      return 0
    fi
    HOS_ROLE=""
  fi

  # Rung 4 — transcript tag. Dispatch prompts carry
  # <<harness-os-role: NAME>> (the dispatch gate denies prompts without
  # it). Exactly ONE distinct tag in the transcript → it is the child's
  # own transcript and the tag is its identity. Multiple distinct tags →
  # a parent-wide transcript; ambiguous, fall through.
  if [ -n "$HOS_TRANSCRIPT" ] && [ -f "$HOS_TRANSCRIPT" ]; then
    local tags
    tags=$(grep -oE "$HOS_ROLE_TAG_RE" "$HOS_TRANSCRIPT" 2>/dev/null | sort -u || echo "")
    if [ -n "$tags" ] && [ "$(printf '%s\n' "$tags" | wc -l | tr -d ' ')" = "1" ]; then
      HOS_ROLE=$(printf '%s' "$tags" | sed -E 's/^<<harness-os-role: ([a-z][a-z0-9-]*)>>$/\1/')
      if [ -n "$HOS_ROLE" ] && harness_os__role_exists "$HOS_ROLE"; then
        harness_os__bind "$HOS_AGENT_ID" "$HOS_ROLE"
        HOS_ROLE_STATE="governed"
        return 0
      fi
      HOS_ROLE=""
    fi
  fi

  # Rung 5 — registry claim (unambiguous single-role in-flight set).
  HOS_ROLE=$(harness_os__registry_claim "$HOS_AGENT_ID")
  if [ -n "$HOS_ROLE" ] && harness_os__role_exists "$HOS_ROLE"; then
    harness_os__bind "$HOS_AGENT_ID" "$HOS_ROLE"
    HOS_ROLE_STATE="governed"
    return 0
  fi

  # Rung 6 — unresolvable: the unboundAgentPolicy governs.
  HOS_ROLE=""
  HOS_ROLE_STATE="unbound"
  return 0
}

# harness_os_register_dispatch <role> <tool_use_id>
# Records an Agent dispatch in the registry (TTL-pruned, atomic).
harness_os_register_dispatch() {
  local role="$1" id="$2" reg="$HOS_STATE_DIR/dispatch-registry.json" now existing updated
  [ -n "$id" ] || return 0
  mkdir -p "$HOS_STATE_DIR" 2>/dev/null || return 0
  now=$(date +%s)
  existing="{}"
  if [ -f "$reg" ]; then
    existing=$(cat "$reg" 2>/dev/null || echo "{}")
    printf '%s' "$existing" | "$HOS_JQ" -e 'type == "object"' >/dev/null 2>&1 || existing="{}"
  fi
  updated=$(printf '%s' "$existing" | "$HOS_JQ" -c \
    --arg id "$id" --arg role "$role" --argjson now "$now" --argjson ttl "$HOS_TTL" '
      . as $reg
      | reduce keys[] as $k ({};
          if ($reg[$k].ts // 0) >= ($now - $ttl) then . + { ($k): $reg[$k] } else . end)
      | . + { ($id): { role: $role, ts: $now } }
    ' 2>/dev/null || echo "")
  if [ -n "$updated" ]; then
    printf '%s' "$updated" > "$reg.tmp" 2>/dev/null && mv "$reg.tmp" "$reg" 2>/dev/null || rm -f "$reg.tmp" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Glob → ERE path matching
# ---------------------------------------------------------------------------
# Manifest scope semantics: '**' crosses directory boundaries, '*' stays
# within one, '?' is a single non-/ char. 'docs/**' matches docs itself
# AND everything under it; '**/x' matches x at any depth including root.

harness_os_glob_to_ere() {
  local g="$1" ph=$'\001'
  g=$(printf '%s' "$g" | sed -e 's/[.[\]()+{}^$|\\]/\\&/g')
  g="${g//\*\*/$ph}"
  g="${g//\*/[^/]*}"
  g="${g//\?/[^/]}"
  g=$(printf '%s' "$g" | sed \
    -e "s|/${ph}\$|(/.*)?|" \
    -e "s|^${ph}/|(.*/)?|" \
    -e "s|/${ph}/|/(.*/)?|g" \
    -e "s|${ph}|.*|g")
  printf '^%s$' "$g"
}

# harness_os_relpath <path> — repo-root-relativise. Paths outside the
# root stay absolute (they then only match absolute-anchored patterns).
harness_os_relpath() {
  local p="$1"
  case "$p" in
    "$HOS_ROOT") printf '.' ; return 0 ;;
    "$HOS_ROOT"/*) p="${p#"$HOS_ROOT"/}" ;;
    /*) : ;;
    ./*) p="${p#./}" ;;
  esac
  printf '%s' "$p"
}

# harness_os_path_in_scope <relpath> <patterns-json-array>
# 0 when relpath matches at least one glob in the JSON array.
harness_os_path_in_scope() {
  local rel="$1" patterns="$2" glob ere
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    ere=$(harness_os_glob_to_ere "$glob")
    if printf '%s' "$rel" | grep -Eq "$ere"; then return 0; fi
  done < <(printf '%s' "$patterns" | "$HOS_JQ" -r '.[]?' 2>/dev/null)
  return 1
}

# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------

harness_os_log() {
  local decision="$1" detail="$2"
  mkdir -p "$HOS_STATE_DIR" 2>/dev/null || return 0
  "$HOS_JQ" -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg role "${HOS_ROLE:-}" \
    --arg state "${HOS_ROLE_STATE:-}" \
    --arg tool "${HOS_TOOL:-}" \
    --arg decision "$decision" \
    --arg detail "$detail" \
    '{ts: $ts, role: $role, roleState: $state, tool: $tool, decision: $decision, detail: $detail}' \
    >> "$HOS_STATE_DIR/decision-log.jsonl" 2>/dev/null || true
}

# harness_os_deny <short-detail-for-log> <reason>
# Emits the repo-standard deny JSON and exits 0.
harness_os_deny() {
  harness_os_log "deny" "$1"
  "$HOS_JQ" -n --arg r "$2" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
  exit 0
}

# harness_os_role_field <role> <jq-path-expression>
# Prints the JSON value at .roles[<role>]<expr> (compact) or "null".
harness_os_role_field() {
  printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -c --arg r "$1" ".roles[\$r]$2 // null" 2>/dev/null || echo "null"
}
