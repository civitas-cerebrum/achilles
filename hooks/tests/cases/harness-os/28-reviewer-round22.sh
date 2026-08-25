#!/bin/bash
# 28-reviewer-round22.sh — regressions for round 22 of independent
# adversarial review.
#
#   F1  self-protection was attached to tool NAMES, not to the act of
#       writing. The axis is a `case "$HOS_TOOL"` with two arms —
#       `Write|Edit|NotebookEdit` and `Bash` — and a mapped MCP write
#       tool matches neither, so the manifest, the role bindings, the
#       hook registration and the installed kernel were reachable
#       through it untouched by any of the screen.
#
#       The MCP axis holds a mapped tool's path arguments to the role's
#       write scope and stops there, which is not enough. A config role
#       whose scope legitimately covers `.claude/**` could rewrite the
#       file that says what it may do — and then grant itself
#       `bash.unrestricted`, or forge a binding naming itself the judge,
#       or overwrite the hook registration and disable the kernel
#       entirely. The role's OWN manifest never had to be over-broad.
#
# The kernel's comment for this axis promises, verbatim, that no
# governed role may change these things "whatever its other grants".
# That was true of two write channels out of three.
#
# The fix is a single function called from all three, and factoring it
# out found the second half of the problem: the two existing copies had
# ALREADY DRIFTED. The Bash copy was missing the bare `.claude/hooks`
# entry the Write/Edit copy had. Round 13 made this exact argument about
# the read scan's positional-program exemption — a rule duplicated per
# channel is a rule that will differ per channel — and the difference is
# always found by a reviewer rather than by its authors.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-22 regressions"

R22=$(mktemp -d)
P="$R22/proj"
mkdir -p "$P/.claude/harness-os.state/agents" "$P/.claude/hooks"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
unset HARNESS_OS_STATE_DIR   # exercise the DEFAULT state-dir location

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r22",
  "settings": {
    "mainSessionRole": "orchestrator",
    "mcpPathArguments": { "mcp__fs__write*": { "write": ["path"] }, "mcp__fs__read*": { "read": ["path"] } }
  },
  "roles": {
    "orchestrator": { "description": "root", "tools": { "allow": ["Read"] }, "read": { "allow": ["**"] } },
    "config-keeper": {
      "description": "Maintains the project's .claude configuration.",
      "tools": { "allow": ["Write", "Edit", "mcp__*"] },
      "read":  { "allow": [".claude/**"] },
      "write": { "allow": [".claude/**"] }
    }
  }
}
JSON
printf 'config-keeper\n' > "$P/.claude/harness-os.state/agents/ck"

mcpw() { "$JQ" -nc --arg p "$1" \
  '{tool_name:"mcp__fs__write_file",tool_input:{path:$p},cwd:"'"$P"'",agent_id:"ck"}'; }
mcpr() { "$JQ" -nc --arg p "$1" \
  '{tool_name:"mcp__fs__read_file",tool_input:{path:$p},cwd:"'"$P"'",agent_id:"ck"}'; }
wr()   { "$JQ" -nc --arg f "$1" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:"x"},cwd:"'"$P"'",agent_id:"ck"}'; }

# --- F1: the third write channel carries the screen too ---------------
assert_deny "$H" "$(mcpw "$P/.claude/harness-os.json")" \
  "F1 a mapped MCP write may not rewrite the manifest → DENY" "modify the harness OS itself"
assert_deny "$H" "$(mcpw "$P/.claude/harness-os.state/agents/attacker")" \
  "F1 nor forge a role binding in the state dir → DENY" "modify the harness OS itself"
assert_deny "$H" "$(mcpw "$P/.claude/settings.json")" \
  "F1 nor rewrite the hook registration → DENY" "modify the harness OS itself"
assert_deny "$H" "$(mcpw "$P/.claude/settings.local.json")" \
  "F1 nor its local override → DENY" "modify the harness OS itself"
assert_deny "$H" "$(mcpw "$P/.claude/hooks/evil.sh")" \
  "F1 nor plant a hook beside the kernel → DENY" "modify the harness OS itself"
assert_deny "$H" "$(mcpw "$P/node_modules/@civitas-cerebrum/harness-os/hooks/harness-os-role-gate.sh")" \
  "F1 nor truncate the installed kernel → DENY" "modify the harness OS itself"

# The core tools were always protected; pin that the three channels now
# agree rather than merely that the new one works.
assert_deny "$H" "$(wr "$P/.claude/harness-os.json")" \
  "F1 the Write tool, as before → DENY" "modify the harness OS itself"
assert_deny "$H" "$(wr "$P/.claude/hooks")" \
  "F1 the bare .claude/hooks entry the Bash copy had DRIFTED without" \
  "modify the harness OS itself"

