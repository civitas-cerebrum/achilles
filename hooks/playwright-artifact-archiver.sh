#!/bin/bash
# playwright-artifact-archiver.sh — per-run Playwright evidence preservation
#
# Hook    : PostToolUse:Bash  (primary — fires after a Playwright run command)
#           Stop, SubagentStop  (backstop — catches interrupted / aborted runs)
# Mode    : RECORD (copies artifacts; never denies, never blocks)
#           + WARN (only when something is dropped: size-ceiling skips, pruned runs)
# State   : <project>/.achilles/runs/<runId>/        archived evidence + manifest.json
#           <project>/.achilles/runs/.last-archive.json   idempotency fingerprint
#           <project>/.achilles/runs/latest              symlink to the newest run
# Env     : ACHILLES_ARTIFACT_RETAIN=<int>   (default 5; 0 disables archiving entirely)
#           ACHILLES_ARTIFACT_MAX_MB=<int>   (default 512; per-run ceiling — above it the
#                                             large blobs (*.zip traces, *.webm/*.mp4 videos)
#                                             are skipped and the small evidence still lands)
#
# Rule
# ----
# After a Playwright run, copy that run's artifacts into a per-run directory
# under `<project>/.achilles/runs/<runId>/` so the NEXT run cannot destroy
# them. Playwright wipes its `outputDir` at the START of every run and reuses
# per-test `test-results/<slug>/` directories, so traces, videos, screenshots
# and `error-context.md` from run N are gone the moment run N+1 starts. The
# archive is a copy, never a move: `show-report` / `show-trace` against
# `test-results/` keep working exactly as before.
#
# Paths are DISCOVERED, not assumed: `--output=<dir>` on the observed command,
# then `outputDir:` / html `outputFolder:` / json `outputFile:` in the nearest
# playwright config (resolved relative to the config file), then
# PLAYWRIGHT_JSON_OUTPUT_NAME / PLAYWRIGHT_JUNIT_OUTPUT_NAME from the command
# line or the environment, then the Playwright defaults. Anything that cannot
# be resolved degrades to the default and is recorded in the manifest.
#
# Why
# ---
# During an autonomous self-repair session a baseline run captured traces and
# error-context for a failing test; later runs in the same session wiped them,
# and the repair worker dispatched to diagnose that test found no evidence and
# had to reproduce from scratch. The same hazard silently overwrites the
# failure artifacts a bug report links to. The methodology's answer was a rule
# telling agents to copy evidence out immediately — exactly the kind of
# discipline a harness should enforce instead of asking humans and agents to
# remember it under context pressure.
#
# Canonical reference
# -------------------
# skills/element-interactions/references/harness-hooks.md §"PostToolUse"
#
# Non-destructive contract
# ------------------------
# - Copies only. Nothing under the consumer's `outputDir` / report dir is ever
#   read-modify-written, moved or removed.
# - The only deletions are whole run directories the hook itself created, under
#   `<project>/.achilles/runs/`, whose basename matches the runId pattern
#   `YYYYmmddTHHMMSSZ[-N]`. Anything else in that directory is left alone.
# - Idempotent: a fingerprint (file count + byte total + newest mtime of the
#   candidate set) is recorded per archive; an unchanged candidate set is a
#   no-op, so the Stop backstop never duplicates what PostToolUse already took.
#   The same file also carries the Achilles Playwright reporter's claim when
#   that reporter is wired in: `claimedBy: "reporter"` plus the candidate set's
#   file count, byte total and newest mtime. This hook honours the claim only
#   while all three still match what is on disk, so the reporter's per-attempt
#   archive is not duplicated and nothing the reporter did not see is skipped.
# - Failure-tolerant: every step is guarded and the hook always exits 0. Losing
#   a run because the archiver broke is worse than losing the archive.
#
# Failure → action
# ----------------
# - Playwright artifacts changed since the last archive        → archive (RECORD)
# - Candidate set unchanged / absent                           → silent no-op
# - Reporter claim matches the candidate set on disk           → silent no-op
# - Non-Playwright Bash command                                → silent no-op
# - ACHILLES_ARTIFACT_RETAIN=0                                 → silent no-op (opt-out)
# - Candidate set above ACHILLES_ARTIFACT_MAX_MB               → archive small
#                                                                evidence, skip
#                                                                traces/videos, WARN
# - Older runs pruned past the retention window                → WARN (never silent)
# - Copy short of what was intended (disk full, permissions)   → archive kept and
#                                                                marked incomplete,
#                                                                WARN, fingerprint
#                                                                NOT stamped so the
#                                                                next invocation
#                                                                retries
# - jq missing / unwritable archive root / unreadable config   → silent no-op, exit 0

