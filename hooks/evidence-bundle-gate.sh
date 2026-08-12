#!/bin/bash
# evidence-bundle-gate.sh — a QA verdict without evidence is an opinion, and a
#                           bundle with a live credential in it is a leak.
#
# Hook    : PreToolUse:mcp__.*  (tracker mutation tools)
#           PreToolUse:Bash     (`gh pr create|ready` — entry B's sign-off boundary)
# Mode    : DENY  (terminal transition / PR publish with no evidence bundle for
#                  THIS ticket — sign-off is the moment the evidence must exist)
#           DENY  (an unredacted secret in a captured HAR or console log, on ANY
#                  gated surface including comments — see "Why secrets DENY
#                  everywhere" below)
#           WARN  (verdict-shaped comment with no bundle — the report can still
#                  be useful, it just must not read as evidence-backed)
#           silent allow (protocol inactive; non-tracker tools; tracker reads;
#                  a bundle for this ticket exists and carries no live secret)
# State   : reads only. Scans <workspace>/**/evidence/<ticket>*/ (and
#           $ACHILLES_EVIDENCE_DIR when set). This gate never authors the thing
#           it checks.
# Env     : WORKSPACE_ROOT          — defaults to git toplevel of cwd
#           ACHILLES_EVIDENCE_DIR   — extra directory to search for bundles,
#                                     for projects whose evidence lives outside
#                                     the repo
#           CIVITAS_DISABLE_EVIDENCE_GATE=1 disables the hook. Deliberately NOT
#           repeated in the denial message, for the same reason its sibling
#           adversarial-verification-gate.sh does not: a gate that prints its
#           own bypass at the moment of maximum frustration lives in someone's
#           shell profile by the end of week one.
#
# Rule
# ----
# `ticket-driven-testing` §"The Contract" requires five deliverables per ticket,
# item 3 of which is "an evidence bundle — via companion-mode". This gate binds
# that requirement to the actions that constitute sign-off, PER TICKET: a
# transition to a completed state, a published (non-draft) PR, and — as a warn —
# a verdict-shaped tracker comment. A bundle belonging to a DIFFERENT ticket
# does not satisfy it. That per-ticket binding is the mechanical half of the
# skill's §0 re-entry rule: one ticket, one run.
#
# The gate additionally refuses to let a sign-off proceed while a captured
# `network.har` / `console.log` in the matched bundle still carries an
# unredacted credential — `companion-mode` §"Redaction" mandates that pass and
# nothing enforced it.
#
# Why
# ---
# Observed failure, and the reason this hook exists rather than another
# paragraph of markdown:
#
#   A session invoked `ticket-driven-testing` for one ticket and followed it
#   properly. The operator then moved to a SECOND ticket in the same session.
#   The agent treated the skill as "already loaded", ran an ad-hoc verification
#   instead of the sequence, and posted a verdict to the tracker with measured
#   numbers and ZERO artifacts — no screenshots, no recording, no trace, no
#   bundle. Nothing objected. When the same work was redone under
#   `companion-mode` it immediately surfaced two defects the ad-hoc path had
#   missed: artifact paths that collided so a second environment's run silently
#   overwrote the first's video/trace/HAR, and a live deployment
#   protection-bypass token sitting unredacted in the captured HARs.
#
# The skill's activation is intent-triggered, and the agent's own judgement was
# the only thing that could re-fire it. Judgement is exactly what a second
# ticket erodes: the skill IS loaded, the transcript DOES contain the method, so
# "I already did this" is a locally reasonable inference and a globally wrong
# one. A gate keyed on the ACTION does not care what the agent inferred.
#
# HONEST SCOPE — read this before relying on the gate. In the origin story above
# the artifact-free verdict was posted as a tracker COMMENT, and this gate WARNs
# on comments; it does not block them. What it would have blocked is the
# terminal transition and the published PR that follow. Adversarial review made
# that point sharply and it is correct: on the comment surface this is an
# advisory, which is the same class of thing the "Why" paragraph argues is
# insufficient. The grading is deliberate (see below) but it is a trade, not a
# win, and the narrative should not imply otherwise.
#
# Why secrets DENY everywhere, including comments
# -----------------------------------------------
# The missing-bundle case is graded (DENY terminal / WARN comment) because it
# has a legitimate outcome: `ticket-driven-testing` §"Prerequisites" says a run
# against an unreachable app "stops at the diff review, which is still worth
# doing". A bundle-less verdict CAN be honest, so long as it says so — and a
# hard block there would push an honest report into either dishonesty or a
# disabled hook.
#
# An unredacted live credential in a captured artifact has no such outcome.
# There is no run for which the right answer is "ship it with the token in it",
# and the remedy costs about thirty seconds. So that branch denies on every
# gated surface, comments included — the comment is usually where the bundle's
# path gets published to the tracker in the first place.
#
# Deliberately NOT enforced — the honest limits
# ---------------------------------------------
# Every item below was found by adversarial review of this hook, reproduced,
# and left in place with a reason. A limits list that omits the limits the
# reviewer found is worse than no list.
#
# * **Staleness.** Its sibling gate requires the receipt to be newer than the
#   newest spec. That check is WRONG here and is deliberately absent: the
#   skill's own order runs the evidence bundle at §6 and writes the durable
#   tests at §7, so a correct bundle ALWAYS predates the specs. A staleness rule
#   would make this gate permanently unpassable.
# * **That the bundle is honest.** The bundle is authored by the same actor the
#   gate judges, in a directory no protected-artifact guard covers. Fabricating
#   one that satisfies this gate is `mkdir -p x/screenshots && touch
#   x/summary.md x/screenshots/a.png` — three empty files. Cross-ticket reuse is
#   one `ln -s`; symlinked bundles are accepted, because legitimate setups
#   symlink evidence out of the repo. So this raises the cost of *forgetting*,
#   and barely raises the cost of *faking*. It is a speed bump, not a control.
#   Making it sound needs a hook-authored, hash-chained manifest on the
#   protected list — the pattern ledger-integrity-chain.sh already implements.
# * **Jira transitions identified only by numeric id.** `transitionJiraIssue`
#   sends `{"transition":{"id":"31"}}`. Whether 31 is Done or In Review is
#   per-project data this hook cannot see, and treating every numeric
#   transition as terminal would deny ordinary workflow moves. `.fields.status.
#   name`, `.state`, `.stateId`, `.status`, `.transition.name` ARE read; a bare
#   numeric id is not classifiable and silently allows.
# * **Status vocabularies are English words.** `Ferdig`, `Terminé`, `完了` are
#   not recognised and allow. Conversely, closures that are not QA sign-off
#   (`Won't Do`, `Duplicate`, `Superseded`, `Cancelled`, `Obsolete`,
#   `Invalid`) are excluded from the terminal set so the gate does not demand
#   an evidence bundle for a ticket nobody tested.
# * **`gh` invocation forms.** Wrapper prefixes (`env`, `command`, `time`,
#   `nohup`, `exec`, `eval`, `sh -c`, `bash -lc`, leading `VAR=val`
#   assignments, an absolute or relative path to `gh`) ARE stripped and gated.
#   Not gated: `gh` reached through an alias, a shell function, a wrapper
#   script, `xargs`, or a heredoc. A PreToolUse hook sees a command string, not
#   a resolved process.
# * **Secret detection is name-and-shape based.** Header, cookie and
#   query-string NAMES are matched against a fixed vocabulary, and HAR request/
#   response body text is matched for `access_token`-shaped assignments. A
#   credential in a field named nothing like a credential is not found. High-
#   entropy scanning is deliberately not attempted — the false-positive rate on
#   real artifacts is what gets a gate disabled.
# * **`console.log` is unstructured**, so its scan is line-and-occurrence based
#   rather than structural. Each occurrence is checked for a redaction
#   placeholder individually (a placeholder elsewhere on the line does not
#   launder a live value beside it), but a credential printed with no
#   recognisable key is not found.
# * **Secrets outside a matched bundle.** The scan follows the bundle, so an
#   ad-hoc HAR written somewhere the gate cannot find is unscanned. That is why
#   `companion-mode` §"Redaction" is scoped to the ARTIFACT rather than to this
#   gate's reach. The better long-term surface for the secret half is a
#   `PostToolUse:Bash` hook at the moment a HAR is written, which would reach
#   every capture regardless of layout; this sign-off scan is a backstop at the
#   last boundary, not the primary control.
# * **Bash, curl and `gh api`** as tracker transports are ungated on the comment
#   and transition surfaces — only `mcp__*` tools are seen there. Same hole its
#   sibling documents.
# * **Overlap with the sibling gate.** Both this and
#   adversarial-verification-gate.sh fire on the same payloads, so a
#   verdict-shaped comment with neither receipt nor bundle draws two warnings
#   with similar guidance. That is noisy and known; consolidating them is a
#   separate change.
# * **A bare project prefix as the key.** Bundle stems are
#   `<key>-<slug>-<timestamp>`, so the match is anchored at a separator rather
#   than exact — a payload whose key is the project prefix alone ("ABC" against
#   `abc-1-…`) would match. Tightening it breaks the branch-bound entry-B case.
#   The collision that occurs in practice, ABC-1 vs ABC-15, is closed by the
#   separator anchor and is pinned in the tests.
#
# Secret values are NEVER echoed. Findings name the file and the header/field
# only — a gate that prints the credential it caught has published it into the
# transcript.
#
# Canonical reference
# -------------------
# skills/ticket-driven-testing/SKILL.md §"The sequence" (step 0),
#                                       §"The Contract",
#                                       §"The sign-off gate"
# skills/companion-mode/SKILL.md        §"Redaction (mandatory …)"
# skills/element-interactions/references/harness-hooks.md
#
# Failure → action
# ----------------
# - terminal transition / non-draft `gh pr create|ready`, no bundle    → DENY
# - verdict-shaped comment, no bundle                                  → WARN
# - bundle found, unredacted secret in its HAR / console log           → DENY
# - non-terminal transition, non-QA closure, tracker read              → silent allow
# - ordinary comment, `gh pr create --draft`, `gh pr view/list`        → silent allow
# - protocol not activated in this session                             → silent allow
# - anything else                                                      → silent allow

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JQ="$HOOK_DIR/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

