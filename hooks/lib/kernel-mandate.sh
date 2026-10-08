# kernel-mandate.sh — shared kernel library for the kernel mandate role gate.
#
# CANONICAL HOME: github.com/civitas-cerebrum/kernel-mandate
# Copies of this file in consumer repos (e.g. achilles) are vendored
# verbatim — edit upstream, then run the consumer's sync.
#
# The kernel mandate is the generic role-based operating layer described in
# skills/mandate-designer/references/architecture.md: a consumer project
# declares agent roles and their grants in .claude/kernel-mandate.json, and
# hooks/kernel-mandate-role-gate.sh enforces them at tool-call time. This lib
# owns everything the gate needs that is not per-axis policy:
#
#   - activation      (manifest discovery; KERNEL_MANDATE=0 operator kill-switch)
#   - role resolution (the identity ladder: main-session role → cached
#                      binding → parent_tool_use_id → transcript tag →
#                      registry claim → unbound policy)
#   - glob matching   (manifest path scopes → POSIX ERE)
#   - state           (dispatch registry, agent bindings, decision log)
#   - deny emission   (repo-standard permissionDecision JSON)
#
# Deliberately NOT sourced: lib/achilles-activation.sh. The achilles
# activation lib scopes the METHODOLOGY gates to methodology sessions;
# the kernel mandate scopes itself by manifest presence in the project. The
# two compose but neither depends on the other.
#
# Caller contract
# ---------------
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/kernel-mandate.sh"
#   kernel_mandate_load "$INPUT" || exit 0     # inactive project → silent allow
#   kernel_mandate_resolve_role                # sets KM_ROLE / KM_ROLE_STATE
#
# Globals set by kernel_mandate_load:
#   KM_JQ KM_INPUT KM_CWD KM_ROOT KM_MANIFEST KM_MANIFEST_JSON
#   KM_AGENT_TYPE (host-supplied agent definition name, subagents only)
#   KM_MANIFEST_BROKEN KM_STATE_DIR KM_TOOL KM_AGENT_ID
#   KM_TOOL_USE_ID KM_PARENT_TOOL_USE_ID KM_TRANSCRIPT KM_TTL
# Globals set by kernel_mandate_resolve_role:
#   KM_ROLE        role name ('' when none applies)
#   KM_ROLE_STATE  governed | ungoverned | unbound | misconfigured
#
# Test seams (env):
#   KERNEL_MANDATE          0|false|off → inactive (operator kill-switch; set
#                       in the OPERATOR's shell before launching the
#                       session — agents cannot alter hook env from inside)
#   KERNEL_MANDATE_MANIFEST explicit manifest path (bypasses discovery)
#   KERNEL_MANDATE_STATE_DIR explicit state dir

# The binding tag carried by every dispatch prompt. The role name is
# required; an optional `#NONCE` (4+ chars of [a-z0-9]) is registered
# nonce→role at dispatch time, so a child binds exactly by the nonce in its
# own transcript even under mixed parallel dispatch or a quoted foreign tag.
KM_ROLE_TAG_RE='<<kernel-mandate-role: [a-z][a-z0-9-]*(#[a-z0-9]{4,})?>>'
# Anything shaped like a role tag. A near miss (`<<kernel-mandate-role:  judge>>`,
# a short nonce) fails the strict form; the dispatch gate refuses it rather
# than rely on the resolver being exactly as strict, in another process.
KM_ROLE_NEARTAG_RE='<<[[:space:]]*kernel-mandate-role[^>]*>>'

# kernel_mandate_grep_or_empty <grep args…> — grep whose "no match" (exit 1)
# is an empty result rather than a failure, so a screen's pipeline fails
# only when a tool actually breaks (exit 2 and up).
kernel_mandate_grep_or_empty() {
  grep "$@" || [ $? -eq 1 ]
}

# kernel_mandate_tag_roles — read text on stdin, print the role NAME of every
# strict role tag in it, one per line, sorted and unique. Shared by the
# dispatch gate (the prompt) and resolution rung 4b (the transcript), which
# must agree. Exits non-zero when a tool fails, so a caller can tell "no
# tags" from "could not read the tags".
kernel_mandate_tag_roles() {
  kernel_mandate_grep_or_empty -oE "$KM_ROLE_TAG_RE" 2>/dev/null \
    | sed -E 's/^<<kernel-mandate-role: ([a-z][a-z0-9-]*)(#[a-z0-9]+)?>>$/\1/' \
    | kernel_mandate_grep_or_empty -v '^$' | sort -u
}

# kernel_mandate_neartag — read text on stdin, print the first tag-SHAPED string
# that the strict form does not accept, or nothing.
kernel_mandate_neartag() {
  local nt_all nt_one
  nt_all=$(kernel_mandate_grep_or_empty -oE "$KM_ROLE_NEARTAG_RE" 2>/dev/null) || return 1
  [ -n "$nt_all" ] || return 0
  while IFS= read -r nt_one; do
    [ -n "$nt_one" ] || continue
    printf '%s' "$nt_one" | grep -qE "^${KM_ROLE_TAG_RE}\$" 2>/dev/null && continue
    printf '%s' "$nt_one"
    return 0
  done <<< "$nt_all"
  return 0
}

# kernel_mandate__deny_tag_screen — a tool failed while the resolver was
# reading the child's role tag from its transcript. An agent left unbound
# falls to the unboundAgentPolicy, whose default is wider than any one
# role, so the call is refused instead.
kernel_mandate__deny_tag_screen() {
  kernel_mandate_deny "role-tag-screen" "[BLOCKED] kernel-mandate could not screen this dispatch's role tags (a text tool failed). Refusing rather than running this agent unbound.

Retry the call. If it fails again, the host's awk, sed, grep or sort is not behaving as the kernel expects; report it with the output of: uname -sr; command -v awk sed grep sort"
}

kernel_mandate__jq() {
  if [ -n "${JQ:-}" ] && [ -x "${JQ:-}" ]; then printf '%s' "$JQ"; return 0; fi
  local candidate
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/jq"
  if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  command -v jq || true
}

# kernel_mandate_load <input-json>
# Returns 1 (caller should silent-allow) when the kernel mandate is not in
# play: kill-switch set, no manifest found, or unknown manifest version.
# A PRESENT but unparseable manifest is a distinct state (fail closed):
# KM_MANIFEST_BROKEN=1 and the function returns 0 so the gate can deny
# mutating tools while leaving the read path open for repair.
# kernel_mandate__emit_fixed_deny <reason>
# A deny that needs nothing but the shell: no jq, no manifest, no role.
# Used for the failures that happen before this kernel can read anything,
# where the alternative is returning "not governed" and meaning it.
kernel_mandate__emit_fixed_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  KM_DECIDED=1
  exit 0
}

