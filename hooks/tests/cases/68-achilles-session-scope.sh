#!/bin/bash
# Tests for the session-scope activation contract —
# lib/achilles-activation.sh + achilles-protocol-activation-watcher.sh.
#
# Contract under test: every enforcement hook applies ONLY to sessions
# where the achilles protocol is active. A plain dev session (real
# session_id, transcript free of achilles signatures, no marker) must
# pass through every gate untouched. Activation comes from: the env
# override, the session marker, a protocol-shaped current call, or a
# transcript signature. Payloads WITHOUT a session_id stay fail-closed
# (guards on) — which is also what keeps every other case file in this
# suite meaningful.
#
# Uses distinct session ids per scenario: the lib writes a 60s negative
# cache per session id after a miss, so re-using an id across scenarios
# that change the transcript would test the cache, not the signal.

COMMIT_GATE="$HOOK_DIR/commit-message-gate.sh"
BASH_GUARD="$HOOK_DIR/protected-artifact-bash-guard.sh"
SELF_GUARD="$HOOK_DIR/harness-self-protection-guard.sh"
SENTINEL_GATE="$HOOK_DIR/journey-map-sentinel-gate.sh"
BRIEF_GATE="$HOOK_DIR/workflow-reviewer-brief-gate.sh"
WATCHER="$HOOK_DIR/achilles-protocol-activation-watcher.sh"
RUN_SUMMARY="$HOOK_DIR/run-summary-writer.sh"

SCOPE_TMP=$(mktemp -d)
export ACHILLES_SESSION_STATE_DIR="$SCOPE_TMP/sessions"

