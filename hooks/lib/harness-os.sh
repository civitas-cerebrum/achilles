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

# The binding tag carried by every dispatch prompt. The role name is
# required; an optional `#NONCE` makes the binding collision-proof and
# robust against a transcript that quotes another role's tag — the kernel
# registers each dispatch's nonce→role at dispatch time and resolves the
# child by the nonce in its own transcript, so mixed parallel dispatch no
# longer degrades to the unbound fallback whenever the child has its own
# transcript. Nonce: 4+ chars of [a-z0-9]. Both forms are accepted.
HOS_ROLE_TAG_RE='<<harness-os-role: [a-z][a-z0-9-]*(#[a-z0-9]{4,})?>>'
# Anything SHAPED like a role tag. A near miss — `<<harness-os-role:  judge>>`
# with two spaces, a nonce too short, a stray character — does not match the
# strict form above, so the dispatch gate's foreign-tag scan never saw it and
# the prompt was allowed through. It is inert today for exactly one reason:
# the resolver happens to be precisely as strict as the gate. Round 30 made
# the argument that this is debt rather than safety, and it is right — the
# gate's ALLOW is only sound relative to today's resolver, and the two live
# in different files and run in different processes, which is the one shape
# of coupling this project has been burned by four times.
HOS_ROLE_NEARTAG_RE='<<[[:space:]]*harness-os-role[^>]*>>'

# harness_os_tag_roles — read text on stdin, print the role NAME of every
# strict role tag in it, one per line, sorted and unique.
#
# ONE DECISION, ONE PLACE. This extraction existed twice — in the dispatch
# gate's tag-purity check and in resolution rung 4b — as two hand-rolled
# copies of the same sed. They agreed, and the entire security of the bare
# tag rests on them agreeing: the gate validates the PROMPT it can see, the
# resolver reads the TRANSCRIPT at a different time in a different process,
# and nothing anywhere sees both sides. Two copies that must agree, with no
# test able to catch the day they stop, is the defect this project has
# recorded under four different names. It is one function now.
harness_os_tag_roles() {
  grep -oE "$HOS_ROLE_TAG_RE" 2>/dev/null \
    | sed -E 's/^<<harness-os-role: ([a-z][a-z0-9-]*)(#[a-z0-9]+)?>>$/\1/' \
    | grep -v '^$' | sort -u || true
}

# harness_os_neartag — read text on stdin, print the first tag-SHAPED string
# that the strict form does not accept, or nothing.
harness_os_neartag() {
  local nt_all nt_one
  nt_all=$(grep -oE "$HOS_ROLE_NEARTAG_RE" 2>/dev/null || true)
  [ -n "$nt_all" ] || return 0
  while IFS= read -r nt_one; do
    [ -n "$nt_one" ] || continue
    printf '%s' "$nt_one" | grep -qE "^${HOS_ROLE_TAG_RE}\$" 2>/dev/null && continue
    printf '%s' "$nt_one"
    return 0
  done <<< "$nt_all"
}

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
# harness_os__emit_fixed_deny <reason>
# A deny that needs nothing but the shell: no jq, no manifest, no role.
# Used for the failures that happen before this kernel can read anything,
# where the alternative is returning "not governed" and meaning it.
harness_os__emit_fixed_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  HOS_DECIDED=1
  exit 0
}