kernel_mandate_load() {
  KM_INPUT="$1"

  # The operator's kill-switch outranks everything below, including the
  # guards. Someone turning enforcement off must always be able to.
  case "${KERNEL_MANDATE:-}" in
    0|false|off) return 1 ;;
  esac

  KM_JQ="$(kernel_mandate__jq)"
  if [ -z "$KM_JQ" ]; then
    # Without jq nothing can be read, but with a manifest present returning
    # "not governed" would silently unenforce every role. The manifest is
    # located by file test alone, which needs no jq.
    local probe
    probe="${KERNEL_MANDATE_MANIFEST:-$( { git rev-parse --show-toplevel 2>/dev/null || pwd; } )/.claude/kernel-mandate.json}"
    if [ -f "$probe" ]; then
      kernel_mandate__emit_fixed_deny "[BLOCKED] kernel-mandate cannot enforce this project: jq is not installed, and jq is how the kernel reads both the manifest and the call it is deciding about. This project HAS a role manifest, so treating the kernel as absent would leave every role unenforced without saying so. Install jq (https://jqlang.github.io/jq/), or set KERNEL_MANDATE=0 to run this session ungoverned on purpose."
    fi
    return 1
  fi

  KM_TOOL=$(printf '%s' "$KM_INPUT" | "$KM_JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
  KM_CWD=$(printf '%s' "$KM_INPUT" | "$KM_JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
  KM_AGENT_ID=$(printf '%s' "$KM_INPUT" | "$KM_JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
  KM_AGENT_TYPE=$(printf '%s' "$KM_INPUT" | "$KM_JQ" -r '.agent_type // empty' 2>/dev/null || echo "")
  KM_TOOL_USE_ID=$(printf '%s' "$KM_INPUT" | "$KM_JQ" -r '.tool_use_id // empty' 2>/dev/null || echo "")
  KM_PARENT_TOOL_USE_ID=$(printf '%s' "$KM_INPUT" | "$KM_JQ" -r '.parent_tool_use_id // empty' 2>/dev/null || echo "")
  KM_TRANSCRIPT=$(printf '%s' "$KM_INPUT" | "$KM_JQ" -r '.transcript_path // empty' 2>/dev/null || echo "")

  # Where the manifest is decides everything: not-found means ALLOW for
  # every axis. Discovery walks up from cwd and stops at the first
  # `.claude/kernel-mandate.json`, whose directory is the project root; a git
  # toplevel lookup misses projects nested in a larger repo or outside git.
  if [ -n "${KERNEL_MANDATE_MANIFEST:-}" ]; then
    KM_MANIFEST="$KERNEL_MANDATE_MANIFEST"
    KM_ROOT=$(kernel_mandate_physical_root)
  else
    local km_dir km_found=""
    km_dir=$(cd "$KM_CWD" 2>/dev/null && pwd -P 2>/dev/null || printf '%s' "$KM_CWD")
    # Bounded: each step drops a path component, so the walk ends at `/`.
    # A relative or nonexistent cwd falls through to not-found, where the
    # gate's cwd-fault check reports it.
    # The walk stops at the first manifest that PARSES and remembers the first
    # one found. A broken inner manifest must not shadow the outer law (its
    # repair path would open reads); a lone broken one is the repair state.
    local km_first=""
    case "$km_dir" in
      /*)
        while [ -n "$km_dir" ]; do
          if [ -f "$km_dir/.claude/kernel-mandate.json" ]; then
            [ -n "$km_first" ] || km_first="$km_dir"
            if "$KM_JQ" -e 'type == "object" and (.roles | type == "object")' \
                 < "$km_dir/.claude/kernel-mandate.json" >/dev/null 2>&1; then
              km_found="$km_dir"; break
            fi
          fi
          [ "$km_dir" = "/" ] && break
          km_dir=$(dirname "$km_dir")
        done ;;
    esac
    [ -n "$km_found" ] || km_found="$km_first"
    if [ -n "$km_found" ]; then
      KM_ROOT="$km_found"
      KM_MANIFEST="$KM_ROOT/.claude/kernel-mandate.json"
    else
      # A git worktree is a sibling of the main checkout, not a descendant, and
      # an untracked manifest exists only in main. With no manifest above cwd
      # inside a worktree, the main worktree's manifest is the law and this
      # checkout's root is the base its scopes resolve against. It must parse.
      KM_ROOT=$(kernel_mandate_physical_root)
      KM_MANIFEST="$KM_ROOT/.claude/kernel-mandate.json"
      local km_common km_main
      km_common=$(cd "$KM_CWD" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null || echo "")
      if [ -n "$km_common" ]; then
        km_common=$(cd "$KM_CWD" 2>/dev/null && cd "$km_common" 2>/dev/null && pwd -P 2>/dev/null || echo "")
        km_main="${km_common%/.git}"
        if [ -n "$km_main" ] && [ "$km_main" != "$km_common" ] \
           && [ "$km_main" != "$KM_ROOT" ] \
           && [ -f "$km_main/.claude/kernel-mandate.json" ] \
           && "$KM_JQ" -e 'type == "object" and (.roles | type == "object")' \
                < "$km_main/.claude/kernel-mandate.json" >/dev/null 2>&1; then
          KM_MANIFEST="$km_main/.claude/kernel-mandate.json"
        fi
      fi
    fi
  fi
  [ -f "$KM_MANIFEST" ] || return 1

  KM_MANIFEST_BROKEN=0
  KM_MANIFEST_JSON=$(cat "$KM_MANIFEST" 2>/dev/null || echo "")
  if ! printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -e 'type == "object" and (.roles | type == "object")' >/dev/null 2>&1; then
    KM_MANIFEST_BROKEN=1
    KM_MANIFEST_JSON="{}"
  else
    local version
    version=$(printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -r '.kernelMandateVersion // empty' 2>/dev/null || echo "")
    # An unimplemented manifest version is refused by name, not treated as
    # inactive: silently enforcing nothing is worse than either alternative.
    if [ "$version" != "1" ]; then
      kernel_mandate__emit_fixed_deny "[BLOCKED] kernel-mandate cannot enforce this project: its manifest declares a kernelMandateVersion this kernel does not implement (this kernel implements version 1). Enforcing grants the kernel cannot interpret would be unsound, and ignoring them would leave every role unenforced without saying so. Upgrade the kernel-mandate kernel to match the manifest, correct the manifest's kernelMandateVersion, or set KERNEL_MANDATE=0 to run this session ungoverned on purpose."
    fi
  fi

  KM_STATE_DIR="${KERNEL_MANDATE_STATE_DIR:-$KM_ROOT/.claude/kernel-mandate.state}"
  KM_TTL=$(printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -r '.settings.dispatchTtlSeconds // 1800' 2>/dev/null || echo 1800)
  case "$KM_TTL" in ''|*[!0-9]*) KM_TTL=1800 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# Role resolution ladder
# ---------------------------------------------------------------------------

# An agent id becomes a filename, and `tr -c` maps `a/b` and `a:b` to the
# same `a_b`, which would share one role binding. Ids that need no
# substitution keep their name; only those that would collide gain a digest.
kernel_mandate__sanitize_id() {
  local raw="$1" safe
  safe=$(printf '%s' "$raw" | tr -c 'a-zA-Z0-9_-' '_')
  if [ "$safe" = "$raw" ]; then printf '%s' "$safe"; return 0; fi
  printf '%s-%s' "$(printf '%s' "$safe" | cut -c1-200)" \
    "$(printf '%s' "$raw" | cksum 2>/dev/null | cut -d' ' -f1)"
}

kernel_mandate__binding_file() {
  printf '%s/agents/%s' "$KM_STATE_DIR" "$(kernel_mandate__sanitize_id "$1")"
}

kernel_mandate__role_exists() {
  printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -e --arg r "$1" '.roles[$r] | type == "object"' >/dev/null 2>&1
}

# kernel_mandate__bind <agent_id> <role> — persist the binding (atomic, best-effort).
kernel_mandate__bind() {
  local file
  file="$(kernel_mandate__binding_file "$1")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  printf '%s\n' "$2" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" 2>/dev/null || rm -f "$file.tmp" 2>/dev/null || true
}

# kernel_mandate__registry_claim <agent_id>
# Prints a role name iff every fresh, unclaimed dispatch-registry entry
# names the SAME role (unambiguous), and marks the oldest such entry
# claimed by this agent. Mixed roles in flight → prints nothing.
kernel_mandate__registry_claim() {
  local agent_id="$1" reg="$KM_STATE_DIR/dispatch-registry.json" now existing distinct role
  [ -f "$reg" ] || return 0
  now=$(date +%s)
  existing=$(cat "$reg" 2>/dev/null || echo "{}")
  printf '%s' "$existing" | "$KM_JQ" -e 'type == "object"' >/dev/null 2>&1 || return 0

  # `nonce:`-prefixed entries mirror a tool_use_id entry (same role); skip
  # them so a nonce'd dispatch is not double-counted as two in-flight
  # dispatches, which would only ever cause a false ambiguity.
  distinct=$(printf '%s' "$existing" | "$KM_JQ" -r --argjson now "$now" --argjson ttl "$KM_TTL" '
    [ to_entries[]
      | select(.key | startswith("nonce:") | not)
      | select((.value.ts // 0) >= ($now - $ttl))
      | select((.value.claimed_by // "") == "")
      | .value.role ] | unique | if length == 1 then .[0] else empty end
  ' 2>/dev/null || echo "")
  [ -n "$distinct" ] || return 0
  role="$distinct"

  local updated
  updated=$(printf '%s' "$existing" | "$KM_JQ" -c --argjson now "$now" --argjson ttl "$KM_TTL" --arg who "$agent_id" '
    ( [ to_entries[]
        | select(.key | startswith("nonce:") | not)
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

kernel_mandate_resolve_role() {
  KM_ROLE=""
  KM_ROLE_STATE="ungoverned"

  # Rung 1 — no agent_id: this is the top-level session. A named
  # mainSessionRole that does not exist is a misconfiguration and fails
  # closed, distinct from declaring none (ungoverned on purpose).
  if [ -z "$KM_AGENT_ID" ]; then
    KM_ROLE=$(printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -r '.settings.mainSessionRole // empty' 2>/dev/null || echo "")
    if [ -z "$KM_ROLE" ]; then
      # Declares no main-session role: ungoverned on purpose.
      KM_ROLE_STATE="ungoverned"
    elif kernel_mandate__role_exists "$KM_ROLE"; then
      KM_ROLE_STATE="governed"
    else
      KM_ROLE_STATE="misconfigured"
    fi
    return 0
  fi

  # Rung 2 — cached binding for this agent_id.
  local binding
  binding="$(kernel_mandate__binding_file "$KM_AGENT_ID")"
  if [ -f "$binding" ]; then
    KM_ROLE=$(head -n1 "$binding" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$KM_ROLE" ] && kernel_mandate__role_exists "$KM_ROLE"; then
      KM_ROLE_STATE="governed"
      return 0
    fi
    KM_ROLE=""
  fi

  # Rung 2b — the host's own agent_type: the agent definition the child was
  # dispatched as, owned by the host, needing no tag, nonce or registry.
  # After the cached binding, before the prose rungs. validate refuses a type
  # listed under two roles, so a match is unambiguous; it is cached.
  if [ -n "$KM_AGENT_TYPE" ]; then
    local type_role
    type_role=$(printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -r --arg t "$KM_AGENT_TYPE"       'first(.roles | to_entries[] | select(.value.agentTypes // [] | index($t)) | .key) // empty'       2>/dev/null || echo "")
    if [ -n "$type_role" ] && kernel_mandate__role_exists "$type_role"; then
      KM_ROLE="$type_role"
      kernel_mandate__bind "$KM_AGENT_ID" "$KM_ROLE"
      KM_ROLE_STATE="governed"
      return 0
    fi
  fi

  # Rung 3 — parent_tool_use_id → exact registry match (older builds).
  if [ -n "$KM_PARENT_TOOL_USE_ID" ] && [ -f "$KM_STATE_DIR/dispatch-registry.json" ]; then
    KM_ROLE=$("$KM_JQ" -r --arg id "$KM_PARENT_TOOL_USE_ID" '.[$id].role // empty' \
      "$KM_STATE_DIR/dispatch-registry.json" 2>/dev/null || echo "")
    if [ -n "$KM_ROLE" ] && kernel_mandate__role_exists "$KM_ROLE"; then
      kernel_mandate__bind "$KM_AGENT_ID" "$KM_ROLE"
      KM_ROLE_STATE="governed"
      return 0
    fi
    KM_ROLE=""
  fi

  # Rung 4 — transcript tag. Dispatch prompts carry
  # <<kernel-mandate-role: NAME[#NONCE]>> (the dispatch gate denies prompts
  # without a tag). Only USER-authored transcript lines count: an agent
  # echoing a foreign role tag in its own output must not be able to
  # poison (or ambiguate) its binding, so assistant lines are filtered
  # out before tag extraction.
  if [ -n "$KM_TRANSCRIPT" ] && [ -f "$KM_TRANSCRIPT" ]; then
    local user_line user_tags nonce_roles distinct_nonce_role tags
    # A role tag only counts when it comes from the dispatch prompt: the first
    # user line that is not a tool_result (fetched content arrives as user
    # lines, and docs contain tags). Later user turns cannot re-bind.
    # One awk selects that line and stops, so a tool failure is a failure, not
    # "no tags" (which would leave the agent on the wider unbound policy).
    user_line=$(awk '/"(type|role)"[[:space:]]*:[[:space:]]*"user"/ && !/"(tool_result|tool_use|tool_output)"|"toolUseResult"/ { print; exit }' "$KM_TRANSCRIPT" 2>/dev/null) \
      || kernel_mandate__deny_tag_screen
    user_tags=$(printf '%s\n' "$user_line" | kernel_mandate_grep_or_empty -oE "$KM_ROLE_TAG_RE") \
      || kernel_mandate__deny_tag_screen

    # 4a — NONCE match (collision-proof). For every nonce-bearing tag in
    # the child's own transcript, look up the registered nonce→role. If
    # all resolved nonces name ONE role, that is the identity — exact
    # even amid quoted foreign tags or parallel sibling dispatch.
    if [ -n "$user_tags" ] && [ -f "$KM_STATE_DIR/dispatch-registry.json" ]; then
      local nonces n role_for
      nonces=$(printf '%s\n' "$user_tags" | grep -oE '#[a-z0-9]{4,}>>$' | sed -E 's/^#([a-z0-9]+)>>$/\1/' | sort -u || echo "")
      nonce_roles=""
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        role_for=$("$KM_JQ" -r --arg k "nonce:$n" '.[$k].role // empty' "$KM_STATE_DIR/dispatch-registry.json" 2>/dev/null || echo "")
        [ -n "$role_for" ] && nonce_roles="$nonce_roles$role_for"$'\n'
      done <<< "$nonces"
      distinct_nonce_role=$(printf '%s' "$nonce_roles" | grep -v '^$' | sort -u || echo "")
      if [ -n "$distinct_nonce_role" ] && [ "$(printf '%s\n' "$distinct_nonce_role" | wc -l | tr -d ' ')" = "1" ]; then
        KM_ROLE="$distinct_nonce_role"
        if kernel_mandate__role_exists "$KM_ROLE"; then
          kernel_mandate__bind "$KM_AGENT_ID" "$KM_ROLE"
          KM_ROLE_STATE="governed"
          return 0
        fi
        KM_ROLE=""
      fi
    fi

    # 4b — nonce-free fallback: exactly ONE distinct role across the
    # transcript's user-line tags → it is the child's own transcript and
    # that tag is its identity. Multiple distinct roles → a parent-wide
    # transcript; ambiguous, fall through.
    tags=$(printf '%s\n' "$user_tags" | kernel_mandate_tag_roles) || kernel_mandate__deny_tag_screen
    if [ -n "$tags" ] && [ "$(printf '%s\n' "$tags" | wc -l | tr -d ' ')" = "1" ]; then
      KM_ROLE="$tags"
      # Corroborate the bare tag against what was actually dispatched: it is a
      # string in a file, unlike the rungs above. `strict` refuses an
      # uncorroborated tag; `auto` refuses only when live dispatch records
      # contradict it. Either way the agent falls to unbound.
      # Default `off`: `auto` would unbind resumed sessions with a cleared state
      # dir, hand-placed tags and children spawned outside this gate. `validate`
      # recommends `auto` for any manifest with a dispatcher (docs/benchmark.md).
      local tag_policy tag_ok tag_reg tag_now
      tag_policy=$(printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -r '.settings.roleTagCorroboration // "off"' 2>/dev/null || echo "off")
      if [ "$tag_policy" != "off" ]; then
        tag_reg="$KM_STATE_DIR/dispatch-registry.json"
        tag_now=$(date +%s)
        tag_ok=$(cat "$tag_reg" 2>/dev/null | "$KM_JQ" -r --argjson now "$tag_now" --argjson ttl "$KM_TTL" --arg r "$KM_ROLE" '
          [ to_entries[] | select((.value.ts // 0) >= ($now - $ttl)) ] as $live
          | if ($live | length) == 0 then "none"
            elif ([ $live[] | .value.role ] | index($r)) != null then "yes"
            else "no" end
        ' 2>/dev/null || echo "none")
        case "$tag_ok" in
          yes)  : ;;
          no)   KM_ROLE="" ;;
          *)    [ "$tag_policy" = "strict" ] && KM_ROLE="" ;;
        esac
      fi
      if [ -n "$KM_ROLE" ] && kernel_mandate__role_exists "$KM_ROLE"; then
        kernel_mandate__bind "$KM_AGENT_ID" "$KM_ROLE"
        KM_ROLE_STATE="governed"
        return 0
      fi
      KM_ROLE=""
    fi
  fi

  # Rung 5 — registry claim (unambiguous single-role in-flight set).
  # Opt-in: it binds on ambient state ("one role is in flight, so you are
  # it") without checking the caller is that dispatch's child. Off, such an
  # agent is unbound and unboundAgentPolicy decides.
  local claim_policy
  claim_policy=$(printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -r '.settings.ambientDispatchClaim // "off"' 2>/dev/null || echo "off")
  if [ "$claim_policy" = "on" ]; then
  KM_ROLE=$(kernel_mandate__registry_claim "$KM_AGENT_ID")
  else
  KM_ROLE=""
  fi
  if [ -n "$KM_ROLE" ] && kernel_mandate__role_exists "$KM_ROLE"; then
    kernel_mandate__bind "$KM_AGENT_ID" "$KM_ROLE"
    KM_ROLE_STATE="governed"
    return 0
  fi

  # Rung 6 — unresolvable: the unboundAgentPolicy governs.
  KM_ROLE=""
  KM_ROLE_STATE="unbound"
  return 0
}

# kernel_mandate_register_dispatch <role> <tool_use_id> [nonce]
# Records an Agent dispatch in the registry (TTL-pruned, atomic). Keyed
# by tool_use_id; when the dispatch prompt carried a #NONCE it is also
# recorded under "nonce:<NONCE>" so a child can bind exactly by the nonce
# in its own transcript (see resolve rung 4a).
kernel_mandate_register_dispatch() {
  local role="$1" id="$2" nonce="${3:-}" reg="$KM_STATE_DIR/dispatch-registry.json" now existing updated
  [ -n "$id" ] || return 0
  mkdir -p "$KM_STATE_DIR" 2>/dev/null || return 0
  now=$(date +%s)
  existing="{}"
  if [ -f "$reg" ]; then
    existing=$(cat "$reg" 2>/dev/null || echo "{}")
    printf '%s' "$existing" | "$KM_JQ" -e 'type == "object"' >/dev/null 2>&1 || existing="{}"
  fi
  updated=$(printf '%s' "$existing" | "$KM_JQ" -c \
    --arg id "$id" --arg role "$role" --arg nonce "$nonce" --argjson now "$now" --argjson ttl "$KM_TTL" '
      . as $reg
      | reduce keys[] as $k ({};
          if ($reg[$k].ts // 0) >= ($now - $ttl) then . + { ($k): $reg[$k] } else . end)
      | . + { ($id): { role: $role, ts: $now } }
      # Nonce collision: a live nonce already bound to a DIFFERENT role
      # must not be silently overwritten (last-writer-wins would let a
      # reused nonce rebind a low role to a high one). Mark it poisoned
      # instead; resolution treats a poisoned nonce as no match at all,
      # so the child falls to the protective unbound policy.
      | if ($nonce | length) == 0 then .
        elif (.["nonce:" + $nonce] | type) == "object"
             and (.["nonce:" + $nonce].role != $role)
             and ((.["nonce:" + $nonce].ts // 0) >= ($now - $ttl))
          then . + { ("nonce:" + $nonce): { role: "", collided: true, ts: $now } }
        else . + { ("nonce:" + $nonce): { role: $role, ts: $now } }
        end
    ' 2>/dev/null || echo "")
  if [ -n "$updated" ]; then
    printf '%s' "$updated" > "$reg.tmp" 2>/dev/null && mv "$reg.tmp" "$reg" 2>/dev/null || rm -f "$reg.tmp" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Quote-aware shell word handling
# ---------------------------------------------------------------------------
# A quoted word is a literal; an unquoted one is a pattern the shell
# expands (`find tests -name "*.json"` reads no json file). Neither helper
# is a full shell parser; both fail toward "unquoted", which is expanded
# and scope-checked.

# kernel_mandate_shell_words — read one segment on stdin, emit one word per
# line prefixed with its quoting state:
#   Q<word>  every character came from inside quotes -> the shell will
#            NOT glob-expand it; it names exactly this literal
#   U<word>  at least one character was unquoted -> expansion applies
# Unquoted '>' also separates words (a '>' inside quotes is just text).
# The whole input is one record, as in kernel_mandate_unquoted_view, so the
# two scanners agree about a quoted string spanning newlines.
kernel_mandate_shell_words() {
  awk 'BEGIN { RS = "\034" }
  {
    s = $0; n = length(s); word = ""; inword = 0; q = ""; unq = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      # An escaped character is literal — the backslash goes away and the
      # character joins the word without making it expandable. `cat \*`
      # names a file called *, and `cat a\ b` is ONE operand.
      if (c == "\\" && q != "'"'"'" && i < n) {
        word = word substr(s, i + 1, 1)
        inword = 1
        i++
        continue
      }
      if (q != "") {                       # inside quotes: only the
        if (c == q) { q = "" }             # matching quote ends them
        else { word = word c }
        inword = 1
        continue
      }
      if (c == "\"" || c == "'"'"'") { q = c; inword = 1; continue }
      if (c == " " || c == "\t" || c == ">") {
        if (inword) { print (unq ? "U" : "Q") word }
        word = ""; inword = 0; unq = 0
        continue
      }
      word = word c; inword = 1; unq = 1
    }
    if (inword) { print (unq ? "U" : "Q") word }
  }'
}

# kernel_mandate_unquoted_view — read a segment on stdin, emit it with the
# quoted regions neutralised. What survives is exactly the text the shell
# still interprets, so a check run against this view fires on
# `cat {.env,x}` and stays quiet on the JSON literal `echo '{"a":1}'`.
# Modes:
#   both    (default) blank every quoted run — globbing and brace
#           expansion die inside either quote style
#   single  blank only single-quoted runs — $… and `…` keep expanding
#           inside double quotes, so expansion checks must see in there
#   redir   keep every character EXCEPT that < and > inside quotes lose
#           their meaning, so `grep '=>' f` redirects nothing while
#           `echo x > "docs/ledger.json"` still names its target.
#   split   keep every character EXCEPT that ; | & and newline inside
#           quotes are swapped for distinct placeholders the caller
#           restores after splitting: `echo "a; b"` is one command.
# The whole input is one record (RS is a byte no command contains), so a
# quoted NEWLINE is seen by the scanner rather than being pre-split by
# awk. That matters only for 'split', which is the mode that runs on a
# whole multi-line command; the other modes are handed one segment.
kernel_mandate_unquoted_view() {
  awk -v mode="${1:-both}" 'BEGIN { RS = "\034"; ORS = "" }
  {
    s = $0; n = length(s); out = ""; q = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      # A backslash escapes the next character everywhere except inside
      # single quotes, where bash does no escaping at all. The escaped
      # character is literal TEXT and can never be syntax — not a quote,
      # not a separator, not a redirect: `echo \" ; cat .env` is two commands.
      if (c == "\\" && q != "'"'"'" && i < n) {
        e = substr(s, i + 1, 1)
        if (mode == "split") {
          # Must round-trip byte-exactly: keep the backslash, and hold
          # only a separator that the escape has disarmed.
          out = out c
          if (e == ";") out = out "\002"
          else if (e == "|") out = out "\003"
          else if (e == "&") out = out "\004"
          else if (e == "\n") out = out "\005"
          else out = out e
        } else if (mode == "redir") {
          out = out "\001"
          out = out ((e == "<" || e == ">") ? "\001" : e)
        } else {
          out = out "XX"
        }
        i++
        continue
      }
      if (q != "") {
        if (c == q) { q = "" ; out = out ((mode == "redir" || mode == "split") ? c : "X") }
        else if (mode == "redir") { out = out ((c == "<" || c == ">") ? "\001" : c) }
        else if (mode == "split") {
          if (c == ";") out = out "\002"
          else if (c == "|") out = out "\003"
          else if (c == "&") out = out "\004"
          else if (c == "\n") out = out "\005"
          else out = out c
        }
        else { out = out ((q == "\"" && mode == "single") ? c : "X") }
        continue
      }
      if (c == "'"'"'" || c == "\"") {
        q = c
        out = out ((mode == "redir" || mode == "split") ? c : "X")
        continue
      }
      out = out c
    }
    print out
  }'
}

# kernel_mandate_unsplit — restore the placeholders kernel_mandate_unquoted_view
# 'split' put in, so a segment carries its original text verbatim.
kernel_mandate_unsplit() {
  tr '\002\003\004\005' ';|&\n'
}

# kernel_mandate_quotes_balanced — 0 when every quote in the input on stdin
# is closed. After a stray quote the scanner reads the rest as inert text;
# bash refuses such a command anyway, so refusing it here loses nothing.
kernel_mandate_quotes_balanced() {
  awk 'BEGIN { RS = "\034"; ORS = "" }
  {
    s = $0; n = length(s); q = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "\\" && q != "'"'"'" && i < n) { i++; continue }
      if (q != "") { if (c == q) q = ""; continue }
      if (c == "'"'"'" || c == "\"") q = c
    }
    exit (q == "" ? 0 : 1)
  }'
}

# ---------------------------------------------------------------------------
# Glob → ERE path matching
# ---------------------------------------------------------------------------
# Manifest scope semantics: '**' crosses directory boundaries, '*' stays
# within one, '?' is a single non-/ char. 'docs/**' matches docs itself
# AND everything under it; '**/x' matches x at any depth including root.

kernel_mandate_glob_to_ere() {
  local g="$1" ph=$'\037' out="" i c
  # Escape the regex metacharacters in the LITERAL part of the glob, so
  # `docs/e2e-ledger.json` matches that file and not `docs/e2e-ledgerXjson`.
  # `*` and `?` are deliberately NOT escaped — they are the glob operators
  # the conversion below turns into character classes. A `case` per
  # character, not a sed bracket expression whose meaning depends on where
  # `]` sits; it also saves an execve in the hottest function here.
  for (( i = 0; i < ${#g}; i++ )); do
    c="${g:i:1}"
    case "$c" in
      '.'|'['|']'|'('|')'|'+'|'{'|'}'|'^'|'$'|'|'|'\') out="${out}\\${c}" ;;
      *) out="${out}${c}" ;;
    esac
  done
  g="$out"
  g="${g//\*\*/$ph}"
  g="${g//\*/[^/]*}"
  g="${g//\?/[^/]}"
  # Parameter expansion, not sed: a sed that failed here returned an empty
  # ERE, `^$`, and every deny pattern then matched nothing.
  # The `/` in a ${g//…} pattern is held in a variable: bash 3.2 ends the
  # pattern at the first `/` even inside quotes.
  local any_tail='(/.*)?' any_head='(.*/)?' any_mid='/(.*/)?' any='.*' mid="/$ph/"
  case "$g" in *"/$ph") g="${g%"/$ph"}$any_tail" ;; esac
  case "$g" in "$ph/"*) g="$any_head${g#"$ph/"}" ;; esac
  g="${g//$mid/$any_mid}"
  g="${g//$ph/$any}"
  printf '^%s$' "$g"
}

# kernel_mandate_url_authority <url> — print the authority a client will
# actually connect to (host[:port], lowercased), or nothing when the
# string is not a network URL. A parser, because a prefix match is fooled
# by userinfo (`http://localhost:4173@example.com/` dials example.com).
# kernel_mandate_is_network_url <string> — true when the string names a
# REMOTE resource. Shared by every network check, and case-insensitive:
# RFC 3986 schemes are, and curl normalises `HTTP://` before dialling.
kernel_mandate_is_network_url() {
  case "$1" in *://*) : ;; *) return 1 ;; esac
  # Any `scheme://…` is a destination unless the scheme names something
  # local or inert. An allowlist of network schemes fails open on schemes
  # curl supports and it does not know (`rtmp`, `gophers`, `smbs`).
  case "$(printf '%s' "${1%%://*}" | tr 'A-Z' 'a-z')" in
    file|data|blob|about|javascript|chrome|chrome-extension|resource|jar|classpath|filesystem) return 1 ;;
    *) return 0 ;;
  esac
}

kernel_mandate_url_authority() {
  local u="$1" auth
  kernel_mandate_is_network_url "$u" || return 0
  auth="${u#*://}"
  # Everything after the first /, ?, or # is path/query/fragment.
  auth="${auth%%/*}"; auth="${auth%%\?*}"; auth="${auth%%#*}"
  # Userinfo is everything up to the LAST `@` — `a@b@c` connects to `c`.
  case "$auth" in *@*) auth="${auth##*@}" ;; esac
  printf '%s' "$auth" | tr 'A-Z' 'a-z'
}

# kernel_mandate_url_userinfo <url> — print the userinfo portion, or nothing.
# Its presence is the signal: an agent has no reason to embed credentials
# in a URL, and it is the one spelling that makes a URL's prefix differ
# from its destination.
kernel_mandate_url_userinfo() {
  local u="$1" auth
  kernel_mandate_is_network_url "$u" || return 0
  case "$u" in *://*) : ;; *) return 0 ;; esac
  auth="${u#*://}"; auth="${auth%%/*}"; auth="${auth%%\?*}"; auth="${auth%%#*}"
  case "$auth" in *@*) printf '%s' "${auth%@*}" ;; esac
}