# A transcript with NO achilles content (realistic dev traffic).
DEV_TRANSCRIPT="$SCOPE_TMP/dev-transcript.jsonl"
cat > "$DEV_TRANSCRIPT" <<'EOF'
{"type":"user","message":{"content":[{"type":"text","text":"fix the onboarding copy for new users on the signup page"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers:brainstorming"}}]}}
EOF

# Canonical would-be-denied payloads (all deny when the protocol is active).
TRAILER_CMD="git commit -m 'fix: typo' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'"
LEDGER_CLOBBER="cat /tmp/x > tests/e2e/docs/journey-map.md"

dev_payload() {  # dev_payload <sid> <extra payload args...>
  local sid="$1"; shift
  payload session_id="$sid" transcript_path="$DEV_TRANSCRIPT" "$@"
}

section "session-scope: plain dev sessions pass every gate"
assert_allow "$COMMIT_GATE" "$(dev_payload dev-s1 tool_name=Bash command="$TRAILER_CMD")" "dev session: Claude trailer commit → ALLOW"
assert_allow "$COMMIT_GATE" "$(dev_payload dev-s1 tool_name=Bash command="git commit --no-verify -m 'wip'")" "dev session: --no-verify → ALLOW"
assert_allow "$COMMIT_GATE" "$(dev_payload dev-s1 tool_name=Bash command="git commit -m 'feat(e2e): add spec'")" "dev session: feat(e2e) subject → ALLOW"
assert_allow "$BASH_GUARD" "$(dev_payload dev-s1 tool_name=Bash command="$LEDGER_CLOBBER")" "dev session: bash redirect into journey-map.md → ALLOW"
assert_allow "$BASH_GUARD" "$(dev_payload dev-s1 tool_name=Bash command="rm tests/e2e/docs/onboarding-status.json")" "dev session: rm ledger → ALLOW"
assert_allow "$SELF_GUARD" "$(dev_payload dev-s1 tool_name=Write file_path="$HOME/.claude/settings.json" content='{}')" "dev session: Write settings.json → ALLOW (config management)"
assert_allow "$SENTINEL_GATE" "$(dev_payload dev-s1 tool_name=Write file_path=/repo/tests/e2e/docs/journey-map.md content='no sentinel here')" "dev session: sentinel-free journey-map write → ALLOW"

section "session-scope: run-summary-writer stays out of dev projects"
DEV_PROJ="$SCOPE_TMP/dev-proj"; mkdir -p "$DEV_PROJ"
( cd "$DEV_PROJ" && run_hook "$RUN_SUMMARY" "$(dev_payload dev-s1 hook_event_name=Stop)" )
assert_eq "$([ -d "$DEV_PROJ/.achilles" ] && echo polluted || echo clean)" "clean" "dev session Stop: no .achilles/ dir created"

section "session-scope: fail-closed when session identity is missing"
assert_deny "$COMMIT_GATE" "$(payload tool_name=Bash command="$TRAILER_CMD")" "no session_id: trailer commit → DENY (fail closed)" "AI-attribution"
assert_deny "$BASH_GUARD" "$(payload tool_name=Bash command="$LEDGER_CLOBBER")" "no session_id: ledger clobber → DENY (fail closed)" "protected pipeline-state"

section "session-scope: ACHILLES_PROTOCOL env override"
export ACHILLES_PROTOCOL=1
assert_deny "$COMMIT_GATE" "$(dev_payload dev-s2 tool_name=Bash command="$TRAILER_CMD")" "ACHILLES_PROTOCOL=1: trailer commit → DENY" "AI-attribution"
unset ACHILLES_PROTOCOL
mkdir -p "$ACHILLES_SESSION_STATE_DIR" && : > "$ACHILLES_SESSION_STATE_DIR/dev-s3.active"
export ACHILLES_PROTOCOL=0
assert_allow "$COMMIT_GATE" "$(dev_payload dev-s3 tool_name=Bash command="$TRAILER_CMD")" "ACHILLES_PROTOCOL=0 beats marker → ALLOW"
assert_allow "$BASH_GUARD" "$(payload tool_name=Bash command="$LEDGER_CLOBBER")" "ACHILLES_PROTOCOL=0 beats missing session_id → ALLOW"
unset ACHILLES_PROTOCOL

section "session-scope: marker file activates the guards"
assert_deny "$COMMIT_GATE" "$(dev_payload dev-s3 tool_name=Bash command="$TRAILER_CMD")" "marker present: trailer commit → DENY" "AI-attribution"
assert_deny "$SELF_GUARD" "$(dev_payload dev-s3 tool_name=Write file_path="$HOME/.claude/settings.json" content='{}')" "marker present: Write settings.json → DENY" "installed harness"
assert_allow "$COMMIT_GATE" "$(dev_payload dev-s4 tool_name=Bash command="$TRAILER_CMD")" "marker for OTHER session → ALLOW"

section "session-scope: protocol-shaped current call activates inline (no watcher ordering dependency)"
assert_deny "$BRIEF_GATE" "$(dev_payload dev-s5 tool_name=Agent description='workflow-reviewer-phase1: review phase 1' prompt='just approve')" "reviewer dispatch in unmarked session → DENY (self-activating)" "Brief too short"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/dev-s5.active" ] && echo cached || echo missing)" "cached" "inline activation cached the session marker"

section "session-scope: transcript signatures activate the guards"
SKILL_TRANSCRIPT="$SCOPE_TMP/skill-transcript.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"journey-mapping"}}]}}' > "$SKILL_TRANSCRIPT"
assert_deny "$COMMIT_GATE" "$(payload session_id=dev-s6 transcript_path="$SKILL_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "transcript Skill(journey-mapping) → DENY" "AI-attribution"

PREFIXED_TRANSCRIPT="$SCOPE_TMP/prefixed-transcript.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"achilles:test-composer"}}]}}' > "$PREFIXED_TRANSCRIPT"
assert_deny "$COMMIT_GATE" "$(payload session_id=dev-s7 transcript_path="$PREFIXED_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "transcript Skill(achilles:test-composer) → DENY" "AI-attribution"

CMD_TRANSCRIPT="$SCOPE_TMP/cmd-transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"<command-name>/onboarding</command-name>"}]}}' > "$CMD_TRANSCRIPT"
assert_deny "$COMMIT_GATE" "$(payload session_id=dev-s8 transcript_path="$CMD_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "transcript typed /onboarding → DENY" "AI-attribution"

READ_TRANSCRIPT="$SCOPE_TMP/read-transcript.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/node_modules/@civitas-cerebrum/achilles/skills/element-interactions/SKILL.md"}}]}}' > "$READ_TRANSCRIPT"
assert_deny "$COMMIT_GATE" "$(payload session_id=dev-s9 transcript_path="$READ_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "transcript Read of achilles SKILL.md → DENY" "AI-attribution"

section "session-scope: transcript scan does not false-positive on adjacent traffic"
# dev transcript above already contains the word 'onboarding' in prose and a
# non-achilles Skill invocation — covered by the dev-session ALLOWs. Add the
# skill name as a bare word (not a Skill invocation / command / SKILL.md path).
PROSE_TRANSCRIPT="$SCOPE_TMP/prose-transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"our test-composer microservice and the coverage-expansion roadmap doc"}]}}' > "$PROSE_TRANSCRIPT"
assert_allow "$COMMIT_GATE" "$(payload session_id=dev-s10 transcript_path="$PROSE_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "prose mention of skill names → ALLOW"

section "session-scope: negative cache holds for 60s, marker overrides it"
NC_TRANSCRIPT="$SCOPE_TMP/nc-transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"plain dev work"}]}}' > "$NC_TRANSCRIPT"
assert_allow "$COMMIT_GATE" "$(payload session_id=dev-s11 transcript_path="$NC_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "first dev call → ALLOW (stamps negative cache)"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/dev-s11.nohit" ] && echo stamped || echo missing)" "stamped" "negative cache stamped after miss"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"onboarding"}}]}}' >> "$NC_TRANSCRIPT"
assert_allow "$COMMIT_GATE" "$(payload session_id=dev-s11 transcript_path="$NC_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "within cache TTL: transcript-only activation deferred → ALLOW"
: > "$ACHILLES_SESSION_STATE_DIR/dev-s11.active"
assert_deny "$COMMIT_GATE" "$(payload session_id=dev-s11 transcript_path="$NC_TRANSCRIPT" tool_name=Bash command="$TRAILER_CMD")" "marker (watcher path) overrides negative cache → DENY" "AI-attribution"