harness_os_load() {
  HOS_INPUT="$1"

  # The operator's kill-switch outranks everything below, including the
  # guards. Someone turning enforcement off must always be able to.
  case "${HARNESS_OS:-}" in
    0|false|off) return 1 ;;
  esac

  HOS_JQ="$(harness_os__jq)"
  if [ -z "$HOS_JQ" ]; then
    # Returning 1 here means "this project is not governed", and for an
    # ungoverned project that is true. But jq is how this kernel reads
    # the payload AND the manifest, so with a manifest present the same
    # return says "not governed" about a project that is — every role
    # unenforced, silently, because a dependency is missing. Enforcement
    # that can be switched off by uninstalling a tool is not enforcement.
    # The manifest is located here by file test alone, which is all that
    # is possible without jq and all that is needed to tell the two
    # states apart.
    local probe
    probe="${HARNESS_OS_MANIFEST:-$( { git rev-parse --show-toplevel 2>/dev/null || pwd; } )/.claude/harness-os.json}"
    if [ -f "$probe" ]; then
      harness_os__emit_fixed_deny "[BLOCKED] harness-os cannot enforce this project: jq is not installed, and jq is how the kernel reads both the manifest and the call it is deciding about. This project HAS a role manifest, so treating the kernel as absent would leave every role unenforced without saying so. Install jq (https://jqlang.github.io/jq/), or set HARNESS_OS=0 to run this session ungoverned on purpose."
    fi
    return 1
  fi

  HOS_TOOL=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
  HOS_CWD=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
  HOS_AGENT_ID=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
  HOS_TOOL_USE_ID=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.tool_use_id // empty' 2>/dev/null || echo "")
  HOS_PARENT_TOOL_USE_ID=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.parent_tool_use_id // empty' 2>/dev/null || echo "")
  HOS_TRANSCRIPT=$(printf '%s' "$HOS_INPUT" | "$HOS_JQ" -r '.transcript_path // empty' 2>/dev/null || echo "")

  # WHERE THE MANIFEST IS, and this is the most important question in
  # the file: every axis in this kernel is dead code the moment the
  # answer is "nowhere". Not-found means the project never opted in,
  # which means ALLOW — so a wrong answer here does not deny anything,
  # it silently ungoverns everything, with no deny, no warning and no
  # line in the decision log.
  #
  # It used to be a POINT LOOKUP keyed on git:
  #
  #     HOS_ROOT=$(cd "$HOS_CWD" && git rev-parse --show-toplevel || echo "$HOS_CWD")
  #     HOS_MANIFEST="$HOS_ROOT/.claude/harness-os.json"
  #
  # which reads as "the project root", and is not. It is an assumption
  # that repo-root equals project-root, documented nowhere as a
  # requirement, and false for the two most ordinary ways code sits on
  # disk. Round 27 demonstrated both against the benchmark's own
  # manifest:
  #
  #   a governed project checked out inside a larger repo — git answers
  #   with the OUTER root, the manifest is not there, and the reviewer,
  #   a role with no write grants at all, was allowed to overwrite the
  #   manifest itself. The root of trust, rewritable by the most
  #   restricted role in the manifest — not by defeating a check, but by
  #   making every check unreachable;
  #
  #   a non-git project with cwd one directory down — same silence.
  #
  # So discovery WALKS UP, the way every other tool finds its own
  # config, and stops at the first `.claude/harness-os.json`. The
  # directory holding it is the project root, which makes the root a
  # consequence of where the law is rather than a guess that the law
  # will be where git says.
  #
  # Round 10 swept "is this kernel applicable here?" and fixed four
  # instances — a nonexistent cwd, a relative cwd, a missing jq, an
  # unimplemented version. This is a fifth, and the one that needed no
  # adversary at all: only a project that lives inside a repo.
  if [ -n "${HARNESS_OS_MANIFEST:-}" ]; then
    HOS_MANIFEST="$HARNESS_OS_MANIFEST"
    HOS_ROOT=$(cd "$HOS_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$HOS_CWD")
  else
    local hos_dir hos_found=""
    hos_dir=$(cd "$HOS_CWD" 2>/dev/null && pwd -P 2>/dev/null || printf '%s' "$HOS_CWD")
    # Bounded by construction: each step drops a path component, so the
    # walk terminates at `/` whatever it is handed. A relative or
    # nonexistent cwd falls through to the not-found branch, where the
    # gate's own cwd-fault check (round 10) reports it properly.
    case "$hos_dir" in
      /*)
        while [ -n "$hos_dir" ]; do
          if [ -f "$hos_dir/.claude/harness-os.json" ]; then hos_found="$hos_dir"; break; fi
          [ "$hos_dir" = "/" ] && break
          hos_dir=$(dirname "$hos_dir")
        done ;;
    esac
    if [ -n "$hos_found" ]; then
      HOS_ROOT="$hos_found"
    else
      HOS_ROOT=$(cd "$HOS_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$HOS_CWD")
    fi
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
    # A version this kernel does not implement used to be treated as
    # inactive, on the reasoning that half-enforcing grants you do not
    # understand is worse than not enforcing them. The first half of that
    # is right and the conclusion is not: a project that ships
    # `harnessOsVersion: 2` to an older kernel got NO enforcement and no
    # indication of it, which is the one outcome worse than both. Refuse
    # instead, and name the mismatch — the operator can then upgrade or
    # opt out deliberately.
    if [ "$version" != "1" ]; then
      harness_os__emit_fixed_deny "[BLOCKED] harness-os cannot enforce this project: its manifest declares a harnessOsVersion this kernel does not implement (this kernel implements version 1). Enforcing grants the kernel cannot interpret would be unsound, and ignoring them would leave every role unenforced without saying so. Upgrade the harness-os kernel to match the manifest, correct the manifest's harnessOsVersion, or set HARNESS_OS=0 to run this session ungoverned on purpose."
    fi
  fi

  HOS_STATE_DIR="${HARNESS_OS_STATE_DIR:-$HOS_ROOT/.claude/harness-os.state}"
  HOS_TTL=$(printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -r '.settings.dispatchTtlSeconds // 1800' 2>/dev/null || echo 1800)
  case "$HOS_TTL" in ''|*[!0-9]*) HOS_TTL=1800 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# Role resolution ladder
# ---------------------------------------------------------------------------

# An agent id becomes a FILENAME, and a filename is where two distinct
# ids can become one. `tr -c` maps every unsafe character to `_`, so
# `a/b` and `a:b` both land on `a_b` — and a binding file is what says
# which role an agent is. Two agents sharing one file is one agent
# inheriting the other's role.
#
# Not reachable today: agent ids are host-assigned and this host assigns
# safe ones. Round 27 flagged it as a sharp edge rather than an escape,
# and it is worth removing while it is still cheap, because the day a
# host starts putting a `/` or a `:` in an id is not a day anyone will
# connect to this function.
#
# An id that needs no substitution keeps its own name — so every binding
# already on disk, and every test that seeds one by hand, is unchanged.
# Only the ids that WOULD collide grow a digest of the original, which
# is exactly the set where the collision lives.
harness_os__sanitize_id() {
  local raw="$1" safe
  safe=$(printf '%s' "$raw" | tr -c 'a-zA-Z0-9_-' '_')
  if [ "$safe" = "$raw" ]; then printf '%s' "$safe"; return 0; fi
  printf '%s-%s' "$(printf '%s' "$safe" | cut -c1-200)" \
    "$(printf '%s' "$raw" | cksum 2>/dev/null | cut -d' ' -f1)"
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

  # `nonce:`-prefixed entries mirror a tool_use_id entry (same role); skip
  # them so a nonce'd dispatch is not double-counted as two in-flight
  # dispatches, which would only ever cause a false ambiguity.
  distinct=$(printf '%s' "$existing" | "$HOS_JQ" -r --argjson now "$now" --argjson ttl "$HOS_TTL" '
    [ to_entries[]
      | select(.key | startswith("nonce:") | not)
      | select((.value.ts // 0) >= ($now - $ttl))
      | select((.value.claimed_by // "") == "")
      | .value.role ] | unique | if length == 1 then .[0] else empty end
  ' 2>/dev/null || echo "")
  [ -n "$distinct" ] || return 0
  role="$distinct"

  local updated
  updated=$(printf '%s' "$existing" | "$HOS_JQ" -c --argjson now "$now" --argjson ttl "$HOS_TTL" --arg who "$agent_id" '
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
  # <<harness-os-role: NAME[#NONCE]>> (the dispatch gate denies prompts
  # without a tag). Only USER-authored transcript lines count: an agent
  # echoing a foreign role tag in its own output must not be able to
  # poison (or ambiguate) its binding, so assistant lines are filtered
  # out before tag extraction.
  if [ -n "$HOS_TRANSCRIPT" ] && [ -f "$HOS_TRANSCRIPT" ]; then
    local user_tags nonce_roles distinct_nonce_role tags
    # A role tag only counts when it comes from the DISPATCH PROMPT.
    #
    # Transcript lines of type "user" are not all operator-authored: a
    # tool_result is delivered as a user line whose content is whatever
    # the agent just fetched. An adversarial reviewer used exactly that
    # to promote an unbound agent to `judge` by having it READ a file
    # containing the literal string `<<harness-os-role: judge>>` — a
    # string that appears in this project's own documentation, so it is
    # plantable and guessable. Any line carrying a tool_result (or tool
    # output/use) is therefore excluded before tags are extracted, and
    # only the FIRST such qualifying line is considered: the dispatch
    # brief is the child's opening turn, so later user turns cannot
    # re-bind an agent either.
    user_tags=$(grep -E '"(type|role)"[[:space:]]*:[[:space:]]*"user"' "$HOS_TRANSCRIPT" 2>/dev/null \
      | grep -vE '"(tool_result|tool_use|tool_output)"|"toolUseResult"' \
      | head -n1 \
      | grep -oE "$HOS_ROLE_TAG_RE" || echo "")

    # 4a — NONCE match (collision-proof). For every nonce-bearing tag in
    # the child's own transcript, look up the registered nonce→role. If
    # all resolved nonces name ONE role, that is the identity — exact
    # even amid quoted foreign tags or parallel sibling dispatch.
    if [ -n "$user_tags" ] && [ -f "$HOS_STATE_DIR/dispatch-registry.json" ]; then
      local nonces n role_for
      nonces=$(printf '%s\n' "$user_tags" | grep -oE '#[a-z0-9]{4,}>>$' | sed -E 's/^#([a-z0-9]+)>>$/\1/' | sort -u || echo "")
      nonce_roles=""
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        role_for=$("$HOS_JQ" -r --arg k "nonce:$n" '.[$k].role // empty' "$HOS_STATE_DIR/dispatch-registry.json" 2>/dev/null || echo "")
        [ -n "$role_for" ] && nonce_roles="$nonce_roles$role_for"$'\n'
      done <<< "$nonces"
      distinct_nonce_role=$(printf '%s' "$nonce_roles" | grep -v '^$' | sort -u || echo "")
      if [ -n "$distinct_nonce_role" ] && [ "$(printf '%s\n' "$distinct_nonce_role" | wc -l | tr -d ' ')" = "1" ]; then
        HOS_ROLE="$distinct_nonce_role"
        if harness_os__role_exists "$HOS_ROLE"; then
          harness_os__bind "$HOS_AGENT_ID" "$HOS_ROLE"
          HOS_ROLE_STATE="governed"
          return 0
        fi
        HOS_ROLE=""
      fi
    fi

    # 4b — nonce-free fallback: exactly ONE distinct role across the
    # transcript's user-line tags → it is the child's own transcript and
    # that tag is its identity. Multiple distinct roles → a parent-wide
    # transcript; ambiguous, fall through.
    tags=$(printf '%s\n' "$user_tags" | harness_os_tag_roles)
    if [ -n "$tags" ] && [ "$(printf '%s\n' "$tags" | wc -l | tr -d ' ')" = "1" ]; then
      HOS_ROLE="$tags"
      # CORROBORATE THE BARE TAG AGAINST WHAT WAS ACTUALLY DISPATCHED.
      #
      # Rungs 1-4a anchor identity to something the caller demonstrably
      # owns: a binding recorded for this agent_id, a parent tool_use_id
      # naming its own dispatch, a nonce this kernel itself minted and
      # wrote to the registry. This rung anchored it to a string printed
      # in a file, corroborated by nothing — and rounds 29 and 30
      # independently made the same argument about it: the FORGEABLE
      # path was the DEFAULT path, which is this project's own
      # anti-pattern ("a gate whose failure mode is ALLOW is not a
      # gate") pointed at identity instead of at path scope.
      #
      # Requiring corroboration unconditionally would break the
      # documented plain-tag flow wherever it is legitimate, which is
      # why round 29 left it alone and said so. The middle is sound and
      # costs nothing: corroborate WHEN CORROBORATION IS POSSIBLE. If
      # this session has live dispatch records the kernel knows which
      # roles were actually summoned, and a tag naming any other role is
      # a claim it can refuse on evidence. If there are none — no
      # dispatcher in play, or a human driving with tags by hand —
      # there is nothing to check against and the tag stands, exactly as
      # before.
      #
      # `strict` refuses an uncorroborated tag outright; `auto` refuses
      # only when the registry can contradict it. Either way the fall is
      # to unbound, where unboundAgentPolicy decides — a degradation,
      # not a break.
      #
      # AND THE DEFAULT IS `off`, which is a decision worth being
      # explicit about rather than burying. Two reviewers argued the
      # believe-on-sight default is wrong and I think they are right on
      # the merits. I did not flip it, because `auto` refuses any
      # tag-bound agent whose dispatch was never registered — a session
      # resumed after the state directory was cleared, a child spawned
      # by something that is not this gate, a tag placed by hand — and
      # silently narrowing those into unbound is a functional break I
      # should not choose on a user's behalf from inside a review loop.
      # What was mine to fix was that the choice had no name and no
      # switch. It has both now, `validate` recommends `auto` for any
      # manifest that has a dispatcher, and the argument is recorded in
      # docs/benchmark.md rather than settled quietly.
      local tag_policy tag_ok tag_reg tag_now
      tag_policy=$(printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -r '.settings.roleTagCorroboration // "off"' 2>/dev/null || echo "off")
      if [ "$tag_policy" != "off" ]; then
        tag_reg="$HOS_STATE_DIR/dispatch-registry.json"
        tag_now=$(date +%s)
        tag_ok=$(cat "$tag_reg" 2>/dev/null | "$HOS_JQ" -r --argjson now "$tag_now" --argjson ttl "$HOS_TTL" --arg r "$HOS_ROLE" '
          [ to_entries[] | select((.value.ts // 0) >= ($now - $ttl)) ] as $live
          | if ($live | length) == 0 then "none"
            elif ([ $live[] | .value.role ] | index($r)) != null then "yes"
            else "no" end
        ' 2>/dev/null || echo "none")
        case "$tag_ok" in
          yes)  : ;;
          no)   HOS_ROLE="" ;;
          *)    [ "$tag_policy" = "strict" ] && HOS_ROLE="" ;;
        esac
      fi
      if [ -n "$HOS_ROLE" ] && harness_os__role_exists "$HOS_ROLE"; then
        harness_os__bind "$HOS_AGENT_ID" "$HOS_ROLE"
        HOS_ROLE_STATE="governed"
        return 0
      fi
      HOS_ROLE=""
    fi
  fi

  # Rung 5 — registry claim (unambiguous single-role in-flight set).
  #
  # OFF BY DEFAULT since round 29, and the reason is worth stating
  # exactly, because every other rung is a different KIND of answer.
  # Rungs 1-4 answer "this agent is role X": a binding file recorded for
  # this agent_id, a parent tool_use_id that names this agent's own
  # dispatch, a tag on this agent's own transcript. Rung 5 answers
  # "some single role is in flight, therefore you are it" — an identity
  # oracle keyed on AMBIENT state, which never checks that the caller is
  # the child of that dispatch. And it persists the binding.
  #
  # Round 29 demonstrated the consequence: with a judge legitimately
  # dispatched and in flight, an unrelated fresh agent — not the child,
  # no parent, no tag — wrote the ledger as the judge. That is the one
  # direction this project had not found before: a rung resolving a role
  # MORE privileged than the caller holds.
  #
  # It was safe in practice only by an emergent property nobody had
  # written down as load-bearing: registration runs in the parent's
  # PreToolUse, before the child is spawned, so a real child always has
  # its own entry by the time it calls. Rounds 3, 4 and 22 are all about
  # what happens to an undocumented invariant, and a host that ever
  # reused an agent_id or let a call precede its own registration would
  # turn this into a live escalation with nothing to catch it.
  #
  # So it is opt-in. Turning it off does not break a project, it
  # DEGRADES it: an agent that would have been guessed at is now
  # unbound, and unboundAgentPolicy — which exists for exactly that
  # caller — decides. That is the safe direction, and the deny an
  # operator sees names the setting.
  local claim_policy
  claim_policy=$(printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -r '.settings.ambientDispatchClaim // "off"' 2>/dev/null || echo "off")
  if [ "$claim_policy" = "on" ]; then
  HOS_ROLE=$(harness_os__registry_claim "$HOS_AGENT_ID")
  else
  HOS_ROLE=""
  fi
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

# harness_os_register_dispatch <role> <tool_use_id> [nonce]
# Records an Agent dispatch in the registry (TTL-pruned, atomic). Keyed
# by tool_use_id; when the dispatch prompt carried a #NONCE it is also
# recorded under "nonce:<NONCE>" so a child can bind exactly by the nonce
# in its own transcript (see resolve rung 4a).
harness_os_register_dispatch() {
  local role="$1" id="$2" nonce="${3:-}" reg="$HOS_STATE_DIR/dispatch-registry.json" now existing updated
  [ -n "$id" ] || return 0
  mkdir -p "$HOS_STATE_DIR" 2>/dev/null || return 0
  now=$(date +%s)
  existing="{}"
  if [ -f "$reg" ]; then
    existing=$(cat "$reg" 2>/dev/null || echo "{}")
    printf '%s' "$existing" | "$HOS_JQ" -e 'type == "object"' >/dev/null 2>&1 || existing="{}"
  fi
  updated=$(printf '%s' "$existing" | "$HOS_JQ" -c \
    --arg id "$id" --arg role "$role" --arg nonce "$nonce" --argjson now "$now" --argjson ttl "$HOS_TTL" '
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
# The kernel used to tokenise a command segment by deleting every quote
# character and splitting on whitespace. That conflates two things the
# shell keeps strictly apart: a quoted word is a LITERAL, an unquoted one
# is a pattern the shell expands. Deleting the quotes made
# `find tests -name "*.json"` look like a read of every .json file in the
# project — a false deny on one of the most ordinary commands there is.
#
# These two helpers restore the distinction. Neither is a full shell
# parser, and neither needs to be: both fail toward "treat it as
# unquoted", which is the conservative direction (an unquoted word is
# expanded and scope-checked; a quoted one is only checked literally).

# harness_os_shell_words — read one segment on stdin, emit one word per
# line prefixed with its quoting state:
#   Q<word>  every character came from inside quotes -> the shell will
#            NOT glob-expand it; it names exactly this literal
#   U<word>  at least one character was unquoted -> expansion applies
# Unquoted '>' also separates words, matching the redirection split the
# caller previously did with sed (a '>' inside quotes is just text).
# The whole input is one record, matching harness_os_unquoted_view. With
# awk's default newline record separator the two scanners disagreed about
# a quoted string spanning newlines: this one reset its quote state at
# every line, so `echo "row1\n.env\nrow3" > notes.txt` had `.env` read as
# an unquoted operand and denied as an out-of-scope read, when bash only
# ever writes it as text. Two parsers of the same command must not
# disagree about where the quotes are.
harness_os_shell_words() {
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

# harness_os_unquoted_view — read a segment on stdin, emit it with the
# quoted regions neutralised. What survives is exactly the text the shell
# still interprets, so a check run against this view fires on
# `cat {.env,x}` and stays quiet on the JSON literal `echo '{"a":1}'`.
# Modes:
#   both    (default) blank every quoted run — globbing and brace
#           expansion die inside either quote style
#   single  blank only single-quoted runs — $… and `…` keep expanding
#           inside double quotes, so expansion checks must see in there
#   redir   keep every character EXCEPT that < and > inside quotes lose
#           their meaning. Redirection is the one thing that must be read
#           from a view where quoted text cannot pose as syntax and
#           quoted PATHS survive: `grep '=>' f` redirects nothing, while
#           `echo x > "docs/ledger.json"` still names its target.
#   split   keep every character EXCEPT that the command separators
#           ; | & and newline lose their meaning INSIDE quotes, each
#           swapped for a distinct placeholder the caller restores after
#           splitting. `echo "a; b"` is one command, not two, and
#           splitting it into two produced denies on ordinary quoted text
#           containing a semicolon — which is most lines of JavaScript.
# The whole input is one record (RS is a byte no command contains), so a
# quoted NEWLINE is seen by the scanner rather than being pre-split by
# awk. That matters only for 'split', which is the mode that runs on a
# whole multi-line command; the other modes are handed one segment.
harness_os_unquoted_view() {
  awk -v mode="${1:-both}" 'BEGIN { RS = "\034"; ORS = "" }
  {
    s = $0; n = length(s); out = ""; q = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      # A backslash escapes the next character everywhere except inside
      # single quotes, where bash does no escaping at all. The escaped
      # character is literal TEXT and can never be syntax — not a quote,
      # not a separator, not a redirect. Missing this was an escape of my
      # own making: `echo \" ; cat .env` reads as an opening quote to a
      # naive scanner, which then swallows the `;` and hides `cat .env`
      # inside a string bash never saw. It also over-split `"a\" ; b"`,
      # where the escaped quote does NOT end the string.
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

# harness_os_unsplit — restore the placeholders harness_os_unquoted_view
# 'split' put in, so a segment carries its original text verbatim.
harness_os_unsplit() {
  tr '\002\003\004\005' ';|&\n'
}

# harness_os_quotes_balanced — 0 when every quote in the input on stdin
# is closed. An unterminated quote means the scanner's idea of what is
# text and what is syntax has diverged from any shell's, and everything
# after the stray quote reads as inert string. bash refuses such a
# command outright ("unexpected EOF while looking for matching") so
# nothing is lost by refusing it here too — and resting on "the shell
# will error anyway" is exactly the assumption that becomes an escape
# the day the runtime differs.
harness_os_quotes_balanced() {
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

harness_os_glob_to_ere() {
  local g="$1" ph=$'\001' out="" i c
  # Escape the regex metacharacters in the LITERAL part of the glob, so
  # `docs/e2e-ledger.json` matches that file and not `docs/e2e-ledgerXjson`.
  # `*` and `?` are deliberately NOT escaped — they are the glob operators
  # the conversion below turns into character classes.
  #
  # This was a sed bracket expression, and it escaped NOTHING. `s/[.[\]…/`
  # does not mean "the class containing ] "; POSIX reads it as the class
  # `{. [ \}` followed by the literal text `()+{}^$|\]`, which never
  # occurs — so every metacharacter in every manifest path scope was a
  # live regex operator, silently, in the one function every path
  # decision flows through. Round 24 found it by testing the function
  # character by character rather than reading it.
  #
  # The replacement is pure bash, which is the real lesson rather than a
  # corrected class: a bracket expression whose meaning depends on where
  # `]` sits and how many backslashes survive three layers of quoting is
  # a construct that can be wrong while looking right, and this one was,
  # for twenty-three rounds. A `case` cannot be. It is also one fewer
  # execve in the hottest function in the kernel.
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
  g=$(printf '%s' "$g" | sed \
    -e "s|/${ph}\$|(/.*)?|" \
    -e "s|^${ph}/|(.*/)?|" \
    -e "s|/${ph}/|/(.*/)?|g" \
    -e "s|${ph}|.*|g")
  printf '^%s$' "$g"
}

