#!/bin/bash
# 42-reviewer-round36.sh — regressions for round 36 of independent
# adversarial review.
#
# Round 35 fixed the scheme test's CASE. Round 36 took the same function
# and asked whether the list was COMPLETE:
#
#     curl -s http://localhost:4173 rtmp://127.0.0.1:9999/live/x   -> ALLOW
#
# The reviewer stood up a listener on 127.0.0.1:9999 and ran the
# kernel-approved command; curl opened a live TCP connection to a
# destination the manifest forbids. `gophers`, `smbs`, `rtmp` and
# `rtmps` are all compiled into this machine's curl and none of them was
# on the kernel's list.
#
# The shape was wrong by this project's OWN stated principle, and the
# proof is two functions away: the network scan exempts a known-safe set
# of text commands and checks everything unknown, "because the unknown
# tool that connects is more dangerous than the unknown tool that
# prints". The scheme test did the opposite — it enumerated the network
# schemes, so an unrecognised scheme meant "not a network URL" and
# failed OPEN.
#
# It also coupled the kernel to libcurl's compiled protocol table: a
# list some other tool maintains and this one had to match, which is the
# coupling the benchmark records being burned by again and again. That
# is the part worth keeping. Inverting removes the coupling entirely —
# anything spelled `scheme://…` is a destination unless the scheme names
# something LOCAL or INERT, so a protocol curl adds next year needs no
# edit here.
#
# Round 36 also executed nine other helpers against their contracts and
# found them sound, which is recorded in docs/benchmark.md: a documented
# "these held" is a result, not an absence of one.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-36 regressions"

R36=$(mktemp -d)
P="$R36/proj"
mkdir -p "$P/.claude" "$P/docs"
printf 'ac\n' > "$P/docs/ac.md"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
export KERNEL_MANDATE_STATE_DIR="$R36/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "r36",
  "settings": {
    "mainSessionRole": "scoped",
    "mcpPathArguments": { "mcp__fs__read_file": { "read": ["path"] } }
  },
  "commandGroups": { "probe": ["^curl\\b", "^(echo|cat)\\b"] },
  "roles": {
    "scoped": {
      "description": "Declares where it may connect.",
      "tools": { "allow": ["Bash", "WebFetch", "mcp__fs__*"] },
      "bash": { "groups": ["probe"] },
      "network": { "allow": ["localhost:4173"] },
      "read": { "allow": ["docs/**"] }
    }
  }
}
JSON
printf 'scoped\n' > "$KERNEL_MANDATE_STATE_DIR/agents/scoped"

bp() { "$JQ" -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:"scoped"}'; }
wf() { "$JQ" -nc --arg u "$1" '{tool_name:"WebFetch",tool_input:{url:$u},cwd:"'"$P"'",agent_id:"scoped"}'; }
mp() { "$JQ" -nc --arg v "$1" '{tool_name:"mcp__fs__read_file",tool_input:{path:$v},cwd:"'"$P"'",agent_id:"scoped"}'; }

# --- Every scheme curl compiles, and one nobody has heard of ----------
for scheme in rtmp rtmps gophers gopher smbs smb dict tftp ldaps imaps pop3s telnet scp sftp mqtt; do
  assert_deny "$H" "$(bp "curl -s http://localhost:4173 ${scheme}://127.0.0.1:9999/x")" \
    "R36 ${scheme}:// to a forbidden host → DENY" "outside the role's network scope"
done
assert_deny "$H" "$(bp 'curl -s http://localhost:4173 whatever://127.0.0.1:9999/x')" \
  "R36 a scheme nobody has heard of is checked, not skipped → DENY" "outside the role's network scope"
assert_deny "$H" "$(bp 'curl -s http://localhost:4173 RTMP://127.0.0.1:9999/x')" \
  "R36 and round 35's case rule still applies to it → DENY" "outside the role's network scope"

# --- Calibration: an unusual scheme INSIDE the scope is fine ----------
# The rule is about the destination, not about the protocol.
assert_allow "$H" "$(bp 'curl -s http://localhost:4173 rtmp://localhost:4173/x')" \
  "R36 calibration: an unusual scheme to a permitted host → ALLOW"
assert_allow "$H" "$(bp 'curl -s http://localhost:4173/forms')" \
  "R36 calibration: the app under test → ALLOW"

# --- The LOCAL and INERT schemes must not become destinations ---------
# Inverting the test means everything is a destination by default, so
# the schemes that name something local have to be right or the axis
# starts denying ordinary reads.
assert_allow "$H" "$(wf 'data:text/plain,hello')" \
  "R36 calibration: data: is inline content, not a host → ALLOW"
assert_deny "$H" "$(wf "file://$P/.env")" \
  "R36 calibration: file:// is still a READ, not a destination → DENY" "outside the role's read scope"
assert_allow "$H" "$(wf "file://$P/docs/ac.md")" \
  "R36 calibration: ...and an in-scope one still passes → ALLOW"
assert_deny "$H" "$(mp "file://$P/.env")" \
  "R36 calibration: the MCP arm agrees → DENY" "outside the role's read scope"
assert_allow "$H" "$(mp 'rtmp://example.com/x')" \
  "R36 calibration: MCP treats an unusual scheme as remote, not a path → ALLOW"

# --- WebFetch inherits the same predicate ----------------------------
assert_deny "$H" "$(wf 'rtmp://evil.example/x')" \
  "R36 WebFetch: an unusual scheme is still a destination → DENY" "outside the role's network scope"
