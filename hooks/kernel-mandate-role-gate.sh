#!/bin/bash
# kernel-mandate-role-gate.sh — the kernel mandate kernel: one generic hook that
#                           enforces every declared role's boundaries.
#
# CANONICAL HOME: github.com/civitas-cerebrum/kernel-mandate
# Copies of this file in consumer repos (e.g. achilles) are vendored
# verbatim — edit upstream, then run the consumer's sync (for achilles:
# npm run sync:kernel-mandate).
#
# Hook    : PreToolUse:.* (all tools — the gate routes internally)
# Mode    : DENY (fail-closed inside governed contexts; silent allow
#           everywhere the project has not opted in)
# State   : <repo-root>/.claude/kernel-mandate.state/
#             dispatch-registry.json   role dispatches (TTL-pruned)
#             agents/<agent_id>        resolved role bindings
#             decision-log.jsonl       one line per deny (calibration)
# Env     : KERNEL_MANDATE=0             operator kill-switch (design sessions)
#           KERNEL_MANDATE_MANIFEST      manifest path override (tests)
#           KERNEL_MANDATE_STATE_DIR     state dir override (tests)
#
# Why
# ---
# Prose mandates ("you are the reviewer; only read the acceptance criteria")
# do not bind. This gate reads the role manifest (.claude/kernel-mandate.json,
# schema: schemas/kernel-mandate.schema.json), resolves which role the calling
# context is (resolution ladder in lib/kernel-mandate.sh), and enforces:
#
#   1. self-protection  — no governed context touches the manifest/state
#   2. tool gate        — tools.deny / tools.allow (shell-glob names)
#   3. bash gate        — every command segment must match the role's
#                         command groups; indirection constructs are
#                         denied unless bash.permit names them; redirect
#                         targets obey the write scope and file-naming
#                         tokens obey the read scope
#   4. read scope       — Read/Glob/Grep/NotebookRead path globs
#   5. write scope      — Write/Edit/NotebookEdit path globs (opt-in)
#   6. dispatch gate    — Agent calls: target role must be in the
#                         caller's dispatch list, description must be
#                         role-prefixed, prompt must carry the
#                         <<kernel-mandate-role: NAME[#NONCE]>> binding tag;
#                         the dispatch (and its nonce) is recorded so the
#                         child binds exactly, even under parallel
#                         mixed-role dispatch
#   7. skill gate       — optional skills.allow over the Skill tool
#   8. MCP arg scoping  — path arguments named in
#                         settings.mcpPathArguments obey the read/write
#                         scopes; unmapped MCP tools stay name-gated
#
# The read boundary doubles as context hygiene: a role that cannot read a
# file never loads it into its context window.
#
# Canonical reference
# -------------------
# skills/mandate-designer/references/architecture.md
# skills/mandate-designer/SKILL.md            (onboarding flow)
# schemas/kernel-mandate.schema.json              (manifest contract)
#
# Failure → action
# ----------------
# Axis violation → DENY with the role's mandate, the violated grant, and
# the sanctioned alternative. Manifest present but unparseable → DENY
# mutating tools, allow the read path (so it can be repaired).

set -uo pipefail

# A hook that exits with no JSON on stdout allows the call, and Claude Code
# runs the tool on any exit other than 2. So any exit before a verdict
# (set -u, a failed jq) is turned into the deny JSON on stdout, exit 0.
# Built with printf, not jq: jq may be what failed.
KM_DECIDED=0
kernel_mandate__on_exit() {
  local code=$?
  if [ "$code" -eq 0 ] && [ "${KM_DECIDED:-0}" != "1" ]; then
    # The decision log records denies only, unless settings.decisionLog is
    # "all". Logged here because the trap sees every `exit 0` allow site.
    if [ "${KM_LOG_ALLOWS:-0}" = "1" ]; then
      kernel_mandate_log allow "${KM_TOOL:-?} ${KM_ALLOW_DETAIL:-}" 2>/dev/null || true
    fi
    return 0
  fi
  [ "$code" -eq 0 ] && return 0
  [ "${KM_DECIDED:-0}" = "1" ] && return 0
  printf '%s\n' "[kernel-mandate] INTERNAL ERROR: the role gate exited $code before reaching a decision." >&2
  printf '%s\n' "[kernel-mandate] Refusing to treat that as permission: this call is DENIED. Re-run with bash -x to see where, or set KERNEL_MANDATE=0 in the operator's shell to bypass the kernel deliberately." >&2
  # Best-effort record; the log function may be the thing that broke.
  kernel_mandate_log deny "internal-error exit=$code tool=${KM_TOOL:-?}" 2>/dev/null || true
  # $code is an integer from $?; nothing else user-controlled enters the
  # string, so this is valid JSON without an escaper.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] kernel-mandate hit an internal error (exit %d) before reaching a decision on this call, and a gate whose failure mode is ALLOW is not a gate — so the call is refused.\\n\\nThis is a bug in the kernel, not in the call. Re-run the hook with bash -x to locate it. An operator who needs to proceed can bypass the kernel deliberately with KERNEL_MANDATE=0 in their own shell; an agent cannot lift this from inside a governed session."}}\n' "$code"
  exit 0
}
trap kernel_mandate__on_exit EXIT

INPUT=$(cat)

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  # Without jq nothing can be enforced. An ungoverned project must keep
  # working (and the kill-switch must still work), so deny only when a
  # manifest is present.
  case "${KERNEL_MANDATE:-}" in
    0|false|off) exit 0 ;;
  esac
  # The payload's cwd names the project; extract it with sed since jq is
  # missing. If that fails, fall back to $PWD: a spurious deny is loud and
  # names its remedy, a spurious "ungoverned" is silent.
  KM_PROBE_CWD=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$KM_PROBE_CWD" ] && [ -d "$KM_PROBE_CWD" ] || KM_PROBE_CWD="$PWD"
  KM_PROBE="${KERNEL_MANDATE_MANIFEST:-$( { cd "$KM_PROBE_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null; } || printf '%s' "$KM_PROBE_CWD" )/.claude/kernel-mandate.json}"
  if [ ! -f "$KM_PROBE" ]; then
    exit 0   # no manifest: this project never opted in, and jq is not its problem
  fi
  # A manifest is present: allowing would leave every role unenforced.
  KM_DECIDED=1
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] kernel-mandate cannot enforce this project: jq is not installed, and jq is how the kernel reads both the role manifest and the call it is deciding about. This project HAS a manifest, so treating the kernel as absent would leave every role unenforced without saying so. Install jq (https://jqlang.github.io/jq/), or set KERNEL_MANDATE=0 to run this session ungoverned on purpose."}}'
  exit 0
fi

# shellcheck source=lib/kernel-mandate.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/kernel-mandate.sh"

kernel_mandate_load "$INPUT" || exit 0   # project has not opted in — silent allow

# settings.decisionLog: "denies" (default) | "all". See the exit trap.
KM_LOG_ALLOWS=0
if [ "$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r '.settings.decisionLog // "denies"' 2>/dev/null || echo denies)" = "all" ]; then
  KM_LOG_ALLOWS=1
fi
KM_ALLOW_DETAIL=$(printf '%s' "$INPUT" | "$JQ" -r '
  .tool_input.command // .tool_input.file_path // .tool_input.path // .tool_input.url // .tool_input.description // empty' 2>/dev/null || echo "")

MANIFEST_REF="Manifest: ${KM_MANIFEST}
Docs:     skills/mandate-designer/references/architecture.md"

# search_pattern_offender — does a Glob/Grep pattern climb out of the
# search root? Sets SEARCH_PAT to the first offending pattern field, or
# empty. Shared by the governed and unbound arms; each renders its own deny.
search_pattern_offender() {
  local sp_fields sp_cand
  SEARCH_PAT=""
  # Glob's `pattern` IS a path glob, so it counts there; for Grep the
  # pattern is a regex over CONTENT and only `glob` names paths.
  if [ "$KM_TOOL" = "Glob" ]; then
    sp_fields=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.pattern // empty, .tool_input.glob // empty' 2>/dev/null)
  else
    sp_fields=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.glob // empty' 2>/dev/null)
  fi
  local sp_flat sp_esc sp_join sp_view
  while IFS= read -r sp_cand; do
    [ -n "$sp_cand" ] || continue
    # Glob syntax spells `..` in ways a substring test misses:
    # `{..,..}`, `[.][.]`, `[.]{,}[.]{,}`, `[.-.]`. Test both brace readings
    # (JOINED: empty alternations vanish; SPLIT: alternatives are segments).
    # A bracket expression that can match `.` becomes `.`, otherwise an inert
    # letter, so `[ab]/[cd]` is not read as `../`.
    sp_esc=$(printf '%s' "$sp_cand" | sed -E 's/\\(.)/\1/g')
    # Without perl every bracket expression becomes a dot: more false
    # positives, never a miss.
    sp_esc=$(printf '%s' "$sp_esc" | perl -pe '
      s{\[([^]]*)\]}{
        my $b = $1;
        my $dot = 0;
        $dot = 1 if $b =~ /^[!^]/;                 # negated: matches . unless listed
        $dot = 1 if $b =~ /\./;                    # literal dot
        while ($b =~ /(.)-(.)/g) {                 # a range straddling 0x2E
          $dot = 1 if ord($1) <= 0x2E && 0x2E <= ord($2);
        }
        $dot ? "." : "x"
      }ge' 2>/dev/null || printf '%s' "$sp_esc" | sed -E 's/\\[[^]]*\\]/./g')
    # JOINED: `{`, `}` and `,` vanish, the way an empty alternation does.
    sp_join=$(printf '%s' "$sp_esc" | tr -d '{},')
    # SPLIT: they become separators, the way a real alternation reads.
    sp_flat=$(printf '%s' "$sp_esc" | sed -E 's/[{},]/\//g')
    case "$sp_cand" in
      */..|*/../*|../*|..) SEARCH_PAT="$sp_cand" ;;   # climbs out of the root
      /*|"~"*)             SEARCH_PAT="$sp_cand" ;;   # absolute / home — ignores the root
    esac
    for sp_view in "$sp_esc" "$sp_join" "$sp_flat"; do
      case "$sp_view" in
        */..|*/../*|../*|..) SEARCH_PAT="$sp_cand"; break ;;
      esac
    done
    [ -n "$SEARCH_PAT" ] && break
  done <<< "$sp_fields"
}

# kernel_mandate_search_root — the directory a Glob actually searches when the
# call carries no `path`. Glob's `pattern` names its own root
# (`tests/e2e/**`), so a missing path is not always the repo root.
kernel_mandate_search_root() {
  local sr_pat sr_prefix
  SEARCH_ROOT=""
  [ "$KM_TOOL" = "Glob" ] || return 0
  sr_pat=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.pattern // empty' 2>/dev/null || echo "")
  [ -n "$sr_pat" ] || return 0
  # `{` and `[` end the literal prefix too, or `[.][.]/…` would count as
  # a literal directory name.
  sr_prefix="${sr_pat%%[*?\[{]*}"
  sr_prefix="${sr_prefix%/}"
  case "$sr_prefix" in
    ""|.|..|/*) return 0 ;;
  esac
  SEARCH_ROOT="${KM_CWD%/}/$sr_prefix"
}


# ---------------------------------------------------------------------------
# Broken manifest — fail closed on mutation, open on inspection/repair.
# ---------------------------------------------------------------------------
if [ "${KM_MANIFEST_BROKEN:-0}" = "1" ]; then
  case "$KM_TOOL" in
    Read|Glob|Grep|NotebookRead|TaskGet|TaskList) exit 0 ;;
    Write|Edit)
      # Permit repairing the manifest itself; deny other writes.
      # Never from a role-bound agent: a broken manifest is a state an agent can
      # cause, and repair would let it install a manifest granting itself everything.
      FILE_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
      if [ "$FILE_PATH" = "$KM_MANIFEST" ]; then
        KM_REPAIR_BOUND=0
        if [ -n "${KM_AGENT_ID:-}" ] && [ -f "$(kernel_mandate__binding_file "$KM_AGENT_ID")" ]; then
          KM_REPAIR_BOUND=1
        fi
        if [ "$KM_REPAIR_BOUND" = "0" ]; then exit 0; fi
        kernel_mandate_deny "broken-manifest-repair-by-bound-agent" "[BLOCKED] The kernel mandate manifest is not valid JSON, and this call comes from an agent bound to a role — so it may not be the one to rewrite it.

${MANIFEST_REF}

The manifest is the record of what each role may do. An agent that HAS a role has one because somebody decided what it may do, and losing that file must not be a way to decide differently. A broken manifest is also a state an agent can cause, so repairing it from inside a bound role would turn any write channel into a way to grant itself anything.

Hand this back to the orchestrator or the operator, who can repair the manifest outside a bound role — or disable the kernel deliberately with KERNEL_MANDATE=0."
      fi
      ;;
  esac
  kernel_mandate_deny "broken-manifest tool=$KM_TOOL" "[BLOCKED] The kernel mandate manifest exists but is not valid JSON, so no role's grants can be verified.

${MANIFEST_REF}

While the manifest is broken the kernel fails closed: only read tools and a Write/Edit that repairs the manifest itself are permitted. Fix the manifest (validate against schemas/kernel-mandate.schema.json) or have the operator disable the kernel mandate for this session with KERNEL_MANDATE=0 in their shell."
fi

kernel_mandate_resolve_role

# ---------------------------------------------------------------------------
# Misconfigured — settings.mainSessionRole names a role that does not
# exist. Deny with a reason rather than allow silently: the author meant
# to govern this session, and a silent allow leaves no log for `doctor`.
# ---------------------------------------------------------------------------
if [ "$KM_ROLE_STATE" = "misconfigured" ]; then
  KM_BAD_ROLE=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r '.settings.mainSessionRole // empty' 2>/dev/null || echo "")
  KM_KNOWN_ROLES=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r '[.roles | keys[]?] | join(", ")' 2>/dev/null || echo "")
  kernel_mandate_deny "misconfigured-main-session-role ${KM_BAD_ROLE}" "[BLOCKED] settings.mainSessionRole is \"${KM_BAD_ROLE}\", and this mandate defines no such role.

Roles defined here: ${KM_KNOWN_ROLES:-(none)}

The kernel fails closed on this rather than running ungoverned, because the two are indistinguishable from the outside and only one of them is what the manifest's author asked for. A mandate that names a main-session role is a mandate that intends to govern this session.

Fix the name in ${KM_MANIFEST}, or remove settings.mainSessionRole entirely to leave the top-level session ungoverned on purpose. \`kernel-mandate validate\` names this error directly."
fi

# ---------------------------------------------------------------------------
# Ungoverned context (no manifest role applies) — the operator's design
# surface. Silent allow.
# ---------------------------------------------------------------------------
[ "$KM_ROLE_STATE" = "ungoverned" ] && exit 0

# ---------------------------------------------------------------------------
# Unbound subagent — identity could not be resolved (mixed-role parallel
# dispatch on a build without parent_tool_use_id / per-child transcripts).
# ---------------------------------------------------------------------------
if [ "$KM_ROLE_STATE" = "unbound" ]; then
  POLICY=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r '.settings.unboundAgentPolicy // "readonly"' 2>/dev/null || echo "readonly")
  case "$POLICY" in
    allow) exit 0 ;;
    readonly)
      case "$KM_TOOL" in
        TaskGet|TaskList) exit 0 ;;
        Read|Glob|Grep|NotebookRead)
          # An unbound agent is held to the UNION of every role's read.allow:
          # material no role may read stays out of reach of a caller the kernel
          # could not identify.
          UNBOUND_SCOPE=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -c '[.roles[]?.read.allow[]?] | unique' 2>/dev/null || echo "[]")
          if [ "$UNBOUND_SCOPE" = "[]" ] || [ "$UNBOUND_SCOPE" = "null" ]; then exit 0; fi
          UNBOUND_TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' 2>/dev/null || echo "")
          # A search with no path runs from its search root, so scope-check that
          # root; an absent path field is not an allow.
          if [ -z "$UNBOUND_TARGET" ]; then
            kernel_mandate_search_root
            [ -n "$SEARCH_ROOT" ] && UNBOUND_TARGET="$SEARCH_ROOT"
          fi
          [ -n "$UNBOUND_TARGET" ] || UNBOUND_TARGET="$KM_ROOT"
          # A pattern that climbs out of the root evades the root check.
          search_pattern_offender
          if [ -n "$SEARCH_PAT" ]; then
            kernel_mandate_deny "unbound search-pattern-traversal" "[BLOCKED] This subagent's harness-OS role could not be resolved, and its $KM_TOOL pattern ('$SEARCH_PAT') climbs out of the project root.

${MANIFEST_REF}

unboundAgentPolicy is \"readonly\", which permits reading only what some role in this OS may read. A pattern is applied under the search root, so one that escapes upward is not a search of anything this OS has a scope for."
          fi
          kernel_mandate_is_manifest_path "$UNBOUND_TARGET" && exit 0
          UNBOUND_REL=$(kernel_mandate_relpath "$UNBOUND_TARGET")
          kernel_mandate_path_in_scope "$UNBOUND_REL" "$UNBOUND_SCOPE" && exit 0
          kernel_mandate_deny "unbound read-out-of-scope $UNBOUND_REL" "[BLOCKED] This subagent's harness-OS role could not be resolved, and '$UNBOUND_REL' is outside every role's read scope.

${MANIFEST_REF}

unboundAgentPolicy is \"readonly\", which permits reading only what some role in this OS is allowed to read — not the whole project. Material no role may see stays out of reach of a caller the kernel cannot identify.

Re-dispatch this task with a role-prefixed description (\"<role>-<slug>: ...\") and the binding tag <<kernel-mandate-role: NAME#nonce>> as the first line of the prompt, and the role's own read scope applies instead."
          ;;
      esac
      ;;
  esac
  kernel_mandate_deny "unbound tool=$KM_TOOL policy=$POLICY" "[BLOCKED] This subagent's harness-OS role could not be resolved, and the manifest's unboundAgentPolicy (\"$POLICY\") does not permit '$KM_TOOL'.

${MANIFEST_REF}

A subagent binds to a role when its dispatch carried a role-prefixed description (\"<role>-<slug>: ...\") and the prompt embedded the binding tag <<kernel-mandate-role: NAME>>. When several DIFFERENT roles are dispatched at once, give each dispatch tag a unique nonce — <<kernel-mandate-role: NAME#a1b2c3>> — so every child binds exactly. Return now and let the orchestrator re-dispatch this task with a properly tagged brief."
fi

# ---------------------------------------------------------------------------
# Governed context — enforce the role's grants.
# ---------------------------------------------------------------------------
ROLE="$KM_ROLE"
ROLE_DESC=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '.roles[$r].description // ""' 2>/dev/null || echo "")
ROLE_HEADER="Role:     ${ROLE} — ${ROLE_DESC}
${MANIFEST_REF}"

# Every path scope resolves against cwd. A missing or relative cwd would
# resolve scopes against the wrong tree (or none), so refuse rather than
# answer about somewhere else.
case "$KM_CWD" in
  /*) [ -d "$KM_CWD" ] || KM_CWD_FAULT="does not exist" ;;
  *)  KM_CWD_FAULT="is not an absolute path" ;;
esac
if [ -n "${KM_CWD_FAULT:-}" ]; then
  kernel_mandate_deny "cwd-unresolvable $KM_CWD" "[BLOCKED] Role '${ROLE}' made a call whose working directory ('$KM_CWD') ${KM_CWD_FAULT}, so none of this role's path scopes can be evaluated against it.

${ROLE_HEADER}

Read and write scopes are relative to the directory a call runs in. Without a directory to resolve them against — or with one this kernel would have to guess at — there is nothing to compare a path to, and a scope that cannot be evaluated is refused rather than skipped."
fi

# --- Axis 1: self-protection --------------------------------------------
# The manifest and the kernel's state dir are the root of trust; no
# governed role may mutate them through any channel. Changes go through
# an operator design session (KERNEL_MANDATE=0) or a hand edit.
SELF_PROTECT_MSG="[BLOCKED] Role '${ROLE}' attempted to modify the kernel mandate itself.

${ROLE_HEADER}

The manifest, .claude/kernel-mandate.state/, and the project's .claude/settings*/hooks (which register this kernel) are the root of trust for every role boundary — no governed role may change them, whatever its other grants. To redesign the harness: ask the operator to relaunch with KERNEL_MANDATE=0 (or edit the manifest outside the session), ideally via the mandate-designer skill."

NORM_MANIFEST="$(kernel_mandate_normalize_path "$KM_MANIFEST")"
NORM_STATE_DIR="$(kernel_mandate_normalize_path "$KM_STATE_DIR")"

# deny_unscreened <log-key> <what was being screened> <context line>
# A text tool inside a screen failed. Its output would be empty or
# partial, and an empty list of imports or segments checks nothing, so
# the call is refused rather than passed on unscreened.
deny_unscreened() {
  kernel_mandate_deny "$1" "[BLOCKED] kernel-mandate could not screen $2 (a text tool failed). Refusing rather than allowing it unscreened.

${ROLE_HEADER}
$3

Retry the call. If it fails again, the host's sed, awk, grep, sort or perl is not behaving as the kernel expects; report it with the output of: uname -sr; command -v sed awk grep sort perl"
}

deny_unscreened_targets() {
  deny_unscreened "bash-write-target-screen" "this command's write targets" "Command: ${CMD}"
}

# kernel_mandate_self_protect <path> <log-prefix>
# Refuses a write to the kernel mandate itself: the manifest, the state
# directory, this project's .claude config and hooks, and the installed
# kernel wherever it lives. One function for every write channel
# (Write/Edit, Bash targets, mapped MCP writes) so the rule cannot drift.
#
# prot_reader_command <command-word> — true when the program cannot write
# a path it is handed: not by an operand, not by a flag.
# Being absent from this list is the safe state. `echo`/`printf`/`:` take
# text operands; `sort` writes only via `-o`, refused separately. Not here:
# `uniq`, `tee`, `split`, `csplit`, `gzip`/`gunzip`, `curl`, `wget`.
prot_reader_command() {
  case "${1##*/}" in
    echo|printf|:|true|false|test|expr|\
    cat|head|tail|grep|egrep|fgrep|rg|ag|ack|jq|yq|wc|nl|od|xxd|hexdump|\
    file|stat|realpath|readlink|dirname|basename|ls|du|less|more|column|\
    cmp|diff|comm|md5sum|sha1sum|sha256sum|sha512sum|cksum|b2sum|sum|\
    strings|tac|rev|fold|expand|unexpand|pr|base64|base32|iconv|\
    zcat|bzcat|xzcat|cut|paste|sort|git) return 0 ;;
  esac
  return 1
}

# prot_reader_flag <token> — true when the token is a FLAG whose operand
# the tool only ever READS. The manifest is readable by design: it is the
# law each role is held to, so naming it after one of these is ordinary.
prot_reader_flag() {
  case "$1" in
    -f|--file|--from-file|-K|--config|--rawfile|--slurpfile|-L|\
    -T|--upload-file|-e|--regexp|--exclude-from|--include-from|\
    --files0-from|-a|--arg-file|--input-file|--manifest) return 0 ;;
  esac
  return 1
}