set -u

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0

INPUT=$(cat 2>/dev/null || echo "{}")

# Session-scope gate: reporting hooks run while the protocol is active OR
# after the pipeline completed; plain dev sessions silent-allow.
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
achilles_require_active_or_completed "$INPUT"

RETAIN="${ACHILLES_ARTIFACT_RETAIN:-5}"
case "$RETAIN" in ''|*[!0-9]*) RETAIN=5 ;; esac
[ "$RETAIN" -eq 0 ] && exit 0

MAX_MB="${ACHILLES_ARTIFACT_MAX_MB:-512}"
case "$MAX_MB" in ''|*[!0-9]*) MAX_MB=512 ;; esac

EVENT=$(printf '%s' "$INPUT" | "$JQ" -r '.hook_event_name // ""' 2>/dev/null || echo "")
TOOL=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // ""' 2>/dev/null || echo "")
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // ""' 2>/dev/null || echo "")
[ -n "$CWD" ] || CWD="$PWD"
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")
[ -d "$ROOT" ] || exit 0
# Normalise through cd/pwd so the prefix comparisons in rel_to_root() see the
# same symlink-resolved form the discovered paths do (/tmp vs /private/tmp).
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || exit 0

# ---------------------------------------------------------------------------
# Trigger. On Bash the command must actually be a Playwright run; on Stop /
# SubagentStop the fingerprint check below is the only gate (an interrupted
# run's PostToolUse may never fire, but its evidence is still evidence).
# ---------------------------------------------------------------------------
is_playwright_run() {
  local c="$1"
  printf '%s' "$c" | grep -qE '(^|[;&|[:space:]])(npx|bunx|pnpm[[:space:]]+(exec|dlx)|yarn[[:space:]]+(exec|dlx))?[[:space:]]*playwright[[:space:]]+test([[:space:]]|$)' && return 0
  printf '%s' "$c" | grep -qE 'achilles-self-repair|bin/self-repair\.mjs' && return 0
  # `npm|pnpm|yarn run <script>` — resolve the script body from package.json.
  local script
  script=$(printf '%s' "$c" | grep -oE '(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?[A-Za-z0-9:_-]+' | head -1 \
             | sed -E 's/^(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?//' || true)
  if [ -n "$script" ] && [ -f "$ROOT/package.json" ]; then
    local body
    body=$("$JQ" -r --arg s "$script" '.scripts[$s] // ""' "$ROOT/package.json" 2>/dev/null || echo "")
    printf '%s' "$body" | grep -qE 'playwright[[:space:]]+test' && return 0
  fi
  return 1
}

if [ "$TOOL" = "Bash" ] || [ "$EVENT" = "PostToolUse" ]; then
  is_playwright_run "$CMD" || exit 0
fi

# ---------------------------------------------------------------------------
# Path discovery. Config values are grepped, not evaluated — a hook must not
# execute a consumer's config. Anything unresolvable degrades to the
# Playwright default and is labelled `default` in the manifest.
# ---------------------------------------------------------------------------
CONFIG=""
for c in "$ROOT"/playwright.config.ts "$ROOT"/playwright.config.js "$ROOT"/playwright.config.mjs \
         "$ROOT"/playwright.config.cjs "$ROOT"/playwright.config.mts "$ROOT"/playwright.config.cts \
         "$ROOT"/tests/e2e/playwright.config.ts "$ROOT"/tests/e2e/playwright.config.js \
         "$ROOT"/tests/playwright.config.ts "$ROOT"/tests/playwright.config.js; do
  [ -f "$c" ] && { CONFIG="$c"; break; }
done
CONFIG_DIR="$ROOT"
[ -n "$CONFIG" ] && CONFIG_DIR=$(dirname "$CONFIG")