# harness_os_url_authority <url> — print the authority a client will
# actually connect to (host[:port], lowercased), or nothing when the
# string is not a network URL.
#
# The whole point is that this is a PARSER problem and a command group is
# a regex. Round 33 pointed a grant reading `^curl … http://localhost:4173`
# at `http://localhost:4173@example.com/` and curl connected to
# example.com — `localhost:4173` is USERINFO, not a host. The visible
# prefix and the destination are different strings, which is exactly the
# shape a prefix match cannot see.
# harness_os_is_network_url <string> — true when the string names a
# REMOTE resource. ONE DECISION, ONE PLACE, and case-insensitively.
#
# This was three copies of a lowercase prefix list — here, in the
# WebFetch arm, and in the MCP arm — and all three agreed on being
# wrong. RFC 3986 says a scheme is case-insensitive and curl normalises
# it before dialling, so `HTTP://evil.example/` is a URL to every client
# and was a URL to none of these lists. Round 35 appended one to an
# otherwise-permitted curl and shipped an in-scope file to a host the
# manifest forbids; the identical command in lowercase was correctly
# refused. A confident DENY for `http://` beside a silent ALLOW for
# `HTTP://` is worse than no check, because it looks exactly like one.
#
# Every network fix since round 33 — userinfo, lookalike hosts, the
# override flags, the proxy environment — sits downstream of this
# function, so every one of them inherited the blindness. That is why
# this is a shared predicate now rather than a fourth list.
harness_os_is_network_url() {
  case "$1" in *://*) : ;; *) return 1 ;; esac
  # INVERTED, after round 36. This was an ALLOWLIST of network schemes,
  # and an unrecognised scheme therefore meant "not a network URL" —
  # skipped, no authority parsed, no scope checked. The machine's own
  # curl compiles `gophers`, `smbs`, `rtmp` and `rtmps`; none was on the
  # list, and `curl … rtmp://127.0.0.1:9999/live/x` opened a live
  # connection to a forbidden host under a kernel ALLOW.
  #
  # The shape was wrong by this project's own stated principle, which
  # the network scan two functions away already follows: exempt the
  # known-safe and check everything unknown. This did the opposite, and
  # an unknown scheme failed OPEN. Worse, it coupled the kernel to
  # libcurl's compiled protocol table — a list some other tool maintains
  # and this one must match — which is the coupling the benchmark has
  # been burned by repeatedly.
  #
  # So: anything spelled `scheme://…` is a destination, unless the
  # scheme is one of the few that names something LOCAL or INERT. A
  # scheme nobody has heard of is checked, because the client that dials
  # it is more dangerous than the one that does not exist.
  case "$(printf '%s' "${1%%://*}" | tr 'A-Z' 'a-z')" in
    file|data|blob|about|javascript|chrome|chrome-extension|resource|jar|classpath|filesystem) return 1 ;;
    *) return 0 ;;
  esac
}

