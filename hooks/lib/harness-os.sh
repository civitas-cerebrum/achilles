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
    tags=$(printf '%s\n' "$user_tags" | sed -E 's/^<<harness-os-role: ([a-z][a-z0-9-]*)(#[a-z0-9]+)?>>$/\1/' | grep -v '^$' | sort -u || echo "")
    if [ -n "$tags" ] && [ "$(printf '%s\n' "$tags" | wc -l | tr -d ' ')" = "1" ]; then
      HOS_ROLE="$tags"
      if harness_os__role_exists "$HOS_ROLE"; then
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