self_protect_target() {
  local sp_path="$1" sp_prefix="${2:-self-protect write}" sp_norm sp_rel
  [ -n "$sp_path" ] || return 0
  sp_norm="$(kernel_mandate_normalize_path "$sp_path")"
  # macOS and Windows filesystems are case-insensitive, so `.CLAUDE/SETTINGS.json`
  # opens the protected file. Fold case for the comparison: the protected names
  # are ASCII, so folding can only over-match.
  local sp_fold
  sp_fold=$(printf '%s' "$sp_norm" | tr 'A-Z' 'a-z')
  case "$sp_norm" in
    "$NORM_MANIFEST"|"$NORM_STATE_DIR"|"$NORM_STATE_DIR"/*)
      kernel_mandate_deny "$sp_prefix $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
  # `.claude/agents/` and `.mcp.json` are control surfaces: an agent
  # definition is what a role is when identity binds to agent_type, and
  # `.mcp.json` registers tool servers.
  sp_rel="$(kernel_mandate_relpath "$sp_path" | tr 'A-Z' 'a-z')"
  case "$sp_rel" in
    .claude/kernel-mandate.json|.claude/kernel-mandate.state|.claude/kernel-mandate.state/*|.claude/settings.json|.claude/settings.local.json|.claude/hooks|.claude/hooks/*|.claude/agents|.claude/agents/*|.mcp.json)
      kernel_mandate_deny "$sp_prefix $sp_path" "$SELF_PROTECT_MSG" ;;
  esac

  # Discovery uses the nearest `.claude/kernel-mandate.json` above cwd, so a
  # nested `.claude` holds law too. Match the same protected children at any
  # depth, not the whole `.claude` dir (a config role may own `.claude/**`).
  case "$sp_fold" in
    */.claude/kernel-mandate.json \
    |*/.claude/kernel-mandate.state|*/.claude/kernel-mandate.state/* \
    |*/.claude/settings.json|*/.claude/settings.local.json \
    |*/.claude/hooks|*/.claude/hooks/* \
    |*/.claude/agents|*/.claude/agents/*|*/.mcp.json)
      kernel_mandate_deny "$sp_prefix nested-config $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
  # A manifest filename outside `.claude` is not law today, but the Bash
  # channel refuses it and the two channels must agree.
  case "${sp_fold##*/}" in
    kernel-mandate.json|kernel-mandate.state)
      kernel_mandate_deny "$sp_prefix nested-manifest $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
  # The installed kernel is the root of trust wherever it lives; a
  # project-local install in node_modules is covered too.
  case "$sp_fold" in
    */kernel-mandate/hooks/*|*/.claude/hooks/*|*/kernel-mandate-role-gate.sh|*/lib/kernel-mandate.sh)
      kernel_mandate_deny "$sp_prefix kernel $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
}

case "$KM_TOOL" in
  Write|Edit|NotebookEdit)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    if [ -n "$TARGET" ]; then
      self_protect_target "$TARGET" "self-protect write"
    fi
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null || echo "")
    # A protected path that is the TARGET of a write-shaped command → deny;
    # mere mention (`echo see .claude/x > notes.txt`) passes to the bash axis.
    # Case-insensitive for the same reason self_protect_target folds case.
    PROT_RE='(kernel-mandate\.(json|state)|(^|[^a-zA-Z0-9_.-])\.claude(/|$)|(^|[^a-zA-Z0-9_.-])\.claude/(settings(\.local)?\.json|hooks|agents)(/|$)|(^|[^a-zA-Z0-9_.-])\.mcp\.json($|[^a-zA-Z0-9_.-]))'
    if printf '%s' "$CMD" | grep -Eqi ">>?[[:space:]]*[^[:space:]|&;]*${PROT_RE}"; then
      kernel_mandate_deny "self-protect bash redirect" "$SELF_PROTECT_MSG"
    fi
    if printf '%s' "$CMD" | grep -Eqi "(^|[;&|][[:space:]]*|[[:space:]])(rm|rmdir|unlink|mv|cp|tee|truncate|shred|dd|install|ln|chmod|chown)([[:space:]]+(-[^[:space:]]+|if=[^[:space:]]+))*[[:space:]]+[^;|&]*${PROT_RE}"; then
      kernel_mandate_deny "self-protect bash mutate" "$SELF_PROTECT_MSG"
    fi
    if printf '%s' "$CMD" | grep -Eqi "sed[[:space:]]+-[a-zA-Z]*i[^;|&]*${PROT_RE}"; then
      kernel_mandate_deny "self-protect bash sed-i" "$SELF_PROTECT_MSG"
    fi
    # An operand naming a protected path is a write unless the program only
    # ever reads its operands (prot_reader_command) or the flag carrying it is
    # a reader flag. Enumerating write flags/operands fails (`uniq IN OUT`).
    # Tokenised here rather than via SEG_WORDS, which bash.unrestricted skips.
    if [ -n "$CMD" ] && printf '%s' "$CMD" | grep -Eqi "$PROT_RE"; then
      # The text pattern is a prefilter; the verdict comes from
      # self_protect_target, so `/root/.claude/projects/…` is not misreported.
      # Line continuations are joined first, as the shell joins them.
      if ! __psegs=$(printf '%s' "$CMD" | tr -d "\"'" \
        | awk '{ if (sub(/\\$/, "")) { printf "%s", $0; held = 1 } else { print; held = 0 } } END { if (held) print "\\" }' \
        | awk '{ gsub(/[;&|]+/, "\n"); print }'); then
        deny_unscreened "bash-self-protect-screen" "this command's operands" "Command: ${CMD}"
      fi
      while IFS= read -r __pseg; do
        [ -n "$__pseg" ] || continue
        # shellcheck disable=SC2206
        __pwords=( $__pseg )
        [ "${#__pwords[@]}" -ge 1 ] || continue
        __pcmd="${__pwords[0]}"
        # A segment whose command word is a protected path executes the
        # manifest, state dir or kernel; nothing legitimate does that.
        if printf '%s' "$__pcmd" | grep -Eqi "$PROT_RE"; then
          self_protect_target "$__pcmd" "self-protect bash command-word"
        fi
        __pcmd="${__pcmd##*/}"
        prot_reader_command "$__pcmd" && continue
        # Reader flags in both spellings: `--file=.claude/x` and `--file .claude/x`.
        # Not `local`: this runs in the script body, not a function.
        __emb=""
        __prev=""
        for __tok in "${__pwords[@]:1}"; do
          if printf '%s' "$__tok" | grep -Eqi "$PROT_RE"; then
            case "$__tok" in
              -*)
                __flag="${__tok%%=*}"
                prot_reader_flag "$__flag" && { __prev="$__tok"; continue; }
                self_protect_target "${__tok#*=}" "self-protect bash flag-operand $__flag" ;;
              *)
                prot_reader_flag "$__prev" && { __prev="$__tok"; continue; }
                self_protect_target "$__tok" "self-protect bash operand $__pcmd"
                # A protected path embedded in a larger operand (curl's
                # `%output{.claude/kernel-mandate.json}`) is pulled out and judged alone.
                # Limited to protected paths so ordinary mentions stay allowed.
                __emb=$(printf '%s' "$__tok" \
                  | grep -oEi "[^\"'{}(),;|&=]*${PROT_RE}[^\"'{}(),;|&]*" 2>/dev/null | head -1)
                [ -n "$__emb" ] && [ "$__emb" != "$__tok" ] \
                  && self_protect_target "$__emb" "self-protect bash embedded-operand $__pcmd" ;;
            esac
          fi
          __prev="$__tok"
        done
      done <<< "$__psegs"
    fi
    ;;
esac

# --- Axis 2: tool gate ---------------------------------------------------
tool_matches_any() {
  # tool_matches_any <tool> <patterns-json-array> — shell-glob match.
  local tool="$1" patterns="$2" pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$tool" in $pat) return 0 ;; esac
  done < <(printf '%s' "$patterns" | "$JQ" -r '.[]?' 2>/dev/null)
  return 1
}

TOOLS_DENY=$(kernel_mandate_role_field "$ROLE" '.tools.deny')
TOOLS_ALLOW=$(kernel_mandate_role_field "$ROLE" '.tools.allow')

if [ "$TOOLS_DENY" != "null" ] && tool_matches_any "$KM_TOOL" "$TOOLS_DENY"; then
  kernel_mandate_deny "tool-deny $KM_TOOL" "[BLOCKED] Role '${ROLE}' is explicitly denied the '$KM_TOOL' tool.

${ROLE_HEADER}

If this step genuinely needs '$KM_TOOL', it belongs to a different role — return your findings and let the orchestrator dispatch the role whose mandate covers it."
fi

