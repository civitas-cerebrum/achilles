#!/bin/bash
# 40-reviewer-round34.sh — regressions for round 34 of independent
# adversarial review.
#
# Round 7 recorded that a layer is most dangerous in the window right
# after it is promoted to load-bearing and before anyone has attacked
# it. Round 33 built the network axis; round 34 was pointed at it
# immediately and walked through it in one command:
#
#     curl -s http://localhost:4173 --connect-to localhost:4173:127.0.0.1:9999
#
# The URL token parses to `localhost:4173` and is in scope. The override
# carries the real destination as a bare `host:port` with no `://`, so a
# URL-token scanner never looks at it — and curl dialled 127.0.0.1:9999.
# The reviewer ran it, took the connection on a listener, and then
# shipped `docs/acceptance/registration.md` through the same command.
# Every capability round 33 had just claimed to close, back in one
# ALLOW, through a channel round 33's fix did not touch.
#
# Round 33's own stated invariant is the one that broke: does the string
# the kernel parses equal the host the client dials? For a client whose
# destination can be overridden by a flag, the URL is not that string.
#
#   --connect-to / --resolve  move the destination and leave the URL
#   -x / --proxy              make the proxy the destination
#   -K / --config             move the destination into a FILE
#   http_proxy= and friends   move it into the environment
#   WebFetch                  had no network scope at all — the axis was
#                             built on Bash and stopped there, on the
#                             tool whose entire job is fetching a URL
#
# All five are closed here. The enumeration of curl's override flags is
# an enumeration and the reviewer's objection to it is correct and
# recorded: the next flag always arrives, and the sound boundary is
# egress enforced OUTSIDE the process. `network.allow` is advisory for
# any role that can run curl until one is in place, which is what
# `validate` and the architecture doc now say in those words.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-34 regressions"

R34=$(mktemp -d)
P="$R34/proj"
mkdir -p "$P/.claude" "$P/docs"
export HARNESS_OS_STATE_DIR="$R34/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r34",
  "settings": { "mainSessionRole": "scoped" },
  "commandGroups": { "probe": ["^curl\\b", "^(echo|cat)\\b"] },
  "roles": {
    "scoped": {
      "description": "Declares where it may connect.",
      "tools": { "allow": ["Bash", "WebFetch"] },
      "bash": { "groups": ["probe"] },
      "network": { "allow": ["localhost:4173"] },
      "read": { "allow": ["docs/**"] }
    },
    "pinned": {
      "description": "Scope names the address, not just the name.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["probe"] },
      "network": { "allow": ["localhost:4173", "127.0.0.1"] },
      "read": { "allow": ["docs/**"] }
    },
    "unscoped": {
      "description": "Declares no network scope.",
      "tools": { "allow": ["Bash", "WebFetch"] },
      "bash": { "groups": ["probe"] },
      "read": { "allow": ["docs/**"] }
    }
  }
}
JSON
for r in scoped pinned unscoped; do printf '%s\n' "$r" > "$HARNESS_OS_STATE_DIR/agents/$r"; done

bp() { "$JQ" -nc --arg c "$1" --arg a "${2:-scoped}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }
wf() { "$JQ" -nc --arg u "$1" --arg a "${2:-scoped}" \
  '{tool_name:"WebFetch",tool_input:{url:$u},cwd:"'"$P"'",agent_id:$a}'; }

# --- Destination overrides that are not URLs --------------------------
for spec in \
  "curl -s http://localhost:4173 --connect-to localhost:4173:127.0.0.1:9999|the command that was proven" \
  "curl -s http://localhost:4173 --connect-to=localhost:4173:evil.com:80|its = spelling" \
  "curl -s http://localhost:4173 --resolve localhost:4173:203.0.113.5|--resolve, which redirects the address" \
  "curl -s http://localhost:4173 -x evil.example.com:8080|a schemeless proxy" \
  "curl -s http://localhost:4173 -xevil.example.com:8080|its attached spelling" \
  "curl -s http://localhost:4173 --proxy=evil.com:80|--proxy with =" \
  "curl -s http://localhost:4173 --socks5 evil.com:1080|a socks proxy" \
  "curl -s http://localhost:4173 --preproxy evil.com:80|a pre-proxy" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R34 $label → DENY" "network scope"
done

# A destination that moves into a FILE cannot be checked, so it is
# refused rather than checked against a URL that is no longer the one
# being used.
assert_deny "$H" "$(bp 'curl -s http://localhost:4173 -K /tmp/c')" \
  "R34 options read from a file → DENY" "options from a file"
assert_deny "$H" "$(bp 'curl -s http://localhost:4173 --config /tmp/c')" \
  "R34 ...in its long spelling → DENY" "options from a file"

# ...and one that moves into the ENVIRONMENT.
for spec in \
  "http_proxy=http://evil.com curl http://localhost:4173/|http_proxy" \
  "HTTPS_PROXY=evil.com:8080 curl http://localhost:4173/|HTTPS_PROXY" \
  "ALL_PROXY=socks5://evil.com curl http://localhost:4173/|ALL_PROXY" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R34 $label → DENY" "in front of a command"
done

# --- Calibration: the role's job, and an override pointing IN scope ----
assert_allow "$H" "$(bp 'curl http://localhost:4173/forms')" \
  "R34 calibration: the app under test → ALLOW"
assert_allow "$H" "$(bp 'curl -s http://localhost:4173 --connect-to localhost:4173:localhost:4173')" \
  "R34 calibration: an override that stays in scope → ALLOW"
# `--resolve NAME:PORT:ADDRESS` says "when you look up this name, use
# this address" — so the ADDRESS is the destination, and the kernel
# cannot know that 127.0.0.1 is localhost without doing DNS, which is
# not its job. A scope naming a hostname does not cover an address, and
# refusing is the answer that does not require the kernel to guess.
assert_deny "$H" "$(bp 'curl -s http://localhost:4173 --resolve localhost:4173:127.0.0.1')" \
  "R34 --resolve to an address the scope does not name → DENY" "network scope"
assert_allow "$H" "$(bp 'curl -s http://localhost:4173 --resolve localhost:4173:127.0.0.1' pinned)" \
  "R34 ...and a scope that names the address permits it → ALLOW"
assert_allow "$H" "$(bp 'CI=1 curl http://localhost:4173/')" \
  "R34 calibration: an ordinary env assignment → ALLOW"
assert_allow "$H" "$(bp 'echo curl --connect-to is a flag')" \
  "R34 calibration: the flag NAME in prose → ALLOW"

# An unscoped role keeps its old behaviour: the override checks are what
# a declared scope buys, and the proxy-env screen is not.
assert_allow "$H" "$(bp 'curl -s http://localhost:4173 -x evil.example.com:8080' unscoped)" \
  "R34 without a declared scope, overrides are not checked → ALLOW"

# --- The fetch tool gets the same scope as the shell -------------------
assert_deny "$H" "$(wf 'https://evil.example/')" \
  "R34 WebFetch is held to the network scope → DENY" "outside the role's network scope"
assert_deny "$H" "$(wf 'http://localhost:4173@evil.example/')" \
  "R34 and to the userinfo rule → DENY" "userinfo"
assert_allow "$H" "$(wf 'http://localhost:4173/forms')" \
  "R34 calibration: fetching the app under test → ALLOW"
assert_allow "$H" "$(wf 'https://evil.example/' unscoped)" \
  "R34 calibration: no declared scope, no destination check → ALLOW"
