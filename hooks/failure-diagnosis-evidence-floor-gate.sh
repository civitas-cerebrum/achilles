#!/bin/bash
# failure-diagnosis-evidence-floor-gate.sh — evidence-floor gate for diagnosis writes.
#                                            Denies spec / element-repository
#                                            writes from a failure-diagnosis
#                                            context whose transcript shows no
#                                            failure-evidence access at all.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY
# State   : reads the session transcript at `transcript_path` from the hook
#           input — scans for Read/Bash tool uses that touch failure evidence
#           (trace, error-context.md, failure screenshot, video, JSON reporter
#           output, downloaded CI artifacts).
# Env     : FD_EVIDENCE_FLOOR_GATE=off   bypass for special cases (advisory;
#           document the bypass authorisation)
#
# Rule
# ----
# `failure-diagnosis` §"Evidence floor — non-negotiable, both entrypoints,
# both conclusions" requires the trace, the UI/DOM at the moment of failure,
# and the browser console to be inspected — each with a written observation —
# BEFORE a root cause is written down, a heal is proposed, a spec is edited,
# or the element repository is touched. This gate enforces the mechanically
# detectable half of that rule: in a session where failure-diagnosis is in
# play, a Write|Edit to a `*.spec.*` file or a `page-repository*.json` is
# denied when the transcript contains NO evidence access whatsoever.
#
# Scope
# -----
# The gate proves evidence was ACCESSED, not that it was UNDERSTOOD. An agent
# that opens a trace and then ignores it passes. It cannot read the written
# observation for each floor item, and it cannot tell attempt 0's trace from
# the passing retry's. Those remain enforced by the skill text and by
# reviewers (see the registry entry cited below). What it does catch is the
# dominant observed failure: a diagnosis written entirely from
# `gh run view --log-failed` output or a terminal error string, with the
# artifacts never opened at all. That shape produces a zero-evidence
# transcript, which is exactly what this gate refuses to let write.
#
# Why
# ---
# Markdown could not hold this line. Three independent live sessions shipped
# a root cause from log text alone — the error string looked familiar, the
# trace felt redundant, and the resulting spec edit encoded a workaround for a
# defect the evidence would have named differently. The error message says
# WHERE execution stopped; the trace says WHAT the page was doing. A gate at
# the write boundary is the only reader the diagnoser cannot talk past,
# because it fires after the rationalisation and before the damage.
#
# Trigger conditions (ALL must hold for the gate to consider a call)
# ------------------------------------------------------------------
# 1. Tool is Write or Edit.
# 2. Target path is a spec file (`*.spec.ts|tsx|js|mjs|cjs`, `*.test.ts|...`)
#    or an element repository (`page-repository*.json`).
# 3. The WRITER is doing failure diagnosis — its own transcript shows a
#    Skill('failure-diagnosis') or a Read of `skills/failure-diagnosis/SKILL.md`,
#    or the writer is a subagent whose agent_type is an `fd` / `repair-worker`
#    role. Only the writer's transcript counts: a subagent's call is judged on
#    <session>/subagents/agent-<agent_id>.jsonl, never on the parent session's
#    (the parent dispatching an fd- worker once does not make every later
#    probe or composer a diagnoser, and the fd worker's evidence reads live in
#    its own transcript).
# 4. The transcript shows NO evidence access (the signal list below).
#
# Evidence signals (ANY ONE satisfies the floor's mechanical half)
# ----------------------------------------------------------------
# Read  file_path matching : trace.zip | trace/*.trace | error-context.md
#                            test-failed-*.png | *-actual.png | video.webm
#                            *results.json under test-results | screencast
#                            page@*.jpeg | any path under test-results/ or
#                            playwright-report/
# Bash  command matching   : playwright show-trace | show-report | unzip *trace
#                            gh run download | gh api */artifacts | trace.zip
#                            jq over *.trace / *-results.json
#
# Fail-open cases (silent allow)
# ------------------------------
# - FD_EVIDENCE_FLOOR_GATE=off
# - Tool is not Write|Edit
# - Path is not a spec / element repository
# - transcript_path missing or unreadable (older harness, fixtures)
# - Transcript shows no failure-diagnosis context (a composer writing a new
#   spec is not diagnosing anything)
# - Any evidence signal present
#
# Canonical reference
# -------------------
# skills/failure-diagnosis/SKILL.md §"Evidence floor — non-negotiable, both
#   entrypoints, both conclusions"
# skills/failure-diagnosis/SKILL.md §"Stage 0b — Pipeline evidence retrieval"
# skills/coverage-expansion/references/anti-rationalizations.md
#   §"Pattern: Diagnosis from log text alone (evidence floor skipped)"
#
# Failure → action
# ----------------
# - Spec / page-repository write, fd context, zero evidence reads  → DENY
# - Spec / page-repository write, fd context, any evidence read    → silent allow
# - Spec / page-repository write, no fd context                    → silent allow
# - Any other path or tool                                         → silent allow