if [ "$TOOLS_ALLOW" != "null" ] && ! tool_matches_any "$KM_TOOL" "$TOOLS_ALLOW"; then
  ALLOWED_LIST=$(printf '%s' "$TOOLS_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null || echo "")
  kernel_mandate_deny "tool-not-allowed $KM_TOOL" "[BLOCKED] Role '${ROLE}' may not use the '$KM_TOOL' tool.

${ROLE_HEADER}
Granted tools: ${ALLOWED_LIST}

This boundary is also your context budget — work within the granted tools, and hand anything outside them back to the orchestrator for the role whose mandate covers it."
fi

# --- Axis 5b: write-then-execute containment -----------------------------
# A role that authors executable code holds whatever permissions that code
# gets when something runs it, so code written into an executable file may
# not reach capabilities outside the role's envelope (fs, process, network,
# eval/dynamic import) unless declared: "write": { "codeCapabilities": ["fs"] }.
# Called from every channel that authors a file.
#
#   check_code_capabilities <target-path> <code-text> <channel-hint>
check_code_capabilities() {
  local target="$1" code="$2" via="${3:-}" rel
  [ -n "$target" ] || return 0
  [ -n "$code" ] || return 0
  rel=$(kernel_mandate_relpath "$target")
  # A file with no extension is runnable (a `#!/bin/sh` shebang), so it is screened.
  # Config a runtime loads by itself (tsconfig `paths`, runner configs) can
  # remap a declared import to arbitrary code, so a role with code constraints
  # may not author it. Checked before the extension gate: these are data
  # extensions. The table of names is a floor, not the boundary.
  if [ "$(kernel_mandate_role_field "$ROLE" '.write.codeImports')" != "null" ] \
     || [ "$(kernel_mandate_role_field "$ROLE" '.write.codeCapabilities')" != "null" ]; then
    local cfg_kind=""
    case "${rel##*/}" in
      tsconfig.json|tsconfig.*.json|jsconfig.json|jsconfig.*.json|deno.json|deno.jsonc|import_map.json|importmap.json|.pnp.cjs|.pnp.js)
        cfg_kind="resolution" ;;
      package.json|.npmrc|.yarnrc|.yarnrc.yml|.pnpmrc|bunfig.toml)
        cfg_kind="resolution" ;;
      .babelrc|.babelrc.*|babel.config.*|.swcrc|.browserslistrc)
        cfg_kind="build" ;;
      Makefile|makefile|GNUmakefile|*.mk|Rakefile|Justfile|justfile|Taskfile.yml|Taskfile.yaml|CMakeLists.txt|build.gradle|build.gradle.kts|pom.xml)
        cfg_kind="build" ;;
      .mocharc|.mocharc.*|.nycrc|.nycrc.*|.c8rc|.c8rc.*|.taprc)
        cfg_kind="runner" ;;
      *.config.js|*.config.mjs|*.config.cjs|*.config.ts|*.config.mts|*.config.cts|*.config.json|*.config.yaml|*.config.yml)
        cfg_kind="runner" ;;
      .env|.env.*)
        cfg_kind="environment" ;;
      # Agent runtimes auto-load files too: a nested CLAUDE.md is read as
      # instructions by any agent working in that tree, including a grader
      # whose read scope overlaps this role's write scope.
      CLAUDE.md|AGENTS.md|AGENT.md|GEMINI.md|.cursorrules|.clinerules|.windsurfrules|.aiderrules|*.mdc|copilot-instructions.md)
        cfg_kind="agent-instructions" ;;
    esac
    # A package directory in the write scope (`node_modules/<name>/`) shadows
    # the real package, so a declared import resolves to authored code.
    case "/$rel" in
      */node_modules/*) cfg_kind="resolution" ;;
    esac
    if [ -n "$cfg_kind" ]; then
      local cfg_why
      case "$cfg_kind" in
        resolution) cfg_why="This file decides what a module specifier RESOLVES to. This role declares which packages its code may import, and a resolution map makes that declaration meaningless: an import of a declared package can be pointed at any module on disk, which is exactly how it was broken. The declaration and the map cannot both belong to the same role." ;;
        agent-instructions) cfg_why="This file is loaded by an AGENT runtime as authoritative instructions for anyone working in that directory — not by a test runner, by the reader. A role that authors it is writing the prompt of every role whose read scope covers this path, which for a graded deliverable means the reviewer and the judge. That is a verdict steered without a single write to the ledger." ;;
        build)      cfg_why="This file rewrites code before it runs — a transform or plugin named here executes with the runner's permissions, and nothing in the authored source shows it." ;;
        runner)     cfg_why="A granted runner loads this file by convention, without anyone naming it on a command line, and a runner config can name a web-server command, a setup module or a reporter. Every one of those becomes a process." ;;
        environment) cfg_why="A framework auto-loads this file into the environment of every process the run starts." ;;
      esac
      kernel_mandate_deny "write-runtime-config:$cfg_kind $rel" "[BLOCKED] Role '${ROLE}' may not author '$rel' — it is $cfg_kind configuration that a runtime picks up on its own.

${ROLE_HEADER}
File: $rel${via}

$cfg_why

This role declares what its code may import or do, which is a statement about the artifacts it produces. Configuration a runner discovers by convention is not one of those artifacts: it is an instruction to the runner, and it is not screened by anything, because it contains no code to screen.

Options, narrowest first:
  1. Put the setting in the file the operator owns, outside this role's write scope — the run still finds it, and the role cannot rewrite it.
  2. If this role genuinely needs its own, hand the file to the role that owns runner configuration.

This is a table of names, so it is a floor rather than a boundary. The boundary is running the executor under 'kernel-mandate run --role ${ROLE}', or splitting authoring from running into two roles: kernel-mandate validate says which applies here."
    fi
  fi
  case "${rel##*/}" in
    *.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.tsx|*.jsx|*.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.php|*.ipynb|*.lua|*.ps1|*.awk|*.sed|*.jq) : ;;
    *.*) return 0 ;;
    *) : ;;
  esac
  local CAPS_ALLOW CODE_N CODE_C CAP_ID CAP_WHAT LOAD FS_METHODS
  CAPS_ALLOW=$(kernel_mandate_role_field "$ROLE" '.write.codeCapabilities')
  CAP_ID=""; CAP_WHAT=""
  # Normalise how a module name can be spelled (whitespace, backticks,
  # `node:` prefix, \x/octal escapes, String.fromCharCode, shell-escaped
  # quotes) so a synonym is not a bypass.
  # Strip comments, matching string literals first so a `/*` inside a string
  # stays literal; then rejoin a specifier split from its keyword by a removed
  # `//` comment. Each stage denies when its tool fails.
  CODE_N=$(printf '%s' "$code" | perl -0777 -pe '
      s{ ("(?:\\.|[^"\\])*")
       | (\x27(?:\\.|[^\x27\\])*\x27)
       | (`(?:\\.|[^`\\])*`)
       | (/(?:\\.|\[(?:\\.|[^\]\\])*\]|[^/\\\[\n])+/[gimsuyvd]*)
       | (/\*.*?\*/)
       | (//[^\n]*)
       }{ (defined($1) || defined($2) || defined($3) || defined($4)) ? $& : " " }gsex;
      s{\b(require|import)\s*\(\s*}{$1(}gs;
      s{\bfrom\s*(["\x27])}{from $1}gs' 2>/dev/null) \
    || deny_unscreened "write-code-import-screen $rel" "this file's imports" "File: $rel${via}"
  # A second view strips comment shapes unconditionally: through Bash the
  # outer quotes are the shell's, so the lexer view sees one string literal.
  # Stripping only removes text to a space, so it adds no false positives.
  CODE_C=$(printf '%s' "$code" | perl -0777 -pe 's{/\*.*?\*/}{ }gs; s{(^|[^:"\x27\\])//[^\n]*}{$1}g;
      s{\b(require|import)\s*\(\s*}{$1(}gs;
      s{\bfrom\s*(["\x27])}{from $1}gs' 2>/dev/null) \
    || deny_unscreened "write-code-import-screen $rel" "this file's imports" "File: $rel${via}"
  CODE_N="$CODE_N
$CODE_C"
  CODE_N=$(printf '%s' "$CODE_N" \
    | sed -E 's/\\"/"/g; s/\\'"'"'/'"'"'/g' \
    | tr '\140' '"' \
    | sed -E "s/'/\"/g; s/[[:space:]]*\+[[:space:]]*\"\"//g; s/\"[[:space:]]*\+[[:space:]]*\"//g; s/node:/ /g" \
    | perl -pe 's/\\x\{?([0-9a-fA-F]{2})\}?/chr(hex($1))/ge; s/\\u\{?([0-9a-fA-F]{4})\}?/chr(hex($1))/ge; s/\\([0-7]{1,3})/chr(oct($1))/ge' 2>/dev/null \
    | sed -E "s/[[:space:]]+/ /g") \
    || deny_unscreened "write-code-import-screen $rel" "this file's imports" "File: $rel${via}"
  # Any module-loading call (import, require, dynamic import(), createRequire,
  # builtin-module accessors, module.constructor._load, Function, process.binding)
  # followed by the capability name; the bracket form is a computed member.
  LOAD='(require|\[[[:space:]]*"(require|import)"[[:space:]]*\]|import|createRequire\([^)]*\)|process\.getBuiltinModule|process\.binding|module\.constructor\._load|constructor\.constructor|Deno\.|Bun\.)'
  # Filesystem is matched by method family (*Sync, fs.promises, *FileSync) and
  # without a following `(`, so a method bound first and called later still
  # matches. `path` does no I/O and is not listed; `\bPath(` is pathlib only.
  # process.report.writeReport writes files; process.chdir re-anchors paths.
  FS_METHODS='\b(open|read|write|append|stat|lstat|fstat|copy|rename|rm|unlink|mkdir|rmdir|readdir|realpath|access|truncate|chmod|chown|link|symlink|readlink|utimes|watch|opendir|mkdtemp|cp)[A-Za-z]*Sync\b|\[[[:space:]]*"[^"]*Sync"[[:space:]]*\]|\bfs\.promises\b|\bfsPromises\b|\bcreate(Read|Write)Stream\b|\bprocess\.report\.writeReport\b|\bprocess\.chdir\b'
  if printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*\"[[:space:]]*(fs|fs/promises|os)[[:space:]]*\"|from[[:space:]]*\"[[:space:]]*(fs|fs/promises)[[:space:]]*\"|^[[:space:]]*import[[:space:]]+(os|shutil|pathlib|io|glob)([[:space:],.]|$)|^[[:space:]]*from[[:space:]]+(os|shutil|pathlib|io|glob)([[:space:].]|$)|(^|[^a-zA-Z_.])open[[:space:]]*\([[:space:]]*[\"'\`]|${FS_METHODS}|readFile[[:space:]]*\(|(^|[^A-Za-z0-9_])Path[[:space:]]*\("; then
    CAP_ID='fs'; CAP_WHAT='filesystem access (fs / os / open / readFileSync …) — code that can read or write any path, ignoring the role scopes'
  elif printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*\"[[:space:]]*(child_process|node:child_process)[[:space:]]*\"|from[[:space:]]*\"[[:space:]]*child_process[[:space:]]*\"|^[[:space:]]*import[[:space:]]+(subprocess|pty|multiprocessing)([[:space:],.]|$)|^[[:space:]]*from[[:space:]]+subprocess([[:space:].]|$)|execSync|spawnSync|execFileSync|\bspawn[[:space:]]*\(|subprocess\.(run|Popen|call|check_output)|os\.(system|popen|exec|spawn)"; then
    CAP_ID='process'; CAP_WHAT='process spawning (child_process / subprocess / os.system …) — code that runs commands no command group checked'
  elif printf '%s' "$CODE_N" | grep -Eq '\bworker_threads\b'; then
    # A worker_threads Worker escapes Node's permission model. A bare
    # `new Worker` is a browser worker (Node has no global Worker) and is allowed.
    CAP_ID='process'; CAP_WHAT='a worker thread (worker_threads) — a worker does NOT inherit the runtime permission profile, so it is a way out of the containment that profile installs'
  elif printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*\"[[:space:]]*(net|http|https|dgram|tls|dns|inspector)[[:space:]]*\"|from[[:space:]]*\"[[:space:]]*(net|http|https|dgram)[[:space:]]*\"|^[[:space:]]*import[[:space:]]+(socket|urllib|requests|httpx|ftplib|smtplib|telnetlib)([[:space:],.]|$)|^[[:space:]]*from[[:space:]]+(socket|urllib|requests|httpx)([[:space:].]|$)"; then
    CAP_ID='network'; CAP_WHAT='raw network access (net / http / socket …) — an exfiltration channel'
  elif printf '%s' "$CODE_N" | grep -Eq "\b(request|apiRequest|context)\.(get|post|put|patch|delete|fetch|head)[[:space:]]*\([[:space:]]*[\"'\`]?[a-zA-Z][a-zA-Z0-9+.-]*://|\bsendBeacon[[:space:]]*\(|\bnavigator\.sendBeacon\b" \
       && ! kernel_mandate_code_calls_in_scope "$CODE_N" "$(kernel_mandate_role_field "$ROLE" '.network.allow')" \
            "\.(get|post|put|patch|delete|fetch|head)"; then
    # Playwright's `request` fixture reaches any host, so it is an exfil channel.
    CAP_ID='network'; CAP_WHAT='the test framework''s HTTP client (request.get / page.request / sendBeacon) pointed at an arbitrary host — the same exfiltration channel as fetch(), reached through a fixture'
  elif printf '%s' "$CODE_N" | grep -Eq "\bprocess\.env[[:space:]]*[),;}]|\bprocess\.env[[:space:]]*$|\(process\.env\)|\bentries[[:space:]]*\([[:space:]]*process\.env|\bkeys[[:space:]]*\([[:space:]]*process\.env|\bstringify[[:space:]]*\([[:space:]]*process\.env|\bfor[[:space:]]*\([^)]*\bin[[:space:]]+process\.env\b"; then
    # `process.env` as a value (passed, serialised, iterated) leaks every secret;
    # a member read (`process.env.X`) is followed by `.` or `[` and does not match.
    CAP_ID='env'; CAP_WHAT='the entire process environment as a value (process.env handed to a call, serializer, iterator or return) — every secret the runner was started with, read at once. Read the specific variable the test needs (process.env.APP_URL)'
  elif printf '%s' "$CODE_N" | grep -Eq "\beval[[:space:]]*\(|new Function[[:space:]]*\(|__import__[[:space:]]*\(|\bimportlib\b|\bexec[[:space:]]*\(|vm\.(run|compile)"; then
    CAP_ID='eval'; CAP_WHAT='eval / new Function — code the static check cannot read'
  elif printf '%s' "$CODE_N" | tr '\n' ' ' | grep -Eq '[=,:([][[:space:]]*require[[:space:]]*([];,)}]|$)'; then
    # `const r = require; r("x")` hides the specifier from every later check.
    CAP_ID='eval'; CAP_WHAT='the module loader bound to a name (`const r = require`) rather than called — the static check cannot follow an alias to see what it loads'
  elif printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*[^\"[:space:])]"; then
    # A module specifier that is not a plain quoted literal cannot be read
    # statically, so it is refused as 'eval' whatever it evaluates to.
    CAP_ID='eval'; CAP_WHAT='a module name built at runtime rather than written as a literal — the static check cannot see what it resolves to, so it cannot be scoped'
  fi
  # A file:// URL is a local read channel; `file:/x` is the same URL.
  if [ -z "$CAP_ID" ] && printf '%s' "$CODE_N" | grep -Eq 'file:/'; then
    CAP_ID='fs'; CAP_WHAT='a file: URL — the browser/runtime reads the path directly, with no host module for a scope check to see'
  fi
  # Framework file APIs write too (screenshot, saveAs, storageState, recordHar…),
  # and a write can forge the ledger or disarm the kernel. A `path:` option is
  # a write unless the method is a known reader.
  if [ -z "$CAP_ID" ]; then
    local wr_call wr_meth wr_arg wr_lit wr_abs wr_rel wr_dir wr_wscope
    # Playwright resolves `path:` and setInputFiles() against process.cwd() (the
    # project root), not the spec's directory; relative imports resolve against
    # the importing file.
    # A file key is matched by shape (ends in path/dir/file, case-insensitive);
    # `storageState` is listed by name because its name gives no hint.
    # Chromium switches in `launchOptions.args` name output files
    # (`--log-file=`, `--user-data-dir=`), so any authoring role is refused them;
    # put switches in playwright.config.ts, which the role cannot write.
    if [ "$(kernel_mandate_role_field "$ROLE" '.write.allow')" != "null" ]; then
      if printf '%s' "$CODE_N" | grep -Eq 'args[[:space:]]*:[[:space:]]*\[[^]]*--[a-z]'; then
        CAP_ID='fs'; CAP_WHAT="browser launch switches authored inline (launchOptions.args) — several of Chromium's switches name output files (--log-file=, --user-data-dir=, --disk-cache-dir=), so this is a file-writing channel underneath the framework API this screen models, and no list of switches finishes. Put the switch in playwright.config.ts, which this role may not write, or split the role that authors specs from the role that runs them"
      fi
    fi
    KM_FILE_KEY_RE='([A-Za-z0-9_]*([Pp]ath|[Dd]ir|[Ff]ile)|storageState)'
    wr_dir="${KM_CWD%/}"
    wr_wscope=$(kernel_mandate_role_field "$ROLE" '.write.allow')
    while IFS= read -r wr_call; do
      [ -n "$wr_call" ] || continue
      # Reader methods (`attach({ path })`) keep their exemption and are held to
      # the read scope instead. Without a method in view the bare `path:` form
      # is treated as a write.
      wr_read=0; wr_dirread=0
      case "$wr_call" in
        .saveAs*)
          wr_arg="${wr_call#*(}"
          wr_arg=$(printf '%s' "$wr_arg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*$//') ;;
        .routeFromHAR*)
          # A HAR is read back to replay it, as is a storageState file.
          wr_read=1
          wr_arg="${wr_call#*(}"
          wr_arg=$(printf '%s' "$wr_arg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*$//') ;;
        *)
          # The nearest call before the operand decides, not the first in the window.
          wr_meth=$(printf '%s' "$wr_call" | sed -E "s/${KM_FILE_KEY_RE}[[:space:]]*:[^:]*$//" \
            | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' 2>/dev/null \
            | tail -1 | sed -E 's/[[:space:]]*\($//')
          case "$wr_meth" in
            attach|attachFile|setInputFiles|uploadFile|uploadFiles|setFiles) continue ;;
          esac
          # The shape test says the value names a file, not who opens it. Unknown
          # keys stay writes (the narrower scope); three families are not writes.
          wr_key=$(printf '%s' "$wr_call" | grep -oE "${KM_FILE_KEY_RE}[[:space:]]*:" 2>/dev/null \
            | tail -1 | sed -E 's/[[:space:]]*:$//')
          case "$wr_key" in
            storageState|har|harPath) wr_read=1 ;;
            # testDir is where the runner LOOKS for tests: it loads the files under
            # it and creates nothing there. A directory read, held to the read scope.
            testDir) wr_read=1; wr_dirread=1 ;;
            executablePath|*ExecutablePath)
              # executablePath names a binary to run. Allowed unless it points into the
              # role's write scope, which would run a file the role authored.
              wr_exec=1 ;;
          esac
          # A cookie's or route's `path` is a URL path, not a file. Read as one only
          # when the object carries a cookie- or route-only key.
          case "$CODE_N" in
            *domain:*|*domain\ :*|*sameSite:*|*sameSite\ :*|*httpOnly:*|*httpOnly\ :*)
              case "${wr_call#*:}" in
                *\'/\'*|*\"/\"*) continue ;;
              esac ;;
          esac
          # The match ends immediately after the value, so the LAST
          # file-shaped key in the candidate is the one it belongs to.
          wr_arg=$(printf '%s' "$wr_call" | sed -E "s/^.*${KM_FILE_KEY_RE}[[:space:]]*:[[:space:]]*//; s/[[:space:]]+\$//") ;;
      esac
      [ -n "$wr_arg" ] || continue
      case "$wr_arg" in
        \"*\") wr_lit="${wr_arg%\"}"; wr_lit="${wr_lit#\"}"; case "$wr_lit" in *\"*) wr_lit="" ;; esac ;;
        \'*\') wr_lit="${wr_arg%\'}"; wr_lit="${wr_lit#\'}"; case "$wr_lit" in *\'*) wr_lit="" ;; esac ;;
        *) wr_lit="" ;;
      esac
      case "$wr_lit" in *'${'*|*'`'*) wr_lit="" ;; esac
      if [ -z "$wr_lit" ]; then
        CAP_ID='fs'; CAP_WHAT="a framework file API whose path is built at run time ('$wr_arg') — a path that does not exist until the test runs cannot be held to this role's write scope, and the framework creates the file directly with no host module for a check to see"
        break
      fi
      case "$wr_lit" in *://*) continue ;; esac
      case "$wr_lit" in /*) wr_abs="$wr_lit" ;; *) wr_abs="$wr_dir/$wr_lit" ;; esac
      wr_rel=$(kernel_mandate_relpath "$wr_abs")
      # The root of trust first, on this channel too.
      # self_protect_target denies by printing and exiting 0, so call it in a
      # subshell and treat its output as the signal.
      if [ -n "$( self_protect_target "$wr_abs" "framework-write" 2>/dev/null )" ]; then
        CAP_ID='fs'; CAP_WHAT="a framework file API aimed at '$wr_rel' — that is the kernel mandate itself, and no governed role may write it through any channel"
        break
      fi
      # The shape test found a key that names a file; these decide who opens it.
      if [ "${wr_exec:-0}" = "1" ]; then
        # An executable inside the role's write scope is write-then-execute.
        wr_exec=0
        [ "$wr_wscope" = "null" ] && continue
        kernel_mandate_path_in_scope "$wr_rel" "$wr_wscope" || continue
        CAP_ID='fs'; CAP_WHAT="a framework option that EXECUTES '$wr_rel', which is inside this role's own write scope — a binary this role may author and the granted runner then runs is the write-then-execute channel, whatever the option is called"
        break
      fi
      if [ "${wr_read:-0}" = "1" ]; then
        # A read sink, held to the read scope.
        wr_rscope=$(kernel_mandate_role_field "$ROLE" '.read.allow')
        [ "$wr_rscope" = "null" ] && continue
        kernel_mandate_path_in_scope "$wr_rel" "$wr_rscope" && { wr_dirread=0; continue; }
        # A directory read (testDir) is in scope when the files under it are.
        if [ "${wr_dirread:-0}" = "1" ]; then
          wr_dirread=0
          kernel_mandate_path_in_scope "$wr_rel/x.spec.ts" "$wr_rscope" && continue
        fi
        CAP_ID='fs'; CAP_WHAT="a framework file API that READS '$wr_rel', which is outside this role's read scope ($(printf '%s' "$wr_rscope" | "$JQ" -r 'join(", ")' 2>/dev/null)) — the framework opens it directly, so naming it here is the same act as naming it to the Read tool"
        break
      fi
      if [ "$wr_wscope" = "null" ]; then
        CAP_ID='fs'; CAP_WHAT="a framework file API that writes '$wr_rel' — this role has no write grants at all, and a file the framework creates is a write like any other"
        break
      fi
      kernel_mandate_path_in_scope "$wr_rel" "$wr_wscope" && continue
      CAP_ID='fs'; CAP_WHAT="a framework file API that writes '$wr_rel', which is outside this role's write scope ($(printf '%s' "$wr_wscope" | "$JQ" -r 'join(", ")' 2>/dev/null)) — the file the framework creates is a write, and the Write tool refuses that same path"
      break
    # Every `path:` in the authored text is a candidate wherever it sits (nested
    # parens, a variable-bound object), and its operand must be a provable
    # literal. `[^,}]`, not `[^,}\n]`: in a bracket expression `\n` excludes `n`.
    done < <(printf '%s' "$CODE_N" \
      | grep -oE "[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^;]{0,200}${KM_FILE_KEY_RE}[[:space:]]*:[^,}]*|${KM_FILE_KEY_RE}[[:space:]]*:[^,}]*|\.saveAs[[:space:]]*\([^,)]*|\.routeFromHAR[[:space:]]*\([^,)]*" 2>/dev/null)
  fi
  # Authored navigation is held to the network scope: a literal URL is
  # scope-checked, a destination built at run time is refused. A role with
  # no declared scope keeps the blanket exfil behaviour.
  if [ -z "$CAP_ID" ]; then
    local nav_scope nav_call nav_arg nav_lit nav_auth
    nav_scope=$(kernel_mandate_role_field "$ROLE" '.network.allow')
    while IFS= read -r nav_call; do
      [ -n "$nav_call" ] || continue
      nav_arg="${nav_call#*(}"
      nav_arg=$(printf '%s' "$nav_arg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*[,)].*$//')
      case "$nav_arg" in
        \"*\") nav_lit="${nav_arg%\"}"; nav_lit="${nav_lit#\"}"
               # A quote surviving inside is a concatenation, not a literal.
               case "$nav_lit" in *\"*) nav_lit="" ;; esac ;;
        \'*\') nav_lit="${nav_arg%\'}"; nav_lit="${nav_lit#\'}"
               case "$nav_lit" in *\'*) nav_lit="" ;; esac ;;
        *) nav_lit="" ;;
      esac
      case "$nav_lit" in *'${'*|*'`'*) nav_lit="" ;; esac
      # A relative path navigates against baseURL, the app under test.
      case "$nav_lit" in /*|'#'*|'?'*) continue ;; esac
      # An empty operand is a call with no destination argument.
      case "$nav_arg" in '') continue ;; esac
      if [ -z "$nav_lit" ]; then
        # A run-time destination is refused only where `network.allow` is declared:
        # `url = process.env.APP_URL || '/forms'` is an ordinary spec idiom.
        [ "$nav_scope" = "null" ] && continue
        CAP_ID='network'; CAP_WHAT="a browser navigation whose destination is built at run time ('$nav_arg') — a host assembled from expressions cannot be checked against this role's network scope, and the browser dials it directly with no host module for a scope check to see"
        break
      fi
      kernel_mandate_is_network_url "$nav_lit" || continue
      nav_auth=$(kernel_mandate_url_authority "$nav_lit")
      [ -n "$nav_auth" ] || continue
      if [ "$nav_scope" = "null" ]; then
        CAP_ID='network'; CAP_WHAT="a browser navigation to '$nav_auth' — this role declares no network scope, so no destination can be shown to be permitted"
        break
      fi
      if ! kernel_mandate_authority_in_scope "$nav_auth" "$nav_scope"; then
        CAP_ID='network'; CAP_WHAT="a browser navigation to '$nav_auth', which is outside this role's network scope ($(printf '%s' "$nav_scope" | "$JQ" -r 'join(", ")' 2>/dev/null))"
        break
      fi
    done < <(printf '%s' "$CODE_N" \
      | grep -oE "\.(goto|navigateTo|navigate|open|setExtraHTTPHeaders)[[:space:]]*\([^)]*\)?|\b(request|apiRequest|context)\.(get|post|put|patch|delete|fetch|head)[[:space:]]*\([^)]*\)?" 2>/dev/null)
  fi

  # Bare global network sinks (fetch, WebSocket, EventSource, SharedWorker,
  # dynamic import) with a constructed destination are refused as unverifiable.
  # Runs on string-blanked code so a sink named in a label or title is ignored.
  if [ -z "$CAP_ID" ]; then
    local g_blanked
    # Applies to every code-authoring role, scope or not: a constructed URL
    # must not be weaker than a literal one, which is denied regardless.
    {
      # Blank '…' and "…" interiors so a sink named in a string vanishes.
      # Templates are handled below. If perl fails, unblanked code only over-matches.
      g_blanked=$(printf '%s' "$CODE_N" | perl -pe 's/"(?:\\.|[^"\\])*"/""/g; '"s/'(?:\\\\.|[^'\\\\])*'/''/g;" 2>/dev/null || printf '%s' "$CODE_N")
      # A bare global sink whose first argument is an expression — a
      # variable, an array, atob(…), or a string immediately followed by
      # `+` (a concatenation) — is a destination built at run time.
      if printf '%s' "$g_blanked" | grep -Eq '(^|[^.A-Za-z0-9_$])(fetch|import)\([[:space:]]*[^[:space:]"'"'"'`)]|(^|[^.A-Za-z0-9_$])new[[:space:]]+(WebSocket|EventSource|SharedWorker)\([[:space:]]*[^[:space:]"'"'"'`)]|(^|[^.A-Za-z0-9_$])(fetch|import)\([[:space:]]*("")[[:space:]]*\+|(^|[^.A-Za-z0-9_$])new[[:space:]]+(WebSocket|EventSource|SharedWorker)\([[:space:]]*("")[[:space:]]*\+'; then
        CAP_ID='network'; CAP_WHAT="a network destination built at run time and handed to a global sink (fetch / WebSocket / EventSource / import) — a host assembled from expressions cannot be checked against this role's network scope, so it is refused as unverifiable. Write the destination as a literal, or route the connection through an API whose target this role's network.allow permits"
      # A template with an absolute scheme and ${…} is a constructed absolute
      # destination; a relative template reaches the app under test.
      elif printf '%s' "$CODE_N" | grep -Eq '(^|[^.A-Za-z0-9_$])(fetch|import)\([[:space:]]*`[a-zA-Z][a-zA-Z0-9+.-]*://[^`]*\$\{|[^.A-Za-z0-9_$]new[[:space:]]+(WebSocket|EventSource|SharedWorker)\([[:space:]]*`[a-zA-Z][a-zA-Z0-9+.-]*://[^`]*\$\{'; then
        CAP_ID='network'; CAP_WHAT="a network destination whose host is interpolated into a template literal (\`scheme://\${…}\`) and handed to a global sink — the host is built at run time and cannot be checked against this role's network scope, so it is refused as unverifiable"
      fi
    }
  fi

  # Independent of any sink list: an absolute network URL written as a whole
  # literal anywhere in authored code is held to the network scope, whatever
  # API receives it. URLs built at run time are not seen here (a documented limit).
  if [ -z "$CAP_ID" ]; then
    local url_scope url_lit url_auth url_rows url_row url_ctx url_near
    url_scope=$(kernel_mandate_role_field "$ROLE" '.network.allow')
    url_rows=$(printf '%s' "$CODE_N" | perl -ne '
      while (/"[[:space:]]*((?:[a-zA-Z][a-zA-Z0-9+.-]*:\/\/|stun:|stuns:|turn:|turns:)[^"]*)"/g) {
        my $u = $1; my $ctx = substr($_, 0, pos($_));
        $ctx = substr($ctx, -140) if length($ctx) > 140;
        $ctx =~ s/[\t\n]/ /g; $u =~ s/[[:space:]]+$//;
        print "$ctx\t$u\n";
      }' 2>/dev/null) \
      || deny_unscreened "write-code-network-screen $rel" "this file's network destinations" "File: $rel${via}"
    while IFS= read -r url_row; do
      [ -n "$url_row" ] || continue
      # A URL a test asserts on or blocks is not one it dials. A literal whose
      # nearest preceding call is an assertion matcher or interception API is data;
      # an unnamed call leaves it a destination.
      url_ctx="${url_row%%$'\t'*}"
      url_lit="${url_row#*$'\t'}"
      [ -n "$url_lit" ] || continue
      url_near=$(printf '%s' "$url_ctx" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' 2>/dev/null \
        | tail -1 | sed -E 's/[[:space:]]*\($//')
      case "$url_near" in
        toHaveAttribute|toHaveURL|toHaveJSProperty|toBe|toEqual|toStrictEqual|\
        toContain|toMatch|toContainText|toHaveText|toHaveValue|\
        route|unroute|unrouteAll|routeWebSocket|routeFromHAR|\
        getByText|getByLabel|getByTitle|getByPlaceholder|getByAltText|fill|\
        toHaveScreenshot|describe|it|test)
          continue ;;
      esac
      # ICE server URLs (`stun:host:port`, `turn:`) have no `//`; normalise them
      # to authority form before the shared URL check.
      case "$url_lit" in
        stun:*|stuns:*|turn:*|turns:*)
          url_lit="${url_lit%%:*}://${url_lit#*:}" ;;
      esac
      kernel_mandate_is_network_url "$url_lit" || continue
      url_auth=$(kernel_mandate_url_authority "$url_lit")
      [ -n "$url_auth" ] || continue
      if [ "$url_scope" = "null" ]; then
        CAP_ID='network'; CAP_WHAT="an absolute URL '$url_auth' written into authored code — this role declares no network scope, so no destination can be shown to be permitted. The browser and the runtime have many ways to dial a host, so this is judged by the DESTINATION rather than by which API receives it"
        break
      fi
      if ! kernel_mandate_authority_in_scope "$url_auth" "$url_scope"; then
        CAP_ID='network'; CAP_WHAT="an absolute URL '$url_auth' written into authored code, which is outside this role's network scope ($(printf '%s' "$url_scope" | "$JQ" -r 'join(", ")' 2>/dev/null)). This is judged by the DESTINATION rather than by which API receives it, because a browser has more ways to reach a host than any list can name"
        break
      fi
    # The URL must be the whole literal (surrounding space allowed): a URL inside
    # prose or a test title is documentation, not a destination.
    done <<< "$url_rows"
  fi
  # A config `command:`/`cmd:` string is a shell command the runtime spawns
  # (`webServer: { command: "cat .env > x" }`), so it counts as process
  # spawning. An enumeration, so a floor; the boundary is `kernel-mandate run`.
  if [ -z "$CAP_ID" ] \
     && printf '%s' "$CODE_N" | grep -Eq '(^|[^A-Za-z0-9_$.])["'"'"'`]?(command|cmd)["'"'"'`]?[[:space:]]*:[[:space:]]*["'"'"'`]'; then
    CAP_ID='process'; CAP_WHAT='a configuration key whose value is a command string (command:/cmd:) — a runtime that reads this file spawns that command through a shell, which no command group ever checked'
  fi
  # File and process primitives of the non-JS languages the extension gate
  # opts in. A floor, not a boundary; the boundary is `kernel-mandate run`.
  if [ -z "$CAP_ID" ]; then
    if printf '%s' "$CODE_N" | grep -Eq '\b(File|IO)\.(read|write|open|binread|binwrite|readlines|foreach)\b|\bDir\.(glob|entries|children)\b|\bFileUtils\b'; then
      CAP_ID='fs'; CAP_WHAT='Ruby filesystem access (File/IO/Dir/FileUtils) — code that can read or write any path, ignoring the role scopes'
    elif printf '%s' "$CODE_N" | grep -Eq '\b(file_get_contents|file_put_contents|fopen|readfile|fread|fwrite|scandir|glob)[[:space:]]*\('; then
      CAP_ID='fs'; CAP_WHAT='PHP filesystem access (file_get_contents / fopen / readfile …) — code that can read or write any path, ignoring the role scopes'
    elif printf '%s' "$CODE_N" | grep -Eq '\bio\.(open|lines|input|output)[[:space:]]*\(|\bloadfile[[:space:]]*\(|\bdofile[[:space:]]*\('; then
      CAP_ID='fs'; CAP_WHAT='Lua filesystem access (io.open / io.lines / loadfile) — code that can read or write any path, ignoring the role scopes'
    elif printf '%s' "$CODE_N" | grep -Eq '\bGet-Content\b|\bSet-Content\b|\bOut-File\b|\bAdd-Content\b|\[IO\.File\]|\[System\.IO\.File\]'; then
      CAP_ID='fs'; CAP_WHAT='PowerShell filesystem access (Get-Content / Set-Content / [IO.File]) — code that can read or write any path, ignoring the role scopes'
    elif printf '%s' "$CODE_N" | grep -Eq '\b(codecs|fileinput|tempfile|pathlib)\.(open|input|Path|NamedTemporaryFile)|__builtins__(\.|\[)|\bgetattr[[:space:]]*\([[:space:]]*__'; then
      CAP_ID='fs'; CAP_WHAT='Python filesystem access reached indirectly (codecs / fileinput / __builtins__) — code that can read or write any path, ignoring the role scopes'
    elif printf '%s' "$CODE_N" | grep -Eq '\b(system|exec|popen|backticks|Open3)[[:space:]]*\(|`[^`]*`|\bshell_exec[[:space:]]*\(|\bproc_open[[:space:]]*\(|\bos\.execute[[:space:]]*\(|\bStart-Process\b|\bInvoke-Expression\b'; then
      CAP_ID='process'; CAP_WHAT='process spawning in a non-JS language (system / exec / backticks / Invoke-Expression) — code that runs commands no command group checked'
    fi
  fi
  # Framework file APIs (setInputFiles, attach({path}), upload wrappers such
  # as uploadFile) read a path the kernel never sees. Only a call naming a
  # path is checked: it must be a literal resolving inside the read scope,
  # since a path built at run time cannot be scoped at author time.
  if [ -z "$CAP_ID" ]; then
    local fw_call fw_arg fw_lit fw_abs fw_rel fw_dir fw_scope
    # Resolved against the runner's cwd, as in the write direction above.
    fw_dir="${KM_CWD%/}"
    fw_scope=$(kernel_mandate_role_field "$ROLE" ".read.allow")
    while IFS= read -r fw_call; do
      [ -n "$fw_call" ] || continue
      # The argument text: for attach({path: X}) the value after `path:`,
      # otherwise everything inside the parens. Spaces around the colon are
      # normalised first: in a `case` glob `[[:space:]]*` is not zero-or-more.
      local fw_norm
      fw_norm=$(printf '%s' "$fw_call" | sed -E 's/[[:space:]]*:[[:space:]]*/:/g')
      # `attach` names a file only through `path:`; `{ body: … }` opens nothing.
      case "$fw_norm" in
        .attach*|.attachFile*)
          case "$fw_norm" in *[Pp]ath:*) : ;; *) continue ;; esac ;;
      esac
      case "$fw_norm" in
        *[Pp]ath:*)
          # attach(name, { path: X }) — the value after `path:`.
          fw_arg="${fw_norm#*[Pp]ath:}"
          fw_arg=$(printf '%s' "$fw_arg" | sed -E 's/[,)}].*$//') ;;
        *)
          # setInputFiles and the upload wrappers take the path LAST:
          # `setInputFiles(path)`, `setInputFiles(sel, path)`, `uploadFile(a, b, path)`.
          fw_arg="${fw_norm#*(}"
          fw_arg=$(printf '%s' "$fw_arg" | sed -E 's/\)[^)]*$//')
          # An array names several files and the framework reads each one.
          case "$fw_arg" in
            *\[*\]*) fw_arg="${fw_arg#*\[}"; fw_arg="${fw_arg%%\]*}" ;;
            *,*)       fw_arg="${fw_arg##*,}" ;;
          esac ;;
      esac
      # One candidate per comma; a call is safe only when every path it names is.
      local fw_cand fw_bad=0
      while IFS= read -r fw_cand; do
        [ -n "$fw_cand" ] || continue
        # Trim after splitting, or a trailing space fails the literal test.
        fw_arg=$(printf '%s' "$fw_cand" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -n "$fw_arg" ] || continue
      # A literal is a single quoted string and nothing else. Anything
      # further — a variable, a template, a member expression, a call —
      # is a path this kernel cannot resolve.
      case "$fw_arg" in
        \"*\") fw_lit="${fw_arg%\"}"; fw_lit="${fw_lit#\"}"; case "$fw_lit" in *\"*) fw_lit="" ;; esac ;;
        \'*\') fw_lit="${fw_arg%\'}"; fw_lit="${fw_lit#\'}"; case "$fw_lit" in *\'*) fw_lit="" ;; esac ;;
        *) fw_lit="" ;;
      esac
      # A quoted string carrying `${…}` names a path that exists only at run
      # time, so it is not a literal.
      case "$fw_lit" in *'${'*|*'`'*) fw_lit="" ;; esac
        if [ -z "$fw_lit" ]; then
          CAP_ID='fs'; CAP_WHAT="a test-framework file API whose path is built at run time ('$fw_arg'), which no scope check can resolve — the framework opens it directly, with no host module for a check to see"
          fw_bad=1; break
        fi
        case "$fw_lit" in *://*) continue ;; esac
        case "$fw_lit" in /*) fw_abs="$fw_lit" ;; *) fw_abs="$fw_dir/$fw_lit" ;; esac
        fw_rel=$(kernel_mandate_relpath "$fw_abs")
        if [ "$fw_scope" != "null" ] && kernel_mandate_path_in_scope "$fw_rel" "$fw_scope"; then continue; fi
        CAP_ID='fs'; CAP_WHAT="a test-framework file API naming '$fw_rel', which is outside this role's read scope — the framework opens it directly, with no host module for a scope check to see"
        fw_bad=1; break
      done <<< "$(printf '%s' "$fw_arg" | tr ',' '\n')"
      [ "$fw_bad" = "1" ] && break
    done < <(printf '%s' "$CODE_N" \
      | grep -oE "\.(attach|setInputFiles|uploadFile|uploadFiles|attachFile|setFiles)[[:space:]]*\([^)]*\)?" 2>/dev/null)
  fi
  # An import allowlist, when the role declares one: the set of packages
  # that touch the filesystem is open (`require("dotenv").config()` reads .env),
  # so a role may declare exactly which non-relative modules its code imports.
  local IMPORTS_ALLOW
  IMPORTS_ALLOW=$(kernel_mandate_role_field "$ROLE" '.write.codeImports')
  # For a role that both authors executable files and runs commands, an
  # absent codeImports reads as an EMPTY list: the unconfigured state of a
  # capable role must be its most restrictive. Author-only roles are unchanged.
  if [ "$IMPORTS_ALLOW" = "null" ] \
     && [ "$(kernel_mandate_role_field "$ROLE" '.write.allow')" != "null" ] \
     && [ "$(kernel_mandate_role_field "$ROLE" '.bash')" != "null" ]; then
    IMPORTS_ALLOW='[]'
  fi
  if [ -z "$CAP_ID" ] && [ "$IMPORTS_ALLOW" != "null" ]; then
    local spec CODE_IMP
    # A string literal is emptied unless it directly follows `from`, `require(`
    # or `import(`, so an import written inside prose names nothing.
    CODE_IMP=$(printf '%s' "$CODE_N" | perl -0777 -pe '
        s{("(?:\\.|[^"\\])*")}{ my $s = $1; ($` =~ /(?:\bfrom|\brequire\s*\(|\bimport\s*\(|\bimport)\s*$/s) ? $s : q{""} }ge
      ' 2>/dev/null || printf '%s' "$CODE_N")
    [ -n "$CODE_IMP" ] || CODE_IMP="$CODE_N"
    # Normalise to one line and split before every import/export/require
    # keyword, so a formatter-wrapped specifier stays with its keyword.
    # `import type` is erased at compile time and dropped.
    # A specifier with a `..` segment is kept whole: `pkg/../../dotenv` would
    # otherwise reduce to the allowed `pkg` while Node loads dotenv.
    # A failed text tool yields an empty list, which allows every package, so
    # any failure other than grep's "no match" denies (kernel_mandate_grep_or_empty).
    local import_specs
    if ! import_specs=$(printf '%s' "$CODE_IMP" | tr '\n' ' ' | tr ';' '\n' \
      | awk '{ out = ""; s = $0
               while (match(s, /[^A-Za-z0-9_$](import|export|require)[^A-Za-z0-9_$]/)) {
                 out = out substr(s, 1, RSTART) "\n" substr(s, RSTART + 1, RLENGTH - 1)
                 s = substr(s, RSTART + RLENGTH)
               }
               print out s }' \
      | kernel_mandate_grep_or_empty -vE '^[[:space:]]*(import|export)[[:space:]]+type[[:space:]]' \
      | kernel_mandate_grep_or_empty -oE '(^|[^A-Za-z0-9_$])(require|import)[[:space:]]*\([[:space:]]*"[^"]+"|^[[:space:]]*(import|export)[^";]*from[[:space:]]*"[^"]+"|^[[:space:]]*import[[:space:]]*"[^"]+"' 2>/dev/null \
      | sed -E 's/.*"([^"]+)".*/\1/' \
      | sed -E -e '/^[.\/]/b' -e '/(^|\/)\.\.(\/|$)/b' -e 's|^(@[^/]+/[^/]+).*|\1|' -e 't' -e 's|^([^/]+)/.*|\1|' \
      | sort -u); then
      deny_unscreened "write-code-import-screen $rel" "this file's imports" "File: $rel${via}"
    fi
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      case "$spec" in '') continue ;; esac
      # A relative or absolute specifier is still a read: resolve it against the
      # file's directory and hold it to the read scope. Only existing candidates deny.
      case "$spec" in
        ./*|../*|/*)
          local imp_dir imp_abs imp_rel imp_scope imp_wscope imp_ext imp_cand
          # The importing file's directory is the base here: that is the module
          # loader's rule, unlike the framework-path screens above.
          imp_dir=$(dirname "$(kernel_mandate_normalize_path "$target")")
          imp_scope=$(kernel_mandate_role_field "$ROLE" '.read.allow')
          imp_wscope=$(kernel_mandate_role_field "$ROLE" '.write.allow')
          [ "$imp_scope" = "null" ] && continue
          case "$spec" in /*) imp_abs="$spec" ;; *) imp_abs="$imp_dir/$spec" ;; esac
          imp_abs=$(kernel_mandate_normalize_path "$imp_abs")
          for imp_ext in "" .ts .tsx .mts .cts .js .jsx .mjs .cjs .json .node /index.ts /index.js /index.mjs; do
            imp_cand="${imp_abs}${imp_ext}"
            [ -f "$imp_cand" ] || continue
            imp_rel=$(kernel_mandate_relpath "$imp_cand")
            kernel_mandate_path_in_scope "$imp_rel" "$imp_scope" && continue
            if [ "$imp_wscope" != "null" ] && kernel_mandate_path_in_scope "$imp_rel" "$imp_wscope"; then continue; fi
            kernel_mandate_deny "write-code-import-scope:$imp_rel $rel" "[BLOCKED] Role '${ROLE}' may not author code importing '$spec' — it resolves to '$imp_rel', which is outside this role's read scope.

${ROLE_HEADER}
File: $rel${via}
read scope: $(printf '%s' "$imp_scope" | "$JQ" -r 'join(", ")' 2>/dev/null)

A relative import is exempt from the package allowlist because it names no package — but it is still a read, and the runtime opens it directly with no host module for a scope check to see. It is held to the same scope as naming the file any other way.

Import only paths inside this role's read scope."
          done
          continue ;;
      esac
      # The capability scanner's `s/node:/ /` leaves the specifier as " path".
      # Normalise both sides: drop the space, and match a declared entry with
      # or without its `node:` prefix.
      spec_n="${spec# }"; spec_n="${spec_n%% }"
      if ! printf '%s' "$IMPORTS_ALLOW" | "$JQ" -e --arg m "$spec_n" \
           'map(sub("^node:";"")) | index($m) != null' >/dev/null 2>&1; then
        kernel_mandate_deny "write-code-import:$spec_n $rel" "[BLOCKED] Role '${ROLE}' may not author code importing '$spec_n' — it is not in this role's declared import list.

${ROLE_HEADER}
File: $rel${via}
declared imports: $(printf '%s' "$IMPORTS_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

A package name is an open set: 'dotenv' reads .env, 'glob' and 'fs-extra' wrap the filesystem, and no list of dangerous names can be finished. So this role declares what its code DOES import, and everything else is refused — the same inversion that made the builtin-module check sound.

Options, narrowest first:
  1. Use a module already declared, or a relative import inside your write scope.
  2. If this role's work genuinely needs it, the operator can add it:
       \"write\": { \"codeImports\": [\"$spec\"] }
     Every other package stays denied.

Preview before committing: kernel-mandate explain --role ${ROLE} --tool Write --path <file> --content '<code>'"
      fi
    done <<< "$import_specs"
  fi

  [ -n "$CAP_ID" ] || return 0
  if [ "$CAPS_ALLOW" != "null" ] && printf '%s' "$CAPS_ALLOW" | "$JQ" -e --arg c "$CAP_ID" 'index($c) != null' >/dev/null 2>&1; then
    return 0
  fi
  kernel_mandate_deny "write-code-capability:${CAP_ID} $rel" "[BLOCKED] Role '${ROLE}' may not author code using ${CAP_WHAT}.

${ROLE_HEADER}
File: $rel${via}

Why this is gated: code you write is code something will RUN — your own test command, CI, or another role. At that moment the code holds ITS permissions, not yours, so an unrestricted \`${CAP_ID}\` capability inside a file you author silently voids every read/write scope on this role. Path scopes only bind if the code inside the path stays inside them.

Options, narrowest first:
  1. Use the framework's own API instead of reaching for the host — a
     test should drive the app through its fixtures, not the filesystem.
  2. If this file genuinely needs it, the operator can grant exactly
     that capability to this role:
       \"write\": { \"codeCapabilities\": [\"${CAP_ID}\"] }
     Other capabilities stay denied, and every path scope still applies.

Preview before committing: kernel-mandate explain --role ${ROLE} --tool Write --path <file>"
}

# --- Axis 3: bash command gate ------------------------------------------
# Bash is the widest laundering channel a role has, so this axis carries
# most of the leak-proofing: quote-blind segmentation over EVERY command
# separator, a built-in deny list for indirection constructs no allow
# pattern can safely coexist with, write-target checks on redirections,
# and a read-scope check over every token that resolves to a real file.
# Everywhere the axis guesses, it guesses toward deny-with-guidance.

# screen_env_assignments <segment>
# Refuses a leading NAME=value whose NAME is not provably inert. The
# assignment strip removes text before every axis runs, and names like
# PATH, NODE_OPTIONS or LD_PRELOAD decide which program or module runs.
# Dangerous names cannot be enumerated (PATH is one), so only names on the
# inert list or the role's `bash.env` pass. Called from both strips.
screen_env_assignments() {
  local sa_seg="$1" sa_list sa_a sa_name sa_why
  sa_list=$(printf '%s' "$sa_seg" | sed -E 's/^[[:space:]({]+//' \
    | kernel_mandate_grep_or_empty -oE '^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]<>|&]*[[:space:]]+)+' 2>/dev/null) \
    || deny_unscreened "bash-env-screen" "this command's leading assignments" "Segment: ${sa_seg}"
  [ -n "$sa_list" ] || return 0
  for sa_a in $sa_list; do
    sa_name="${sa_a%%=*}"
    # Provably inert: data an application reads. None changes which program
    # runs, which module loads, which host is dialled, or how the shell behaves.
    case "$sa_name" in
      CI|NODE_ENV|APP_ENV|RAILS_ENV|ENVIRONMENT|STAGE|\
      TZ|LANG|LANGUAGE|LC_ALL|LC_CTYPE|LC_NUMERIC|LC_TIME|LC_COLLATE|LC_MONETARY|LC_MESSAGES|\
      TERM|COLUMNS|LINES|FORCE_COLOR|NO_COLOR|CLICOLOR|CLICOLOR_FORCE|\
      DEBUG|LOG_LEVEL|LOGLEVEL|VERBOSE|QUIET|SILENT|\
      HEADLESS|HEADED|SLOWMO|WORKERS|RETRIES|SHARD|TEST_ENV|TEST_TIMEOUT|\
      JEST_WORKER_ID|VITEST_POOL_ID|PWTEST_SKIP_TEST_OUTPUT)
        continue ;;
    esac
    # ...or the operator named it for this role.
    if [ "$BASH_ENV_ALLOW" != "null" ] \
       && printf '%s' "$BASH_ENV_ALLOW" | "$JQ" -e --arg n "$sa_name" 'index($n) != null' >/dev/null 2>&1; then
      continue
    fi
    # ...or the role opted into environment injection wholesale.
    if [ "$BASH_PERMIT" != "null" ] \
       && printf '%s' "$BASH_PERMIT" | "$JQ" -e 'index("env-injection") != null' >/dev/null 2>&1; then
      continue
    fi
    case "$sa_name" in
      PATH) sa_why="'PATH' decides which FILE a command word runs. Setting it in front of a permitted command means the kernel checks the name \`grep\` while the shell executes something else entirely — every axis in this manifest is written against argv, and this rebinds what argv means." ;;
      NODE_OPTIONS|PERL5OPT|RUBYOPT|PYTHONSTARTUP|BASH_ENV|ENV|LD_PRELOAD|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS)
        sa_why="'$sa_name' is read as OPTIONS by the runtime it starts, so it loads code the kernel's checks never see — \`NODE_OPTIONS=--require=<file>\` turns any permitted node command into a loader for that file, and it cancels the runtime profile \`kernel-mandate run\` exists to install." ;;
      *_PROXY|*_proxy|CURL_HOME|npm_config_*)
        sa_why="'$sa_name' redirects where a client connects, which is the network scope's job and not this variable's." ;;
      GIT_*) sa_why="'$sa_name' changes what git does — the config it reads, the pager or diff tool it spawns, the transport it uses — none of which is visible in the command." ;;
      *) sa_why="The kernel cannot show that '$sa_name' is data rather than configuration for the program, the loader, the shell or the network, so it is refused rather than deleted." ;;
    esac
    set +f
    kernel_mandate_deny "bash-env-assignment $sa_name" "[BLOCKED] Role '${ROLE}' set '$sa_name' in front of a command, and the kernel cannot treat that as data.

${ROLE_HEADER}

Command: ${CMD}

$sa_why

A leading NAME=value is normally data for the command, and the kernel strips it before every other check — which is why the name has to be one it can show is inert. That list used to name the DANGEROUS variables and let everything else through; \`PATH\` is not an exotic name, and it was not on it.

Options, narrowest first:
  1. Run the command without the assignment.
  2. If this role genuinely needs the variable, the operator can name it:
       \"bash\": { \"env\": [\"$sa_name\"] }
     Every other name stays refused.
  3. bash.permit: [\"env-injection\"] waives the screen entirely — for a
     deliberately trusted role, never to silence a single deny."
  done
}

if [ "$KM_TOOL" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null || echo "")
  BASH_SPEC=$(kernel_mandate_role_field "$ROLE" '.bash')
  BASH_UNRESTRICTED=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '.roles[$r].bash.unrestricted // false' 2>/dev/null || echo "false")
  # Named indirection constructs this role may use despite the built-in
  # denies (see axis 3a). Granular by design: permitting one construct
  # never waives the others.
  BASH_PERMIT=$(kernel_mandate_role_field "$ROLE" '.bash.permit')
  # Environment variable names this role may set in front of a command.
  # The screen above refuses everything it cannot show to be inert, so
  # this is how an operator says "this one, deliberately".
  BASH_ENV_ALLOW=$(kernel_mandate_role_field "$ROLE" '.bash.env')

  WRITE_ALLOW=$(kernel_mandate_role_field "$ROLE" '.write.allow')
  WRITE_DENY=$(kernel_mandate_role_field "$ROLE" '.write.deny')
  READ_ALLOW=$(kernel_mandate_role_field "$ROLE" '.read.allow')
  READ_DENY=$(kernel_mandate_role_field "$ROLE" '.read.deny')
  HAS_WRITE_GRANTS=0
  if [ "$WRITE_ALLOW" != "null" ] && [ "$(printf '%s' "$WRITE_ALLOW" | "$JQ" -r 'length' 2>/dev/null || echo 0)" != "0" ]; then
    HAS_WRITE_GRANTS=1
  fi

  ALLOW_PATTERNS=""
  DENY_PATTERNS=""
  if [ "$BASH_SPEC" != "null" ]; then
    # Effective allow set = expansion of named commandGroups + inline allow.
    ALLOW_PATTERNS=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '
      [ ((.roles[$r].bash.groups // [])[] as $g | (.commandGroups[$g] // [])[]),
        ((.roles[$r].bash.allow // [])[]) ] | .[]' 2>/dev/null || echo "")
    DENY_PATTERNS=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '(.roles[$r].bash.deny // [])[]' 2>/dev/null || echo "")

    if [ -z "$ALLOW_PATTERNS" ] && [ "$BASH_UNRESTRICTED" != "true" ]; then
      kernel_mandate_deny "bash-no-allow" "[BLOCKED] Role '${ROLE}' declares a bash section but its command groups expand to zero allow patterns (a named group may be missing from commandGroups).

${ROLE_HEADER}

Fix the manifest in an operator design session — until then this role can run no Bash commands."
    fi
  fi

  # Mask fd-plumbing (2>&1, >/dev/null, …) BEFORE segmentation so a
  # lone '&' separator can be split on without shredding '2>&1', and so
  # redirect analysis below only ever sees real file targets.
  if ! CLEAN=$(printf '%s' "$CMD" | sed -E 's/[0-9]*>&[0-9-]+//g; s/[0-9&]*>>?[[:space:]]*\/dev\/(null|stderr|stdout|tty)//g'); then
    deny_unscreened "bash-clean-screen" "this command" "Command: ${CMD}"
  fi

  # Split on every command separator — newline, && || ; | and a single '&'.
  # Then strip leading env-var assignments and grouping punctuation and
  # require EVERY non-empty segment to clear every check below.
  # Quote-aware: a separator inside quotes is not one to the shell either.
  # Placeholders carry quoted separators through and are restored after.
  # An unterminated quote is refused (bash refuses it too).
  if ! printf '%s' "$CMD" | kernel_mandate_quotes_balanced; then
    kernel_mandate_deny "bash-unbalanced-quotes" "[BLOCKED] Role '${ROLE}' sent a command with an unterminated quote, which cannot be checked.

${ROLE_HEADER}

Command: ${CMD}

Everything after an unclosed quote reads as string rather than syntax, so the kernel cannot tell which parts are commands and which are text. A shell would refuse this command too. Close the quote and send it again."
  fi

  if ! SEGMENTS=$(printf '%s' "$CLEAN" | kernel_mandate_unquoted_view split \
    | awk '{ gsub(/&&|\|\||[;|&]/, "\n"); print }'); then
    deny_unscreened "bash-segment-screen" "this command's segments" "Command: ${CMD}"
  fi
  # A command with words in it yields at least one segment. None means a
  # stage above returned nothing while exiting 0, and nothing is checked.
  # Pure shell patterns, so this check has no tool of its own to fail.
  case "$CMD" in
    *[!\;\&\|[:space:]]*)
      case "$SEGMENTS" in
        *[![:space:]]*) ;;
        *) deny_unscreened "bash-segment-empty" "this command's segments" "Command: ${CMD}" ;;
      esac ;;
  esac
  while IFS= read -r seg; do
    # Keep the untouched segment: the normalisation below strips trailing
    # grouping punctuation, which would remove the `}` of `cat {.env,x}`.
    # Checks that the strip could fool consult SEG_RAW instead.
    # Restore the separators that were placeheld through the split, so
    # every check below sees the segment exactly as the shell will.
    seg=$(printf '%s' "$seg" | kernel_mandate_unsplit)
    SEG_RAW="$seg"
    # Screen the leading assignments before dropping them (screen_env_assignments).
    # Option-string variables (`NODE_OPTIONS=--require=./.env`) are refused, not
    # scope-checked: their value is an option string, not a path.
    screen_env_assignments "$seg"
    seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]({]+//; s/[[:space:])}]+$//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]<>|&]*[[:space:]]+)*//')
    [ -n "$seg" ] || continue

    # Quote-aware views of the segment. Quoting does not change which word
    # is the command — `"cat" x` still runs cat — so the command-name and
    # allow-set checks keep reading the segment verbatim. It DOES decide
    # whether a construct is syntax or text, and the expansion checks below
    # would otherwise fire on `echo '{"a":1,"b":2}'` and stay silent on
    # nothing at all. SEG_NOQ blanks every quoted run (what the shell still
    # globs / brace-expands); SEG_NOSQ blanks only single-quoted runs,
    # because $… and `…` keep expanding inside double quotes.
    SEG_NOQ=$(printf '%s\n' "$SEG_RAW" | kernel_mandate_unquoted_view both)
    SEG_NOSQ=$(printf '%s\n' "$seg" | kernel_mandate_unquoted_view single)
    # Redirection is read from the UN-STRIPPED segment, quote-masked:
    #   * un-stripped, because the assignment and wrapper strips would eat
    #     the redirect in `env X=1<.env cat`;
    #   * quote-masked, because `grep '=>' spec.ts` is not a redirection.
    SEG_REDIR=$(printf '%s\n' "$SEG_RAW" | kernel_mandate_unquoted_view redir)

    # Strip leading wrapper prefixes (`env`, `timeout 5`, `sudo`, `nohup`,
    # `nice`) so the checks below see the real command; each iteration removes
    # one wrapper word and its options / numeric / KEY=VAL args.
    WRAP_RE='^(env|sudo|doas|nohup|setsid|nice|ionice|chrt|stdbuf|time|timeout|command|builtin|exec|then|else|do|watch|unbuffer)([[:space:]]|$)'
    STRIP_GUARD=0
    while printf '%s' "$seg" | grep -Eq "$WRAP_RE"; do
      STRIP_GUARD=$((STRIP_GUARD + 1)); [ "$STRIP_GUARD" -gt 20 ] && break
      # Drop the wrapper word, then any following options / numeric
      # durations / KEY=VAL assignments that belong to it.
      seg=$(printf '%s' "$seg" | sed -E 's/^[a-z]+[[:space:]]+//')
      # Every alternative stops at a redirection character: the read-token scan
      # runs on $seg, so this must not swallow syntax.
      # The wrapper loop strips assignments too (`env NODE_OPTIONS=… cmd`), so it
      # screens them. Flags first, then screen, then strip: one pass would stop at `-i`.
      seg=$(printf '%s' "$seg" | sed -E 's/^((-[^[:space:]<>|&]+|[0-9]+[smhd]?)[[:space:]]+)*//')
      screen_env_assignments "$seg"
      seg=$(printf '%s' "$seg" | sed -E 's/^((-[^[:space:]<>|&]+|[0-9]+[smhd]?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]<>|&]*)[[:space:]]+)*//')
      [ -n "$seg" ] || break
    done
    [ -n "$seg" ] || continue

    # Quote-stripped word list for the segment — what the shell will treat
    # as the command word and its operands.
    SEG_WORDS=()
    while IFS= read -r __w; do
      [ -n "$__w" ] || continue
      SEG_WORDS+=("${__w#?}")
    done < <(printf '%s\n' "$seg" | kernel_mandate_shell_words)

    # 3a-bis. Version-control history is a second copy of the working tree:
    # `git show HEAD:.env` names no existing path. Content-bearing git
    # subcommands are held to the read scope:
    #   * a `<rev>:<path>` operand is scope-checked on its <path>;
    #   * pathspecs after `--` are scope-checked;
    #   * a command with no path constraint at all reads whatever the
    #     history holds, which cannot be scope-checked, so it is denied as
    #     the construct 'vcs-history' (permit it per role if a role's job
    #     really is reading history wholesale).
    # Metadata-only forms (`git log` without a patch flag, `--stat`,
    # `--name-only`, `git status`, `git rev-parse`…) print no file content
    # and stay allowed.
    # `kernel-mandate run --role X` installs role X's runtime profile; the
    # only profile a role may install is its own, however loose the pattern.
    if [ "${SEG_WORDS[0]:-}" = "kernel-mandate" ] \
       || { [ "${SEG_WORDS[0]:-}" = "npx" ] && [ "${SEG_WORDS[1]:-}" = "kernel-mandate" ]; }; then
      KM_SUB=""; KM_RUN_ROLE=""; __want_role=0
      for __w in "${SEG_WORDS[@]}"; do
        if [ "$__want_role" = "1" ]; then KM_RUN_ROLE="$__w"; __want_role=0; continue; fi
        case "$__w" in
          --role) __want_role=1 ;;
          --role=*) KM_RUN_ROLE="${__w#*=}" ;;
          run) [ -n "$KM_SUB" ] || KM_SUB=run ;;
        esac
      done
      if [ "$KM_SUB" = "run" ] && [ -n "$KM_RUN_ROLE" ] && [ "$KM_RUN_ROLE" != "$ROLE" ]; then
        kernel_mandate_deny "run-role-mismatch $KM_RUN_ROLE" "[BLOCKED] Role '${ROLE}' may not run a command under role '${KM_RUN_ROLE}'s runtime profile.