# --- calibration: the role's actual job still works -------------------
# `.claude/**` is a legitimate write scope for a config role, and the
# point of self-protection is that it holds WITHOUT narrowing that scope.
assert_allow "$H" "$(mcpw "$P/.claude/notes.md")" \
  "calibration: an ordinary file in the role's scope → ALLOW"
assert_allow "$H" "$(mcpr "$P/.claude/harness-os.json")" \
  "calibration: READING the manifest stays allowed — it is the law the role is held to"
assert_deny "$H" "$(mcpw "$P/elsewhere.md")" \
  "calibration: and the write scope itself still applies" "outside"

# --- self-probe: the same question asked of every other axis ----------
# Round 22's lesson generalises into a question worth asking of any
# check in this kernel: not "is it correct?" but "how many channels
# implement it, and do they agree?" Asking it turned up two more before
# the next reviewer arrived, and both are the same shape — a rule the
# kernel already knows, absent from one channel.
#
#   A fetch tool is a read channel whenever its URL names the local
#   filesystem. The kernel knew that in TWO other places: the code
#   screen refuses `page.goto("file:///…")`, and the MCP axis unwraps
#   `file://` before scoping — with a comment recording that skipping
#   anything merely containing "://" had once let `file://secret` past.
#   Neither copy covered `WebFetch`, whose entire job is fetching a URL.
#
#   And the dispatch gate fired on the tool name `Agent` alone. `Task`
#   is the same operation under another name, and which one a host uses
#   is the host's business — a dispatch gate that knows only one of them
#   is a dispatch gate a rename switches off.
FP="$R22/fetch"
mkdir -p "$FP/.claude" "$FP/tests"
printf 'SECRET=hunter2\n' > "$FP/.env"
printf 'x\n' > "$FP/tests/a.txt"
cat > "$FP/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r22b",
  "settings": { "mainSessionRole": "fetcher" },
  "commandGroups": { "g": ["^cat\\b"] },
  "roles": {
    "fetcher": {
      "description": "Reads the served app and the test tree.",
      "tools": { "allow": ["*"] },
      "bash": { "groups": ["g"] },
      "read": { "allow": ["tests/**"] },
      "dispatch": ["fetcher"]
    }
  }
}
JSON
mkdir -p "$R22/fstate/agents"; printf 'fetcher\n' > "$R22/fstate/agents/f1"
fp() { "$JQ" -nc --arg t "$1" --argjson i "$2" \
  '{tool_name:$t,tool_input:$i,cwd:"'"$FP"'",agent_id:"f1"}'; }
export HARNESS_OS_STATE_DIR="$R22/fstate"
export HARNESS_OS_MANIFEST="$FP/.claude/harness-os.json"

assert_deny "$H" "$(fp WebFetch '{"url":"file:///etc/passwd"}')" \
  "self-probe WebFetch of a file:// URL is a READ → DENY" "read scope"
assert_deny "$H" "$(fp WebFetch '{"url":"file://.env"}')" \
  "self-probe the relative file:// form → DENY" "read scope"
assert_deny "$H" "$(fp WebFetch '{"url":"../.env"}')" \
  "self-probe a bare relative path as the URL → DENY" "read scope"
assert_deny "$H" "$(fp WebFetch '{"url":"/etc/passwd"}')" \
  "self-probe a bare absolute path → DENY" "read scope"

assert_allow "$H" "$(fp WebFetch '{"url":"https://example.com/x"}')" \
  "self-probe calibration: a genuinely remote URL → ALLOW"
assert_allow "$H" "$(fp WebFetch '{"url":"http://localhost:4173/forms"}')" \
  "self-probe calibration: the served app → ALLOW"
assert_allow "$H" "$(fp WebFetch "{\"url\":\"file://$FP/tests/a.txt\"}")" \
  "self-probe calibration: a file:// INSIDE the read scope → ALLOW"

# `Task` must be governed exactly as `Agent` is — both directions.
assert_deny "$H" "$(fp Task '{"description":"other: go","prompt":"y"}')" \
  "self-probe Task dispatching an unlisted role → DENY" "dispatch"
assert_deny "$H" "$(fp Task '{"description":"fetcher: go","prompt":"y"}')" \
  "self-probe Task without the binding tag → DENY, as Agent is" "binding tag"
assert_allow "$H" "$(fp Task '{"description":"fetcher: go","prompt":"<<harness-os-role: fetcher>>\ndo it"}')" \
  "self-probe calibration: a properly tagged Task → ALLOW"
assert_allow "$H" "$(fp Agent '{"description":"fetcher: go","prompt":"<<harness-os-role: fetcher>>\ndo it"}')" \
  "self-probe calibration: and Agent behaves identically → ALLOW"

unset HARNESS_OS_MANIFEST HARNESS_OS_STATE_DIR
rm -rf "$R22"