# Intentional: `set -uo pipefail` without `-e`. The hook is input-tolerant by
# design — malformed stdin, missing tool_input, or jq extraction failures
# silent-allow rather than crashing the PreToolUse pipeline.
set -uo pipefail

# Bypass switch.
if [ "${FD_EVIDENCE_FLOOR_GATE:-on}" = "off" ]; then
  exit 0
fi

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_jq_init fatal

hook_read_input

# Session-scope gate: this hook applies only to achilles-activated sessions;
# plain dev sessions silent-allow (lib/achilles-activation.sh).
hook_lib achilles-activation.sh hook-emit.sh
achilles_require_active "$INPUT"

TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

# Normalise to leading-slash form so a bare relative path is gated like an
# absolute one.
NORM_PATH="/${FILE_PATH#/}"
case "$NORM_PATH" in
  *.spec.ts|*.spec.tsx|*.spec.js|*.spec.mjs|*.spec.cjs|\
  *.test.ts|*.test.tsx|*.test.js|*.test.mjs|*.test.cjs)
    TARGET_KIND="spec" ;;
  */page-repository.json|*/page-repository-*.json|*/page-repository.*.json)
    TARGET_KIND="element-repository" ;;
  *) exit 0 ;;
esac

# Locate the WRITER's transcript. A subagent's call carries `agent_id`, while
# `transcript_path` still names the parent session's file; the child's own
# transcript sits beside it under subagents/. Without one — fail open.
TRANSCRIPT_PATH=$(echo "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null || echo "")
AGENT_ID=$(echo "$INPUT" | "$JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
AGENT_TYPE=$(echo "$INPUT" | "$JQ" -r '.agent_type // empty' 2>/dev/null || echo "")
if [ -n "$AGENT_ID" ]; then
  case "$AGENT_ID" in *[!A-Za-z0-9_-]*) exit 0 ;; esac
  TRANSCRIPT_PATH="${TRANSCRIPT_PATH%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"
fi
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Flatten every tool_use in the transcript into one "<KIND> <value>" line per
# salient field. Both the context probe and the evidence probe read this.
# Space-separated (not tab) so the patterns below stay readable and portable.
TOOL_USES=$(
  "$JQ" -r '
    if (.message? | type) == "object" and (.message.content? | type) == "array" then
      .message.content[] |
        select(.type? == "tool_use") |
        (
          (select(.name? == "Skill") | "SKILL " + (.input.skill // "")),
          (select(.name? == "Read")  | "READ "  + (.input.file_path // "")),
          (select(.name? == "Bash")  | "BASH "  + (.input.command // ""))
        )
    else empty end
  ' "$TRANSCRIPT_PATH" 2>/dev/null || true
)

# --- (3) Is the writer doing failure diagnosis? -----------------------------
# The writer is an fd / repair-worker subagent, or its own transcript loaded
# Skill('failure-diagnosis') (bare or plugin/path-prefixed) or read the skill
# file. No fd context → this write is somebody else's business (a composer or
# a pass-5 probe authoring a spec, say).
FD_CONTEXT=$(
  { printf '%s\n' "$AGENT_TYPE" | grep -E '(^|:)('"$DISPATCH_FD_ROLE_ALT"')$'
    printf '%s\n' "$TOOL_USES" \
      | grep -E '^SKILL ([a-z0-9./_-]+[:/])?failure-diagnosis$|^READ .*skills/failure-diagnosis/SKILL\.md$'
  } | head -1 || true
)
if [ -z "$FD_CONTEXT" ]; then
  exit 0
fi

# --- (4) Any evidence access at all? ----------------------------------------
# Deliberately generous: ONE signal is enough. The gate catches the
# zero-evidence transcript, not the shallow read.
EVIDENCE=$(
  printf '%s\n' "$TOOL_USES" \
    | grep -E '^(READ|BASH) .*(trace\.zip|\.trace([^a-z]|$)|error-context\.md|test-failed-[0-9]*\.png|video\.webm|page@[0-9a-f]*\.jpe?g|results\.json|/test-results/|/playwright-report/|show-trace|show-report|gh run download|actions/runs/[^ ]*/artifacts)' \
    | head -1 || true
)
if [ -n "$EVIDENCE" ]; then
  exit 0
fi

# --- DENY -------------------------------------------------------------------
case "$TARGET_KIND" in
  spec) WHAT="spec file"; ALSO="the spec's assertions and waits" ;;
  *)    WHAT="element repository"; ALSO="the page's locator entries" ;;
esac

REASON="[BLOCKED] Evidence-floor violation — about to write ${WHAT} \`${FILE_PATH}\` from a failure-diagnosis context whose transcript shows no failure evidence was ever opened.

──────────────────────────────────────────────────────────────────
Do this instead — open the evidence, then write:
──────────────────────────────────────────────────────────────────

  Option A — LOCAL failure (artifacts already on disk)
    Read  test-results/<sanitized-title>-<project>/test-failed-1.png
    Read  test-results/<sanitized-title>-<project>/error-context.md
    Bash  unzip -o -q test-results/<...>/trace.zip -d ./trace-x
    Bash  jq -r 'select(.type==\"console\") | \"[\\(.messageType)] \\(.text)\"' ./trace-x/0-trace.trace

  Option B — PIPELINE failure (artifacts still inside the CI run)
    Bash  gh run view <run-id> --json headSha,conclusion,jobs
    Bash  gh api repos/<owner>/<repo>/actions/runs/<run-id>/artifacts --jq '.artifacts[].name'
    Bash  gh run download <run-id> --dir <scratch-dir>
    ...then Option A against the downloaded paths.

  Mind the attempt split: attempt 0 and \`-retry1\` are SIBLING directories.
  Under trace: 'on-first-retry' the only trace belongs to the retry — which on
  a flaky test PASSED. Read attempt 0's screenshot / error-context / video.

──────────────────────────────────────────────────────────────────
What was wrong:
──────────────────────────────────────────────────────────────────
File: ${FILE_PATH}
Context: this writer is diagnosing a failure (it loaded failure-diagnosis,
         or it is an fd / repair-worker subagent).
Evidence reads found in transcript: NONE — no trace, no error-context.md, no
         failure screenshot, no video, no JSON reporter output, no
         \`show-trace\` / \`unzip … trace.zip\` / \`gh run download\` call.

The evidence floor (trace + UI/DOM at failure + browser console) is a
precondition of EVERY classification, not just app bugs — a wrong \"test
issue\" call is the cheaper and far more common one, and it lands a spec edit
that hides the real defect and makes the suite lie. The error message says
WHERE execution stopped; the trace says WHAT the page was doing. One
\`Timeout … waiting for element to be visible, enabled and stable\` is emitted
identically by an intercepting overlay, a consent banner, a never-settling
animation, a mid-flight navigation, a 500 behind a skeleton, a framework-side
defect, and a genuinely absent element. Editing ${ALSO} from the log line
picks one of those seven at random.

──────────────────────────────────────────────────────────────────
If the trace felt redundant or expensive — read this:
──────────────────────────────────────────────────────────────────
A trace.zip is a plain zip of JSONL streams: \`unzip\` + \`jq\` reads it
headlessly in seconds, no browser and no viewer needed, and the screencast
frames under \`resources/page@*.jpeg\` are ordinary images the Read tool
opens. If the artifact is genuinely gone (expired retention, no retry under
trace: 'on-first-retry', never uploaded), that is a NAMED gap: record the
specific gap and its specific reason in the evidence package, work the
remaining floor items plus the JSON reporter's \`stderr\` / \`annotations\`
and the video — and the transcript will then carry the reads this gate looks
for.

Bypass (advisory only — document the authorisation): set
\`FD_EVIDENCE_FLOOR_GATE=off\` in the harness environment.

References:
  skills/failure-diagnosis/SKILL.md §\"Evidence floor — non-negotiable, both entrypoints, both conclusions\"
  skills/failure-diagnosis/SKILL.md §\"Stage 0b — Pipeline evidence retrieval\"
  skills/coverage-expansion/references/anti-rationalizations.md §\"Pattern: Diagnosis from log text alone\"
  skills/achilles-protocol/references/harness-hooks.md"

emit_pre_deny "$REASON"
exit 0