${ROLE_HEADER}

Command: ${CMD}

'kernel-mandate run --role X' installs X's path scopes as the process's permission profile. Invoking it with another role's name borrows that role's scopes — which would make the runtime profile a way around the boundary rather than part of it. A role may only install its own:

  kernel-mandate run --role ${ROLE} -- <command>"
      fi
    fi

    GIT_CONTENT=0
    # Package-manager re-anchoring flags (npm --prefix, -C, --userconfig) move
    # where package.json is read and which shell runs scripts, so a role could
    # run an authored `"test"` script from any directory. Refused outright.
    if [ "$BASH_UNRESTRICTED" != "true" ]; then
      case "${SEG_WORDS[0]##*/}" in
        npm|npx|pnpm|yarn|bun|bunx)
          for __w in "${SEG_WORDS[@]:1}"; do
            case "$__w" in
              --prefix|--prefix=*|-C|--userconfig|--userconfig=*|--globalconfig|--globalconfig=*|\
              --script-shell|--script-shell=*|-w|--workspace|--workspace=*|--cwd|--cwd=*|\
              --dir|--dir=*|--modules-folder|--modules-folder=*|--cache|--cache=*)
                kernel_mandate_deny "bash-reanchor ${SEG_WORDS[0]##*/} $__w" "[BLOCKED] Role '${ROLE}' passed '${__w}' to ${SEG_WORDS[0]##*/} — that re-anchors where the package manager reads its manifest and which shell runs its scripts, so every scope this role's command was granted against no longer applies.