# kernel_mandate_authority_in_scope <authority> <json-array> — does the
# authority match one of the manifest's network entries? An entry with no
# port matches any port on that host; an entry with a port must match
# exactly. A leading `*.` matches subdomains, and nothing else does —
# `localhost:4173` must NOT match `localhost:4173.evil.com`.
kernel_mandate_authority_in_scope() {
  local auth="$1" patterns="$2" host port entry ehost eport
  [ -n "$auth" ] || return 1
  host="${auth%%:*}"; port=""
  case "$auth" in *:*) port="${auth##*:}" ;; esac
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry=$(printf '%s' "$entry" | tr 'A-Z' 'a-z')
    ehost="${entry%%:*}"; eport=""
    case "$entry" in *:*) eport="${entry##*:}" ;; esac
    if [ -n "$eport" ] && [ "$eport" != "$port" ]; then continue; fi
    case "$ehost" in
      '*') return 0 ;;
      '*.'*) case "$host" in *".${ehost#\*.}") return 0 ;; esac
             [ "$host" = "${ehost#\*.}" ] && return 0 ;;
      *) [ "$host" = "$ehost" ] && return 0 ;;
    esac
  done < <(printf '%s' "$patterns" | "$KM_JQ" -r '.[]?' 2>/dev/null)
  return 1
}

