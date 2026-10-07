#!/bin/bash
# deck-inspection-gate.sh: a rendered deck must be inspected before any further dispatch.
# PostToolUse:Bash records a sentinel after export-pdf.js; PreToolUse:Agent denies while it exists.
H="$HOOK_DIR/deck-inspection-gate.sh"
with_tmp_project_into DK deck stub-bin
DECK="$DK/proj/deck"
SENT="$DECK/.deck-pending-inspection"
agent() { payload hook_event_name=PreToolUse tool_name=Agent description='reviewer-x: review' prompt='Review.' cwd="$DECK"; }
export_cmd() { payload hook_event_name=PostToolUse tool_name=Bash command="$1" cwd="$DECK"; }
# Render dirs are named by the second; clear them so a prior run's pages cannot satisfy the next.
reset() { rm -rf "$SENT" "$DK"/deck-inspection-*; }
has_sentinel() { [ -f "$SENT" ] && echo yes || echo no; }

# pdftoppm stand-in so the render path is independent of poppler being installed.
STUB="$DK/proj/stub-bin"
printf '#!/bin/sh\nout=""; for a; do out="$a"; done\n[ "${STUB_PAGES:-1}" = 0 ] || : > "$out-1.png"\n' > "$STUB/pdftoppm"
chmod +x "$STUB/pdftoppm"
printf '%%PDF-1.4\n' > "$DECK/deck.pdf"
export TMPDIR="$DK"

section "deck-inspection-gate: Agent dispatch"
assert_allow "$H" "$(agent)" "no sentinel → Agent dispatch ALLOW"
printf 'pdf_path=%s\ninspect_dir=MANUAL\npage_count=3\n' "$DECK/deck.pdf" > "$SENT"
assert_deny "$H" "$(agent)" "sentinel present → Agent dispatch DENY" "DECK INSPECTION GATE — BLOCKED"
assert_deny "$H" "$(payload hook_event_name=PreToolUse tool_name=Agent description='reviewer-x: review' prompt='Review.' cwd="$DECK/sub")" "cwd below the sentinel dir → still DENY" "Pages:    3"
assert_allow "$H" "$(payload hook_event_name=PreToolUse tool_name=Agent description='reviewer-x: review' prompt='Review.' cwd="$DK")" "cwd outside the deck dir → ALLOW"
DECK_INSPECTION_GATE=0 assert_allow "$H" "$(agent)" "DECK_INSPECTION_GATE=0 → ALLOW with sentinel present"
reset
assert_allow "$H" "$(agent)" "sentinel cleared → ALLOW again"

section "deck-inspection-gate: export detection"
PATH="$STUB:$PATH" assert_warn "$H" "$(export_cmd 'node export-pdf.js deck.html')" "export produced a PDF and pages → systemMessage" "DECK INSPECTION GATE"
assert_eq "$(has_sentinel)" "yes" "…and the sentinel is written"
assert_eq "$(grep -c '^page_count=1$' "$SENT")" "1" "…recording the rendered page count"
assert_deny "$H" "$(agent)" "…so the next Agent dispatch is DENIED" "BLOCKED"
reset
printf 'x' > "$DECK/rel.pdf"
PATH="$STUB:$PATH" assert_warn "$H" "$(export_cmd 'cd x && node /a/export-pdf.js rel.html; echo done')" "export arg followed by shell separators → PDF resolved, gated" "DECK INSPECTION GATE"
reset
STUB_PAGES=0 PATH="$STUB:$PATH" assert_allow "$H" "$(export_cmd 'node export-pdf.js deck.html')" "renderer produced no pages → silent ALLOW"
assert_eq "$(has_sentinel)" "no" "…and no sentinel"
assert_allow "$H" "$(export_cmd 'node export-pdf.js missing.html')" "export produced no PDF → silent ALLOW"
assert_eq "$(has_sentinel)" "no" "…and no sentinel"
assert_allow "$H" "$(export_cmd 'ls')" "non-export Bash → silent ALLOW"
DECK_INSPECTION_GATE=0 assert_allow "$H" "$(export_cmd 'node export-pdf.js deck.html')" "DECK_INSPECTION_GATE=0 → export not gated"
assert_eq "$(has_sentinel)" "no" "…and no sentinel"

section "deck-inspection-gate: other events"
assert_allow "$H" "$(payload hook_event_name=PreToolUse tool_name=Bash command='ls' cwd="$DECK")" "PreToolUse:Bash → silent ALLOW"