harness_os_url_authority() {
  local u="$1" auth
  harness_os_is_network_url "$u" || return 0
  auth="${u#*://}"
  # Everything after the first /, ?, or # is path/query/fragment.
  auth="${auth%%/*}"; auth="${auth%%\?*}"; auth="${auth%%#*}"
  # Userinfo is everything up to the LAST `@` — `a@b@c` connects to `c`.
  case "$auth" in *@*) auth="${auth##*@}" ;; esac
  printf '%s' "$auth" | tr 'A-Z' 'a-z'
}

# harness_os_url_userinfo <url> — print the userinfo portion, or nothing.
# Its presence is the signal: an agent has no reason to embed credentials
# in a URL, and it is the one spelling that makes a URL's prefix differ
# from its destination.
harness_os_url_userinfo() {
  local u="$1" auth
  harness_os_is_network_url "$u" || return 0
  case "$u" in *://*) : ;; *) return 0 ;; esac
  auth="${u#*://}"; auth="${auth%%/*}"; auth="${auth%%\?*}"; auth="${auth%%#*}"
  case "$auth" in *@*) printf '%s' "${auth%@*}" ;; esac
}

# harness_os_authority_in_scope <authority> <json-array> — does the
# authority match one of the manifest's network entries? An entry with no
# port matches any port on that host; an entry with a port must match
# exactly. A leading `*.` matches subdomains, and nothing else does —
# `localhost:4173` must NOT match `localhost:4173.evil.com`, which is the
# other half of round 33.
harness_os_authority_in_scope() {
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
  done < <(printf '%s' "$patterns" | "$HOS_JQ" -r '.[]?' 2>/dev/null)
  return 1
}