# kernel_mandate_normalize_path <path> — absolute form with symlinks resolved.
# Relative paths resolve against KM_CWD. `.`/`..` segments are squashed
# BEFORE scope matching, so `src/../.claude/x` can never ride a `src/**`
# grant. Prefers GNU `realpath -m`. Without it (BSD/macOS) the same
# walk is done here: components left to right, each symlink replaced by
# its target before the next `..` applies, as the OS resolves the path
# when the command opens it. The project root is found physically
# (`git rev-parse`, `pwd -P`), so a path left at /var/... on macOS would
# never match a root under /private/var/....
kernel_mandate_normalize_path() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in /*) : ;; *) p="${KM_CWD%/}/$p" ;; esac
  local rp
  rp=$(realpath -m -- "$p" 2>/dev/null || true)
  if [ -n "$rp" ]; then printf '%s' "$rp"; return 0; fi
  local out="" rest="$p" seg link hops=0
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    case "$seg" in
      ''|'.') continue ;;
      '..') out="${out%/*}"; continue ;;
    esac
    # 40 hops is Linux's ELOOP limit.
    if [ -L "$out/$seg" ] && [ "$hops" -lt 40 ]; then
      hops=$((hops + 1))
      link=$(readlink -- "$out/$seg")
      case "$link" in /*) out="" ;; esac
      rest="$link/$rest"
      continue
    fi
    out="$out/$seg"
  done
  printf '%s' "${out:-/}"
}

# kernel_mandate_physical_root — the repo top-level of KM_CWD, else KM_CWD
# itself, both with symlinks resolved: every path is compared against the
# root after kernel_mandate_normalize_path resolves ITS symlinks.
kernel_mandate_physical_root() {
  ( cd "$KM_CWD" 2>/dev/null && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; } ) || printf '%s' "$KM_CWD"
}

# kernel_mandate_relpath <path> — normalise, then repo-root-relativise.
# Paths outside the root stay absolute (they then only match
# absolute-anchored patterns).
kernel_mandate_relpath() {
  local p
  p="$(kernel_mandate_normalize_path "$1")"
  case "$p" in
    "$KM_ROOT") printf '.' ; return 0 ;;
    "$KM_ROOT"/*) p="${p#"$KM_ROOT"/}" ;;
  esac
  printf '%s' "$p"
}

# kernel_mandate_is_manifest_path <path> — the manifest is "the law": every
# governed role may READ it (deny messages quote it; agents consult it
# to understand their own boundaries). Write access stays locked by the
# self-protection axis.
kernel_mandate_is_manifest_path() {
  [ "$(kernel_mandate_normalize_path "$1")" = "$(kernel_mandate_normalize_path "$KM_MANIFEST")" ]
}

# kernel_mandate_lexical_path <path> — absolute, `.`/`..` squashed, symlinks
# NOT resolved: the path as the manifest author would have written it.
kernel_mandate_lexical_path() {
  local p="$1" out="" seg rest
  case "$p" in
    "~") p="${HOME:-}" ;;
    "~/"*) p="${HOME:-}/${p#\~/}" ;;
  esac
  case "$p" in /*) : ;; *) p="${KM_CWD%/}/$p" ;; esac
  rest="$p"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    case "$seg" in
      ''|'.') ;;
      '..') out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# kernel_mandate_path_denied <relpath> <path-as-given> <deny-patterns-json>
# A deny list is matched in BOTH the path's physical form and its form as
# written. Resolution moves a path across symlinks (/etc -> /private/etc
# on macOS), and a pattern with a wildcard at or above the link —
# `/e*/**`, `/*/hosts` — can only be written against the unresolved form.
# An absolute or `~` pattern is matched against the absolute path, so one
# naming a tree INSIDE the project (`<root>/secret/**`) denies `secret/k`;
# a relative pattern is matched against the project-relative path, so
# `**/build/**` never reaches the project's own ancestors. Allow lists
# match the resolved, relative form only, so a link never widens a grant.
kernel_mandate_path_denied() {
  local phys_rel="$1" given="$2" deny="$3" lex_abs lex_rel
  lex_abs=$(kernel_mandate_lexical_path "$given")
  kernel_mandate_path_in_scope "$(kernel_mandate_normalize_path "$given")" "$deny" absolute && return 0
  kernel_mandate_path_in_scope "$lex_abs" "$deny" as-written && return 0
  kernel_mandate_path_in_scope "$phys_rel" "$deny" relative && return 0
  lex_rel=$(kernel_mandate_lexical_relpath "$lex_abs")
  # A path inside the project whose written spelling runs through a link
  # the root's own spelling does not (`<link>/proj/src/a.ts` from a
  # physical cwd) stays absolute here; the physical half already judged
  # it, and against the absolute form `**/build/**` would deny on the
  # project's ancestors.
  case "$lex_rel" in /*) case "$phys_rel" in /*) : ;; *) return 1 ;; esac ;; esac
  kernel_mandate_path_in_scope "$lex_rel" "$deny" relative
}

# kernel_mandate_lexical_relpath <path> — the lexical path, relative to the
# project root when it lies under it. The root is physical; its lexical
# spelling is KM_CWD's, less the part of cwd that lies below the root, and
# it only counts when it resolves to the root. A path left absolute here
# would let a relative `**/build/**` deny match a directory ABOVE the
# project, and deny every file in it.
kernel_mandate_lexical_relpath() {
  local p cwd_lex cwd_phys below root_lex r
  p=$(kernel_mandate_lexical_path "$1")
  cwd_lex=$(kernel_mandate_lexical_path "$KM_CWD")
  cwd_phys=$(kernel_mandate_normalize_path "$KM_CWD")
  root_lex=""
  case "$cwd_phys" in
    "$KM_ROOT"|"$KM_ROOT"/*)
      below="${cwd_phys#"$KM_ROOT"}"
      case "$cwd_lex" in *"$below") root_lex="${cwd_lex%"$below"}" ;; esac ;;
  esac
  if [ -n "$root_lex" ] && [ "$(kernel_mandate_normalize_path "$root_lex")" != "$KM_ROOT" ]; then
    root_lex=""
  fi
  for r in "$KM_ROOT" "$root_lex"; do
    [ -n "$r" ] || continue
    case "$p" in
      "$r") printf '.'; return 0 ;;
      "$r"/*) printf '%s' "${p#"$r"/}"; return 0 ;;
    esac
  done
  printf '%s' "$p"
}

# kernel_mandate_path_in_scope <path> <patterns-json-array> [mode]
# 0 when the path matches at least one glob in the JSON array. Without a
# mode every pattern is tried, with the literal prefix of an absolute or
# `~` pattern resolved through symlinks, for a path resolved the same way.
# `absolute` tries only absolute and `~` patterns; `as-written` tries the
# same patterns unresolved, for a path that was not resolved either;
# `relative` tries only relative patterns.
kernel_mandate_path_in_scope() {
  local rel="$1" patterns="$2" mode="${3:-}" glob ere lit rlit
  # A path is one string and grep matches line by line, so a path containing
  # a newline would be in scope if any line matched. No legitimate path has
  # one; the scope test is a whole-string question.
  case "$rel" in *$'\n'*) return 1 ;; esac
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # The path arrives with symlinks resolved, so an absolute pattern's
    # literal directory prefix is resolved the same way: on macOS /etc,
    # /tmp and /var are symlinks into /private, and `/etc/**` written in
    # a deny list must still deny /etc/hosts. `~` is expanded for the
    # same reason — the path side already expands it.
    # With HOME unset, `~/**` would become `/**`; it names nothing instead.
    case "$glob" in
      /*|"~"|"~/"*) [ "$mode" != relative ] || continue ;;
      *) case "$mode" in absolute|as-written) continue ;; esac ;;
    esac
    case "$glob" in "~"|"~/"*) [ -n "${HOME:-}" ] || continue; glob="$HOME${glob#\~}" ;; esac
    if [ "$mode" != as-written ]; then
      case "$glob" in
        /?*)
          lit="${glob%%[*?[]*}"
          [ "$lit" = "$glob" ] || lit="${lit%/*}"
          if [ -n "$lit" ]; then
            rlit=$(kernel_mandate_normalize_path "$lit")
            [ "$rlit" = "/" ] && rlit=""
            glob="$rlit${glob#"$lit"}"
          fi ;;
      esac
    fi
    ere=$(kernel_mandate_glob_to_ere "$glob")
    if printf '%s' "$rel" | grep -Eq "$ere"; then return 0; fi
  done < <(printf '%s' "$patterns" | "$KM_JQ" -r '.[]?' 2>/dev/null)
  return 1
}

# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------

kernel_mandate_log() {
  local decision="$1" detail="$2" line
  local LC_ALL=C
  mkdir -p "$KM_STATE_DIR" 2>/dev/null || return 0

  # Bound the RENDERED line, not the input: JSON expands each control
  # character to \uXXXX, and an append larger than the writer's buffer is
  # split into several write() calls that interleave with concurrent roles.
  # Control characters are flattened, then the line shrinks until it fits.
  detail=$(printf '%s' "$detail" | tr '\000-\037\177' '?')
  [ "${#detail}" -le 4000 ] || detail="${detail:0:4000} [truncated]"
  local guard=0
  while : ; do
    line=$("$KM_JQ" -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg role "${KM_ROLE:-}" \
      --arg state "${KM_ROLE_STATE:-}" \
      --arg tool "${KM_TOOL:-}" \
      --arg decision "$decision" \
      --arg detail "$detail" \
      '{ts: $ts, role: $role, roleState: $state, tool: $tool, decision: $decision, detail: $detail}' \
      2>/dev/null) || return 0
    [ "${#line}" -le 3500 ] && break
    guard=$((guard + 1))
    [ "$guard" -gt 12 ] && { detail="[unloggable]"; continue; }
    detail="${detail:0:$(( ${#detail} / 2 ))} [truncated]"
  done
  printf '%s\n' "$line" >> "$KM_STATE_DIR/decision-log.jsonl" 2>/dev/null || true
}

# kernel_mandate_awk_sed_verdict <command-word> <segment-text>
# Prints "indirect" when an awk/sed program is NOT provably inert, and
# nothing otherwise. Their programs can spawn processes and open files,
# and an operand can be any expression (`f=".env"; getline l < f`), so
# inertness must be proved; roles that need the constructs use bash.permit.
# kernel_mandate_interpreter_inline <command-word> <segment-text>
# Prints "indirect" when an interpreter is being handed code to run.
# Matches the short-option CLUSTER (`perl -ne`, `python3 -Ic`), not an
# exact `-c`/`-e` token. The command word must be the interpreter itself;
# wrappers (`env`, `timeout`, `sh -c`) are denied by their own entries.
kernel_mandate_interpreter_inline() {
  local cmd="$1" seg="$2" base value_letters code_letters
  base="${cmd##*/}"
  # Each interpreter's short options are booleans, value-takers, or code
  # letters, and the lists differ (`-E` is code for perl, a boolean for
  # python). Code letters are split: `-c`/`-e` run agent-written code,
  # `-m`/`-r` run an installed module, so `python -m pytest` can be
  # permitted without `python -c`.
  local module_letters
  case "$base" in
    python|python2|python3|python[0-9].[0-9]*)
      value_letters='cmWXQ';        code_letters='c';       module_letters='m' ;;
    perl)
      value_letters='eEFiIlmMDCS';  code_letters='eE';      module_letters='mM' ;;
    ruby)
      value_letters='eFiIrKEC';     code_letters='e';       module_letters='r' ;;
    node|nodejs|deno|bun)
      value_letters='epr';          code_letters='ep';      module_letters='r' ;;
    php)
      value_letters='rBRFEH';       code_letters='rBRFEH';  module_letters='' ;;
    *) return 0 ;;
  esac

  local w rest i ch informational=0 script=0
  set -- $seg
  shift 2>/dev/null || true
  for w in "$@"; do
    case "$w" in
      --version|-V|--help|-h|-\?) informational=1; continue ;;
      --eval|--eval=*|--print|--print=*|--command|--command=*)
        printf 'indirect'; return 0 ;;
      --require|--require=*)
        printf 'module'; return 0 ;;
      --*) continue ;;
      -) continue ;;
      -*)
        # Walk the cluster left to right. The first value-taking letter
        # swallows the rest of the token, so nothing after it is a flag;
        # if that letter is a code letter the interpreter is running code,
        # whether its argument is attached (`-c'…'`) or separated (`-c '…'`).
        rest="${w#-}"
        i=0
        while [ "$i" -lt "${#rest}" ]; do
          ch="${rest:$i:1}"
          case "$code_letters" in *"$ch"*) printf 'indirect'; return 0 ;; esac
          [ -n "$module_letters" ] && case "$module_letters" in *"$ch"*) printf 'module'; return 0 ;; esac
          case "$value_letters" in *"$ch"*) break ;; esac
          i=$((i + 1))
        done
        continue ;;
    esac
    # A positional. It counts as the SCRIPT only if it is a real file:
    # without that test `python3 -X dev` reads its own flag value as a
    # script and hands the stdin channel back.
    case "$w" in
      /*) [ -f "$w" ] && script=1 ;;
      *)  [ -f "${KM_CWD:-.}/$w" ] && script=1 ;;
    esac
  done
  [ "$informational" = "1" ] && return 0
  # No code flag and no script: every one of these interpreters then
  # reads its program from STDIN. `python3 <<< 'CODE'` and a bare
  # `python3` carry arbitrary code past a check looking for `-c`.
  [ "$script" = "1" ] || printf 'indirect'
}

kernel_mandate_awk_sed_verdict() {
  local cmd="$1" seg="$2"
  # gawk and GNU sed `--sandbox` disable these constructs in the interpreter
  # itself, so such a program is inert by construction. Accepted only when
  # the command word is `gawk` or `sed`: a bare `awk` may be mawk or busybox.
  case "$cmd" in
    gawk|sed)
      case " $seg " in *" --sandbox "*|*" --sandbox="*) return 0 ;; esac ;;
  esac
  case "$cmd" in
    awk|gawk|mawk|nawk|busybox)
      # `system`, `getline`, `close` and `ENVIRON` have no inert use.
      # A pipe or redirect is only a redirect in a print statement; elsewhere
      # `|` is alternation and `>` comparison. String and regex literals are
      # removed first, since a `}` or `;` inside one ends the statement scan.
      AWKSEG="$seg" perl -e '
        my $p = $ENV{AWKSEG};
        $p =~ s{"(?:\\.|[^"\\])*"}{ }g;
        $p =~ s{/(?:\\.|[^/\\])*/}{ }g;
        # gawk can also load a shared library, which is strictly worse
        # than system(): `@load`, `@include`, `extension()` and their
        # -l/--load/-i/--include flags all reach code this kernel never
        # sees, and look inert to a scan for redirects.
        print "indirect" if $p =~ /(^|[^a-zA-Z_])(system|getline|close|ENVIRON|extension)([^a-zA-Z_0-9]|$)/
                         || $p =~ /\@(load|include)/
                         || $ENV{AWKSEG} =~ /(^|\s)(-l|-i|--load|--include)(\s|=)/
                         || $p =~ /printf?[^;}]*[|>]/;
      ' 2>/dev/null || printf 'indirect'
      ;;
    sed)
      # sed's dangerous commands are single letters, so they can only be
      # recognised once the places a letter means itself are removed:
      # the bodies of `s` and `y`, and `/regex/` addresses. What is left
      # is command positions, where r/R/w/W/e/F/v name a file or run a
      # shell. The `w` and `e` FLAGS of an s command are caught while
      # its body is being removed.
      SEDSEG="$seg" perl -e '
        my $p = $ENV{SEDSEG}; my $bad = 0;
        # Drop the command word and every -flag first. `-e` is sed`s
        # expression flag and `e` is its shell-out command; read as one
        # letter they are indistinguishable, and reading the flag as the
        # command refuses `sed -e p`, which is as ordinary as sed gets.
        $p =~ s/^\s*\S+//;
        $p =~ s/(^|\s)--?\S+/ /g;
        $p =~ s{([sy])(\W)((?:\\.|(?!\2).)*)\2((?:\\.|(?!\2).)*)\2([a-zA-Z0-9]*)}{
          $bad = 1 if $1 eq "s" && $5 =~ /[we]/; " ";
        }gex;
        $p =~ s{/(?:\\.|[^/])*/}{ }g;
        $bad = 1 if $p =~ /(^|[^a-zA-Z])[rRwWeFv]([^a-zA-Z]|$)/;
        print "indirect" if $bad;
      ' 2>/dev/null || printf 'indirect'
      ;;
  esac
}

