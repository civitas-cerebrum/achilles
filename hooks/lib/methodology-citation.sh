# methodology-citation.sh — transcript-aware "read the methodology" block
# for hook deny messages.
#
# Why
# ---
# A deny that only names the technical violation invites shape-tweaking:
# the agent re-emits the call with a cosmetic change and hits the same
# wall, burning cycles without ever loading the contract it violated.
# Every agentic-OS deny therefore ends with a methodology citation that
# is AWARE of the executing context's transcript:
#
#   - transcript shows no trace of the cited doc → the block is a
#     MANDATORY NEXT STEP instruction: Read the doc before any retry,
#     with the section that specifies the rule.
#   - transcript already references the doc → the block switches to a
#     re-apply reminder (no point instructing a re-read).
#
# Enforceability: for hard rules the Read instruction is directive — the
# denied action stays denied whether or not the doc is read (reading is
# how the agent finds the CONFORMANT path, not an unlock). Where a rule
# is gate-shaped ("this action is legitimate once the skill was loaded"),
# the transcript-preread pattern IS hard-enforceable — see
# journey-mapping-skill-preread-gate.sh, which denies until the
# transcript shows the Skill/Read. This lib deliberately reuses the same
# transcript signal so both postures cite evidence the same way.
#
# Fail-open posture: no transcript_path (harness didn't supply one) or
# unreadable file → treated as "not read" (the stronger instruction);
# never an error.

# methodology_block <transcript-path> <doc-path> <section-hint>
#
# Prints the citation block. <doc-path> is the repo-relative methodology
# reference (e.g. skills/element-interactions/references/agentic-os-roles.md),
# <section-hint> names the section that specifies the violated rule.
methodology_block() {
  local transcript="$1" doc="$2" section="$3"
  local docbase
  docbase=$(basename "$doc")
  if [ -n "$transcript" ] && [ -f "$transcript" ] && grep -qF -- "$docbase" "$transcript" 2>/dev/null; then
    cat <<EOF
Methodology: ${doc} ${section}
Your transcript shows this reference was already loaded in this context —
re-apply it. The constraint above is specified there; retrying a
different spelling of the same action will produce the same deny.
EOF
  else
    cat <<EOF
MANDATORY NEXT STEP before any retry:
  1. Read ${doc} — the rule you hit is specified in ${section}.
  2. Re-shape the work to conform. This deny repeats for every
     non-conforming attempt; only a conforming call proceeds.
Your transcript shows no Read of ${docbase} in this context yet.
EOF
  fi
}