[ "${CIVITAS_DISABLE_EVIDENCE_GATE:-}" = "1" ] && exit 0

INPUT="$(cat)"

# shellcheck source=lib/achilles-activation.sh
if [ -f "$HOOK_DIR/lib/achilles-activation.sh" ]; then
  . "$HOOK_DIR/lib/achilles-activation.sh"
  achilles_session_active "$INPUT" || exit 0
fi

emit_deny() {
  "$JQ" -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
}

emit_warn() {
  "$JQ" -n --arg m "$1" '{systemMessage: $m, suppressOutput: false}'
}

TOOL_NAME="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty')"
[ -n "$TOOL_NAME" ] || exit 0

# ─── which surface are we on ────────────────────────────────────────────────
# Tracker vocabularies differ per vendor; match the shapes, not one product.
IS_TRANSITION=0
IS_COMMENT=0
IS_PR=0
case "$TOOL_NAME" in
  *save_issue*|*transitionJiraIssue*|*update_issue*|*editJiraIssue*) IS_TRANSITION=1 ;;
  *save_comment*|*addCommentToJiraIssue*|*create_comment*)           IS_COMMENT=1 ;;
  Bash)                                                              IS_PR=1 ;;
  *) exit 0 ;;
esac

ARGS="$(printf '%s' "$INPUT" | "$JQ" -c '.tool_input // {}')"