# kernel_mandate_bound_text <text>
# Bounds a deny message: its length is set by what it quotes, and an
# unbounded message pushes arbitrary text into the reading agent's context.
# The middle gives way. Pure parameter expansion: no process at any size.
kernel_mandate_bound_text() {
  local t="$1" keep=2000
  if [ "${#t}" -le $((keep * 2)) ]; then
    printf '%s' "$t"
    return 0
  fi
  printf '%s\n\n[... %s characters elided by kernel-mandate ...]\n\n%s' \
    "${t:0:keep}" "$(( ${#t} - keep * 2 ))" "${t: -keep}"
}

# kernel_mandate_deny <short-detail-for-log> <reason>
# Emits the repo-standard deny JSON and exits 0.
# The reason is bounded, then passed to jq on stdin (argv is capped by
# MAX_ARG_STRLEN, and no JSON means ALLOW). If jq fails anyway, a fixed
# deny string is emitted: losing the explanation must not lose the decision.
kernel_mandate_deny() {
  local reason
  kernel_mandate_log "deny" "$1"
  reason=$(kernel_mandate_bound_text "$2")
  # KM_DECIDED is set AFTER the verdict is on stdout: set earlier, a fault
  # before the printf would make the exit trap stand down with no verdict.
  if printf '%s' "$reason" | "$KM_JQ" -Rs '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": .
    }
  }' 2>/dev/null; then
    KM_DECIDED=1
    exit 0
  fi
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] kernel-mandate refused this call but could not render the explanation for it. The decision stands; only the wording was lost. The recorded reason is the last deny in the decision log under the kernel-mandate state directory."}}'
  KM_DECIDED=1
  exit 0
}

