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
# enforces the role's grants along six axes:
#
#   1. self-protection  — no governed context touches the manifest/state
#   2. tool gate        — tools.deny / tools.allow (shell-glob names)
#   3. bash gate        — every command segment must match the role's
#                         command groups; read-only roles get a built-in
#                         deny on file-redirect shapes
#   4. read scope       — Read/Glob/Grep/NotebookRead path globs
#   5. write scope      — Write/Edit/NotebookEdit path globs (opt-in)
#   6. dispatch gate    — Agent calls: target role must be in the
#                         caller's dispatch list, description must be
#                         role-prefixed, prompt must carry the
#                         <<harness-os-role: NAME>> binding tag; the
#                         dispatch is recorded so the child can bind
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

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || { echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found." >&2; exit 1; }

INPUT=$(cat)

# shellcheck source=lib/harness-os.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness-os.sh"

harness_os_load "$INPUT" || exit 0   # project has not opted in — silent allow

MANIFEST_REF="Manifest: ${HOS_MANIFEST}
Docs:     skills/harness-designer/references/architecture.md"

# ---------------------------------------------------------------------------
# Broken manifest — fail closed on mutation, open on inspection/repair.
# ---------------------------------------------------------------------------
if [ "${HOS_MANIFEST_BROKEN:-0}" = "1" ]; then
  case "$HOS_TOOL" in
    Read|Glob|Grep|NotebookRead|TaskGet|TaskList) exit 0 ;;
    Write|Edit)
      # Permit repairing the manifest itself; deny other writes.
      FILE_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
      [ "$FILE_PATH" = "$HOS_MANIFEST" ] && exit 0
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
        Read|Glob|Grep|NotebookRead|TaskGet|TaskList) exit 0 ;;
      esac
      ;;
  esac
  harness_os_deny "unbound tool=$HOS_TOOL policy=$POLICY" "[BLOCKED] This subagent's harness-OS role could not be resolved, and the manifest's unboundAgentPolicy (\"$POLICY\") does not permit '$HOS_TOOL'.

${MANIFEST_REF}

A subagent binds to a role when its dispatch carried a role-prefixed description (\"<role>-<slug>: ...\") and the prompt embedded the binding tag <<harness-os-role: NAME>>. Resolution can still be ambiguous when DIFFERENT roles are dispatched in parallel — serialise role-heterogeneous dispatch waves, or return now and let the orchestrator re-dispatch this task with a properly tagged brief."
fi

# ---------------------------------------------------------------------------
# Governed context — enforce the role's grants.
# ---------------------------------------------------------------------------
ROLE="$HOS_ROLE"
ROLE_DESC=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '.roles[$r].description // ""' 2>/dev/null || echo "")
ROLE_HEADER="Role:     ${ROLE} — ${ROLE_DESC}
${MANIFEST_REF}"

# --- Axis 1: self-protection --------------------------------------------
# The manifest and the kernel's state dir are the root of trust; no
# governed role may mutate them through any channel. Changes go through
# an operator design session (HARNESS_OS=0) or a hand edit.
SELF_PROTECT_MSG="[BLOCKED] Role '${ROLE}' attempted to modify the harness OS itself.

${ROLE_HEADER}

The manifest, .claude/harness-os.state/, and the project's .claude/settings*/hooks (which register this kernel) are the root of trust for every role boundary — no governed role may change them, whatever its other grants. To redesign the harness: ask the operator to relaunch with HARNESS_OS=0 (or edit the manifest outside the session), ideally via the harness-designer skill."

NORM_MANIFEST="$(harness_os_normalize_path "$HOS_MANIFEST")"
NORM_STATE_DIR="$(harness_os_normalize_path "$HOS_STATE_DIR")"