# harness_os_normalize_path <path> — absolute, lexically-normalised form.
# Relative paths resolve against HOS_CWD. `.`/`..` segments are squashed
# BEFORE scope matching, so `src/../.claude/x` can never ride a `src/**`
# grant. Prefers GNU `realpath -m` (also resolves symlinks in the
# existing prefix); falls back to a pure-bash lexical normaliser.
harness_os_normalize_path() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in /*) : ;; *) p="${HOS_CWD%/}/$p" ;; esac
  local rp
  rp=$(realpath -m -- "$p" 2>/dev/null || true)
  if [ -n "$rp" ]; then printf '%s' "$rp"; return 0; fi
  local out=() seg joined=""
  local IFS='/'
  for seg in $p; do
    case "$seg" in
      ''|'.') ;;
      '..') if [ ${#out[@]} -gt 0 ]; then unset "out[$((${#out[@]} - 1))]"; out=("${out[@]}"); fi ;;
      *) out+=("$seg") ;;
    esac
  done
  for seg in "${out[@]}"; do joined+="/$seg"; done
  [ -n "$joined" ] || joined="/"
  printf '%s' "$joined"
}

# harness_os_relpath <path> — normalise, then repo-root-relativise.
# Paths outside the root stay absolute (they then only match
# absolute-anchored patterns).
harness_os_relpath() {
  local p
  p="$(harness_os_normalize_path "$1")"
  case "$p" in
    "$HOS_ROOT") printf '.' ; return 0 ;;
    "$HOS_ROOT"/*) p="${p#"$HOS_ROOT"/}" ;;
  esac
  printf '%s' "$p"
}

# harness_os_is_manifest_path <path> — the manifest is "the law": every
# governed role may READ it (deny messages quote it; agents consult it
# to understand their own boundaries). Write access stays locked by the
# self-protection axis.
harness_os_is_manifest_path() {
  [ "$(harness_os_normalize_path "$1")" = "$(harness_os_normalize_path "$HOS_MANIFEST")" ]
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
  # Same argv limit as the deny renderer. Here a failure only loses the
  # audit line, but the line it loses is the one describing the call that
  # was long enough to break it — the single entry most worth keeping.
  [ "${#detail}" -le 4000 ] || detail="${detail:0:4000} [truncated]"
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

# harness_os_awk_sed_verdict <command-word> <segment-text>
# Prints "indirect" when an awk/sed program is NOT provably inert, and
# nothing otherwise.
#
# awk and sed are interpreters. Their programs can spawn processes
# (`system()`, `cmd | getline`, `print | cmd`, sed's `e`) and open files
# (`getline < f`, `print > f`, sed's `r`/`w`), so a role granted either
# holds an unrestricted shell unless something says otherwise.
#
# The first version of this check screened for those constructs and
# scope-checked the literal beside them, letting an in-scope path
# through. That is unsound, and a reviewer showed it in eleven
# characters: put the literal in a variable — `f=".env"; getline l < f`
# — and every pattern sees nothing, because the operand of an awk
# construct is an arbitrary expression. Round 8 had already ruled on
# this shape: a channel that turns data into execution must be closed,
# not pattern-matched.
#
# So the question is inverted here. Inert is what must be provable, and
# anything else is refused whatever it names — which is the only form of
# the check that indirection cannot walk around. Roles that genuinely
# need the constructs opt in through bash.permit, like every other
# indirection in that list.
# harness_os_interpreter_inline <command-word> <segment-text>
# Prints "indirect" when an interpreter is being handed code to run.
#
# The screen this replaces matched the code-bearing flag as an exact
# whole-word token — `-c`, `-e`, `-p`, `--eval`. Every one of these
# interpreters also accepts that letter BUNDLED with its other short
# options, as a single argv token that equals none of them:
#
#     perl -ne 'system("cat .env")'      python3 -Ic 'print(open(".env").read())'
#     perl -pe '…'   ruby -ne '…'        python3 -uc '…'
#
# so the screen saw nothing and an interpreter grant became an
# unrestricted shell. That is the same defect as `sort -oFILE` and
# `grep -f.env` — an exact spelling where a cluster was possible — and
# the third axis to have had it.
#
# Matching is therefore on the CLUSTER: any short-option group ending in
# a letter that means "here is code" or "load this module". The command
# word must be the interpreter itself; wrappers that hide it (`env`,
# `timeout`, `sh -c`) are denied by their own entries in the list.
harness_os_interpreter_inline() {
  local cmd="$1" seg="$2" base value_letters code_letters
  base="${cmd##*/}"
  # Each interpreter's short options fall into three kinds: booleans,
  # options that CONSUME a value, and options whose value IS code. Only
  # the last matters, and the three lists differ per interpreter — `-E`
  # is code for perl and a boolean for python, so one shared letter class
  # denies ordinary `python3 -sE script.py` while missing `perl -E`.
  #
  # The code letters are split in two, because the two are not the same
  # risk and a role should not have to accept one to get the other.
  # `-c`/`-e` run a program the AGENT wrote on the command line;
  # `-m`/`-r` run or preload an installed module, which the agent did
  # not author. A Python test role needs `python -m pytest` and has no
  # business with `python -c`, and until this split permitting one meant
  # permitting both.
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
        # if that letter is a CODE letter the interpreter is running code
        # — whether its argument is attached (`-c'…'`) or separated
        # (`-c '…'`). Round 19 got in through the attached spelling,
        # which is the sixth time an exact-versus-attached distinction
        # has defeated a check in this kernel.
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
      *)  [ -f "${HOS_CWD:-.}/$w" ] && script=1 ;;
    esac
  done
  [ "$informational" = "1" ] && return 0
  # No code flag and no script: every one of these interpreters then
  # reads its program from STDIN. `python3 <<< 'CODE'` and a bare
  # `python3` carry arbitrary code past a check looking for `-c`.
  [ "$script" = "1" ] || printf 'indirect'
}