# ─── Bash surface: is this actually publishing a PR? ────────────────────────
# Strip quoted strings and trailing comments before looking at flags. Scanning
# the raw command for `-d` matched flags mentioned inside a PR title or body,
# which silently disabled the gate on ordinary commands.
strip_quoted() {
  printf '%s' "$1" | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g; s/#.*$//"
}

# Peel wrapper prefixes off one command segment so the real program is first.
# `env`, `command`, `time`, `nohup`, `exec`, `eval`, `sh -c`, `bash -lc` and
# leading `VAR=val` assignments are how people actually script `gh` — treating
# them as evasions to be ignored left every one of them ungated.
normalise_segment() {
  local s="$1" peeled=0
  while :; do
    s="${s#"${s%%[![:space:]]*}"}"
    case "$s" in
      \"*|\'*)                                   s="${s#?}"    ; peeled=1; continue ;;
      env\ *|command\ *|time\ *|nohup\ *|exec\ *|eval\ *) s="${s#* }"; peeled=1; continue ;;
      sh\ *|bash\ *|zsh\ *|dash\ *)              s="${s#* }"   ; peeled=1; continue ;;
      [A-Za-z_]*=*\ *)                           s="${s#* }"   ; peeled=1; continue ;;
    esac
    # A flag can only belong to a wrapper we already peeled (`sh -c`, `bash -lc`).
    if [ "$peeled" = "1" ]; then
      case "$s" in -*\ *) s="${s#* }"; continue ;; esac
    fi
    break
  done
  printf '%s' "$s"
}