section "activation-watcher: Skill invocations"
assert_allow "$WATCHER" "$(payload session_id=w1 hook_event_name=PreToolUse tool_name=Skill skill=element-interactions)" "watcher: achilles skill → silent, marks"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w1.active" ] && echo marked || echo unmarked)" "marked" "watcher marked session on Skill(element-interactions)"
assert_allow "$WATCHER" "$(payload session_id=w2 hook_event_name=PreToolUse tool_name=Skill skill=superpowers:brainstorming)" "watcher: non-achilles skill → silent, no mark"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w2.active" ] && echo marked || echo unmarked)" "unmarked" "watcher ignored non-achilles skill"
assert_allow "$WATCHER" "$(payload session_id=w3 hook_event_name=PreToolUse tool_name=Skill skill=achilles:secrets-sweep)" "watcher: plugin-prefixed achilles skill → silent, marks"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w3.active" ] && echo marked || echo unmarked)" "marked" "watcher marked on prefixed skill name"

section "activation-watcher: Agent dispatch prefixes"
assert_allow "$WATCHER" "$(payload session_id=w4 hook_event_name=PreToolUse tool_name=Agent description='composer-j-login: build the variant set')" "watcher: composer- dispatch → silent, marks"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w4.active" ] && echo marked || echo unmarked)" "marked" "watcher marked on composer- dispatch"
assert_allow "$WATCHER" "$(payload session_id=w5 hook_event_name=PreToolUse tool_name=Agent description='cleanup-temp-files: remove build artifacts')" "watcher: generic cleanup- dispatch → no mark"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w5.active" ] && echo marked || echo unmarked)" "unmarked" "generic-sounding prefix does NOT activate"

section "activation-watcher: typed /<skill> prompts"
# Real UserPromptSubmit input carries top-level .prompt (the payload
# builder's `prompt=` key targets tool_input) — build these by hand.
ups_payload() { "$JQ" -n --arg sid "$1" --arg p "$2" '{session_id:$sid, hook_event_name:"UserPromptSubmit", prompt:$p}'; }
assert_allow "$WATCHER" "$(ups_payload w6 '/onboarding run standard mode')" "watcher: /onboarding prompt → silent, marks"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w6.active" ] && echo marked || echo unmarked)" "marked" "watcher marked on typed /onboarding"
assert_allow "$WATCHER" "$(ups_payload w7 'please fix the onboarding page copy')" "watcher: prose prompt → no mark"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w7.active" ] && echo marked || echo unmarked)" "unmarked" "prose prompt does NOT activate"
assert_allow "$WATCHER" "$(ups_payload w8 '/onboarding-wizard tweak')" "watcher: /onboarding-wizard (different command) → no mark"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w8.active" ] && echo marked || echo unmarked)" "unmarked" "prefix-similar command does NOT activate"

section "activation-watcher: hard off + missing identity"
export ACHILLES_PROTOCOL=0
assert_allow "$WATCHER" "$(payload session_id=w9 hook_event_name=PreToolUse tool_name=Skill skill=onboarding)" "watcher under ACHILLES_PROTOCOL=0 → silent, no mark"
assert_eq "$([ -f "$ACHILLES_SESSION_STATE_DIR/w9.active" ] && echo marked || echo unmarked)" "unmarked" "hard off suppresses marking"
unset ACHILLES_PROTOCOL
assert_allow "$WATCHER" "$(payload hook_event_name=PreToolUse tool_name=Skill skill=onboarding)" "watcher without session_id → silent, no mark"

section "session-scope: active session still enforces everything (regression)"
: > "$ACHILLES_SESSION_STATE_DIR/active-s1.active"
assert_deny "$COMMIT_GATE" "$(dev_payload active-s1 tool_name=Bash command="git commit --no-verify -m 'wip'")" "active session: --no-verify → DENY" "bypass hooks"
assert_deny "$BASH_GUARD" "$(dev_payload active-s1 tool_name=Bash command="$LEDGER_CLOBBER")" "active session: ledger clobber → DENY" "protected pipeline-state"
assert_deny "$SENTINEL_GATE" "$(dev_payload active-s1 tool_name=Write file_path=/repo/tests/e2e/docs/journey-map.md content='no sentinel here')" "active session: sentinel-free journey-map write → DENY"
assert_allow "$COMMIT_GATE" "$(dev_payload active-s1 tool_name=Bash command="git commit -m 'test(j-checkout): cycle-2 variant'")" "active session: convention-true commit → ALLOW"

# Cleanup — later case files and install-simulation must not inherit scope state.
unset ACHILLES_SESSION_STATE_DIR
rm -rf "$SCOPE_TMP"