case "$HOS_TOOL" in
  Write|Edit|NotebookEdit)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    if [ -n "$TARGET" ]; then
      NORM_TARGET=$(harness_os_normalize_path "$TARGET")
      case "$NORM_TARGET" in
        "$NORM_MANIFEST"|"$NORM_STATE_DIR"|"$NORM_STATE_DIR"/*) harness_os_deny "self-protect write $TARGET" "$SELF_PROTECT_MSG" ;;
      esac
      REL_TARGET=$(harness_os_relpath "$TARGET")
      case "$REL_TARGET" in
        .claude/harness-os.json|.claude/harness-os.state|.claude/harness-os.state/*|.claude/settings.json|.claude/settings.local.json|.claude/hooks|.claude/hooks/*)
          harness_os_deny "self-protect write $TARGET" "$SELF_PROTECT_MSG" ;;
      esac
    fi
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null || echo "")
    # Mention of the manifest/state — or of the .claude config dir that
    # holds them — in a write-shaped command → deny. Reads pass to the
    # normal bash axis. Quote-blind, protective direction: `rm -rf
    # .claude` must not escape just because it never says "harness-os".
    if printf '%s' "$CMD" | grep -Eq 'harness-os\.(json|state)|(^|[^a-zA-Z0-9_.-])\.claude([/"'"'"'[:space:]]|$)'; then
      if printf '%s' "$CMD" | grep -Eq '(^|[;&| ])(rm|rmdir|unlink|mv|cp|tee|truncate|shred|dd|install|ln)[[:space:]]|>[[:space:]]*[^&[:space:]]|sed[[:space:]]+(-[a-zA-Z]*i)|chmod|chown' ; then
        harness_os_deny "self-protect bash" "$SELF_PROTECT_MSG"
      fi
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

# --- Axis 3: bash command gate ------------------------------------------
# Bash is the widest laundering channel a role has, so this axis carries
# most of the leak-proofing: quote-blind segmentation over EVERY command
# separator, a built-in deny list for indirection constructs no allow
# pattern can safely coexist with, write-target checks on redirections,
# and a read-scope check over every token that resolves to a real file.
# Everywhere the axis guesses, it guesses toward deny-with-guidance.
if [ "$HOS_TOOL" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null || echo "")
  BASH_SPEC=$(harness_os_role_field "$ROLE" '.bash')
  BASH_UNRESTRICTED=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '.roles[$r].bash.unrestricted // false' 2>/dev/null || echo "false")

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
  # arrive verbatim), && || ; | and the single '&' (background). Quote-
  # blind: an over-split segment can only cause a deny, never an allow.
  # Then strip leading env-var assignments and grouping punctuation and
  # require EVERY non-empty segment to clear every check below.
  SEGMENTS=$(printf '%s' "$CLEAN" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g' -e 's/&/\n/g')
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]({]+//; s/[[:space:])}]+$//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
    [ -n "$seg" ] || continue

    # 3a. Built-in indirection denies. Each of these constructs lets a
    # segment that MATCHES an allow pattern execute something that was
    # never checked ($(…) and $VAR indirection, `| sh`, find -exec,
    # xargs, interpreter one-liners, cd un-anchoring every relative
    # path, brace expansion concealing a filename). No allow pattern
    # can be safe alongside them, so they are denied for every governed
    # role. Escape hatch: bash.unrestricted: true in the manifest
    # (schema documents the cost).
    if [ "$BASH_UNRESTRICTED" != "true" ]; then
      BUILTIN_HIT=""
      if printf '%s' "$seg" | grep -q '\$'; then BUILTIN_HIT='variable/command substitution ($…) — expansion executes or reads things no pattern checked'
      elif printf '%s' "$seg" | grep -q '`'; then BUILTIN_HIT='backtick command substitution'
      elif printf '%s' "$seg" | grep -Eq '<\(|>\('; then BUILTIN_HIT='process substitution <(…)/>(…)'
      elif printf '%s' "$seg" | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)'; then BUILTIN_HIT='eval'
      elif printf '%s' "$seg" | grep -Eq '(^|[[:space:]])xargs([[:space:]]|$)'; then BUILTIN_HIT='xargs — arguments become an unchecked command'
      elif printf '%s' "$seg" | grep -Eq '^(source[[:space:]]|\.[[:space:]])'; then BUILTIN_HIT='sourcing a script into the shell'
      elif printf '%s' "$seg" | grep -Eq '^(ba|z|da|k|fi)?sh([[:space:]]|$)'; then BUILTIN_HIT='a shell as the command — its input becomes an unchecked script'
      elif printf '%s' "$seg" | grep -Eq -- '-exec(dir)?([[:space:]]|$)|-delete([[:space:]]|$)'; then BUILTIN_HIT='find -exec/-execdir/-delete — executes/deletes outside the pattern check'
      elif printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(python[0-9.]*|node|nodejs|ruby|perl|php|deno|bun)([[:space:]][^;|&]*)?[[:space:]](-c|-e|-p|--eval|--print)([[:space:]]|$)'; then BUILTIN_HIT='interpreter one-liner (-c/-e/-p) — arbitrary code the patterns cannot see'
      elif printf '%s' "$seg" | grep -Eq '^(cd|pushd|popd)([[:space:]]|$)'; then BUILTIN_HIT='cd/pushd/popd — un-anchors every relative path this axis checks'
      elif printf '%s' "$seg" | grep -Eq '\{[^{}[:space:]]*,[^{}[:space:]]*\}'; then BUILTIN_HIT='brace expansion {a,b} — conceals the expanded filename from every check'
      fi
      if [ -n "$BUILTIN_HIT" ]; then
        harness_os_deny "bash-builtin-deny" "[BLOCKED] Role '${ROLE}' may not run this command — the segment '$seg' uses ${BUILTIN_HIT}.

${ROLE_HEADER}

Command: ${CMD}

These constructs are denied for every governed role because they let a command that matches an allow pattern do something the pattern never checked. Express the operation directly (one plain command per step, granted tools for file writes), or ask the operator — the manifest can set bash.unrestricted for a role that genuinely needs raw shell, at the cost of every bash guarantee."
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
    # groups (skipped when the role has no bash section at all).
    if [ "$BASH_SPEC" != "null" ] && [ "$BASH_UNRESTRICTED" != "true" ]; then
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

    # 3d. Redirect / tee write targets. A '>' that survived the
    # fd-noise mask is a real file write: a role with no write grants
    # may not perform it at all, and a role WITH write grants may only
    # aim it inside its write scope — bash must not launder writes past
    # the Write/Edit axis for anyone.
    REDIR_TARGETS=$(printf '%s' "$seg" | grep -oE '>>?[[:space:]]*[^[:space:]<>;&]+' 2>/dev/null | sed -E 's/^>>?[[:space:]]*//' || true)
    if printf '%s' "$seg" | grep -Eq '^tee([[:space:]]|$)'; then
      TEE_TARGETS=$(printf '%s' "$seg" | tr ' ' '\n' | tail -n +2 | grep -vE '^-' || true)
      REDIR_TARGETS=$(printf '%s\n%s' "$REDIR_TARGETS" "$TEE_TARGETS")
    fi
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      target=$(printf '%s' "$target" | tr -d '"'"'")
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
      TOKCOPY=$(printf '%s' "$seg" | tr -d '"'"'" | sed -E 's/>>?/ /g')
      TOK_N=0
      set -f
      for tok in $TOKCOPY; do
        TOK_N=$((TOK_N + 1)); [ "$TOK_N" -gt 100 ] && break
        case "$tok" in
          -*) continue ;;              # flag/option
          *://*) continue ;;           # URL, never a local file
          *=*) continue ;;             # key=value argument
        esac
        case "$tok" in "~") tok="$HOME" ;; "~/"*) tok="$HOME/${tok#\~/}" ;; esac
        # NB: no `--` before the pattern — `compgen -G -- x` silently
        # matches nothing (bash quirk). Flag-shaped tokens are already
        # skipped above, so bare -G is safe. compgen echoes a
        # metacharacter-free pattern back even when it matches nothing,
        # so every candidate is confirmed with a real existence test
        # below before it can trigger a deny.
        MATCHES=$(cd "$HOS_CWD" 2>/dev/null && compgen -G "$tok" 2>/dev/null || true)
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
      done
      set +f
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
  Glob|Grep)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.path // empty' 2>/dev/null || echo "")
    # No path → the search runs from the repo root; scoped roles are
    # expected to search INSIDE their scope, so root needs a root-wide
    # grant.
    [ -n "$TARGET" ] || TARGET="$HOS_ROOT"
    check_path_scope read "$(harness_os_relpath "$TARGET")" "search"
    ;;
  Write|Edit|NotebookEdit)
    TARGET=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")
    [ -n "$TARGET" ] && check_path_scope write "$(harness_os_relpath "$TARGET")" "write"
    ;;
