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
  [ "$code" -eq 0 ] && return 0
  [ "${HOS_DECIDED:-0}" = "1" ] && return 0
  printf '%s\n' "[harness-os] INTERNAL ERROR: the role gate exited $code before reaching a decision." >&2
  printf '%s\n' "[harness-os] Refusing to treat that as permission. Re-run with bash -x to see where, or set HARNESS_OS=0 to bypass the kernel deliberately." >&2
  exit "$code"
}
trap harness_os__on_exit EXIT

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
          [ -n "$UNBOUND_TARGET" ] || exit 0
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
      # The INSTALLED kernel is the root of trust wherever it lives. A
      # project-local install sits in node_modules, which no self-protect
      # list covered — a role could truncate the hook and disable every
      # boundary on the next call.
      case "$NORM_TARGET" in
        */harness-os/hooks/*|*/.claude/hooks/*|*/harness-os-role-gate.sh|*/lib/harness-os.sh)
          harness_os_deny "self-protect write kernel $TARGET" "$SELF_PROTECT_MSG" ;;
      esac
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
    PROT_RE='(harness-os\.(json|state)|(^|[^a-zA-Z0-9_.-])\.claude(/|$))'
    if printf '%s' "$CMD" | grep -Eq ">>?[[:space:]]*[^[:space:]|&;]*${PROT_RE}"; then
      harness_os_deny "self-protect bash redirect" "$SELF_PROTECT_MSG"
    fi
    if printf '%s' "$CMD" | grep -Eq "(^|[;&|][[:space:]]*|[[:space:]])(rm|rmdir|unlink|mv|cp|tee|truncate|shred|dd|install|ln|chmod|chown)([[:space:]]+(-[^[:space:]]+|if=[^[:space:]]+))*[[:space:]]+[^;|&]*${PROT_RE}"; then
      harness_os_deny "self-protect bash mutate" "$SELF_PROTECT_MSG"
    fi
    if printf '%s' "$CMD" | grep -Eq "sed[[:space:]]+-[a-zA-Z]*i[^;|&]*${PROT_RE}"; then
      harness_os_deny "self-protect bash sed-i" "$SELF_PROTECT_MSG"
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
  case "$rel" in
    *.js|*.mjs|*.cjs|*.ts|*.mts|*.cts|*.tsx|*.jsx|*.py|*.rb|*.sh|*.bash|*.zsh|*.pl|*.php|*.ipynb|*.lua|*.ps1) : ;;
    *) return 0 ;;
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
  LOAD='(require|import|createRequire\([^)]*\)|process\.getBuiltinModule|process\.binding|module\.constructor\._load|constructor\.constructor|Deno\.|Bun\.)'
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
  elif printf '%s' "$CODE_N" | grep -Eq "\b(request|apiRequest|context)\.(get|post|put|patch|delete|fetch|head)[[:space:]]*\([[:space:]]*[\"'\`]?[a-zA-Z][a-zA-Z0-9+.-]*://|\bsendBeacon[[:space:]]*\(|\bnavigator\.sendBeacon\b"; then
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
  if [ -z "$CAP_ID" ]; then
    local fw_lit fw_abs fw_rel fw_dir
    fw_dir=$(dirname "$(harness_os_normalize_path "$target")")
    while IFS= read -r fw_lit; do
      [ -n "$fw_lit" ] || continue
      case "$fw_lit" in *://*) continue ;; esac
      case "$fw_lit" in /*) fw_abs="$fw_lit" ;; *) fw_abs="$fw_dir/$fw_lit" ;; esac
      fw_rel=$(harness_os_relpath "$fw_abs")
      local fw_scope; fw_scope=$(harness_os_role_field "$ROLE" ".read.allow")
      if [ "$fw_scope" != "null" ] && harness_os_path_in_scope "$fw_rel" "$fw_scope"; then continue; fi
      CAP_ID='fs'; CAP_WHAT="a test-framework file API naming '$fw_rel', which is outside this role's read scope — the framework opens it directly, with no host module for a scope check to see"
      break
    done < <(printf '%s' "$CODE_N" \
      | grep -oE "\.attach[[:space:]]*\([^)]*\bpath[[:space:]]*:[[:space:]]*\"[^\"]+\"|\.setInputFiles[[:space:]]*\([^)]*\"[^\"]+\"" 2>/dev/null \
      | sed -E 's/.*"([^"]+)".*/\1/')
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
      case "$spec" in ./*|../*|/*|'') continue ;; esac   # relative/absolute: not a package
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
      | grep -vE '^\.{1,2}/|^/' \
      | sed -E 's|^(@[^/]+/[^/]+).*|\1|; t; s|^([^/]+)/.*|\1|' | sort -u)
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
if [ "$HOS_TOOL" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null || echo "")
  BASH_SPEC=$(harness_os_role_field "$ROLE" '.bash')
  BASH_UNRESTRICTED=$(printf '%s' "$HOS_MANIFEST_JSON" | "$JQ" -r --arg r "$ROLE" '.roles[$r].bash.unrestricted // false' 2>/dev/null || echo "false")
  # Named indirection constructs this role may use despite the built-in
  # denies (see axis 3a). Granular by design: permitting one construct
  # never waives the others.
  BASH_PERMIT=$(harness_os_role_field "$ROLE" '.bash.permit')

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
      elif printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(python[0-9.]*|node|nodejs|ruby|perl|php|deno|bun)([[:space:]][^;|&]*)?[[:space:]](-c|-e|-p|--eval|--print)([[:space:]]|$)'; then BUILTIN_ID='interpreter-inline'; BUILTIN_HIT='interpreter one-liner (-c/-e/-p) — arbitrary code the patterns cannot see'
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
        -o|-O)
          # `find … -fprintf FILE FORMAT` and `sort -o FILE` both put the
          # file first, so the next word is the target either way.
          case "${SEG_WORDS[0]}" in
            sort|cc|gcc|g++|clang|clang++|ld|objcopy|objdump|tar|curl|wget|ffmpeg|pandoc|openssl|tsc|esbuild|rustc|javac|go)
              __fw=1 ;;
          esac ;;
        -o*|-O*)
          case "${SEG_WORDS[0]}" in
            cc|gcc|g++|clang|clang++|curl|wget) FLAG_TARGETS="${FLAG_TARGETS}${__w#-?}"$'\n' ;;
          esac ;;
      esac
    done
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
      NORM_WT="$(harness_os_normalize_path "$target")"
      case "$NORM_WT" in
        "$NORM_MANIFEST"|"$NORM_STATE_DIR"|"$NORM_STATE_DIR"/*)
          harness_os_deny "self-protect bash write-target $target" "$SELF_PROTECT_MSG" ;;
      esac
      case "$(harness_os_relpath "$target")" in
        .claude/harness-os.json|.claude/harness-os.state|.claude/harness-os.state/*|.claude/settings.json|.claude/settings.local.json|.claude/hooks/*)
          harness_os_deny "self-protect bash write-target $target" "$SELF_PROTECT_MSG" ;;
      esac
      case "$NORM_WT" in
        */harness-os/hooks/*|*/.claude/hooks/*|*/harness-os-role-gate.sh|*/lib/harness-os.sh)
          harness_os_deny "self-protect bash write-target kernel $target" "$SELF_PROTECT_MSG" ;;
      esac
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
      case "${SEG_WORDS[0]:-}" in
        grep|egrep|fgrep|rgrep|rg|ag|ack|ripgrep)
          # -e PAT / -f FILE change the grammar: with either present there
          # is no positional pattern, and -f's operand is a real file read.
          __has_pat_flag=0; __skip_next=0; __pat_idx=""
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            __w="${SEG_WORDS[$__i]}"
            if [ "$__skip_next" = "1" ]; then __skip_next=0; continue; fi
            case "$__w" in
              -e|--regexp) __has_pat_flag=1; TOK_SKIP="${TOK_SKIP}$((__i + 1)) "; __skip_next=1; continue ;;
              -f|--file)   __has_pat_flag=1; __skip_next=1; continue ;;
              -e*|--regexp=*) __has_pat_flag=1; continue ;;
              -f*|--file=*)   __has_pat_flag=1; continue ;;
              -*) continue ;;
            esac
            [ -n "$__pat_idx" ] || __pat_idx="$__i"
          done
          [ "$__has_pat_flag" = "0" ] && [ -n "$__pat_idx" ] && TOK_SKIP="${TOK_SKIP}${__pat_idx} "
          ;;
        jq|yq|gojq|jaq)
          # jq's first operand is a FILTER, and the commonest filter of
          # all is `.` — which resolves to the cwd and was denied as an
          # out-of-scope read. An inspector piping the page repository
          # through `jq .` is doing the most ordinary thing its mandate
          # describes, and being refused for it.
          __skip_next=0
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            __w="${SEG_WORDS[$__i]}"
            if [ "$__skip_next" = "1" ]; then __skip_next=0; continue; fi
            case "$__w" in
              --arg|--argjson|--slurpfile|--rawfile|--args|--jsonargs|--indent) __skip_next=1; continue ;;
              -f|--from-file) __skip_next=1; continue ;;   # value IS a file: stays checked
              -*) continue ;;
            esac
            TOK_SKIP="${TOK_SKIP}${__i} "; break
          done
          ;;
        sed|awk|gawk|mawk)
          # The first positional operand is the program text; the rest are
          # input files and stay scope-checked.
          __skip_next=0
          for __i in "${!SEG_WORDS[@]}"; do
            [ "$__i" = "0" ] && continue
            __w="${SEG_WORDS[$__i]}"
            if [ "$__skip_next" = "1" ]; then __skip_next=0; continue; fi
            case "$__w" in
              -e|-f|--expression|--file|-v) __skip_next=1; continue ;;
              -*) continue ;;
            esac
            TOK_SKIP="${TOK_SKIP}${__i} "; break
          done
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
          *://*) continue ;;           # URL, never a local file
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
          -*) continue ;;              # valueless flag/option
          *=*) continue ;;             # NAME=value env assignment: the
                                       # value is data for the command,
                                       # not a file it opens, and
                                       # PLAYWRIGHT_BROWSERS_PATH=/opt/…
                                       # is ordinary setup, not a read.
        esac
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
    # Glob's `pattern` IS a path glob, so it is checked there.
    if [ "$HOS_TOOL" = "Glob" ]; then
      PATH_FIELDS=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.pattern // empty, .tool_input.glob // empty' 2>/dev/null)
    else
      PATH_FIELDS=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.glob // empty' 2>/dev/null)
    fi
    SEARCH_PAT=""
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      case "$cand" in
        */..|*/../*|../*|..) SEARCH_PAT="$cand" ;;   # climbs out of the root
        /*|"~"*)             SEARCH_PAT="$cand" ;;   # absolute / home — ignores the root
      esac
      [ -n "$SEARCH_PAT" ] && break
    done <<< "$PATH_FIELDS"
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
            RESULT_CODE=$(OLD_S="$OLD_S" NEW_S="$CODE" ALL="$REPL_ALL" perl -0777 -e '
              local $/; my $f = <STDIN>;
              my ($o, $n, $all) = ($ENV{OLD_S}, $ENV{NEW_S}, $ENV{ALL} eq "true");
              if ($all) { my $i; while (($i = index($f, $o)) >= 0) { substr($f, $i, length($o)) = $n; } }
              else { my $i = index($f, $o); substr($f, $i, length($o)) = $n if $i >= 0; }
              print $f;' < "$EDIT_TARGET" 2>/dev/null || printf '%s' "$CODE")
            [ -n "$RESULT_CODE" ] || RESULT_CODE="$CODE"
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
    FOREIGN_TAGS=$(printf '%s' "$PROMPT" | grep -oE "$HOS_ROLE_TAG_RE" \
      | sed -E 's/^<<harness-os-role: ([a-z][a-z0-9-]*)(#[a-z0-9]+)?>>$/\1/' \
      | sort -u | grep -vxF "${TARGET_ROLE}" || true)
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
      case "$v" in
        http://*|https://*|ws://*|wss://*|ftp://*|data:*) continue ;;
        file://*) v="${v#file://}"; [ "${v#/}" = "$v" ] && v="/$v" ;;
      esac
      harness_os_is_manifest_path "$v" && [ "$axis" = "read" ] && continue
      check_path_scope "$axis" "$(harness_os_relpath "$v")" \
        "$([ "$axis" = "write" ] && echo "write" || echo "read") via ${HOS_TOOL}"
    done <<< "$vals"
  }

  while IFS= read -r field; do scope_mcp_field read "$field"; done <<< "$MCP_FIELDS_READ"
  while IFS= read -r field; do scope_mcp_field write "$field"; done <<< "$MCP_FIELDS_WRITE"
fi

exit 0