harness_os_awk_sed_verdict() {
  local cmd="$1" seg="$2"
  # Both gawk and GNU sed ship a `--sandbox` that disables exactly these
  # constructs in the interpreter itself — system(), redirections and
  # getline-from-file for gawk; `e`, `r` and `w` for sed. A program run
  # that way is inert by construction rather than by this function's
  # reading of it, which is a far better guarantee than any scan, so it
  # is accepted. On a build that does not know the flag the command
  # fails to start, so the wrong guess errs toward nothing running.
  #
  # Only for the implementations that HAVE it. `gawk` and GNU `sed` do;
  # a bare `awk` could be mawk or busybox, and trusting a flag a binary
  # may not implement is exactly the kind of unverifiable assumption
  # this loop keeps punishing. mawk here rejects the flag outright,
  # which is the fail-safe direction — but "the awk on this machine"
  # is not something the kernel can check at decision time, so the
  # guarantee is claimed only where the command word names it.
  case "$cmd" in
    gawk|sed)
      case " $seg " in *" --sandbox "*|*" --sandbox="*) return 0 ;; esac ;;
  esac
  case "$cmd" in
    awk|gawk|mawk|nawk|busybox)
      # `system`, `getline`, `close` and `ENVIRON` have no inert use.
      # A pipe or redirect is only a redirect in a print STATEMENT —
      # elsewhere `|` is regex alternation and `>` is comparison, and
      # denying those would refuse most ordinary awk.
      #
      # String and regex literals are removed FIRST, because a `}` or a
      # `;` inside one ends the statement scan early: `print "{x}" > f`
      # kept its redirect hidden behind the brace in its own argument.
      AWKSEG="$seg" perl -e '
        my $p = $ENV{AWKSEG};
        $p =~ s{"(?:\\.|[^"\\])*"}{ }g;
        $p =~ s{/(?:\\.|[^/\\])*/}{ }g;
        # gawk can also load a shared library, which is strictly worse
        # than system(): `@load`, `@include`, `extension()` and their
        # -l/--load/-i/--include flags all reach code this kernel never
        # sees. They read as perfectly inert to a scan looking for
        # redirects, which is how they survived the first inversion.
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