GH_SEGMENT=""
if [ "$IS_PR" = "1" ]; then
  CMD="$(printf '%s' "$ARGS" | "$JQ" -r '.command // empty')"
  [ -n "$CMD" ] || exit 0
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    norm="$(normalise_segment "$seg")"
    first="${norm%%[[:space:]]*}"
    case "$first" in
      gh|*/gh) ;;
      *) continue ;;
    esac
    rest="${norm#"$first"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in
      pr\ create*|pr\ ready*) GH_SEGMENT="$norm"; break ;;
    esac
  done < <(printf '%s\n' "$CMD" | tr ';&|(){}' '\n')

  [ -n "$GH_SEGMENT" ] || exit 0
  # Sharing work in progress is not a claim that it is verified.
  printf '%s' "$(strip_quoted "$GH_SEGMENT")" |
    grep -qE '(^|[[:space:]])(--draft|-d)([[:space:]]|$)' && exit 0
fi

# ─── tracker surfaces: is this actually sign-off? ───────────────────────────
if [ "$IS_TRANSITION" = "1" ]; then
  STATE="$(printf '%s' "$ARGS" | "$JQ" -r '
      [ .state?, .status?, .stateId?, .transition?, .fields?.status?,
        .fields?.state?, .state?.name?, .status?.name?, .transition?.name?,
        .fields?.status?.name? ]
      | map(select(. != null))
      | map(if type == "object" then (.name // .id // "") else tostring end)
      | join(" ")' 2>/dev/null || true)"
  # A closure that is not a QA sign-off must not demand QA evidence.
  printf '%s' "$STATE" | grep -qiE "won'?t ?do|wontfix|duplicate|superseded|abandoned|cancell?ed|obsolete|invalid|not ?a ?bug" && exit 0
  printf '%s' "$STATE" | grep -qiE 'done|complete|closed|resolved|shipped|released|merged|accepted' || exit 0
fi

if [ "$IS_COMMENT" = "1" ]; then
  BODY="$(printf '%s' "$ARGS" | "$JQ" -r '.body // empty')"
  printf '%s' "$BODY" | grep -qiE 'qa (test )?report|acceptance criteri|verdict|sign.?off|AC-[0-9]' || exit 0
fi

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ─── whose sign-off is this ─────────────────────────────────────────────────
# `.identifier` first: Linear's human key (ABC-12) is what bundle directories
# are named after, while `.id` is a UUID. Reading `.id` alone denied every
# payload an agent gets back from a list/search call.
TICKET_KEY="$(printf '%s' "$ARGS" | "$JQ" -r '
    (.identifier // .key // .issueIdOrKey // .issue // .issueId // .id // empty) | tostring' 2>/dev/null || true)"

# Entry B has no ticket, so the bundle binds to the BRANCH — the only stable
# identifier the work has. Slashes become dashes so the key is a legal stem.
BRANCH_BOUND=0
if [ "$IS_PR" = "1" ] && [ -z "$TICKET_KEY" ]; then
  BRANCH_BOUND=1
  TICKET_KEY="$(git -C "$WORKSPACE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || true)"
fi

# ─── locate the bundle ──────────────────────────────────────────────────────
evidence_roots() {
  [ -n "${ACHILLES_EVIDENCE_DIR:-}" ] && [ -d "$ACHILLES_EVIDENCE_DIR" ] && printf '%s\n' "$ACHILLES_EVIDENCE_DIR"
  # Prunes DURING the walk, not after. There is deliberately NO result cap:
  # an earlier version truncated at 40, and because `find` emits readdir order
  # that made the gate nondeterministic — a valid bundle in the wrong part of a
  # monorepo silently denied, and the answer changed as the tree changed. The
  # cap was justified by a 10s budget the walk does not come close to using
  # (measured: 0.03s over a 90-package synthetic monorepo, 0.09s over a real
  # one). Correctness beats a bound that was never needed.
  find "$WORKSPACE_ROOT" -maxdepth 10 \
    \( -name node_modules -o -name .git -o -name dist -o -name build -o -name .next -o -name coverage -o -name vendor \) -prune -o \
    -type d -name evidence -print 2>/dev/null
}

# Files a companion-mode bundle can carry, at the bundle root or one level down.
# One level down is not optional: `companion-mode` §"Phase 5" tells operators to
# give each environment its own subdirectory (`preview/`, `production/`) to stop
# the second run overwriting the first — a root-only check denied exactly the
# layout the skill recommends, and a root-only secret scan was blind to the
# credentials inside it.
bundle_artifacts() {
  local d="$1"
  ls -1 "$d"/video.webm "$d"/trace.zip "$d"/*.har "$d"/console.log \
        "$d"/*/video.webm "$d"/*/trace.zip "$d"/*/*.har "$d"/*/console.log 2>/dev/null || true
  { [ -d "$d/screenshots" ] && [ -n "$(ls -A "$d/screenshots" 2>/dev/null)" ] && echo "$d/screenshots"; } || true
  local sub
  for sub in "$d"/*/screenshots; do
    [ -d "$sub" ] && [ -n "$(ls -A "$sub" 2>/dev/null)" ] && echo "$sub"
  done
  return 0
}

is_populated_bundle() {
  local d="$1"
  [ -f "$d/summary.md" ] || return 1
  [ -n "$(bundle_artifacts "$d")" ] || return 1
  return 0
}

# UUID-shaped keys never appear in a directory name. The sibling gate solves the
# same problem with an exact-equality content fallback; the analogue here is the
# bundle's own summary naming the ticket. Exact substring, no fuzzy matching.
uuid_shaped() {
  printf '%s' "$1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

bundle_for_ticket() {
  [ -n "$TICKET_KEY" ] || return 1
  # Degenerate keys only ever arise from a malformed payload, or from
  # `rev-parse --abbrev-ref HEAD` in a repo with no commits — a stem that would
  # otherwise let one `head-*` directory unlock every such workspace.
  case "$TICKET_KEY" in ''|'-'|'.'|'..'|evidence|json|JSON|HEAD|head) return 1 ;; esac
  [ "${#TICKET_KEY}" -ge 3 ] || return 1

  local key_lc root d base is_uuid=0
  key_lc="$(printf '%s' "$TICKET_KEY" | tr '[:upper:]' '[:lower:]')"
  uuid_shaped "$TICKET_KEY" && is_uuid=1

  while IFS= read -r root; do
    [ -d "$root" ] || continue
    # Depth 1 and depth 2: bundles are commonly foldered by date or by run.
    for d in "$root"/*/ "$root"/*/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      base="$(basename "$d" | tr '[:upper:]' '[:lower:]')"
      if [ "$base" = "$key_lc" ] || case "$base" in "$key_lc"[-_.]*) true ;; *) false ;; esac; then
        is_populated_bundle "$d" || continue
        printf '%s\n' "$d"; return 0
      fi
      if [ "$is_uuid" = "1" ] && [ -f "$d/summary.md" ]; then
        grep -qiF -- "$TICKET_KEY" "$d/summary.md" 2>/dev/null || continue
        is_populated_bundle "$d" || continue
        printf '%s\n' "$d"; return 0
      fi
    done
  done < <(evidence_roots)
  return 1
}