${ROLE_HEADER}

Command: ${CMD}

A package manager's --prefix / -C / --userconfig / --script-shell / --workspace move the project it acts on, exactly as git -C does. Authoring a package.json inside your own write scope and then running npm against it is running arbitrary code that no command group checked. Run the project's own scripts from the project root, or hand the task to a role that holds bash.unrestricted." ;;
            esac
          done ;;
      esac
    fi

    GIT_ANCHOR=""
    if [ "${SEG_WORDS[0]:-}" = "git" ]; then
      # Find the subcommand. Global options come first, and some of them
      # TAKE A VALUE — `git -c core.pager=cat show …` would otherwise be
      # read as the subcommand 'core.pager=cat' and sail past this axis.
      GIT_SUB=""
      GIT_SKIP_NEXT=0
      for __i in "${!SEG_WORDS[@]}"; do
        [ "$__i" = "0" ] && continue
        __w="${SEG_WORDS[$__i]}"
        if [ "$GIT_SKIP_NEXT" = "1" ]; then
          GIT_SKIP_NEXT=0
          [ -n "$GIT_ANCHOR" ] || { case "${SEG_WORDS[$((__i - 1))]}" in -C) GIT_ANCHOR="$__w" ;; esac; }
          continue
        fi
        case "$__w" in
          -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)
            GIT_SKIP_NEXT=1; continue ;;
          --git-dir=*) GIT_ANCHOR="${__w#*=}"; continue ;;
          --work-tree=*) GIT_ANCHOR="${__w#*=}"; continue ;;
          -*) continue ;;                    # valueless global option
          *) GIT_SUB="$__w"; break ;;
        esac
      done
      # -C/--git-dir/--work-tree re-anchor the repository the same way `cd`
      # re-anchors relative paths: every scope check below assumes the
      # project this call runs in. A no-op anchor is fine; anything else is
      # denied for the same reason a real `cd` is.
      if [ -n "$GIT_ANCHOR" ] && [ "$BASH_UNRESTRICTED" != "true" ]; then
        GIT_ANCHOR_N=$(kernel_mandate_normalize_path "$GIT_ANCHOR")
        if [ "$GIT_ANCHOR_N" != "$(kernel_mandate_normalize_path "$KM_CWD")" ] \
           && [ "$GIT_ANCHOR_N" != "$(kernel_mandate_normalize_path "$KM_CWD/.git")" ] \
           && ! { [ "$BASH_PERMIT" != "null" ] && printf '%s' "$BASH_PERMIT" | "$JQ" -e 'index("cd") != null' >/dev/null 2>&1; }; then
          kernel_mandate_deny "bash-builtin-deny:cd" "[BLOCKED] Role '${ROLE}' pointed git at a different repository ('$GIT_ANCHOR') — that re-anchors every path this role's scopes are expressed against.

${ROLE_HEADER}

Command: ${CMD}

A role's read and write scopes are relative to the project it is governed in. Run git against that project (drop -C/--git-dir/--work-tree, or point them at the current directory)."
        fi
      fi
      GIT_PATCHY=0
      case " ${SEG_WORDS[*]} " in *' -p '*|*' -u '*|*' --patch '*|*' --patch-with-stat '*) GIT_PATCHY=1 ;; esac
      GIT_NAMESONLY=0
      case " ${SEG_WORDS[*]} " in
        *' --stat '*|*' --name-only '*|*' --name-status '*|*' --numstat '*|*' --shortstat '*|*' -s '*|*' --quiet '*|*' --summary '*) GIT_NAMESONLY=1 ;;
      esac
      case "$GIT_SUB" in
        show|diff|cat-file|archive|grep|blame|format-patch|diff-tree|diff-index)
          GIT_CONTENT=1 ;;
        log|stash|whatchanged)
          [ "$GIT_PATCHY" = "1" ] && GIT_CONTENT=1 ;;
      esac
      # An explicit names-only/stat request prints no file bodies.
      [ "$GIT_NAMESONLY" = "1" ] && [ "$GIT_PATCHY" = "0" ] && GIT_CONTENT=0
    fi
    if [ "$GIT_CONTENT" = "1" ] && [ "$READ_ALLOW" != "null" ]; then
      GIT_CONSTRAINED=0
      GIT_DDASH=0
      for __w in "${SEG_WORDS[@]:1}"; do
        if [ "$__w" = "--" ]; then GIT_DDASH=1; continue; fi
        GIT_PATHS=()
        if [ "$GIT_DDASH" = "1" ]; then
          GIT_PATHS+=("$__w")
        else
          case "$__w" in
            -*) continue ;;
            *://*) continue ;;
            *:*) GIT_PATHS+=("${__w#*:}") ;;   # <rev>:<path> and :<path>
            *)   # a bare operand that IS an existing path is a pathspec;
                 # the read-token scan below scope-checks it for us.
                 if [ -e "$KM_CWD/$__w" ] || { case "$__w" in /*) [ -e "$__w" ] ;; *) false ;; esac; }; then
                   GIT_CONSTRAINED=1
                 fi
                 continue ;;
          esac
        fi
        for __p in "${GIT_PATHS[@]}"; do
          [ -n "$__p" ] || continue
          GIT_CONSTRAINED=1
          kernel_mandate_is_manifest_path "$__p" && continue
          GIT_REL=$(kernel_mandate_relpath "$__p")
          if [ "$READ_DENY" != "null" ] && kernel_mandate_path_denied "$GIT_REL" "$__p" "$READ_DENY"; then :
          elif kernel_mandate_path_in_scope "$GIT_REL" "$READ_ALLOW"; then continue
          elif [ "$HAS_WRITE_GRANTS" = "1" ] && kernel_mandate_path_in_scope "$GIT_REL" "$WRITE_ALLOW"; then continue
          fi
          kernel_mandate_deny "bash-read-out-of-scope $GIT_REL" "[BLOCKED] Role '${ROLE}' may not read '$GIT_REL' out of git history — it is outside the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Git history holds a second copy of the working tree, so 'git show <rev>:<path>' is a read of <path> and is scope-checked identically. The scope is the role's context diet, whichever channel does the reading."
        done
      done
      if [ "$GIT_CONSTRAINED" = "0" ] && [ "$BASH_UNRESTRICTED" != "true" ] \
         && ! { [ "$BASH_PERMIT" != "null" ] && printf '%s' "$BASH_PERMIT" | "$JQ" -e 'index("vcs-history") != null' >/dev/null 2>&1; }; then
        kernel_mandate_deny "bash-builtin-deny:vcs-history" "[BLOCKED] Role '${ROLE}' may not run '${GIT_SUB}' without naming the paths it reads — it would print file contents from git history that no path scope can check.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

NOTE: your command group DOES grant 'git ${GIT_SUB}'. This refusal is a construct deny that overrides it, not a missing grant — so adding another command pattern will not help. Git history is a second copy of the working tree, so an unconstrained 'git ${GIT_SUB}' reads whatever the history holds — including files this role's read scope excludes. Options, narrowest first:
  1. Name the paths: git ${GIT_SUB} … -- <path within the read scope>
     (or 'git show <rev>:<path>'), which is scope-checked like any read.
  2. Ask for names, not contents: --stat / --name-only / --name-status.
  3. If reading history wholesale really is this role's job, the operator
     can permit exactly that construct:
       \"bash\": { \"permit\": [\"vcs-history\"] }
     Every other construct, and every other axis, still applies."
      fi
    fi

    # 3a. Built-in indirection denies. Each of these constructs lets a
    # segment that MATCHES an allow pattern execute something that was
    # never checked ($(…) and $VAR indirection, `| sh`, find -exec,
    # xargs, interpreter one-liners, cd un-anchoring every relative
    # path, brace expansion concealing a filename), so they are denied
    # by default. A role may permit specific construct IDs via bash.permit:
    # a granular hatch avoids the blanket waiver an all-or-nothing one invites.
    CD_NOOP=0
    if [ "$BASH_UNRESTRICTED" != "true" ]; then
      BUILTIN_HIT=""
      BUILTIN_ID=""
      if printf '%s' "$SEG_NOSQ" | grep -q '\$'; then BUILTIN_ID='var-expansion'; BUILTIN_HIT='variable/command substitution ($…) — expansion executes or reads things no pattern checked'
      elif printf '%s' "$SEG_NOSQ" | grep -q '`'; then BUILTIN_ID='command-substitution'; BUILTIN_HIT='backtick command substitution'
      elif printf '%s' "$SEG_NOQ" | grep -Eq '<\(|>\('; then BUILTIN_ID='process-substitution'; BUILTIN_HIT='process substitution <(…)/>(…)'
      elif printf '%s' "$seg" | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)'; then BUILTIN_ID='eval'; BUILTIN_HIT='eval'
      elif printf '%s' "$seg" | grep -Eq '(^|[[:space:]])xargs([[:space:]]|$)'; then BUILTIN_ID='xargs'; BUILTIN_HIT='xargs — arguments become an unchecked command'
      elif printf '%s' "$seg" | grep -Eq '^(source[[:space:]]|\.[[:space:]])'; then BUILTIN_ID='source'; BUILTIN_HIT='sourcing a script into the shell'
      elif printf '%s' "$seg" | grep -Eq '^(ba|z|da|k|fi)?sh([[:space:]]|$)'; then BUILTIN_ID='shell'; BUILTIN_HIT='a shell as the command — its input becomes an unchecked script'
      # find's actions that run or delete: `-exec -execdir -ok -okdir -delete`.
      # Complete against GNU find's manual (`-ok`/`-okdir` are `-exec` with a
      # prompt); the `-fprint*`/`-fls` writers are held to the write scope below.
      elif printf '%s' "$seg" | grep -Eq -- '-(exec|execdir|ok|okdir)([[:space:]]|$)|-delete([[:space:]]|$)'; then BUILTIN_ID='find-exec'; BUILTIN_HIT='find -exec/-execdir/-ok/-okdir/-delete — executes or deletes outside the pattern check (-ok and -okdir are -exec and -execdir with a confirmation prompt, which a piped y answers)'
      # `rg --pre <prog>` runs <prog> on every file it searches; `--pre-glob`
      # only narrows which files, so it is the same channel.
      elif printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])--pre(-glob)?([[:space:]]|=)'; then BUILTIN_ID='search-preprocessor'; BUILTIN_HIT='rg --pre/--pre-glob — a preprocessor program run on every matched file, outside every pattern check'
      elif [ "$(kernel_mandate_interpreter_inline "${SEG_WORDS[0]:-}" "$seg")" = "module" ]; then BUILTIN_ID='interpreter-module'; BUILTIN_HIT='running or preloading a module (-m/-M/-r) — code this kernel never sees, though the role did not author it'
      elif [ "$(kernel_mandate_interpreter_inline "${SEG_WORDS[0]:-}" "$seg")" = "indirect" ]; then BUILTIN_ID='interpreter-inline'; BUILTIN_HIT='interpreter one-liner (-c/-e/-p and their attached and bundled spellings, or a program on stdin) — arbitrary code the patterns cannot see'
      elif [ "$(kernel_mandate_awk_sed_verdict "${SEG_WORDS[0]:-}" "$seg")" = "indirect" ]; then
        # awk and sed are interpreters: their programs can run commands or open
        # files, and an operand can be any expression, so a program must be proved
        # inert or it is refused. IDs are per language (gawk/mawk share `awk-program`).
        case "${SEG_WORDS[0]:-}" in
          sed) BUILTIN_ID='sed-program' ;;
          *)   BUILTIN_ID='awk-program' ;;
        esac
        BUILTIN_HIT="an ${SEG_WORDS[0]:-awk} program using a construct that can run a command or open a file — its operand is an arbitrary expression, so no scan can say which"
      elif printf '%s' "$seg" | grep -Eq '^(cd|pushd|popd)([[:space:]]|$)'; then
        # A `cd` to the directory the call already runs in changes nothing, so it
        # is allowed; a cd anywhere else re-anchors relative paths and stays denied.
        # The target comes only from a bare `cd <dir>` segment (optionally redirected).
        CD_TARGET=$(printf '%s' "$seg" | sed -E 's/^(cd|pushd|popd)[[:space:]]+//; s/[[:space:]].*$//' | tr -d '"'"'")
        if [ -n "$CD_TARGET" ] && [ "$(kernel_mandate_normalize_path "$CD_TARGET")" = "$(kernel_mandate_normalize_path "$KM_CWD")" ]; then
          # A no-op cd needs no allow pattern, but only the construct and allow-set
          # checks are waived: `cd . > secrets` still faces the redirect and
          # read-token analysis.
          CD_NOOP=1
          BUILTIN_ID=''; BUILTIN_HIT=''
        else
          BUILTIN_ID='cd'; BUILTIN_HIT='cd/pushd/popd to a different directory — it re-anchors every relative path this axis checks (a cd to the directory you are already in is allowed)'
        fi
      elif printf '%s' "$SEG_NOQ" | grep -Eq '\{[^{}[:space:]]*,[^{}[:space:]]*\}?|\{[^{}[:space:]]*\.\.[^{}[:space:]]*\}?'; then BUILTIN_ID='brace-expansion'; BUILTIN_HIT='brace expansion {a,b} or {a..z} — the shell expands it into filenames no check ever sees'
      # Install and build verbs (`npm install`, `pip install`, `make`, `gradle`)
      # run a dependency's lifecycle scripts, which no path scope sees. A command
      # group regex cannot express that, so they are a construct to permit explicitly.
      elif printf '%s' "$SEG_NOQ" | grep -Eq '^[[:space:]]*(npm|pnpm|yarn|bun)[[:space:]]+(i|in|install|ci|add|update|upgrade|link|rebuild|exec[[:space:]]+--package)\b'; then
        BUILTIN_ID='dependency-install'; BUILTIN_HIT='a package-manager install verb — it executes the lifecycle scripts of whatever it installs, which is arbitrary code no path scope and no authored-code screen ever sees'
      elif printf '%s' "$SEG_NOQ" | grep -Eq '^[[:space:]]*(pip|pip3|python[0-9.]*[[:space:]]+-m[[:space:]]+pip|gem|cargo|go|composer|bundle|apt|apt-get|apk|brew|dnf|yum|nix-env)[[:space:]]+(install|add|require|get)\b'; then
        BUILTIN_ID='dependency-install'; BUILTIN_HIT='a package-manager install verb — it executes setup code from whatever it installs, which is arbitrary code no path scope and no authored-code screen ever sees'
      elif printf '%s' "$SEG_NOQ" | grep -Eq '^[[:space:]]*(make|gmake|gradle|gradlew|\./gradlew|mvn|ant|rake|just|task|cmake)\b'; then
        BUILTIN_ID='build-recipe'; BUILTIN_HIT='a build-recipe runner — it executes commands from a Makefile or build script, so what it runs is decided by a file rather than by this command'
      fi
      # A permitted construct is skipped — the segment still faces the
      # allow-set, deny patterns, redirect scope and read-token checks.
      if [ -n "$BUILTIN_ID" ] && [ "$BASH_PERMIT" != "null" ] \
         && printf '%s' "$BASH_PERMIT" | "$JQ" -e --arg c "$BUILTIN_ID" 'index($c) != null' >/dev/null 2>&1; then
        BUILTIN_HIT=""
      fi
      if [ -n "$BUILTIN_HIT" ]; then
        kernel_mandate_deny "bash-builtin-deny:${BUILTIN_ID}" "[BLOCKED] Role '${ROLE}' may not run this command — the segment '$seg' uses ${BUILTIN_HIT}.

${ROLE_HEADER}

Command: ${CMD}

These constructs are denied by default because they let a command that matches an allow pattern do something the pattern never checked. Options, narrowest first:
  1. Express the operation directly — one plain command per step, granted tools for file writes.
  2. If this role legitimately needs this construct, the operator can permit exactly it:
       \"bash\": { \"permit\": [\"${BUILTIN_ID}\"] }
     Every other construct stays denied, and the allow-set, redirect-scope
     and read-scope checks still apply to this role.
  3. bash.unrestricted: true waives all of them — for a deliberately
     trusted role only, never to silence a single deny.

Preview the effect before you commit to it: kernel-mandate explain --role ${ROLE} --tool Bash --command '<the command>'"
      fi
    fi

    # 3b. Explicit deny patterns beat the allow check — a deliberately
    # denied shape deserves the specific message even when it also
    # fails the allow set.
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      if printf '%s' "$seg" | grep -Eq "$pat"; then
        kernel_mandate_deny "bash-segment-denied" "[BLOCKED] Role '${ROLE}' is explicitly denied this command shape (segment '$seg' matches deny pattern '$pat').

${ROLE_HEADER}

Command: ${CMD}"
      fi
    done <<< "$DENY_PATTERNS"

    # 3c. Allow set: every segment must be inside the role's command
    # groups (skipped when the role has no bash section at all, and for a
    # no-op cd, which executes nothing for a pattern to authorize — its
    # redirects and file tokens are still checked below).
    if [ "$BASH_SPEC" != "null" ] && [ "$BASH_UNRESTRICTED" != "true" ] && [ "$CD_NOOP" != "1" ]; then
      SEG_OK=0
      while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        if printf '%s' "$seg" | grep -Eq "$pat"; then SEG_OK=1; break; fi
      done <<< "$ALLOW_PATTERNS"
      if [ "$SEG_OK" != "1" ]; then
        kernel_mandate_deny "bash-segment-not-allowed" "[BLOCKED] Role '${ROLE}' may not run this command — the segment '$seg' matches none of the role's permitted command patterns.

${ROLE_HEADER}

Command: ${CMD}

Note: compound commands are checked segment-by-segment (&&, ||, ;, |, &, newlines) and every segment must be within the role's command groups. If this operation is part of your mandate, ask the operator to extend the role's commandGroups in the manifest; otherwise hand it back to the orchestrator."
      fi
    fi

    # 3c-bis. Input redirection is a read: `cat <.env` names no argument.
    # Every single `<` target is scoped against read.allow; `<<`/`<<<` take
    # inline text, not a path.
    if [ "$READ_ALLOW" != "null" ]; then
      IN_TARGETS=$(printf '%s' "$SEG_REDIR" | kernel_mandate_grep_or_empty -oE '(^|[^<])<[[:space:]]*[^[:space:]<>;&|]+' 2>/dev/null \
        | sed -E 's/^[^<]?<[[:space:]]*//') \
        || deny_unscreened "bash-read-target-screen" "this command's input redirections" "Command: ${CMD}"
      while IFS= read -r intarget; do
        [ -n "$intarget" ] || continue
        intarget=$(printf '%s' "$intarget" | tr -d '"'"'" | tr -d '\001')
        [ -n "$intarget" ] || continue
        case "$intarget" in *://*) continue ;; esac
        kernel_mandate_is_manifest_path "$intarget" && continue
        REL_IN=$(kernel_mandate_relpath "$intarget")
        if { [ "$READ_DENY" != "null" ] && kernel_mandate_path_denied "$REL_IN" "$intarget" "$READ_DENY"; } \
           || { ! kernel_mandate_path_in_scope "$REL_IN" "$READ_ALLOW" \
                && { [ "$HAS_WRITE_GRANTS" != "1" ] || ! kernel_mandate_path_in_scope "$REL_IN" "$WRITE_ALLOW"; }; }; then
          kernel_mandate_deny "bash-input-redirect-out-of-scope $REL_IN" "[BLOCKED] Role '${ROLE}' may not read '$REL_IN' — this command redirects it onto a command's standard input, and input redirection is held to the same read scope as naming the file.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}"
        fi
      done <<< "$IN_TARGETS"
    fi

    # 3d. Redirect / tee write targets. A '>' that survived the
    # fd-noise mask is a real file write: a role with no write grants
    # may not perform it at all, and a role WITH write grants may only
    # aim it inside its write scope — bash must not launder writes past
    # the Write/Edit axis for anyone.
    REDIR_TARGETS=$(printf '%s' "$SEG_REDIR" | kernel_mandate_grep_or_empty -oE '>>?[[:space:]]*[^[:space:]<>;&]+' 2>/dev/null | sed -E 's/^>>?[[:space:]]*//') \
      || deny_unscreened_targets
    if [ "${SEG_WORDS[0]:-}" = "tee" ]; then
      TEE_TARGETS=$(printf '%s\n' "${SEG_WORDS[@]:1}" | kernel_mandate_grep_or_empty -vE '^-') || deny_unscreened_targets
      REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$TEE_TARGETS")
    fi
    # Mutate verbs write too (`cp`, `mv`, `dd of=`, `install`, `sed -i`,
    # `truncate`, `ln -s`); their destination operand is held to the write scope.
    # Output-flag operands (`-o/--output/-fprint*/-fls/--out`) are matched
    # generically so a new tool with the same convention is covered.
    # `-o`/`-O` mean "or" to find and "only-matching" to grep, so they count
    # only for commands that spell output that way.
    FLAG_TARGETS=""
    __fw=0
    for __i in "${!SEG_WORDS[@]}"; do
      [ "$__i" = "0" ] && continue
      __w="${SEG_WORDS[$__i]}"
      if [ "$__fw" = "1" ]; then FLAG_TARGETS="${FLAG_TARGETS}${__w}"$'\n'; __fw=0; continue; fi
      case "$__w" in
        --output=*|--out=*|--output-file=*|-of=*) FLAG_TARGETS="${FLAG_TARGETS}${__w#*=}"$'\n' ;;
        --output|--out|--output-file|-of|-fprintf|-fprint|-fprint0|-fls) __fw=1 ;;
        # curl writes files through more flags than `-o` (`-D`, `--trace`, …).
        # These spellings are unambiguous across tools, so need no command list.
        --dump-header=*|--trace=*|--trace-ascii=*|--cookie-jar=*|--etag-save=*|--stderr=*|--output-dir=*|--append-output=*)
          FLAG_TARGETS="${FLAG_TARGETS}${__w#*=}"$'\n' ;;
        --dump-header|--trace|--trace-ascii|--cookie-jar|--etag-save|--stderr|--output-dir|--append-output)
          __fw=1 ;;
        -D|-c)
          # Ambiguous elsewhere (`-c` counts for grep, `-D` defines for
          # the compilers), so these two are curl's alone.
          case "${SEG_WORDS[0]}" in curl) __fw=1 ;; esac ;;
        -D?*|-c?*)
          case "${SEG_WORDS[0]}" in curl) FLAG_TARGETS="${FLAG_TARGETS}${__w#-?}"$'\n' ;; esac ;;
        # Playwright codegen/open write through `--save-har`, `--save-storage`
        # and `--save-trace`; a HAR of a file:// navigation contains the file.
        --save-har=*|--save-storage=*|--save-trace=*|--save-har-glob=*)
          FLAG_TARGETS="${FLAG_TARGETS}${__w#*=}"$'\n' ;;
        --save-har|--save-storage|--save-trace)
          __fw=1 ;;
        # `--libcurl <file>` writes a C source file.
        --libcurl) __fw=1 ;;
        --libcurl=*) FLAG_TARGETS="${FLAG_TARGETS}${__w#*=}"$'\n' ;;
        -O|-[a-zA-Z]*O*)
          # curl's `-O` takes no operand: it derives the filename from the URL and
          # clusters with other letters (`-sO`, `-sSLO`), so derive the target here.
          # wget's `-O` takes a filename, so the two are separate arms.
          case "${SEG_WORDS[0]##*/}" in
            curl)
              __url=""
              for __j in "${!SEG_WORDS[@]}"; do
                case "${SEG_WORDS[$__j]}" in *://*) __url="${SEG_WORDS[$__j]}"; break ;; esac
              done
              __base="${__url%%\?*}"; __base="${__base%%#*}"; __base="${__base##*/}"
              [ -n "$__base" ] || __base="index.html"
              FLAG_TARGETS="${FLAG_TARGETS}${__base}"$'\n' ;;
            wget|aria2c)
              # Only the exact spelling, or a cluster ending in O, takes the next word.
              case "$__w" in -O|-[a-zA-Z]*O) __fw=1 ;; esac ;;
          esac ;;
        -o|-O)
          # `-o` takes a path unless the command is one where it means something
          # else (grep only-matching, find OR). Unknown commands are treated as
          # writing, and the scope check decides whether it matters.
          case "$__w:${SEG_WORDS[0]}" in
            # `-O` is an optimisation level for interpreters and compilers
            # (`python -OO`, `cc -O2`), so it keeps a list of the downloaders.
            -O:wget|-O:curl|-O:aria2c) __fw=1 ;;
            -O:*) : ;;
            *:grep|*:egrep|*:fgrep|*:rgrep|*:rg|*:ag|*:ack|*:ack-grep|*:find|*:nm|*:ps|*:du|*:df|*:stty|*:sox) : ;;
            *) __fw=1 ;;
          esac ;;
        -o*|-O*)
          # The attached spelling (`sort -opackage.json`) follows the same rule as
          # the separated one; a non-path remainder is filtered downstream.
          case "$__w:${SEG_WORDS[0]}" in
            -O*:wget|-O*:curl|-O*:aria2c) FLAG_TARGETS="${FLAG_TARGETS}${__w#-?}"$'\n' ;;
            -O*:*) : ;;
            *:grep|*:egrep|*:fgrep|*:rgrep|*:rg|*:ag|*:ack|*:ack-grep|*:find|*:nm|*:ps|*:du|*:df|*:stty|*:sox) : ;;
            *) FLAG_TARGETS="${FLAG_TARGETS}${__w#-?}"$'\n' ;;
          esac ;;
      esac
    done
    # Archive tools name their output in ways no output-flag spelling covers
    # (`tar -cf out.tar`, `tar cf`, `zip out.zip`), and the file does not exist
    # yet. Per-tool, because `tar -c` writes the archive and `tar -x` reads it.
    case "${SEG_WORDS[0]:-}" in
      tar|bsdtar|gtar)
        __tf=0
        for __i in "${!SEG_WORDS[@]}"; do
          [ "$__i" = "0" ] && continue
          __w="${SEG_WORDS[$__i]}"
          if [ "$__tf" = "1" ]; then FLAG_TARGETS="${FLAG_TARGETS}${__w}"$'\n'; __tf=0; continue; fi
          case "$__w" in
            --file=*) FLAG_TARGETS="${FLAG_TARGETS}${__w#*=}"$'\n' ;;
            --file) __tf=1 ;;
            # A cluster containing `f`, with or without the leading dash
            # (`tar cf`, `tar -czf`). The archive follows the cluster;
            # attached to it when more characters come after the `f`.
            -*f|-*f*|[a-zA-Z]*f|[a-zA-Z]*f*)
              case "$__w" in
                -*|[a-zA-Z]*)
                  __rest="${__w##*f}"
                  if [ -n "$__rest" ]; then FLAG_TARGETS="${FLAG_TARGETS}${__rest}"$'\n'; else __tf=1; fi ;;
              esac ;;
          esac
        done ;;
      zip|7z|7za|zipcloak|zipnote)
        # The first non-flag operand IS the archive it creates.
        for __i in "${!SEG_WORDS[@]}"; do
          [ "$__i" = "0" ] && continue
          case "${SEG_WORDS[$__i]}" in
            -*) continue ;;
            *) FLAG_TARGETS="${FLAG_TARGETS}${SEG_WORDS[$__i]}"$'\n'; break ;;
          esac
        done ;;
    esac
    # curl's `--write-out` directive `%output{path}` writes the rest of the
    # string to that path. Every `%output{…}` is extracted as a write target;
    # `>>` (append) is stripped so the path is judged.
    if [[ "$CMD" == *'%output{'* ]]; then
      __ots=$(printf '%s' "$CMD" | kernel_mandate_grep_or_empty -oE '%output\{[^}]*\}' | sed -E 's/^%output\{//; s/\}$//') \
        || deny_unscreened_targets
      while IFS= read -r __ot; do
        [ -n "$__ot" ] || continue
        __ot="${__ot#>}"; __ot="${__ot#>}"
        [ -n "$__ot" ] && FLAG_TARGETS="${FLAG_TARGETS}${__ot}"$'\n'
      done <<< "$__ots"
    fi
    [ -n "$FLAG_TARGETS" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$FLAG_TARGETS")

    WRITE_VERB=$(printf '%s' "$seg" | sed -E 's/^([a-z0-9_.\/-]*\/)?([a-z0-9_-]+).*/\2/') || deny_unscreened_targets
    case "$WRITE_VERB" in
      cp|mv|install|rsync|ln)
        # Destination is the last non-flag operand.
        DEST=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | kernel_mandate_grep_or_empty -vE '^-' | kernel_mandate_grep_or_empty -v '^$' | tail -n1) || deny_unscreened_targets
        [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        ;;
      dd)
        DEST=$(printf '%s' "$seg" | kernel_mandate_grep_or_empty -oE '(^|[[:space:]])of=[^[:space:]]+' | sed -E 's/.*of=//') || deny_unscreened_targets
        [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        ;;
      truncate|shred|touch|chmod|chown)
        DEST=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | kernel_mandate_grep_or_empty -vE '^-' | kernel_mandate_grep_or_empty -v '^$') || deny_unscreened_targets
        [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        ;;
      rm|rmdir|unlink)
        # Deletion is a write: every non-flag operand of rm/rmdir/unlink is held
        # to the write scope like a redirect destination.
        DEST=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | kernel_mandate_grep_or_empty -vE '^-' | kernel_mandate_grep_or_empty -v '^$') || deny_unscreened_targets
        [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        ;;
      sed|perl|ruby)
        # In-place editing rewrites every file operand.
        # bash's own regex, so the detection has no tool to fail; the
        # pattern sits in a variable because bash 3.2 reads it differently
        # when written inline.
        __inplace_re='[[:space:]]-[a-zA-Z]*i([[:space:]]|$|\.)'
        if [[ " $seg" =~ $__inplace_re ]]; then
          DEST=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | kernel_mandate_grep_or_empty -vE '^-' | kernel_mandate_grep_or_empty -v '^$' | tail -n +2) || deny_unscreened_targets
          [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        fi
        ;;
      uniq)
        # `uniq [OPTION]... [INPUT [OUTPUT]]` — the second non-flag operand is an
        # output file, and axis 5b's code screen only sees collected targets.
        __uniq_seen=0
        for __i in "${!SEG_WORDS[@]}"; do
          [ "$__i" = "0" ] && continue
          # A bare `-` is stdin, an operand: skipping it shifts the count.
          case "${SEG_WORDS[$__i]}" in --) continue ;; -) : ;; -*) continue ;; esac
          __uniq_seen=$((__uniq_seen + 1))
          [ "$__uniq_seen" = "2" ] || continue
          REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "${SEG_WORDS[$__i]}")
          break
        done ;;
      split|csplit)
        # Both write files named by a PREFIX operand, and csplit writes
        # `xx00…` into the cwd when given none. Every non-flag operand
        # after the input is a target.
        __sp_seen=0
        for __i in "${!SEG_WORDS[@]}"; do
          [ "$__i" = "0" ] && continue
          case "${SEG_WORDS[$__i]}" in --) continue ;; -) : ;; -*) continue ;; esac
          __sp_seen=$((__sp_seen + 1))
          [ "$__sp_seen" -ge 2 ] || continue
          REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "${SEG_WORDS[$__i]}")
        done ;;
      gzip|gunzip|bzip2|bunzip2|xz|unxz|zstd|unzstd|compress|uncompress)
        # These REPLACE their operands in place. Every non-flag operand
        # is both a read and a write.
        for __i in "${!SEG_WORDS[@]}"; do
          [ "$__i" = "0" ] && continue
          case "${SEG_WORDS[$__i]}" in --|-) continue ;; -*) continue ;; esac
          REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "${SEG_WORDS[$__i]}")
        done ;;
    esac
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      target=$(printf '%s' "$target" | tr -d '"'"'" | tr -d '\001')
      [ -n "$target" ] || continue
      # /dev/null is fd plumbing, not a file, on the flag channel as on the
      # redirect channel (`curl -o /dev/null`).
      case "$target" in
        /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*|/dev/std*) continue ;;
      esac
      # Axis 5b on the bash authoring route: echo/printf/cat carry the content in
      # the command; cp/mv carry a path already bounded by the read scope. Screen
      # the whole command, since `echo '<code>' | tee spec.ts` splits them.
      # A role that declares code constraints is refused this channel outright:
      # shell escaping (`require\("fs"\)`) defeats JS patterns, so it must author
      # code through Write/Edit, where the content can be screened.
      CC_IMPORTS=$(kernel_mandate_role_field "$ROLE" '.write.codeImports')
      CC_CAPS=$(kernel_mandate_role_field "$ROLE" '.write.codeCapabilities')
      if [ "$CC_IMPORTS" != "null" ] || [ "$CC_CAPS" != "null" ]; then
        # Executable by extension, or with no extension (where a shebang hides).
        EXEC_TARGET=0
        case "${target##*/}" in
          *.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.tsx|*.jsx|*.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.php|*.ipynb|*.lua|*.ps1) EXEC_TARGET=1 ;;
          *.*) EXEC_TARGET=0 ;;             # some other extension: data
          *)   EXEC_TARGET=1 ;;             # no extension: runnable
        esac
        case "$EXEC_TARGET" in
          1)
            kernel_mandate_deny "bash-authoring-executable $(kernel_mandate_relpath "$target")" "[BLOCKED] Role '${ROLE}' may not author '$(kernel_mandate_relpath "$target")' through Bash — an executable file must be written with Write or Edit.