# harness_os_bound_text <text>
# Bounds a deny message to something an agent can actually read.
#
# A deny message quotes the thing it is refusing — a command line, a path,
# a file's contents — so its length is set by the caller, not by us. That
# matters twice over: an unbounded message is a channel for pushing
# arbitrary text into the reading agent's context, and it is what made
# the renderer below reachable as a failure. The opening line says what
# was blocked and the closing lines say what to do instead, so it is the
# middle that gives way. Pure parameter expansion: no process is started
# here, at any input size.
harness_os_bound_text() {
  local t="$1" keep=2000
  if [ "${#t}" -le $((keep * 2)) ]; then
    printf '%s' "$t"
    return 0
  fi
  printf '%s\n\n[... %s characters elided by harness-os ...]\n\n%s' \
    "${t:0:keep}" "$(( ${#t} - keep * 2 ))" "${t: -keep}"
}

# harness_os_deny <short-detail-for-log> <reason>
# Emits the repo-standard deny JSON and exits 0.
#
# The reason used to reach jq through argv, which put the whole decision
# at the mercy of execve's MAX_ARG_STRLEN: pad the quoted text past
# ~128 KB and jq never starts, no JSON is printed, and an empty stdout on
# exit 0 is precisely how this hook says ALLOW. A deny that can be
# switched off by making its own explanation longer is not a deny. The
# EXIT trap does not catch it either, because nothing here exits
# non-zero — the failure is entirely inside a successful-looking run.
#
# So: the reason is bounded first, then handed to jq on stdin, where no
# such limit exists. And if jq fails regardless — missing, killed, out of
# memory — the decision is still emitted, carried by a fixed string that
# needs no renderer. The explanation is not the decision, and losing the
# former must never discard the latter.
harness_os_deny() {
  local reason
  harness_os_log "deny" "$1"
  reason=$(harness_os_bound_text "$2")
  HOS_DECIDED=1
  if printf '%s' "$reason" | "$HOS_JQ" -Rs '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": .
    }
  }' 2>/dev/null; then
    exit 0
  fi
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] harness-os refused this call but could not render the explanation for it. The decision stands; only the wording was lost. The recorded reason is the last deny in the decision log under the harness-os state directory."}}'
  exit 0
}

