#!/bin/bash
# deck-inspection-gate.sh — forces visual PDF inspection before a deck
#                           task can be considered complete.
#
# Hook    : PostToolUse:Bash  (detect export-pdf.js → render pages → set sentinel)
#           PreToolUse:Agent  (DENY agent dispatch while sentinel exists)
# Mode    : RECORD (Post) / DENY (Pre)
# State   : .deck-pending-inspection  (sentinel, in the directory holding the PDF)
#           /tmp/deck-inspection-<ts>/ (rendered page images)
# Env     : DECK_INSPECTION_GATE=0  (opt-out — disables the gate entirely)
#
# Rule
# ----
# After export-pdf.js produces a PDF, the agent MUST visually inspect every
# rendered page before the task can be considered complete. The hook:
#   1. (PostToolUse) detects a successful export-pdf.js run
#   2. renders the PDF pages to PNG images via pdftoppm
#   3. writes a sentinel file listing the pages to inspect
#   4. emits a systemMessage instructing the agent to Read each page
#
# While the sentinel exists, Agent dispatches are DENIED — the orchestrator
# cannot delegate completion to a subagent that has no awareness of the gate.
# The agent clears the sentinel by deleting it after inspecting all pages.
#
# Why
# ---
# PDF export can silently introduce layout overflows, clipped text, missing
# content, and collision issues that are invisible in the HTML source. The
# work-summary-deck skill prescribes inspection but has no enforcement —
# under context pressure the agent routinely skips it. This hook makes the
# skip structurally impossible: the export itself triggers the gate, and
# the only exit is visual verification followed by explicit sentinel removal.
#
# Known limit: macOS Preview transparency artifacts (grey boxes from
# box-shadow/opacity/rgba) do NOT reproduce in poppler renders, so pdftoppm
# cannot catch them. That class of bug is prevented at authoring time via
# the skill's print-safety rules (rule 1), not at inspection time.
#
# Canonical reference
# -------------------
# skills/work-summary-deck/SKILL.md §"Print-safety rules" (lesson 7)
#
# Failure → action
# ----------------
# - export-pdf.js detected in completed Bash    → render + sentinel + systemMessage
# - Agent dispatch while sentinel exists         → DENY
# - pdftoppm not installed                       → sentinel + systemMessage (manual mode)
# - PDF not found on disk after export           → silent allow (export failed)
# - Non-export Bash command                      → silent allow
# - No sentinel present on Agent dispatch        → silent allow
# - DECK_INSPECTION_GATE=0                       → silent allow (opt-out)

set -uo pipefail

# Opt-out.
[ "${DECK_INSPECTION_GATE:-1}" != "0" ] || exit 0

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0

INPUT=$(cat 2>/dev/null || echo "{}")

EVENT=$(printf '%s' "$INPUT" | "$JQ" -r '.hook_event_name // ""' 2>/dev/null || echo "")
TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // ""' 2>/dev/null || echo "")

# ─── PostToolUse:Bash — detect export, render pages, set sentinel ─────────