${ROLE_HEADER}

Command: ${CMD}

This role declares what its code may import or do, and that screen needs the file's CONTENT. Through Bash the kernel sees a shell command, not a file: quoting and escaping differ, and \`require\\(\"fs\"\\)\` reaches disk identical to a form the screen refuses. Rather than pretend to read it, this channel is closed for files something can run.

Use the tool whose input IS the content:
  Write  file_path: $(kernel_mandate_relpath "$target")
  Edit   for a change to a file that already exists

Non-executable files (fixtures, notes, JSON) are unaffected."
            ;;
        esac
      fi

      check_code_capabilities "$target" "$CMD" "
Channel: authored via Bash (\`${SEG_WORDS[0]:-}\`) — the same screen applies to every route that puts a file on disk."
      # Root of trust first, for every write channel, whatever command produced
      # the target: the manifest is read-exempt, never write-exempt.
      self_protect_target "$target" "self-protect bash write-target"
      if [ "$HAS_WRITE_GRANTS" != "1" ]; then
        kernel_mandate_deny "bash-redirect-readonly" "[BLOCKED] Role '${ROLE}' has no write grants, but this command contains a file redirection — Bash must not become a write channel for a read-only role.

${ROLE_HEADER}

Command: ${CMD}

Drop the redirection (pipe to your own context instead of a file), or hand the write to the role that owns the target path."
      fi
      REL_TARGET=$(kernel_mandate_relpath "$target")
      if { [ "$WRITE_DENY" != "null" ] && kernel_mandate_path_denied "$REL_TARGET" "$target" "$WRITE_DENY"; } \
         || ! kernel_mandate_path_in_scope "$REL_TARGET" "$WRITE_ALLOW"; then
        kernel_mandate_deny "bash-redirect-out-of-scope $REL_TARGET" "[BLOCKED] Role '${ROLE}' may not redirect output into '$REL_TARGET' — it is outside the role's write scope.

${ROLE_HEADER}
write scope: $(printf '%s' "$WRITE_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Shell redirection is held to the same write scope as the Write/Edit tools."
      fi
    done <<< "$REDIR_TARGETS"

    # 3e. Read-scope over real files. For a role with a read scope,
    # every token that resolves (glob-aware, via compgen) to an
    # existing file or directory must be inside read.allow ∪
    # write.allow — otherwise `cat .env` through an allowed binary
    # would bypass the Read axis entirely. Tokens that resolve to
    # nothing (flags, patterns, prose) pass; the manifest itself is
    # implicitly readable (it is the law the role is being held to).
    if [ "$READ_ALLOW" != "null" ]; then
      # Operands that are patterns, not paths (`grep package.json src/`,
      # `find . -name x.json`) are exempted by index, only where the command's
      # grammar makes them patterns.
      TOK_SKIP=" "
      # The positional program (grep pattern, sed/awk script, jq filter) is
      # exempt from the read scan, unless a flag supplied the program, in which
      # case the first positional is an input file. The blocks below only report
      # __has_prog_flag and __prog_idx; the single line after the `esac` decides.
      __has_prog_flag=0; __prog_idx=""
      case "${SEG_WORDS[0]:-}" in
        grep|egrep|fgrep|rgrep|rg|ag|ack|ripgrep)
          # -e PAT / -f FILE change the grammar: with either present there
          # is no positional pattern, and -f's operand is a real file read.
          __skip_next=0
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            __w="${SEG_WORDS[$__i]}"
            if [ "$__skip_next" = "1" ]; then __skip_next=0; continue; fi
            case "$__w" in
              -e|--regexp) __has_prog_flag=1; TOK_SKIP="${TOK_SKIP}$((__i + 1)) "; __skip_next=1; continue ;;
              -f|--file)   __has_prog_flag=1; __skip_next=1; continue ;;
              -e*|--regexp=*) __has_prog_flag=1; continue ;;
              -f*|--file=*)   __has_prog_flag=1; continue ;;
              -*) continue ;;
            esac
            [ -n "$__prog_idx" ] || __prog_idx="$__i"
          done
          ;;
        jq|yq|gojq|jaq)
          # jq's first operand is a filter (commonly `.`), not a path. The filter's
          # index depends on how many operands each option consumes; a miscount
          # exempts a file (`--rawfile NAME FILE`). Option operands are exempted
          # only when provably not a path.
          __skip_n=0
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            __w="${SEG_WORDS[$__i]}"
            if [ "$__skip_n" -gt 0 ]; then __skip_n=$((__skip_n - 1)); continue; fi
            case "$__w" in
              # NAME VALUE — two operands, neither of which jq opens.
              --arg|--argjson)
                TOK_SKIP="${TOK_SKIP}$((__i + 1)) $((__i + 2)) "; __skip_n=2; continue ;;
              # NAME FILE — two operands, and the second IS a file read.
              # Exempt the name; the file stays scope-checked.
              --slurpfile|--rawfile)
                TOK_SKIP="${TOK_SKIP}$((__i + 1)) "; __skip_n=2; continue ;;
              # One operand, not a path.
              --indent)
                TOK_SKIP="${TOK_SKIP}$((__i + 1)) "; __skip_n=1; continue ;;
              # One operand which IS a path: consumed, so it is never
              # mistaken for the filter, but NOT exempted. `-L` is jq's library search
              # path, so it belongs here.
              -L) __skip_n=1; continue ;;
              # One operand which IS a file, and which supplies the
              # FILTER — so it stays scope-checked, and there is no
              # positional filter left to exempt.
              -f|--from-file) __has_prog_flag=1; __skip_n=1; continue ;;
              -f*|--from-file=*) __has_prog_flag=1; continue ;;
              # No operand at all — these only change how later
              # positionals are read, and were consuming one each.
              --args|--jsonargs) continue ;;
              -*) continue ;;
            esac
            [ -n "$__prog_idx" ] || __prog_idx="$__i"
          done
          ;;
        sed|awk|gawk|mawk)
          # The first positional operand is the program text; the rest are
          # input files and stay scope-checked. A program flag (`sed -e`, `awk -f`)
          # means there is no positional program. `-v`/`--assign` binds a variable
          # and does not set the guard.
          __skip_next=0
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            __w="${SEG_WORDS[$__i]}"
            if [ "$__skip_next" = "1" ]; then __skip_next=0; continue; fi
            case "$__w" in
              -e|-f|--expression|--file) __has_prog_flag=1; __skip_next=1; continue ;;
              -e*|-f*|--expression=*|--file=*) __has_prog_flag=1; continue ;;
              -v|--assign) __skip_next=1; continue ;;
              -*) continue ;;
            esac
            [ -n "$__prog_idx" ] || __prog_idx="$__i"
          done
          ;;
      esac
      # THE decision — the only place any of the blocks above is exempted
      # from the read scan. A program flag means there is no positional
      # program, and every positional is an input file.
      [ "$__has_prog_flag" = "0" ] && [ -n "$__prog_idx" ] && TOK_SKIP="${TOK_SKIP}${__prog_idx} "

      # An exempted jq filter can still load a file: `import "docs/x" as $d`.
      # Module names are resolved against the cwd and each `-L` directory and
      # scope-checked where a candidate exists.

      case "${SEG_WORDS[0]:-}" in
        jq|gojq|jaq)
          JQ_MODS=$(printf '%s\n' "${SEG_WORDS[@]}" \
            | kernel_mandate_grep_or_empty -oE '(import|include)[[:space:]]*"[^"]*"' 2>/dev/null \
            | sed 's/.*"\([^"]*\)"/\1/') \
            || deny_unscreened "bash-jq-module-screen" "this command's jq modules" "Command: ${CMD}"
          if [ -n "$JQ_MODS" ]; then
            JQ_BASES=("$KM_CWD")
            __skip_next=0
            for __i in "${!SEG_WORDS[@]}"; do
              [ "$__i" = "0" ] && continue
              __w="${SEG_WORDS[$__i]}"
              if [ "$__skip_next" = "1" ]; then __skip_next=0; JQ_BASES+=("$__w"); continue; fi
              case "$__w" in -L) __skip_next=1 ;; -L?*) JQ_BASES+=("${__w#-L}") ;; esac
            done
            while IFS= read -r __mod; do
              [ -n "$__mod" ] || continue
              for __b in "${JQ_BASES[@]}"; do
                case "$__b" in /*) : ;; *) __b="${KM_CWD%/}/$__b" ;; esac
                for __ext in .jq .json ""; do
                  __cand="$__b/$__mod$__ext"
                  [ -f "$__cand" ] || continue
                  kernel_mandate_is_manifest_path "$__cand" && continue
                  __rel=$(kernel_mandate_relpath "$__cand")
                  if [ "$READ_DENY" != "null" ] && kernel_mandate_path_denied "$__rel" "$__cand" "$READ_DENY"; then :
                  elif kernel_mandate_path_in_scope "$__rel" "$READ_ALLOW"; then continue
                  elif [ "$HAS_WRITE_GRANTS" = "1" ] && kernel_mandate_path_in_scope "$__rel" "$WRITE_ALLOW"; then continue
                  fi
                  set +f
                  kernel_mandate_deny "bash-jq-module-out-of-scope $__rel" "[BLOCKED] Role '${ROLE}' may not import '$__mod' — it resolves to '$__rel', which is outside the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

A jq filter is exempt from the read scan because it is a program, not a path — but \`import\`/\`include\` inside one names a file that jq really opens, so the module is scope-checked like any other read. Import only modules inside this role's read scope."
                done
              done
            done <<< "$JQ_MODS"
          fi
          ;;
      esac
      if [ "${SEG_WORDS[0]:-}" = "find" ]; then
        for __i in "${!SEG_WORDS[@]}"; do
          case "${SEG_WORDS[$__i]}" in
            -name|-iname|-path|-ipath|-wholename|-iwholename|-regex|-iregex|-lname|-ilname)
              TOK_SKIP="${TOK_SKIP}$((__i + 1)) " ;;
          esac
        done
      fi

      # Quote-aware word split. A word the shell would glob-expand arrives as
      # U<word> and is expanded here too; a fully quoted word arrives as Q<word>
      # and is literal (`find -name "*.json"` reads no json file).
      TOK_N=0
      TOK_IDX=-1
      TOK_SAW_PATH=0
      set -f
      while IFS= read -r TOKW; do
        # Same producer as SEG_WORDS, so the index lines up with it — that
        # is what lets TOK_SKIP name operands positionally.
        TOK_IDX=$((TOK_IDX + 1))
        [ -n "$TOKW" ] || continue
        TOK_QUOTED=0
        case "$TOKW" in Q*) TOK_QUOTED=1 ;; esac
        tok="${TOKW#?}"
        [ -n "$tok" ] || continue
        case "$TOK_SKIP" in *" $TOK_IDX "*) continue ;; esac
        # Fail CLOSED on an over-long segment: skipping the tail would
        # let a padded command hide an out-of-scope path past the cap.
        TOK_N=$((TOK_N + 1))
        if [ "$TOK_N" -gt 400 ]; then
          set +f
          kernel_mandate_deny "bash-too-many-tokens" "[BLOCKED] Role '${ROLE}' ran a command segment with more than 400 arguments, which the kernel will not scope-check exhaustively.

${ROLE_HEADER}

Command: ${CMD}

A segment this long cannot be verified against the role's read scope, so it is refused rather than partially checked. Split the work into smaller commands naming the files you actually need."
        fi
        case "$tok" in
          file://*)
            # A `file://` URL is a path; the browser opens it directly.
            tok="${tok#file://}"
            tok="${tok#localhost}"
            case "$tok" in /*) : ;; *) tok="/$tok" ;; esac
            tok="${tok%%\?*}"; tok="${tok%%#*}"
            [ -n "$tok" ] || continue
            ;;
          *://*) continue ;;           # any other scheme: never a local file
          -*=*)
            # A flag value can name a file the command reads (`--files0-from=`,
            # `--file=`, `--config=`). Scope-check the value; a non-path value is
            # filtered by the existence test.
            tok="${tok#*=}"
            [ -n "$tok" ] || continue
            ;;
          -*)
            # A short flag's attached value can be a file (`grep -f.env`). Strip the
            # flag letter and let the existence test decide; flags whose attached value
            # is a pattern are named here and left alone.
            case "${SEG_WORDS[0]:-}:$tok" in
              grep:-e*|egrep:-e*|fgrep:-e*|rgrep:-e*|rg:-e*|ag:-e*|ack:-e*|ripgrep:-e*) continue ;;
              sed:-e*|awk:-v*|gawk:-v*|mawk:-v*) continue ;;
            esac
            case "$tok" in
              --*) continue ;;           # long options spell values with `=`
              -?*) tok="${tok#-?}" ;;    # short flag with an attached value
              *) continue ;;
            esac
            [ -n "$tok" ] || continue
            ;;
          *=*)
            # NAME=value is an env assignment, not a file read, except for `dd`,
            # whose `if=`/`of=` operands are paths.
            case "${SEG_WORDS[0]:-}:$tok" in
              dd:if=*|dd:of=*) tok="${tok#*=}"; [ -n "$tok" ] || continue ;;
              # `NAME=@PATH` is curl's `-F field=@file` upload.
              *=@?*) tok="${tok#*=}" ;;
              # `NAME=<PATH` sends the file's contents (`-F 'x=<.env'`); quoted, so it
              # never reaches the redirect masking.
              *=\<?*) tok="${tok#*=<}"; [ -n "$tok" ] || continue ;;
              *) continue ;;
            esac
            ;;
        esac
        # `@PATH` is the "read this file" spelling (`curl -d @file`). De-sugared
        # last, so it applies bare, attached to a short flag, or after `=`.
        case "$tok" in @?*) tok="${tok#@}" ;; esac
        # The target of a no-op cd, or a no-op `git -C` / `--work-tree`, is the
        # directory the call already runs in. Deliberately narrow: a bare `.`
        # operand to a content-reading command (grep -r foo .) is not exempt.
        if { [ "$CD_NOOP" = "1" ] || [ -n "$GIT_ANCHOR" ]; } \
           && [ "$(kernel_mandate_normalize_path "$tok")" = "$(kernel_mandate_normalize_path "$KM_CWD")" ]; then
          continue
        fi
        # An expansion inside a path-shaped token (`cat $PWD/.env`) cannot be
        # scope-checked. Only reachable when the role permits an expansion construct;
        # a bare `$VAR` with no separator stays fine.
        case "$tok" in
          *'$'*/*|*/*'$'*|*'`'*/*|*/*'`'*)
            set +f
            kernel_mandate_deny "bash-unverifiable-path-expansion" "[BLOCKED] Role '${ROLE}' used a shell expansion inside a path argument ('$tok'), which the kernel cannot resolve — so it cannot be checked against the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Write the path literally (relative to the project root) so it can be scope-checked. An expansion is permitted for this role in non-path arguments; a path built by expansion would make the read scope unenforceable."
            ;;
        esac
        # shellcheck disable=SC2088  # deliberately matches a LITERAL ~ token in input and expands it manually
        case "$tok" in "~") tok="$HOME" ;; "~/"*) tok="$HOME/${tok#\~/}" ;; esac
        # No `--` before the pattern: `compgen -G -- x` matches nothing (bash
        # quirk); flag-shaped tokens are skipped above. compgen echoes a
        # metacharacter-free pattern back unmatched, so existence is confirmed below.
        if [ "$TOK_QUOTED" = "1" ]; then
          # Quoted: no expansion. The word names itself, and only itself.
          MATCHES="$tok"
        else
          MATCHES=$(cd "$KM_CWD" 2>/dev/null && compgen -G "$tok" 2>/dev/null || true)
        fi
        [ -n "$MATCHES" ] || continue
        while IFS= read -r m; do
          [ -n "$m" ] || continue
          # Confirm the candidate actually exists (resolve relative to
          # the command's cwd) — this is what makes a non-matching
          # literal like a URL or a bare word harmless.
          case "$m" in
            /*) [ -e "$m" ] || continue ;;
            *)  [ -e "$KM_CWD/$m" ] || continue ;;
          esac
          # This segment names at least one existing path, so it is not one of the
          # pathless reads screened after the loop. Set before the manifest exemption.
          TOK_SAW_PATH=1
          # /dev/null and the standard streams are fd plumbing, not files. Only
          # these: /dev/random, /dev/mem and the rest of /dev stay out of scope.
          case "$m" in
            /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*|/dev/std*) continue ;;
          esac
          kernel_mandate_is_manifest_path "$m" && continue
          REL_M=$(kernel_mandate_relpath "$m")
          DENIED_READ=0
          if [ "$READ_DENY" != "null" ] && kernel_mandate_path_denied "$REL_M" "$m" "$READ_DENY"; then
            DENIED_READ=1
          elif kernel_mandate_path_in_scope "$REL_M" "$READ_ALLOW"; then
            continue
          elif [ "$HAS_WRITE_GRANTS" = "1" ] && kernel_mandate_path_in_scope "$REL_M" "$WRITE_ALLOW"; then
            continue
          else
            DENIED_READ=1
          fi
          if [ "$DENIED_READ" = "1" ]; then
            set +f
            kernel_mandate_deny "bash-read-out-of-scope $REL_M" "[BLOCKED] Role '${ROLE}' may not touch '$REL_M' via Bash — it is outside the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Bash file access is held to the same read scope as the Read tool — the scope is the role's context diet, whichever channel does the reading."
          fi
        done <<< "$MATCHES"
      done < <(printf '%s\n' "$seg" | kernel_mandate_shell_words)
      set +f

      # 3f. A read that names no path (`grep -r PAT`, `rg PAT`, bare `find`,
      # `ls`, `tree`) reads the cwd, so it needs the grant `.` would. The test
      # is "did this segment name a path at all", which needs no per-flag model.
      if [ "$TOK_SAW_PATH" = "0" ]; then
        CWD_READER=0
        case "${SEG_WORDS[0]:-}" in
          # Recursive by construction: no path operand means the cwd.
          rg|ripgrep|ag|ack|ack-grep|fd|fdfind|rgrep|find|ls|dir|vdir|tree|du) CWD_READER=1 ;;
          # The grep family reads stdin when given no path, unless a recursion
          # flag makes it walk the cwd.
          grep|egrep|fgrep)
            for __w in "${SEG_WORDS[@]:1}"; do
              case "$__w" in
                --recursive|--dereference-recursive) CWD_READER=1 ;;
                --*) : ;;
                -*[rR]*) CWD_READER=1 ;;
              esac
            done ;;
        esac
        if [ "$CWD_READER" = "1" ]; then
          CWD_REL=$(kernel_mandate_relpath "$KM_CWD")
          [ -n "$CWD_REL" ] || CWD_REL="."
          CWD_OK=0
          if [ "$READ_DENY" != "null" ] && kernel_mandate_path_denied "$CWD_REL" "$KM_CWD" "$READ_DENY"; then CWD_OK=0
          elif kernel_mandate_path_in_scope "$CWD_REL" "$READ_ALLOW"; then CWD_OK=1
          elif [ "$HAS_WRITE_GRANTS" = "1" ] && kernel_mandate_path_in_scope "$CWD_REL" "$WRITE_ALLOW"; then CWD_OK=1
          fi
          if [ "$CWD_OK" = "0" ]; then
            set +f
            kernel_mandate_deny "bash-pathless-read $CWD_REL" "[BLOCKED] Role '${ROLE}' ran '${SEG_WORDS[0]}' without naming a path, which reads the directory the command runs in ('$CWD_REL') — and that is outside the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Your command group DOES grant '${SEG_WORDS[0]}'. This refusal is about WHERE it reads, not whether you may run it: with no path operand it walks the whole project, so it is held to the same scope as naming that directory outright, which is refused for this role too. Name a path inside your read scope instead: $(printf '%s' "$READ_ALLOW" | "$JQ" -r '.[0] // "<a path in scope>"' 2>/dev/null)"
          fi
        fi
      fi
    fi

    # 3h. The kernel's own CLI writes the manifest without naming it
    # (`kernel-mandate import <bundle> --activate`, `kernel-mandate use <name>`),
    # so a governed role may not reconfigure the harness it is governed by.
    # `validate`, `explain`, `status`, `doctor`, `brief` and `run` are untouched.
    if [ "$KM_TOOL" = "Bash" ]; then
      CLI_IDX=""
      case "${SEG_WORDS[0]:-}" in
        kernel-mandate) CLI_IDX=1 ;;
        npx|pnpm|yarn|bunx)
          # Skip the wrapper's own flags (`npx --yes kernel-mandate use x`).
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            case "${SEG_WORDS[$__i]}" in
              -*) continue ;;
              exec) continue ;;
              kernel-mandate|@civitas-cerebrum/kernel-mandate) CLI_IDX=$((__i + 1)); break ;;
              *) break ;;
            esac
          done ;;
        node|nodejs|bun|deno)
          for __i in "${!SEG_WORDS[@]}"; do
            case "${SEG_WORDS[$__i]}" in
              *kernel-mandate/bin/cli.mjs|*/kernel-mandate/bin/cli.mjs|cli.mjs)
                case "${SEG_WORDS[$__i]}" in *kernel-mandate*) CLI_IDX=$((__i + 1)) ;; esac ;;
            esac
          done ;;
      esac
      if [ -n "$CLI_IDX" ]; then
        CLI_SUB=""
        for __i in "${!SEG_WORDS[@]}"; do
          [ "$__i" -lt "$CLI_IDX" ] && continue
          case "${SEG_WORDS[$__i]}" in -*) continue ;; esac
          CLI_SUB="${SEG_WORDS[$__i]}"; break
        done
        case "$CLI_SUB" in
          init|import|use)
            set +f
            kernel_mandate_deny "self-protect kernel-mandate-cli:${CLI_SUB}" "[BLOCKED] Role '${ROLE}' may not run 'kernel-mandate ${CLI_SUB}' — that subcommand rewrites the manifest this role is governed by.