BUNDLE="$(bundle_for_ticket || true)"

# ─── scan the bundle for credentials that survived redaction ────────────────
# Field NAMES only — never values. A gate that prints the credential it caught
# has published it into the transcript.
SECRET_FINDINGS=""

# Conventional redaction placeholders: the pass has been run, the value is gone.
# `<...>` covers documentation-shaped output ("authorization: bearer <token>"),
# which is app console noise, not a credential.
PLACEHOLDER_RE='redacted|\*\*\*|<removed>|\[hidden\]|xxxxx|<[a-z_-]+>'

# Names that carry credentials. Anchored at word boundaries inside the name:
# an unanchored `session` denied `x-session-id` and a `sessionCartId` cookie,
# which have nothing to redact and no remedy but disabling the hook.
NAME_RE='^(cookie|set-cookie|apikey|x-apikey)$|(^|[-_])(authorization|auth|bypass|token|jwt|secret|credential|password|passwd|api[-_]?key)([-_]|$)'

# Credential-shaped assignments inside request/response bodies. The deny message
# itself tells operators to drop response bodies precisely because they carry
# these, so not scanning them was incoherent. The >=6-char value requirement is
# what keeps `api_key= is required` (an app error string) from denying.
#
# POSIX classes, not `\t`: `grep -E` does not read `\t` as a tab, so `[ \t]`
# is the SET {space, backslash, t} — and under `-i` that silently excludes `T`
# as well, which truncated every match just before the redaction placeholder
# and turned "Bearer [REDACTED]" into a finding.
BODY_RE='(access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|api[_-]?key|password|passwd|secret[_-]?key|private[_-]?key)"?['"'"']?[[:blank:]]*[:=][[:blank:]]*["'"'"']?[^"'"'"'[:space:],;}]{6,}'