# harness_os_role_field <role> <jq-path-expression>
# Prints the JSON value at .roles[<role>]<expr> (compact) or "null".
harness_os_role_field() {
  printf '%s' "$HOS_MANIFEST_JSON" | "$HOS_JQ" -c --arg r "$1" ".roles[\$r]$2 // null" 2>/dev/null || echo "null"
}

# harness_os_code_calls_in_scope <code> <network-allow-json> <method-regex>
# — true when the role declares a network scope AND every matching call
# in the code names a LITERAL destination inside it.
#
# The exfil branches in the code screen are destination-blind and total:
# they refuse the CHANNEL, not the host. Round 38 showed what that costs
# in both directions at once — a composer authoring
# `request.get("http://localhost:4173/api")`, a fetch of its own in-scope
# app, was refused as "an exfiltration channel", while a browser
# navigation to a genuinely forbidden host went through. The check that
# fired was the one that should not have.
#
# A role that declares where it may connect has said something the
# kernel can use. One that has not, has not: absent a scope there is no
# destination that can be shown to be permitted, so the blanket refusal
# stands and this returns false.
harness_os_code_calls_in_scope() {
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
    harness_os_is_network_url "$cc_lit" || return 1
    cc_auth=$(harness_os_url_authority "$cc_lit")
    [ -n "$cc_auth" ] || return 1
    harness_os_authority_in_scope "$cc_auth" "$cc_scope" || return 1
    cc_seen=1
  done < <(printf '%s' "$cc_code" | grep -oE "${cc_re}[[:space:]]*\([^)]*\)?" 2>/dev/null)
  [ "$cc_seen" = "1" ]
}