${ROLE_HEADER}

Command: ${CMD}

Self-protection screens a command for the protected path, and this one never names it: the CLI writes '.claude/kernel-mandate.json' itself. A governed role does not reconfigure the harness that governs it, so the subcommand is refused rather than the path — 'import --activate' also replaces the state directory, and 'use' names a library entry with no path at all.

The read-only subcommands are unaffected: validate, explain, status, doctor and brief, and the 'run' wrapper. Changing the manifest is the operator's, from a session this kernel is not governing."
            ;;
        esac
      fi
    fi

    # 3g. Network destination. A command group is a prefix match and a URL
    # authority is a parser problem (`localhost:4173@example.com` dials
    # example.com), so no pattern is a destination boundary:
    #
    #   userinfo in a URL is refused outright — an agent has no reason to
    #   embed credentials, and it makes the visible prefix differ from
    #   where the URL connects;
    #
    #   a role that declares `network.allow` has every URL authority parsed
    #   and checked against it (which also closes `localhost:4173.evil.com`).
    #
    # Opt-in like `codeImports`: a "no network" default would refuse every
    # existing manifest's health check. `validate` warns for roles without one.
    NET_ALLOW=$(kernel_mandate_role_field "$ROLE" '.network.allow')
    # A URL is a destination only when something can dial it; text commands
    # (`echo`, `grep`) are exempted. An exemption list, so an unmodelled
    # command is checked.
    case "${SEG_WORDS[0]:-}" in
      echo|printf|cat|head|tail|grep|egrep|fgrep|rg|ag|ack|sed|awk|gawk|mawk|jq|ls|find|wc|sort|uniq|comm|diff|tr|cut|paste|tee|basename|dirname|realpath|test|true|false|expr|date|env|export|read|history)
        NET_SKIP=1 ;;
      *) NET_SKIP=0 ;;
    esac
    while [ "$NET_SKIP" = "0" ] && IFS= read -r NETW; do
      [ -n "$NETW" ] || continue
      # A URL can arrive as a flag's value (`--url=http://…`), so strip a leading
      # `opt=` — only for a flag (leading dash), since a query string carries `=`
      # and mentions other URLs as data.
      case "$NETW" in -*=*://*) NETW="${NETW#*=}" ;; esac
      kernel_mandate_is_network_url "$NETW" || continue
      NET_AUTH=$(kernel_mandate_url_authority "$NETW")
      [ -n "$NET_AUTH" ] || continue
      NET_USER=$(kernel_mandate_url_userinfo "$NETW")
      if [ -n "$NET_USER" ]; then
        set +f
        kernel_mandate_deny "bash-url-userinfo $NET_AUTH" "[BLOCKED] Role '${ROLE}' used a URL carrying credentials before the host, which connects somewhere other than it appears to.

${ROLE_HEADER}

Command: ${CMD}

  written:     ${NETW}
  connects to: ${NET_AUTH}
  (everything before the @ is userinfo, not a host)

A command group is a regex over argv, so a pattern pinning a URL prefix cannot be a destination boundary: the text before the @ can be made to read exactly like the host you were granted. Write the URL without userinfo. If this role genuinely needs HTTP authentication, pass it as a header or a credentials flag, where it is not pretending to be a hostname."
      fi
      if [ "$NET_ALLOW" != "null" ] && ! kernel_mandate_authority_in_scope "$NET_AUTH" "$NET_ALLOW"; then
        set +f
        kernel_mandate_deny "bash-network-out-of-scope $NET_AUTH" "[BLOCKED] Role '${ROLE}' may not connect to '$NET_AUTH' — it is outside the role's network scope.

${ROLE_HEADER}
network scope: $(printf '%s' "$NET_ALLOW" | "$JQ" -r 'join(\", \")' 2>/dev/null)

Command: ${CMD}

The authority is parsed rather than pattern-matched, so a host that merely STARTS with a permitted one, or hides it in userinfo, is a different destination and is refused. Entries name a host, optionally with a port: a bare host permits any port, and a leading *. permits subdomains."
      fi
    done < <(printf '%s\n' "$seg" | tr ' \t"'"'"'`(),;' '\n\n\n\n\n\n\n\n\n')

    # 3g-2. Destination overrides that are not URLs (`--connect-to`,
    # `--resolve`) are parsed as destinations and scope-checked; one that
    # moves the destination into a file is refused. An enumeration of curl's
    # flags, so `network.allow` stays advisory without an egress proxy.
    if [ "$NET_ALLOW" != "null" ] && [ "$NET_SKIP" = "0" ]; then
      NF_NEXT=""
      for __i in "${!SEG_WORDS[@]}"; do
        [ "$__i" = "0" ] && continue
        __w="${SEG_WORDS[$__i]}"
        NF_VAL=""
        if [ -n "$NF_NEXT" ]; then NF_VAL="$__w"; NF_KIND="$NF_NEXT"; NF_NEXT=""
        else
          case "$__w" in
            --connect-to|--resolve) NF_NEXT="map"; continue ;;
            -x|--proxy|--preproxy|--socks4|--socks4a|--socks5|--socks5-hostname|--proxy1.0)
              NF_NEXT="proxy"; continue ;;
            --connect-to=*|--resolve=*) NF_VAL="${__w#*=}"; NF_KIND="map" ;;
            --proxy=*|--preproxy=*|--socks5=*|--socks5-hostname=*) NF_VAL="${__w#*=}"; NF_KIND="proxy" ;;
            -x?*) NF_VAL="${__w#-x}"; NF_KIND="proxy" ;;
            -K|--config)
              set +f
              kernel_mandate_deny "bash-network-config-file" "[BLOCKED] Role '${ROLE}' declares a network scope, and this command reads its options from a file, where a destination cannot be checked.

${ROLE_HEADER}
network scope: $(printf '%s' "$NET_ALLOW" | "$JQ" -r 'join(\", \")' 2>/dev/null)

Command: ${CMD}

A curl config file may carry its own \`url =\` line, so the destination moves out of the command entirely. The kernel refuses that rather than checking a URL that is no longer the one being used. Put the request on the command line, where its destination is visible."
              ;;
            -K?*|--config=*)
              set +f
              kernel_mandate_deny "bash-network-config-file" "[BLOCKED] Role '${ROLE}' declares a network scope, and this command reads its options from a file, where a destination cannot be checked.

${ROLE_HEADER}

Command: ${CMD}

Put the request on the command line, where its destination is visible."
              ;;
            *) continue ;;
          esac
        fi
        [ -n "$NF_VAL" ] || continue
        # `--connect-to HOST:PORT:CONNECT-HOST:CONNECT-PORT` and `--resolve
        # HOST:PORT:ADDRESS` put the real destination last; take the tail after
        # the second field.
        case "$NF_KIND" in
          map)
            NF_REST="${NF_VAL#*:}"; NF_REST="${NF_REST#*:}"
            [ -n "$NF_REST" ] && [ "$NF_REST" != "$NF_VAL" ] || continue
            NF_AUTH=$(printf '%s' "$NF_REST" | tr 'A-Z' 'a-z') ;;
          proxy)
            NF_AUTH=$(kernel_mandate_url_authority "$NF_VAL")
            [ -n "$NF_AUTH" ] || NF_AUTH=$(printf '%s' "${NF_VAL%%/*}" | tr 'A-Z' 'a-z') ;;
          *) continue ;;
        esac
        [ -n "$NF_AUTH" ] || continue
        if ! kernel_mandate_authority_in_scope "$NF_AUTH" "$NET_ALLOW"; then
          set +f
          kernel_mandate_deny "bash-network-override-out-of-scope $NF_AUTH" "[BLOCKED] Role '${ROLE}' may not connect to '$NF_AUTH' — the command overrides its destination to somewhere outside the role's network scope.

${ROLE_HEADER}
network scope: $(printf '%s' "$NET_ALLOW" | "$JQ" -r 'join(\", \")' 2>/dev/null)

Command: ${CMD}

  the URL names:  a host inside your scope
  the client dials: ${NF_AUTH}

Flags like --connect-to, --resolve and --proxy replace the destination without changing the URL, so the address in the request is not the address on the wire. The override is held to the same scope as the URL itself."
        fi
      done
    fi

    # 5c. A contained role may not point a run at a file it can write. A config
    # (`-c`, `--config`) is instructions to the runtime (`webServer.command`
    # spawns a shell), and any file can default-export one. Named test files
    # arrive as positional operands and are untouched.
    # Contained: a role that authors executable files and can run them,
    # whether or not it declared a list.
    if [ "$WRITE_ALLOW" != "null" ] && [ "$BASH_SPEC" != "null" ]; then
      case "${SEG_WORDS[0]:-}" in
        npx|npm|yarn|pnpm|bunx|node|nodejs|deno|bun|tsx|ts-node|playwright|vitest|jest|mocha|cypress|wdio)
          CFG_NEXT=0
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            __w="${SEG_WORDS[$__i]}"
            CFG_CAND=""
            if [ "$CFG_NEXT" = "1" ]; then
              CFG_NEXT=0
              case "$__w" in -*) continue ;; esac
              CFG_CAND="$__w"
            else
              case "$__w" in
                -c|--config|--config-file|--global-setup|--globalSetup|--global-teardown|--globalTeardown|--setup-files|--setupFiles|--require|--import|--loader|--experimental-loader|--reporter|--preset)
                  CFG_NEXT=1; continue ;;
                --config=*|--config-file=*|--global-setup=*|--globalSetup=*|--global-teardown=*|--globalTeardown=*|--setup-files=*|--setupFiles=*|--require=*|--import=*|--loader=*|--experimental-loader=*|--reporter=*|--preset=*)
                  CFG_CAND="${__w#*=}" ;;
                -c?*) CFG_CAND="${__w#-c}" ;;
                *) continue ;;
              esac
            fi
            [ -n "$CFG_CAND" ] || continue
            case "$CFG_CAND" in *://*|-*) continue ;; esac
            CFG_REL=$(kernel_mandate_relpath "$(kernel_mandate_normalize_path "$CFG_CAND")")
            kernel_mandate_path_in_scope "$CFG_REL" "$WRITE_ALLOW" || continue
            kernel_mandate_deny "bash-self-authored-config $CFG_REL" "[BLOCKED] Role '${ROLE}' may not hand '$CFG_REL' to '${SEG_WORDS[0]}' as configuration — it is inside this role's own write scope.