# A HAR big enough to be a parsing risk is, by construction, one that still has
# response bodies in it — i.e. exactly the thing redaction removes.
MAX_HAR_BYTES=$((512 * 1024 * 1024))

file_size() { wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

scan_har() {
  local f="$1" label names sz
  [ -f "$f" ] || return 0
  label="${f#"$BUNDLE"/}"
  sz="$(file_size "$f")"
  if [ "${sz:-0}" -gt "$MAX_HAR_BYTES" ]; then
    SECRET_FINDINGS="${SECRET_FINDINGS}  - ${label}: $((sz / 1024 / 1024))MB — too large to verify, and a HAR this size still has response bodies in it
"
    return 0
  fi
  # HAR is JSON, so walk it structurally. A minified HAR is ONE line, which
  # defeats any "is there a placeholder nearby" line heuristic: a single
  # redacted header would launder every live one beside it.
  names="$("$JQ" -r --arg ph "$PLACEHOLDER_RE" --arg nre "$NAME_RE" --arg bre "$BODY_RE" '
      def live: tostring | (length > 0) and (test($ph; "i") | not);
      ( [ .. | objects
          | select(has("name") and has("value"))
          | select((.name | type) == "string")
          | select(.name | ascii_downcase | test($nre))
          | select(.value | live)
          | "field `" + (.name | ascii_downcase) + "`" ]
      + [ .. | objects | to_entries[]
          | select((.value | type) == "string")
          | select(.key | ascii_downcase | test($nre))
          | select(.value | live)
          | "field `" + (.key | ascii_downcase) + "`" ]
      + [ .log?.entries[]? | (.request?.postData?.text?, .response?.content?.text?)
          | select(type == "string")
          | [ match($bre; "ig").string ][]
          | select(test($ph; "i") | not)
          | "a credential-shaped assignment in a request/response body" ]
      ) | unique | .[]' "$f" 2>/dev/null || true)"

  if [ -z "$names" ]; then
    # Unparseable / truncated HAR: fall back to a name scan so a corrupt file is
    # not silently treated as clean.
    "$JQ" -e . "$f" >/dev/null 2>&1 && return 0
    grep -aiqE '"(authorization|set-cookie|cookie)"|bypass|api[-_]?key|[-_]token"' "$f" 2>/dev/null &&
      SECRET_FINDINGS="${SECRET_FINDINGS}  - ${label}: unparseable as JSON and contains credential-bearing field names
"
    return 0
  fi
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    SECRET_FINDINGS="${SECRET_FINDINGS}  - ${label}: ${n} carries a live value (value withheld)
"
  done <<< "$names"
}

# Console logs are unstructured. Each OCCURRENCE is extracted and checked for a
# placeholder on its own — a redacted value earlier on the same line must not
# launder a live one after it, which is the same laundering the structural HAR
# walk exists to prevent.
scan_text() {
  local f="$1" label pat live
  [ -f "$f" ] || return 0
  label="${f#"$BUNDLE"/}"
  for pat in \
    'authorization[[:blank:]]*[:=][[:blank:]]*(bearer|basic|token)[[:blank:]]+[^[:space:]"]+' \
    '(protection|deployment)[-_]?bypass["'"'"']?[[:blank:]]*[:=][[:blank:]]*["'"'"']?[^[:space:]",;}]{6,}' \
    "$BODY_RE"
  do
    live="$(grep -aoiE "$pat" "$f" 2>/dev/null | grep -aivE "$PLACEHOLDER_RE" | head -1 || true)"
    [ -n "$live" ] || continue
    SECRET_FINDINGS="${SECRET_FINDINGS}  - ${label}: a credential-shaped assignment carries a live value (value withheld)
"
    break
  done
  return 0
}

if [ -n "$BUNDLE" ]; then
  # Root and one level down — same reason bundle_artifacts recurses.
  for f in "$BUNDLE"/*.har "$BUNDLE"/*/*.har; do
    [ -f "$f" ] && scan_har "$f"
  done
  for f in "$BUNDLE"/console.log "$BUNDLE"/*/console.log; do
    [ -f "$f" ] && scan_text "$f"
  done
fi

[ -n "$BUNDLE" ] && [ -z "$SECRET_FINDINGS" ] && exit 0

# ─── messages ───────────────────────────────────────────────────────────────
REFS="References:
  skills/ticket-driven-testing/SKILL.md §\"The sequence\" (step 0), §\"The Contract\"
  skills/companion-mode/SKILL.md §\"Redaction (mandatory — scoped to the artifact)\""

if [ -n "$SECRET_FINDINGS" ]; then
  emit_deny "[BLOCKED] A captured artifact in this ticket's evidence bundle still contains a live credential.

──────────────────────────────────────────────────────────────────
Do this instead — run companion-mode's redaction pass, then retry:
──────────────────────────────────────────────────────────────────

  Option A — redact in place (the normal path)
    Redact by FIELD NAME across every entry, not by searching for the
    value you happen to know: one credential appears in the headers of
    every request, so a value-based sweep misses by default. Drop
    response bodies at the same time. Record what was redacted in the
    bundle's summary.md under '## Redactions' — named, not silent.
  Option B — the artifact is not worth keeping
    Delete it from the bundle and say so in summary.md. An absent
    artifact you declared beats a present one that leaks.

──────────────────────────────────────────────────────────────────
What was wrong:
──────────────────────────────────────────────────────────────────
Bundle: ${BUNDLE}
${SECRET_FINDINGS}
Values are withheld from this message by design. A bypass token appears
in the request headers of EVERY entry in a HAR — hundreds of copies of
one credential inside an artifact you are about to publish a link to.

──────────────────────────────────────────────────────────────────
If the token is short-lived or 'only a preview' — read this:
──────────────────────────────────────────────────────────────────
A deployment protection-bypass token is a credential. Its lifetime is
not the point: the artifact outlives the session, gets committed or
attached to a ticket, and is readable by everyone the ticket is.
Rotate it if this bundle has already been shared.

${REFS}"
  exit 0
fi

if [ -n "$TICKET_KEY" ]; then
  WHOSE="No evidence bundle was found for \`${TICKET_KEY}\`."
elif [ "$BRANCH_BOUND" = "1" ]; then
  WHOSE="No ticket key in the payload, and the branch name could not be resolved (detached HEAD, or a repo with no commits), so the gate cannot tell whose evidence it would be looking for."
else
  WHOSE="This payload carries no ticket key, so the gate cannot tell whose evidence it would be looking for."
fi

BODY_MSG="──────────────────────────────────────────────────────────────────
Do this instead:
──────────────────────────────────────────────────────────────────

  Option A — you have not run the sequence for THIS ticket yet
    Run ticket-driven-testing from step 0. A skill loaded earlier in
    this session has NOT been performed for the ticket in front of you
    now: one ticket, one run of steps 1-9. The evidence run itself is
    companion-mode, which produces the bundle this gate looks for.

  Option B — you ran it, and the bundle is somewhere this gate cannot see
    Bundles are matched at <workspace>/**/evidence/<key>*/ (one or two
    levels below an 'evidence' directory) and must carry a summary.md
    plus at least one of screenshots/, video.webm, trace.zip, *.har —
    at the bundle root or one level into it. Either name the directory
    for the ticket, or point the gate at it:
        export ACHILLES_EVIDENCE_DIR=/path/to/evidence

  Option C — there is genuinely nothing to capture
    A run against an unreachable app legitimately stops at the diff
    review. Say THAT in the verdict, scope the claim to what you
    actually did, and do not describe it as verified.

──────────────────────────────────────────────────────────────────
What was wrong:
──────────────────────────────────────────────────────────────────
Workspace: ${WORKSPACE_ROOT}
${WHOSE}

ticket-driven-testing §\"The Contract\" requires five deliverables and
item 3 is an evidence bundle. The binding is PER TICKET on purpose.
The failure this catches: a session runs the method properly for one
ticket, moves to a second, treats the skill as 'already loaded', and
posts a verdict with measured numbers and zero artifacts. The numbers
look like evidence. They are not — nothing can be re-examined.

──────────────────────────────────────────────────────────────────
If this feels redundant because you 'already did this' — read this:
──────────────────────────────────────────────────────────────────
That inference is the failure mode, not an exception to it. The skill
being in your transcript is evidence about the SESSION; this gate asks
about the TICKET. Those came apart the moment you picked up a second
one.

${REFS}"

# Publishing a PR and moving a ticket to a completed state are terminal in the
# same way: they present the work to others as finished. A comment is not, so it
# warns — the report can still be worth reading, it just must not read as
# evidence-backed when there is no evidence.
if [ "$IS_TRANSITION" = "1" ] || [ "$IS_PR" = "1" ]; then
  emit_deny "[BLOCKED] Sign-off blocked — no evidence bundle for this ticket.

$BODY_MSG"
  exit 0
fi

emit_warn "[WARN] Posting a QA verdict with no evidence bundle for this ticket.

$BODY_MSG"
exit 0