esac

# --- Axis 6: dispatch gate + registry ------------------------------------
if [ "$HOS_TOOL" = "Agent" ]; then
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
    if ! printf '%s' "$PROMPT" | grep -qF "<<harness-os-role: ${TARGET_ROLE}>>"; then
      harness_os_deny "dispatch-untagged $TARGET_ROLE" "[BLOCKED] This dispatch of role '${TARGET_ROLE}' is missing the binding tag in its prompt.

${ROLE_HEADER}

Add the literal line
  <<harness-os-role: ${TARGET_ROLE}>>
to the subagent prompt (ideally the first line, followed by the role's mandate and ONLY the context its scope covers). The tag is how the kernel binds the child's tool calls to '${TARGET_ROLE}' — without it the child may fall back to the unboundAgentPolicy."
    fi
    # Tag purity: exactly one role's tag may appear in the prompt. A
    # second, foreign tag would make the child's transcript ambiguous by
    # construction, forcing every child of this dispatch to the
    # unbound fallback — or worse, seeding a mis-binding.
    FOREIGN_TAGS=$(printf '%s' "$PROMPT" | grep -oE "$HOS_ROLE_TAG_RE" | sort -u | grep -vF "<<harness-os-role: ${TARGET_ROLE}>>" || true)
    if [ -n "$FOREIGN_TAGS" ]; then
      harness_os_deny "dispatch-foreign-tag $TARGET_ROLE" "[BLOCKED] This dispatch of role '${TARGET_ROLE}' embeds binding tag(s) for a DIFFERENT role in its prompt:

$(printf '%s' "$FOREIGN_TAGS" | sed 's/^/  /')

${ROLE_HEADER}

A dispatch prompt must carry exactly one role tag — the target's. Foreign tags poison the child's role binding. Remove them (quote a role NAME in prose if you must reference another role, never its <<harness-os-role: …>> tag form)."
    fi
  fi

  # Record the dispatch (also for ungoverned-dispatch-list roles and any
  # recognised prefix) so the child can bind via the registry rung.
  [ -n "$TARGET_ROLE" ] && harness_os_register_dispatch "$TARGET_ROLE" "$HOS_TOOL_USE_ID"
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

exit 0