${ROLE_HEADER}
write scope: $(printf '%s' "$WRITE_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

A configuration file is instructions to the runtime, not data for it: a framework config can name a web-server command, a global setup module or a reporter, and every one of those becomes a process. This role declares what its code may import or do, so its authored files are held at arm's length — which means it may not author the file that tells the runner what to do and then hand it over.

Naming test files is unaffected; they are positional operands, not configuration:
  ${SEG_WORDS[0]} … tests/…/your.spec.ts

If this role genuinely needs its own runner configuration, the operator owns that file: put it outside this role's write scope, where the run picks it up and the role cannot rewrite it."
          done
          ;;
      esac
    fi
  done <<< "$SEGMENTS"
fi
# --- Axis 4: read scope --------------------------------------------------
check_path_scope() {
  # check_path_scope <axis:read|write> <path> <verb-for-message>
  local axis="$1" path="$2" verb="$3" rel allow deny
  rel=$(kernel_mandate_relpath "$path")
  allow=$(kernel_mandate_role_field "$ROLE" ".${axis}.allow")
  deny=$(kernel_mandate_role_field "$ROLE" ".${axis}.deny")

  if [ "$deny" != "null" ] && kernel_mandate_path_denied "$rel" "$path" "$deny"; then
    kernel_mandate_deny "${axis}-deny $rel" "[BLOCKED] Role '${ROLE}' is explicitly denied ${verb} '$rel'.

${ROLE_HEADER}"
  fi
  if [ "$axis" = "read" ]; then
    [ "$allow" = "null" ] && return 0   # read is opt-out
  else
    if [ "$allow" = "null" ]; then
      kernel_mandate_deny "write-none $rel" "[BLOCKED] Role '${ROLE}' has no write grants at all — writing '$rel' is outside its mandate.

${ROLE_HEADER}

Produce your result as your return value (or a report), and let the role that owns this path persist it."
    fi
  fi
  if ! kernel_mandate_path_in_scope "$rel" "$allow"; then
    local scope_list
    scope_list=$(printf '%s' "$allow" | "$JQ" -r 'join(", ")' 2>/dev/null || echo "")
    kernel_mandate_deny "${axis}-out-of-scope $rel" "[BLOCKED] Role '${ROLE}' may not ${verb} '$rel' — it is outside the role's ${axis} scope.

${ROLE_HEADER}
${axis} scope: ${scope_list}

The scope is deliberate context hygiene: files outside it are another role's concern and would only dilute this context window. If the task truly requires this path, the manifest grant is what needs to change — ask the operator."
  fi
}

case "$KM_TOOL" in
  Read|NotebookRead)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    # The manifest itself is implicitly readable by every governed role —
    # it is the law the role is being held to (writes stay locked by the
    # self-protection axis).
    if [ -n "$TARGET" ] && ! kernel_mandate_is_manifest_path "$TARGET"; then
      check_path_scope read "$TARGET" "read"
    fi
    ;;
  WebFetch|WebSearch)
    # A fetch tool is a read channel when its URL names the local filesystem
    # (`file://`), as in the code screen and the MCP axis.
    WF_URL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.url // .tool_input.query // empty' 2>/dev/null || echo "")
    if [ -n "$WF_URL" ]; then
      # `data:` is inline content, not a destination.
      case "$WF_URL" in data:*|DATA:*|Data:*) WF_URL="" ;; esac
      if [ -n "$WF_URL" ] && kernel_mandate_is_network_url "$WF_URL"; then WF_KIND=remote
      else WF_KIND=local; fi
      case "${WF_KIND}:${WF_URL}" in
        remote:*)
          # Remote: held to the same network scope as curl in Bash.
          WF_NET=$(kernel_mandate_role_field "$ROLE" '.network.allow')
          WF_AUTH=$(kernel_mandate_url_authority "$WF_URL")
          WF_USER=$(kernel_mandate_url_userinfo "$WF_URL")
          if [ -n "$WF_USER" ]; then
            kernel_mandate_deny "webfetch-url-userinfo $WF_AUTH" "[BLOCKED] Role '${ROLE}' used a URL carrying credentials before the host, which fetches somewhere other than it appears to.

${ROLE_HEADER}

  written:     ${WF_URL}
  connects to: ${WF_AUTH}

Write the URL without userinfo — everything before the @ is credentials, not a hostname."
          fi
          if [ "$WF_NET" != "null" ] && [ -n "$WF_AUTH" ] \
             && ! kernel_mandate_authority_in_scope "$WF_AUTH" "$WF_NET"; then
            kernel_mandate_deny "webfetch-network-out-of-scope $WF_AUTH" "[BLOCKED] Role '${ROLE}' may not fetch '$WF_AUTH' — it is outside the role's network scope.

${ROLE_HEADER}
network scope: $(printf '%s' "$WF_NET" | "$JQ" -r 'join(", ")' 2>/dev/null)

A fetch tool reaches the network exactly as a curl does, so it is held to the same scope. The authority is parsed rather than matched as text."
          fi
          ;;
        local:file://*|local:FILE://*|local:File://*)
          WF_P="${WF_URL#*://}"; [ "${WF_P#/}" = "$WF_P" ] && WF_P="/$WF_P"
          kernel_mandate_is_manifest_path "$WF_P" || check_path_scope read "$WF_P" "read via ${KM_TOOL}" ;;
        local:/*|local:./*|local:../*|local:~/*)
          kernel_mandate_is_manifest_path "$WF_URL" || check_path_scope read "$WF_URL" "read via ${KM_TOOL}" ;;
      esac
    fi
    ;;
  Glob|Grep)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.path // empty' 2>/dev/null || echo "")
    # A pattern/glob is applied under the search root, so `..`, an absolute
    # path or `~` in it escapes the scoped path. Check both Grep fields
    # (`pattern`, `glob`), but only path-shaped ones: Grep's `pattern` is a regex.
    search_pattern_offender
    case "x$SEARCH_PAT" in
      x) : ;;
      *)
        kernel_mandate_deny "search-pattern-traversal" "[BLOCKED] Role '${ROLE}' used a '..' upward-traversal segment in a $KM_TOOL pattern.

${ROLE_HEADER}

A pattern is applied under the search root, so '..' escapes the role's scope. Narrow the search with the 'path' argument (kept inside your read scope) instead of globbing upward." ;;
    esac
    # No path: Grep searches from the repo root, so a scoped role needs a
    # root-wide grant. Glob's `pattern` names its own root
    # (kernel_mandate_search_root, shared with the unbound arm).
    if [ -z "$TARGET" ]; then
      kernel_mandate_search_root
      [ -n "$SEARCH_ROOT" ] && TARGET="$SEARCH_ROOT"
    fi
    [ -n "$TARGET" ] || TARGET="$KM_ROOT"
    check_path_scope read "$TARGET" "search"
    ;;
  Write|Edit|NotebookEdit)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    [ -n "$TARGET" ] && check_path_scope write "$TARGET" "write"

    # Axis 5b — the shared screen defined above. The bash write channel
    # runs the identical check, so neither authoring route is the soft one.
    # An Edit is screened on the file's RESULTING content, since harmless
    # fragments compose into a capability. The replacement is literal
    # (index-based), so no metacharacter in old_string changes the match.
    if [ -n "$TARGET" ]; then
      CODE=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.content // .tool_input.new_string // .tool_input.new_source // empty' 2>/dev/null || echo "")
      RESULT_CODE="$CODE"
      if [ "$KM_TOOL" = "Edit" ]; then
        # Resolve a relative file_path; falling back to the fragment is the gap.
        EDIT_TARGET="$TARGET"
        case "$EDIT_TARGET" in /*) : ;; *) EDIT_TARGET="${KM_CWD%/}/$EDIT_TARGET" ;; esac
        if [ -f "$EDIT_TARGET" ]; then
          EDIT_SIZE=$(wc -c <"$EDIT_TARGET" 2>/dev/null || echo 0)
          if [ "$EDIT_SIZE" -gt 4194304 ] && { [ "$(kernel_mandate_role_field "$ROLE" '.write.codeImports')" != "null" ] \
               || [ "$(kernel_mandate_role_field "$ROLE" '.write.codeCapabilities')" != "null" ]; }; then
            # A file too large to reconstruct is refused, not screened as a fragment.
            case "$(kernel_mandate_relpath "$EDIT_TARGET")" in
              *.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.tsx|*.jsx|*.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.php|*.ipynb|*.lua|*.ps1)
                kernel_mandate_deny "edit-too-large-to-verify $(kernel_mandate_relpath "$EDIT_TARGET")" "[BLOCKED] Role '${ROLE}' may not Edit '$(kernel_mandate_relpath "$EDIT_TARGET")' — at ${EDIT_SIZE} bytes it is too large for the kernel to verify what the edit makes it become.

${ROLE_HEADER}

An Edit is a diff, and this role declares what its code may import or do — a promise that can only be kept by screening the file's RESULTING content. Above 4 MB that reconstruction is refused rather than skipped, because screening the fragment alone is exactly the blindness the reconstruction exists to remove: an escape can be assembled from fragments that are each innocent.

Options:
  1. Split the file — an executable file this size is unusual, and a spec that big is hard to review for the same reason.
  2. Author a fresh, smaller file with Write, whose whole content is screened." ;;
            esac
          fi
          OLD_S=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.old_string // empty' 2>/dev/null || echo "")
          REPL_ALL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.replace_all // false' 2>/dev/null || echo false)
          if [ -n "$OLD_S" ]; then
            # `replace_all` rescans from after what it just wrote, or renaming `foo`
            # to `foobar` loops forever. `timeout` is a backstop, so its absence is
            # not a denial.
            KM_TMO=""; command -v timeout >/dev/null 2>&1 && KM_TMO="timeout 20"
            RESULT_CODE=$(OLD_S="$OLD_S" NEW_S="$CODE" ALL="$REPL_ALL" $KM_TMO perl -0777 -e '
              local $/; my $f = <STDIN>;
              my ($o, $n, $all) = ($ENV{OLD_S}, $ENV{NEW_S}, $ENV{ALL} eq "true");
              exit 3 unless length $o;
              if ($all) {
                my $pos = 0;
                while ((my $i = index($f, $o, $pos)) >= 0) {
                  substr($f, $i, length($o)) = $n;
                  $pos = $i + length($n);
                }
              }
              else { my $i = index($f, $o); substr($f, $i, length($o)) = $n if $i >= 0; }
              print $f;' < "$EDIT_TARGET" 2>/dev/null)
            if [ $? -ne 0 ]; then
              # An incomplete reconstruction is refused, not screened as a fragment.
              kernel_mandate_deny "edit-unreconstructible $(kernel_mandate_relpath "$EDIT_TARGET")" "[BLOCKED] Role '${ROLE}' may not Edit '$(kernel_mandate_relpath "$EDIT_TARGET")' — the kernel could not work out what the file would become.

${ROLE_HEADER}

This role declares what its code may import or do, and that promise is kept by screening the file's RESULTING content, not the diff. When the result cannot be computed the edit is refused rather than half-checked, because screening the fragment alone is the blindness that screening the result exists to remove.

Options:
  1. Re-read the file and Edit against its current contents.
  2. Author the file afresh with Write, whose whole content is screened."
            fi
          fi
        fi
      fi
      # Screen the fragment first: if only the result trips, the offending line
      # was already in the file, and the message should say so.
      check_code_capabilities "$TARGET" "$CODE"
      check_code_capabilities "$TARGET" "$RESULT_CODE" "
Note: your edit did not introduce this — the file already contains it. Removing that line is the change to make first."
    fi
    ;;
esac

# --- Axis 6: dispatch gate + registry ------------------------------------
# `Agent` and `Task` are the same operation under two host names; the
# rule belongs to the operation.
if [ "$KM_TOOL" = "Agent" ] || [ "$KM_TOOL" = "Task" ]; then
  DESCRIPTION=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
  PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.prompt // ""' 2>/dev/null || echo "")
  DISPATCH_LIST=$(kernel_mandate_role_field "$ROLE" '.dispatch')

  # Which manifest role does the description name? Longest role name
  # wins so 'reviewer' can never shadow 'reviewer-adversarial'.
  TARGET_ROLE=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if printf '%s' "$DESCRIPTION" | grep -Eq "^[[:space:]]*${cand}(-[a-z0-9-]+)?:"; then
      TARGET_ROLE="$cand"; break
    fi
  done < <(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r '.roles | keys[]' 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

  # No dispatch list means no dispatch: handing another agent a role is an
  # authority that must be granted, unlike reading.
  if [ "$DISPATCH_LIST" = "null" ]; then
    kernel_mandate_deny "dispatch-undeclared" "[BLOCKED] Role '${ROLE}' may not dispatch subagents — its manifest entry declares no 'dispatch' list.

${ROLE_HEADER}

Dispatching is how a role hands work, and a ROLE, to another agent. A role that names no dispatchable roles has not been given that authority, so the absence is a refusal rather than a blank cheque: without it there is nothing to check the target against, and an unchecked dispatch can mint a child of any role in this manifest.

The operator grants it explicitly, naming who this role may dispatch:
  \"${ROLE}\": { \"dispatch\": [\"<role>\", \"<role>\"] }

Then the target must be one of those, the description must name it, and the prompt must carry its binding tag."
  fi
  if [ "$DISPATCH_LIST" != "null" ]; then
    ROLE_NAMES=$(printf '%s' "$DISPATCH_LIST" | "$JQ" -r 'join(", ")' 2>/dev/null || echo "")
    if [ -z "$TARGET_ROLE" ]; then
      kernel_mandate_deny "dispatch-unprefixed" "[BLOCKED] Role '${ROLE}' may only dispatch role-tagged subagents, but this description names no manifest role.

${ROLE_HEADER}
Dispatchable roles: ${ROLE_NAMES}

Format the dispatch as:
  description: \"<role>-<slug>: <what this task is>\"
  prompt:      must embed the binding tag <<kernel-mandate-role: <role>>>

Untagged children cannot be bound to a role, so the kernel would have to fall back to the unboundAgentPolicy for every call they make."
    fi
    if ! printf '%s' "$DISPATCH_LIST" | "$JQ" -e --arg t "$TARGET_ROLE" 'index($t) != null' >/dev/null 2>&1; then
      kernel_mandate_deny "dispatch-forbidden $TARGET_ROLE" "[BLOCKED] Role '${ROLE}' may not dispatch role '${TARGET_ROLE}'.

${ROLE_HEADER}
Dispatchable roles: ${ROLE_NAMES}

Dispatch rights are part of the separation of duties — if the workflow needs a '${TARGET_ROLE}', that dispatch belongs to a role holding the grant."
    fi
    # `subagent_type` is what the host spawns, and rung 2b binds the child
    # from it. A type that names a manifest role must be the role the
    # description named; a type no role declares (general-purpose) passes.
    DISPATCH_TYPE=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
    if [ -n "$DISPATCH_TYPE" ]; then
      TYPE_ROLE=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -r --arg t "$DISPATCH_TYPE" \
        'first(.roles | to_entries[] | select(.value.agentTypes // [] | index($t)) | .key) // empty' 2>/dev/null || echo "")
      if [ -n "$TYPE_ROLE" ] && [ "$TYPE_ROLE" != "$TARGET_ROLE" ]; then
        kernel_mandate_deny "dispatch-type-mismatch $TARGET_ROLE!=$TYPE_ROLE" "[BLOCKED] This dispatch names role '${TARGET_ROLE}' in its description but asks the host for subagent_type '${DISPATCH_TYPE}', which this mandate binds to role '${TYPE_ROLE}'.

${ROLE_HEADER}
Dispatchable roles: ${ROLE_NAMES}

The child the host spawns is bound by its agent_type, not by the description — so the description and the type must name the same role. Dispatch '${TYPE_ROLE}' as '${TYPE_ROLE}-<slug>: …' with its own tag (if this role may dispatch it), or use a subagent_type that belongs to '${TARGET_ROLE}'."
      fi
    fi
    # The target's tag may carry an optional #NONCE — accept either form.
    if ! printf '%s' "$PROMPT" | grep -Eq "<<kernel-mandate-role: ${TARGET_ROLE}(#[a-z0-9]{4,})?>>"; then
      kernel_mandate_deny "dispatch-untagged $TARGET_ROLE" "[BLOCKED] This dispatch of role '${TARGET_ROLE}' is missing the binding tag in its prompt.

${ROLE_HEADER}

Add the literal line
  <<kernel-mandate-role: ${TARGET_ROLE}>>
to the subagent prompt (ideally the first line, followed by the role's mandate and ONLY the context its scope covers). The tag is how the kernel binds the child's tool calls to '${TARGET_ROLE}' — without it the child may fall back to the unboundAgentPolicy.

For parallel dispatch, add a unique nonce so binding stays exact even
when several roles run at once: <<kernel-mandate-role: ${TARGET_ROLE}#a1b2c3>>."
    fi
    # Tag purity: exactly one role may be tagged in the prompt (nonce
    # ignored); a second tag makes the child's binding ambiguous.
    # A near miss (`<<kernel-mandate-role:  judge>>`) is also refused: whether
    # it binds depends on a resolver in another file.
    NEAR_TAG=$(printf '%s' "$PROMPT" | kernel_mandate_neartag) \
      || deny_unscreened "dispatch-tag-screen $TARGET_ROLE" "this dispatch's role tags" "Target role: ${TARGET_ROLE}"
    if [ -n "$NEAR_TAG" ]; then
      kernel_mandate_deny "dispatch-malformed-tag" "[BLOCKED] This dispatch's prompt contains something shaped like a binding tag that this kernel cannot parse:

  ${NEAR_TAG}

${ROLE_HEADER}

A binding tag is exactly \`<<kernel-mandate-role: name>>\` or \`<<kernel-mandate-role: name#nonce>>\` — one space after the colon, a lowercase role name, a nonce of four or more characters of [a-z0-9]. Anything else is refused rather than ignored: a tag the gate cannot read is a tag the gate cannot check, and whether it binds anything depends on a resolver this check has no way to consult.

Write the tag exactly:
  <<kernel-mandate-role: ${TARGET_ROLE}>>"
    fi
    FOREIGN_TAGS=$(printf '%s' "$PROMPT" | kernel_mandate_tag_roles | kernel_mandate_grep_or_empty -vxF "${TARGET_ROLE}") \
      || deny_unscreened "dispatch-tag-screen $TARGET_ROLE" "this dispatch's role tags" "Target role: ${TARGET_ROLE}"
    if [ -n "$FOREIGN_TAGS" ]; then
      kernel_mandate_deny "dispatch-foreign-tag $TARGET_ROLE" "[BLOCKED] This dispatch of role '${TARGET_ROLE}' embeds binding tag(s) for a DIFFERENT role in its prompt:

$(printf '%s' "$FOREIGN_TAGS" | sed 's/^/  /')

${ROLE_HEADER}

A dispatch prompt must carry exactly one role tag — the target's. Foreign tags poison the child's role binding. Remove them (quote a role NAME in prose if you must reference another role, never its <<kernel-mandate-role: …>> tag form)."
    fi
  fi

  # Extract the target's optional nonce so the child can bind exactly by
  # it (resolve rung 4a), then record the dispatch. Runs for
  # ungoverned-dispatch-list roles too, so the child can still bind.
  DISPATCH_NONCE=$(printf '%s' "$PROMPT" | grep -oE "<<kernel-mandate-role: ${TARGET_ROLE}#[a-z0-9]{4,}>>" \
    | head -n1 | sed -E 's/.*#([a-z0-9]+)>>$/\1/' || true)
  [ -n "$TARGET_ROLE" ] && kernel_mandate_register_dispatch "$TARGET_ROLE" "$KM_TOOL_USE_ID" "$DISPATCH_NONCE"
fi

# --- Axis 7: skill gate --------------------------------------------------
if [ "$KM_TOOL" = "Skill" ]; then
  SKILLS_ALLOW=$(kernel_mandate_role_field "$ROLE" '.skills.allow')
  if [ "$SKILLS_ALLOW" != "null" ]; then
    SKILL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // ""' 2>/dev/null || echo "")
    if ! tool_matches_any "$SKILL_NAME" "$SKILLS_ALLOW"; then
      kernel_mandate_deny "skill-not-allowed $SKILL_NAME" "[BLOCKED] Role '${ROLE}' may not invoke the skill '${SKILL_NAME}'.

${ROLE_HEADER}
Granted skills: $(printf '%s' "$SKILLS_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)"
    fi
  fi
fi

# --- Axis 8: MCP argument path-scoping -----------------------------------
# An MCP tool's argument shape is its own, so settings.mcpPathArguments
# names which arguments carry paths, and those are held to the same
# read/write scopes as the core tools. Unmapped MCP tools stay name-gated
# (axis 2): grant file-mutating MCP tools only to roles that own the effect.
MCP_MAP=$(printf '%s' "$KM_MANIFEST_JSON" | "$JQ" -c '.settings.mcpPathArguments // {}' 2>/dev/null || echo "{}")
if [ "$MCP_MAP" != "{}" ] && [ -n "$MCP_MAP" ]; then
  # Which mapping entries apply to this tool name (shell-glob match)?
  MCP_FIELDS_READ=""
  MCP_FIELDS_WRITE=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$KM_TOOL" in
      $pat)
        MCP_FIELDS_READ="$MCP_FIELDS_READ$(printf '%s' "$MCP_MAP" | "$JQ" -r --arg p "$pat" '(.[$p].read // [])[]' 2>/dev/null)"$'\n'
        MCP_FIELDS_WRITE="$MCP_FIELDS_WRITE$(printf '%s' "$MCP_MAP" | "$JQ" -r --arg p "$pat" '(.[$p].write // [])[]' 2>/dev/null)"$'\n'
        ;;
    esac
  done < <(printf '%s' "$MCP_MAP" | "$JQ" -r 'keys[]' 2>/dev/null)

  # scope_mcp_field <axis:read|write> <dot-path> — pull the value(s) at
  # tool_input.<dot-path> (array values are checked element-wise) and run
  # each through the same scope check the core tools use.
  scope_mcp_field() {
    local axis="$1" field="$2" vals
    [ -n "$field" ] || return 0
    vals=$(printf '%s' "$INPUT" | "$JQ" -r --arg f "$field" '
      def pick($o; $parts): reduce $parts[] as $k ($o; if . == null then null else .[$k]? end);
      (.tool_input // {}) as $ti
      | pick($ti; ($f | split(".")))
      | if . == null then empty
        elif type == "array" then .[] | select(type == "string")
        elif type == "string" then .
        else empty end' 2>/dev/null || echo "")
    local v
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      # Only a remote scheme is exempt; `file://` is unwrapped and scoped.
      # The scheme test is the shared case-insensitive one (RFC 3986).
      kernel_mandate_is_network_url "$v" && continue
      case "$v" in
        data:*|DATA:*|Data:*) continue ;;
        file://*|FILE://*|File://*) v="${v#*://}"; [ "${v#/}" = "$v" ] && v="/$v" ;;
      esac
      kernel_mandate_is_manifest_path "$v" && [ "$axis" = "read" ] && continue
      # Self-protection, on the third write channel: a config role whose scope
      # covers `.claude/**` must not rewrite the file that says what it may do.
      [ "$axis" = "write" ] && self_protect_target "$v" "self-protect mcp write via ${KM_TOOL}"
      # And the code screen: a mapped MCP write is an authoring route.
      if [ "$axis" = "write" ]; then
        MCP_CONTENT=$(printf '%s' "$INPUT" | "$JQ" -r '
          (.tool_input // {}) | (.content // .contents // .text // .body // .data // empty)
          | if type == "string" then . else empty end' 2>/dev/null || echo "")
        [ -n "$MCP_CONTENT" ] && check_code_capabilities "$v" "$MCP_CONTENT"
      fi
      check_path_scope "$axis" "$v" \
        "$([ "$axis" = "write" ] && echo "write" || echo "read") via ${KM_TOOL}"
    done <<< "$vals"
  }

  while IFS= read -r field; do scope_mcp_field read "$field"; done <<< "$MCP_FIELDS_READ"
  while IFS= read -r field; do scope_mcp_field write "$field"; done <<< "$MCP_FIELDS_WRITE"
fi

exit 0