# cfg_value <key> — first single/double-quoted string literal assigned to <key>.
cfg_value() {
  [ -n "$CONFIG" ] || return 0
  grep -oE "$1[[:space:]]*:[[:space:]]*['\"][^'\"]+['\"]" "$CONFIG" 2>/dev/null \
    | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true
}

# rel_to_root <base-dir> <path> — path relative to $ROOT, or empty when outside.
rel_to_root() {
  local base="$1" p="$2" abs
  case "$p" in /*) abs="$p" ;; *) abs="$base/$p" ;; esac
  abs=$(cd "$(dirname "$abs")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$abs")") || return 0
  case "$abs" in
    "$ROOT"/*) printf '%s' "${abs#"$ROOT"/}" ;;
    *) return 0 ;;
  esac
}

# Command-line env prefixes win over the ambient environment: an agent that
# writes `PLAYWRIGHT_JSON_OUTPUT_NAME=x npx playwright test` sets it inline.
cmd_env() {
  printf '%s' "$CMD" | grep -oE "(^|[[:space:]])$1=[^[:space:];&|]+" | head -1 | sed -E "s/.*$1=//" || true
}

OUT_SRC="default"
OUT_DIR=$(printf '%s' "$CMD" | grep -oE -- '--output[= ][^[:space:];&|]+' | head -1 | sed -E 's/^--output[= ]//' || true)
[ -n "$OUT_DIR" ] && OUT_SRC="cli:--output"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR=$(cfg_value outputDir)
  [ -n "$OUT_DIR" ] && OUT_SRC="config:$(basename "$CONFIG"):outputDir"
fi
if [ -n "$OUT_DIR" ]; then
  OUT_REL=$(rel_to_root "$CONFIG_DIR" "$OUT_DIR")
else
  OUT_REL="test-results"
fi

REPORT_SRC="default"
REPORT_DIR="${PLAYWRIGHT_HTML_REPORT:-}"
[ -n "$REPORT_DIR" ] && REPORT_SRC="env:PLAYWRIGHT_HTML_REPORT"
if [ -z "$REPORT_DIR" ]; then
  REPORT_DIR=$(cfg_value outputFolder)
  [ -n "$REPORT_DIR" ] && REPORT_SRC="config:$(basename "$CONFIG"):outputFolder"
fi
if [ -n "$REPORT_DIR" ]; then
  REPORT_REL=$(rel_to_root "$CONFIG_DIR" "$REPORT_DIR")
else
  REPORT_REL="playwright-report"
fi

JSON_SRC="none"; JSON_REL=""
JSON_NAME=$(cmd_env PLAYWRIGHT_JSON_OUTPUT_NAME)
[ -n "$JSON_NAME" ] && JSON_SRC="cli:PLAYWRIGHT_JSON_OUTPUT_NAME"
if [ -z "$JSON_NAME" ] && [ -n "${PLAYWRIGHT_JSON_OUTPUT_NAME:-}" ]; then
  JSON_NAME="$PLAYWRIGHT_JSON_OUTPUT_NAME"; JSON_SRC="env:PLAYWRIGHT_JSON_OUTPUT_NAME"
fi
if [ -z "$JSON_NAME" ]; then
  JSON_NAME=$(cfg_value outputFile)
  [ -n "$JSON_NAME" ] && JSON_SRC="config:$(basename "$CONFIG"):outputFile"
fi
[ -n "$JSON_NAME" ] && JSON_REL=$(rel_to_root "$CONFIG_DIR" "$JSON_NAME")

JUNIT_REL=""
JUNIT_NAME=$(cmd_env PLAYWRIGHT_JUNIT_OUTPUT_NAME)
[ -z "$JUNIT_NAME" ] && JUNIT_NAME="${PLAYWRIGHT_JUNIT_OUTPUT_NAME:-}"
[ -n "$JUNIT_NAME" ] && JUNIT_REL=$(rel_to_root "$CONFIG_DIR" "$JUNIT_NAME")

# Candidate set: existing paths only, de-duplicated, nested paths dropped
# (a results.json inside outputDir travels with the directory copy).
CANDIDATES=(); KINDS=(); SOURCES=()
add_candidate() {
  local rel="$1" kind="$2" src="$3"
  [ -n "$rel" ] || return 0
  [ -e "$ROOT/$rel" ] || return 0
  local existing
  for existing in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    [ "$existing" = "$rel" ] && return 0
    case "$rel" in "$existing"/*) return 0 ;; esac
  done
  CANDIDATES+=("$rel"); KINDS+=("$kind"); SOURCES+=("$src")
}
add_candidate "$OUT_REL"    outputDir  "$OUT_SRC"
add_candidate "$REPORT_REL" htmlReport "$REPORT_SRC"
add_candidate "$JSON_REL"   jsonReport "$JSON_SRC"
add_candidate "$JUNIT_REL"  junitReport "cli-or-env:PLAYWRIGHT_JUNIT_OUTPUT_NAME"
# Last-resort JSON locations, only when nothing else claimed them.
[ -z "$JSON_REL" ] && for f in playwright-report/results.json test-results/results.json; do
  add_candidate "$f" jsonReport "fallback:$f"
done

[ "${#CANDIDATES[@]}" -gt 0 ] || exit 0

RUNS_DIR="$ROOT/.achilles/runs"
FP_FILE="$RUNS_DIR/.last-archive.json"

# stat_pairs <dir> — emits "<bytes> <mtime> <path>" per regular file, in one
# batched stat(1) call. BSD (macOS) and GNU take different format flags.
if stat -f %m . >/dev/null 2>&1; then
  stat_pairs() { find "$1" -type f -exec stat -f '%z %m %N' {} + 2>/dev/null; }
else
  stat_pairs() { find "$1" -type f -exec stat -c '%s %Y %n' {} + 2>/dev/null; }
fi

# Fingerprint: file count + byte total + digest of every (size, mtime, path) in
# the candidate set. File CONTENT is deliberately not hashed — digesting a
# 120 MB trace would cost more than archiving it. The residual blind spot is
# therefore narrow but real: two runs completing inside the same clock second
# and producing byte-identical trees at identical paths look like one run, and
# the second is treated as already archived. In practice a rerun changes at
# least one trace size and `.last-run.json`'s mtime.
FP_DIGEST="$(command -v shasum || command -v sha1sum || command -v cksum || true)"
fingerprint() {
  local rel listing count total digest
  listing=$(for rel in "${CANDIDATES[@]}"; do stat_pairs "$ROOT/$rel"; done | sort)
  count=$(printf '%s' "$listing" | grep -c . 2>/dev/null || echo 0)
  total=$(printf '%s' "$listing" | awk '{t+=$1} END{printf "%d", t+0}')
  if [ -n "$FP_DIGEST" ]; then
    digest=$(printf '%s' "$listing" | "$FP_DIGEST" 2>/dev/null | awk '{print $1}')
  fi
  printf '%s:%s:%s' "${count:-0}" "${total:-0}" "${digest:-nodigest}"
}

FP=$(fingerprint)
case "$FP" in 0:0:*) exit 0 ;; esac      # candidate paths exist but hold no files
PREV_FP=""
[ -f "$FP_FILE" ] && PREV_FP=$("$JQ" -r '.fingerprint // ""' "$FP_FILE" 2>/dev/null || echo "")
[ "$FP" = "$PREV_FP" ] && exit 0

# ---------------------------------------------------------------------------
# Reporter claim. The Achilles Playwright reporter archives each failing
# attempt as it happens and, from `onExit`, records what the run left on disk:
# per candidate path, the file count, byte total and newest mtime in whole
# seconds. It cannot compute the fingerprint above — that would mean
# reimplementing this script's stat/sort/digest pipeline in another language
# and keeping the two byte-identical — so it records the three quantities that
# ARE reproducible across implementations, and this hook checks those.
#
# Per PATH, not in aggregate, because this hook's candidate set is frequently a
# SUBSET of the reporter's: the reporter is handed the resolved config, while
# this hook greps it, so a computed `outputDir` is invisible here and only the
# html report is seen. The claim is honoured when every path THIS hook resolved
# appears in the claim with numbers that still match disk. Anything the
# reporter did not see is therefore never suppressed, and a stale or partial
# claim costs a duplicate archive rather than lost evidence.
# ---------------------------------------------------------------------------
if [ -f "$FP_FILE" ]; then
  CLAIM_BY=$("$JQ" -r '.claimedBy // ""' "$FP_FILE" 2>/dev/null || echo "")
  CLAIM_OK=$("$JQ" -r '.complete // false' "$FP_FILE" 2>/dev/null || echo "false")
  if [ "$CLAIM_BY" = "reporter" ] && [ "$CLAIM_OK" = "true" ]; then
    CLAIM_COVERS=yes
    for rel in "${CANDIDATES[@]}"; do
      CLAIMED=$("$JQ" -r --arg p "$rel" '.candidates.byPath[$p] // empty | "\(.files) \(.bytes) \(.newestMtime)"' "$FP_FILE" 2>/dev/null || echo "")
      [ -n "$CLAIMED" ] || { CLAIM_COVERS=no; break; }
      CUR=$(stat_pairs "$ROOT/$rel" \
            | awk '{n++; t+=$1; if ($2+0 > m) m=$2+0} END{printf "%d %d %d", n+0, t+0, m+0}')
      [ "$CLAIMED" = "$CUR" ] || { CLAIM_COVERS=no; break; }
    done
    [ "$CLAIM_COVERS" = "yes" ] && exit 0
  fi
fi

CAND_BYTES=${FP#*:}; CAND_BYTES=${CAND_BYTES%%:*}
CAND_FILES=${FP%%:*}
CEILING=$((MAX_MB * 1024 * 1024))
MODE="full"
[ "$CAND_BYTES" -gt "$CEILING" ] && MODE="reduced"

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
n=1
while [ -e "$RUNS_DIR/$RUN_ID" ]; do RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$n"; n=$((n + 1)); done
DEST="$RUNS_DIR/$RUN_ID"
mkdir -p "$DEST/artifacts" 2>/dev/null || exit 0

# Large blobs: Playwright traces (*.zip) and videos (*.webm / *.mp4). These are
# the bytes that fill disks; the small evidence (error-context.md, screenshots,
# JSON report) is what a diagnosis usually needs first, so `reduced` mode keeps
# it and drops only the blobs — never the other way round.
is_blob() { case "$1" in *.zip|*.webm|*.mp4) return 0 ;; *) return 1 ;; esac }

SKIPPED_JSON="[]"; ARCHIVED_BYTES=0; SKIPPED_BYTES=0
for rel in "${CANDIDATES[@]}"; do
  src="$ROOT/$rel"
  if [ "$MODE" = "full" ]; then
    mkdir -p "$DEST/artifacts/$(dirname "$rel")" 2>/dev/null || true
    cp -R "$src" "$DEST/artifacts/$rel" 2>/dev/null || true
    continue
  fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    frel="${f#"$ROOT"/}"
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' '); case "${sz:-}" in ''|*[!0-9]*) sz=0 ;; esac
    if is_blob "$f"; then
      SKIPPED_BYTES=$((SKIPPED_BYTES + ${sz:-0}))
      SKIPPED_JSON=$(printf '%s' "$SKIPPED_JSON" | "$JQ" -c --arg p "$frel" --argjson b "${sz:-0}" \
        '. + [{path:$p, bytes:$b}]' 2>/dev/null || printf '%s' "$SKIPPED_JSON")
      continue
    fi
    mkdir -p "$DEST/artifacts/$(dirname "$frel")" 2>/dev/null || true
    cp "$f" "$DEST/artifacts/$frel" 2>/dev/null || true
  done < <(find "$src" -type f 2>/dev/null)
done
ARCHIVED_BYTES=$(stat_pairs "$DEST/artifacts" | awk '{t+=$1} END{printf "%d", t+0}')
case "${ARCHIVED_BYTES:-}" in ''|*[!0-9]*) ARCHIVED_BYTES=0 ;; esac
ARCHIVED_FILES=$(find "$DEST/artifacts" -type f 2>/dev/null | wc -l | tr -d ' ')
case "${ARCHIVED_FILES:-}" in ''|*[!0-9]*) ARCHIVED_FILES=0 ;; esac

# Reconcile intended against actual. `cp` failures are tolerated (the run must
# never fail because of us) but they must never pass for a complete archive:
# a disk-full or permission error mid-copy would otherwise write a manifest
# claiming mode "full" and stamp the fingerprint, permanently marking a run
# archived whose evidence never landed — and the next run then wipes the
# originals. When the copy is short we say so and deliberately do NOT stamp
# the fingerprint, so the next invocation (or the Stop backstop) retries.
N_SKIPPED_FILES=$(printf '%s' "$SKIPPED_JSON" | "$JQ" -r 'length' 2>/dev/null || echo 0)
EXPECTED_FILES=$((CAND_FILES - ${N_SKIPPED_FILES:-0}))
EXPECTED_BYTES=$((CAND_BYTES - SKIPPED_BYTES))
[ "$EXPECTED_FILES" -lt 0 ] && EXPECTED_FILES=0
[ "$EXPECTED_BYTES" -lt 0 ] && EXPECTED_BYTES=0
INCOMPLETE=false
if [ "$ARCHIVED_FILES" -lt "$EXPECTED_FILES" ] || [ "$ARCHIVED_BYTES" -lt "$EXPECTED_BYTES" ]; then
  INCOMPLETE=true
fi

count_matching() { find "$DEST/artifacts" -type f -name "$1" 2>/dev/null | wc -l | tr -d ' '; }
N_TRACES=$(count_matching '*.zip'); N_VIDEOS=$(find "$DEST/artifacts" -type f \( -name '*.webm' -o -name '*.mp4' \) 2>/dev/null | wc -l | tr -d ' ')
N_SHOTS=$(count_matching '*.png'); N_CTX=$(count_matching 'error-context.md')

# Retention: keep the newest $RETAIN run directories. Only directories this
# hook created (runId-shaped basename, under .achilles/runs/) are ever removed.
PRUNED_JSON="[]"
# Portable read-into-array (bash 3.2 lacks `mapfile`; macOS ships 3.2).
# Only runId-shaped directories are counted or removed — anything else a
# consumer keeps under .achilles/runs/ is invisible to retention.
is_run_id() {
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) return 0 ;;
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}
ALL_RUNS=()
while IFS= read -r d; do
  b=$(basename "$d")
  is_run_id "$b" && ALL_RUNS+=("$b")
done < <(find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
TOTAL_RUNS=${#ALL_RUNS[@]}
if [ "$TOTAL_RUNS" -gt "$RETAIN" ]; then
  DROP=$((TOTAL_RUNS - RETAIN))
  for old in "${ALL_RUNS[@]:0:$DROP}"; do
    is_run_id "$old" || continue          # defence in depth — never rm anything else
    [ -d "$RUNS_DIR/$old" ] || continue
    rm -rf "${RUNS_DIR:?}/$old" 2>/dev/null || continue
    PRUNED_JSON=$(printf '%s' "$PRUNED_JSON" | "$JQ" -c --arg p "$old" '. + [$p]' 2>/dev/null || printf '%s' "$PRUNED_JSON")
  done
fi

SOURCES_JSON="[]"
i=0
while [ "$i" -lt "${#CANDIDATES[@]}" ]; do
  SOURCES_JSON=$(printf '%s' "$SOURCES_JSON" | "$JQ" -c \
    --arg p "${CANDIDATES[$i]}" --arg k "${KINDS[$i]}" --arg r "${SOURCES[$i]}" \
    '. + [{path:$p, kind:$k, resolvedFrom:$r}]' 2>/dev/null || printf '%s' "$SOURCES_JSON")
  i=$((i + 1))
done

CMD_TRUNC="$CMD"; [ ${#CMD_TRUNC} -gt 400 ] && CMD_TRUNC="${CMD_TRUNC:0:400}..."
"$JQ" -n \
  --arg id "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg ev "${EVENT:-unknown}" --arg cmd "$CMD_TRUNC" --arg mode "$MODE" \
  --argjson sources "$SOURCES_JSON" --argjson skipped "$SKIPPED_JSON" --argjson pruned "$PRUNED_JSON" \
  --argjson candBytes "${CAND_BYTES:-0}" --argjson archBytes "${ARCHIVED_BYTES:-0}" \
  --argjson skipBytes "${SKIPPED_BYTES:-0}" --argjson candFiles "${CAND_FILES:-0}" \
  --argjson traces "${N_TRACES:-0}" --argjson videos "${N_VIDEOS:-0}" \
  --argjson shots "${N_SHOTS:-0}" --argjson ctx "${N_CTX:-0}" \
  --argjson retain "$RETAIN" --argjson maxMb "$MAX_MB" \
  --argjson archFiles "${ARCHIVED_FILES:-0}" --argjson expFiles "${EXPECTED_FILES:-0}" \
  --argjson expBytes "${EXPECTED_BYTES:-0}" --argjson incomplete "$INCOMPLETE" \
  '{ schema: "playwright-run-archive/v1", runId: $id, timestamp: $ts, trigger: $ev,
     command: $cmd, mode: $mode, incomplete: $incomplete, sources: $sources,
     counts: { candidateFiles: $candFiles, expectedFiles: $expFiles,
               archivedFiles: $archFiles, traces: $traces, videos: $videos,
               screenshots: $shots, errorContexts: $ctx },
     bytes: { candidate: $candBytes, expected: $expBytes, archived: $archBytes,
              skipped: $skipBytes },
     skipped: $skipped,
     retention: { keep: $retain, maxMb: $maxMb, pruned: $pruned } }' \
  > "$DEST/manifest.json" 2>/dev/null || true

# Only a reconciled archive earns the fingerprint. Leaving it unstamped costs
# at worst a duplicate archive on the next invocation; stamping it after a
# short copy costs the evidence itself.
if [ "$INCOMPLETE" = "false" ]; then
  "$JQ" -n --arg fp "$FP" --arg id "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{fingerprint:$fp, runId:$id, timestamp:$ts}' > "$FP_FILE" 2>/dev/null || true
fi
ln -sfn "$RUN_ID" "$RUNS_DIR/latest" 2>/dev/null || true

# Nothing is ever discarded silently.
N_SKIPPED="${N_SKIPPED_FILES:-0}"
N_PRUNED=$(printf '%s' "$PRUNED_JSON" | "$JQ" -r 'length' 2>/dev/null || echo 0)
if [ "${N_SKIPPED:-0}" -gt 0 ] || [ "${N_PRUNED:-0}" -gt 0 ] || [ "$INCOMPLETE" = "true" ]; then
  MSG="[WARN] Playwright evidence archived to .achilles/runs/$RUN_ID with omissions."
  if [ "$INCOMPLETE" = "true" ]; then
    MSG="$MSG

INCOMPLETE: $ARCHIVED_FILES of $EXPECTED_FILES file(s) copied. Some artifacts could not be written to the archive (disk full, permissions, or an I/O error). The run was NOT marked as archived, so the next run command or Stop will retry — but the originals in the outputDir survive only until the next Playwright run starts. Copy anything you need out now."
  fi
  if [ "${N_SKIPPED:-0}" -gt 0 ]; then
    MSG="$MSG

Skipped $N_SKIPPED trace/video file(s) ($((SKIPPED_BYTES / 1048576)) MB): the run's artifacts exceeded ACHILLES_ARTIFACT_MAX_MB=${MAX_MB}. Screenshots, error-context.md and report JSON were archived. Raise the ceiling (ACHILLES_ARTIFACT_MAX_MB) before the next run if you need the traces, or copy them out of test-results/ now — the next run will wipe them."
  fi
  if [ "${N_PRUNED:-0}" -gt 0 ]; then
    MSG="$MSG

Pruned $N_PRUNED older run(s) past ACHILLES_ARTIFACT_RETAIN=${RETAIN}: $(printf '%s' "$PRUNED_JSON" | "$JQ" -r 'join(", ")' 2>/dev/null). Raise ACHILLES_ARTIFACT_RETAIN to keep more."
  fi
  MSG="$MSG

References:
  skills/element-interactions/references/harness-hooks.md §PostToolUse
  .achilles/runs/$RUN_ID/manifest.json"
  "$JQ" -n --arg m "$MSG" '{systemMessage:$m, suppressOutput:false}' 2>/dev/null || true
fi

exit 0