if [ "$EVENT" = "PostToolUse" ] && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")

  # Only trigger on export-pdf.js invocations.
  echo "$CMD" | grep -q 'export-pdf\.js' || exit 0

  # Extract the HTML path argument from the command.
  # Pattern: node <path>/export-pdf.js <html-file> [pdf-file]
  HTML_ARG=$(echo "$CMD" | grep -oE 'export-pdf\.js[[:space:]]+[^[:space:];&|]+' \
           | sed 's/export-pdf\.js[[:space:]]*//' || true)
  [ -n "$HTML_ARG" ] || exit 0

  # Resolve working directory.
  CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // ""' 2>/dev/null || echo "")
  [ -n "$CWD" ] || CWD=$(pwd)

  # Resolve the HTML path (may be relative).
  if [[ "$HTML_ARG" = /* ]]; then
    HTML_PATH="$HTML_ARG"
  else
    HTML_PATH="$CWD/$HTML_ARG"
  fi

  # Derive PDF path (same logic as export-pdf.js: .html → .pdf).
  PDF_PATH="${HTML_PATH%.html}.pdf"
  [ -f "$PDF_PATH" ] || PDF_PATH="${HTML_PATH%.HTML}.pdf"
  [ -f "$PDF_PATH" ] || exit 0   # Export itself may have failed; nothing to gate.

  PDF_DIR=$(dirname "$PDF_PATH")
  SENTINEL="$PDF_DIR/.deck-pending-inspection"
  TIMESTAMP=$(date +%Y%m%dT%H%M%S)
  INSPECT_DIR="/tmp/deck-inspection-${TIMESTAMP}"

  # Render PDF pages to PNG images using pdftoppm (part of poppler).
  PDFTOPPM=$(command -v pdftoppm || true)
  if [ -n "$PDFTOPPM" ]; then
    mkdir -p "$INSPECT_DIR"
    "$PDFTOPPM" -png -r 150 "$PDF_PATH" "$INSPECT_DIR/page" 2>/dev/null

    # Collect rendered page paths.
    PAGE_COUNT=0
    PAGE_PATHS=""
    for img in "$INSPECT_DIR"/page-*.png; do
      [ -f "$img" ] || continue
      PAGE_COUNT=$((PAGE_COUNT + 1))
      PAGE_PATHS="${PAGE_PATHS}${img}
"
    done

    if [ "$PAGE_COUNT" -eq 0 ]; then
      # pdftoppm produced no output — degrade gracefully.
      rm -rf "$INSPECT_DIR"
      exit 0
    fi

    # Write sentinel.
    printf 'pdf_path=%s\ninspect_dir=%s\npage_count=%s\ntimestamp=%s\n%s' \
      "$PDF_PATH" "$INSPECT_DIR" "$PAGE_COUNT" "$TIMESTAMP" "$PAGE_PATHS" \
      > "$SENTINEL"

    # Build the page list for the agent message.
    PAGE_MSG=""
    for img in "$INSPECT_DIR"/page-*.png; do
      [ -f "$img" ] || continue
      PAGE_MSG="${PAGE_MSG}
  - ${img}"
    done

    MSG="[DECK INSPECTION GATE] PDF exported successfully: ${PDF_PATH}

You MUST now visually inspect every rendered page before delivering the deck. ${PAGE_COUNT} page(s) rendered to PNG:
${PAGE_MSG}

Action required:
1. Use the Read tool on EACH page image above to verify layout, clipping, collisions, and content.
2. After inspecting all pages, run:  rm \"${SENTINEL}\"
3. Only then may you dispatch agents or consider the deck complete.

This is a hard gate — Agent dispatches are DENIED while .deck-pending-inspection exists."

    "$JQ" -n --arg m "$MSG" '{systemMessage:$m, suppressOutput:false}' 2>/dev/null || true

  else
    # pdftoppm not available — set sentinel anyway with a manual-inspection instruction.
    printf 'pdf_path=%s\ninspect_dir=MANUAL\npage_count=0\ntimestamp=%s\n' \
      "$PDF_PATH" "$TIMESTAMP" \
      > "$SENTINEL"

    MSG="[DECK INSPECTION GATE] PDF exported: ${PDF_PATH}

⚠  pdftoppm is not installed — automatic page rendering skipped.
Install it with:  brew install poppler

You MUST still visually inspect the PDF before delivering. Open it and check every page:
  open \"${PDF_PATH}\"

After inspection, clear the gate:
  rm \"${SENTINEL}\""

    "$JQ" -n --arg m "$MSG" '{systemMessage:$m, suppressOutput:false}' 2>/dev/null || true
  fi

  exit 0
fi

# ─── PreToolUse:Agent — DENY while sentinel exists ────────────────────────

if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL_NAME" = "Agent" ]; then
  # Search for a sentinel starting from the working directory.
  CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // ""' 2>/dev/null || echo "")
  [ -n "$CWD" ] || CWD=$(pwd)

  SENTINEL=""
  CHECK_DIR="$CWD"

  # Walk up from CWD, also probing common e2e subdirectories.
  for _ in 1 2 3 4 5; do
    [ -n "$CHECK_DIR" ] || break

    if [ -f "$CHECK_DIR/.deck-pending-inspection" ]; then
      SENTINEL="$CHECK_DIR/.deck-pending-inspection"
      break
    fi

    for sub in apps/e2e tests/e2e e2e; do
      if [ -f "$CHECK_DIR/$sub/.deck-pending-inspection" ]; then
        SENTINEL="$CHECK_DIR/$sub/.deck-pending-inspection"
        break 2
      fi
    done

    PARENT=$(dirname "$CHECK_DIR")
    [ "$PARENT" = "$CHECK_DIR" ] && break   # hit filesystem root
    CHECK_DIR="$PARENT"
  done

  [ -n "$SENTINEL" ] || exit 0

  # Sentinel exists — read it for the deny message.
  PDF_PATH=$(grep '^pdf_path=' "$SENTINEL" 2>/dev/null | head -1 | cut -d= -f2- || echo "unknown")
  PAGE_COUNT=$(grep '^page_count=' "$SENTINEL" 2>/dev/null | head -1 | cut -d= -f2- || echo "?")
  INSPECT_DIR=$(grep '^inspect_dir=' "$SENTINEL" 2>/dev/null | head -1 | cut -d= -f2- || echo "")

  # Build the page list if we have rendered images.
  PAGE_MSG=""
  if [ -n "$INSPECT_DIR" ] && [ "$INSPECT_DIR" != "MANUAL" ] && [ -d "$INSPECT_DIR" ]; then
    for img in "$INSPECT_DIR"/page-*.png; do
      [ -f "$img" ] || continue
      PAGE_MSG="${PAGE_MSG}
  - ${img}"
    done
  fi

  REASON="[DECK INSPECTION GATE — BLOCKED] Agent dispatch denied.

A deck PDF has been exported but not yet visually inspected:
  PDF:      ${PDF_PATH}
  Pages:    ${PAGE_COUNT}
  Sentinel: ${SENTINEL}"

  if [ -n "$PAGE_MSG" ]; then
    REASON="${REASON}

Rendered page images to Read:${PAGE_MSG}"
  fi

  REASON="${REASON}

You must Read each rendered page image to verify the PDF is free of layout
issues before dispatching any agent or considering the task complete.

To clear this gate after inspection:  rm \"${SENTINEL}\""

  "$JQ" -n --arg r "$REASON" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }' 2>/dev/null || true

  exit 0
fi

# Not our event — silent allow.
exit 0
