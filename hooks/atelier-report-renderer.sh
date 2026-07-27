#!/bin/bash
# atelier-report-renderer.sh — Stop-time auto-render of the harness-atelier
#                              report.
#
# Hook  : Stop
# Mode  : silent observer (never blocks; best-effort render; no output)
# Scope : any project whose <project>/.achilles/atelier-telemetry.jsonl
#         exists and is non-empty — the telemetry file IS the opt-in
#         signal, because the collector only writes it in opted-in
#         projects (achilles project, `.atelier` marker, or
#         ATELIER_TELEMETRY=on). Everywhere else: inert.
# Env   : ATELIER_AUTORENDER=off → disable auto-render
#         ATELIER_RENDERER=<path> → explicit visualizer path (tests /
#         other harnesses that vend their own copy)
#
# Why
# ---
# The report should be fresh at the moment a session ends: run the
# harness, open .achilles/harness-atelier.html — no manual
# `npm run atelier` step between. The render is skipped when the existing
# report is already newer than the telemetry (cheap no-op on idle Stops).
#
# Baseline: when a pinned aggregate exists at
# <project>/.achilles/atelier-baseline.json (create one with
# `npm run atelier -- --json > .achilles/atelier-baseline.json`), the
# render passes --baseline so the report carries the vs-baseline
# regression section — session-over-session drift with zero extra steps.
#
# Renderer resolution (first hit wins): $ATELIER_RENDERER, the repo's own
# atelier/harness-atelier.mjs, then installed package copies (the achilles
# package under node_modules/@civitas-cerebrum/*, or the standalone
# harness-atelier package once severed into its own repo). No renderer or
# no node on PATH → silent no-op; a failed render never affects the Stop.
#
# Pairs with:
#   hooks/atelier-telemetry-collector.sh  (writes the telemetry this renders)
#   atelier/harness-atelier.mjs           (the visualizer)
#
# Canonical reference
# -------------------
# skills/element-interactions/references/harness-atelier.md

set -uo pipefail

[ "${ATELIER_AUTORENDER:-on}" = "off" ] && exit 0

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"

INPUT=$(cat 2>/dev/null || echo "")
GUARD_CWD=""
if [ -n "$JQ" ] && [ -n "$INPUT" ]; then
  GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null || echo "")
fi
[ -n "$GUARD_CWD" ] || GUARD_CWD="$PWD"
REPO_ROOT=$(cd "$GUARD_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")

TELEMETRY="$REPO_ROOT/.achilles/atelier-telemetry.jsonl"
REPORT="$REPO_ROOT/.achilles/harness-atelier.html"
[ -s "$TELEMETRY" ] || exit 0
# Already fresh (report newer than the telemetry) → no-op.
if [ -f "$REPORT" ] && [ "$REPORT" -nt "$TELEMETRY" ]; then exit 0; fi

NODE_BIN=$(command -v node || true)
[ -n "$NODE_BIN" ] || exit 0

RENDERER=""
for CAND in "${ATELIER_RENDERER:-}" \
  "$REPO_ROOT/atelier/harness-atelier.mjs" \
  "$REPO_ROOT/node_modules/@civitas-cerebrum/achilles/atelier/harness-atelier.mjs" \
  "$REPO_ROOT/node_modules/@civitas-cerebrum/element-interactions/atelier/harness-atelier.mjs" \
  "$REPO_ROOT/node_modules/harness-atelier/harness-atelier.mjs"; do
  [ -n "$CAND" ] && [ -f "$CAND" ] && { RENDERER="$CAND"; break; }
done
[ -n "$RENDERER" ] || exit 0

BASELINE="$REPO_ROOT/.achilles/atelier-baseline.json"
if [ -f "$BASELINE" ]; then
  "$NODE_BIN" "$RENDERER" --project "$REPO_ROOT" --out "$REPORT" --baseline "$BASELINE" >/dev/null 2>&1 || true
else
  "$NODE_BIN" "$RENDERER" --project "$REPO_ROOT" --out "$REPORT" >/dev/null 2>&1 || true
fi
exit 0