# kernel_mandate_role_field <role> <jq-path-expression>
# Prints the JSON value at .roles[<role>]<expr> (compact) or "null".
kernel_mandate_role_field() {
  printf '%s' "$KM_MANIFEST_JSON" | "$KM_JQ" -c --arg r "$1" ".roles[\$r]$2 // null" 2>/dev/null || echo "null"
}

# kernel_mandate_code_calls_in_scope <code> <network-allow-json> <method-regex>
# — true when the role declares a network scope AND every matching call
# in the code names a literal destination inside it. Without a declared
# scope nothing can be shown permitted, so the blanket refusal stands.
kernel_mandate_code_calls_in_scope() {
  local cc_code="$1" cc_scope="$2" cc_re="$3" cc_call cc_arg cc_lit cc_auth cc_seen=0
  [ "$cc_scope" != "null" ] || return 1
  while IFS= read -r cc_call; do
    [ -n "$cc_call" ] || continue
    cc_arg="${cc_call#*(}"
    cc_arg=$(printf '%s' "$cc_arg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*[,)].*$//')
    case "$cc_arg" in
      \"*\") cc_lit="${cc_arg%\"}"; cc_lit="${cc_lit#\"}" ;;
      \'*\') cc_lit="${cc_arg%\'}"; cc_lit="${cc_lit#\'}" ;;
      *) cc_lit="" ;;
    esac
    case "$cc_lit" in *'${'*|*'`'*) cc_lit="" ;; esac
    kernel_mandate_is_network_url "$cc_lit" || return 1
    cc_auth=$(kernel_mandate_url_authority "$cc_lit")
    [ -n "$cc_auth" ] || return 1
    kernel_mandate_authority_in_scope "$cc_auth" "$cc_scope" || return 1
    cc_seen=1
  done < <(printf '%s' "$cc_code" | grep -oE "${cc_re}[[:space:]]*\([^)]*\)?" 2>/dev/null)
  [ "$cc_seen" = "1" ]
}
