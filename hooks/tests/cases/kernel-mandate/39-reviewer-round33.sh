#!/bin/bash
# 39-reviewer-round33.sh — regressions for round 33 of independent
# adversarial review.
#
# Round 33 asked round 31's question — what can a granted verb actually
# DO — of the LIVE benchmark rather than of a template, and found the
# one category this kernel had no model for at all.
#
# The bench grants its inspector, in a group named `inspection`:
#
#     ^curl -[a-zA-Z]* http://localhost:4173\b
#
# which reads as "this role may talk to the app under test and nothing
# else". Pointed at
#
#     curl -s http://localhost:4173@example.com/
#
# curl connects to example.com: `localhost:4173` is USERINFO, not a
# host. The reviewer ran it — a real connection to a real external host
# — and then shipped an in-scope acceptance-criteria file to a listener
# off-box with `-d @docs/acceptance/...`, the Authorization header
# reading `Basic bG9jYWxob3N0OjQxNzM=` as proof of what curl had parsed.
#
# Three capabilities in one ALLOW: arbitrary external egress, SSRF to
# any other local port, and exfiltration of the role's entire in-scope
# context. That last one is the property this project advertises most —
# a bounded blast radius for prompt injection — and it was never
# enforced on this channel, though the authored-code screen has flagged
# `fetch`/`request.get`/`net` as an exfiltration capability since round
# 1. A rule that exists on one channel and not on its neighbour, for the
# sixth time, and on the load-bearing one.
#
# A URL authority is a PARSER problem and a command group is a prefix
# match, so no pattern an operator can write is a destination boundary.
# Two rules, neither of which hunts for dangerous hosts:
#
#   userinfo is refused outright — an agent has no reason to embed
#   credentials in a URL, and it is the one spelling that makes a URL's
#   visible prefix differ from where it connects;
#
#   `network.allow` scopes destinations by PARSING the authority, which
#   also closes `http://localhost:4173.evil.com/` — a second bug with
#   the same cause, since `\b` ends a pattern where a hostname does not.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-33 regressions"

R33=$(mktemp -d)
P="$R33/proj"
mkdir -p "$P/.claude" "$P/docs"
export KERNEL_MANDATE_STATE_DIR="$R33/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "r33",
  "settings": { "mainSessionRole": "scoped" },
  "commandGroups": {
    "probe": ["^curl\\b", "^(echo|cat)\\b"]
  },
  "roles": {
    "scoped": {
      "description": "Declares where it may connect.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["probe"] },
      "network": { "allow": ["localhost:4173"] },
      "read": { "allow": ["docs/**"] }
    },
    "unscoped": {
      "description": "Declares no network scope — only the userinfo rule applies.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["probe"] },
      "read": { "allow": ["docs/**"] }
    },
    "wide": {
      "description": "Legitimately allowed a whole domain and its subdomains.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["probe"] },
      "network": { "allow": ["*.example.com", "localhost"] },
      "read": { "allow": ["docs/**"] }
    }
  }
}
JSON
for r in scoped unscoped wide; do printf '%s\n' "$r" > "$KERNEL_MANDATE_STATE_DIR/agents/$r"; done

bp() { "$JQ" -nc --arg c "$1" --arg a "${2:-scoped}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# The command group grants `curl` PLAINLY here, which is the point: once
# destinations are a scope, an operator stops trying to encode them in a
# regex that cannot express them. Every deny below comes from the network
# axis rather than from the allow set.

# --- Userinfo: refused for every role, scoped or not -------------------
for role in scoped unscoped wide; do
  assert_deny "$H" "$(bp 'curl -s http://localhost:4173@example.com/' "$role")" \
    "R33 the URL that was proven, role=$role → DENY" "userinfo"
done
for spec in \
  "curl -s http://localhost:4173@localhost:22/|SSRF to another local port" \
  "curl -s https://a@b@evil.com/x|the last @ is the one that decides" \
  "curl -s http://user:pass@evil.com/|an ordinary credentials URL" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R33 $label → DENY" "userinfo"
done

# --- network.allow scopes by PARSING, not by prefix --------------------
assert_deny "$H" "$(bp 'curl -s http://localhost:4173.evil.com/')" \
  "R33 a host that merely STARTS with the granted one → DENY" "outside the role's network scope"
assert_deny "$H" "$(bp 'curl -s http://localhost:9999/')" \
  "R33 another port on the same host → DENY" "outside the role's network scope"
assert_deny "$H" "$(bp 'curl -s http://LOCALHOST:4173.evil.com/')" \
  "R33 and case does not help → DENY" "outside the role's network scope"

# --- Calibration: the role's actual job -------------------------------
assert_allow "$H" "$(bp 'curl http://localhost:4173/forms')" \
  "R33 calibration: the app under test → ALLOW"
assert_allow "$H" "$(bp 'curl -sI http://localhost:4173/')" \
  "R33 calibration: with flags → ALLOW"
assert_allow "$H" "$(bp 'curl -s http://localhost:4173/?next=http://evil.com/')" \
  "R33 calibration: a URL inside a QUERY STRING is not a destination → ALLOW"
assert_allow "$H" "$(bp 'echo see http://localhost:4173/forms')" \
  "R33 calibration: a URL in prose → ALLOW"

# --- An unscoped role is unchanged apart from userinfo ----------------
# The scope is opt-in, like codeImports: a default of "no network" would
# refuse every existing manifest's health check.
assert_allow "$H" "$(bp 'curl -s http://localhost:4173.evil.com/' unscoped)" \
  "R33 without a declared scope, only userinfo is enforced → ALLOW"

# --- Wildcards mean what they say -------------------------------------
assert_allow "$H" "$(bp 'curl -s http://localhost:4173/x' wide)" \
  "R33 a bare host entry permits any port → ALLOW"
assert_allow "$H" "$(bp 'curl -s http://api.example.com/x' wide)" \
  "R33 *.example.com permits a subdomain → ALLOW"
assert_allow "$H" "$(bp 'curl -s http://example.com/x' wide)" \
  "R33 ...and the domain itself → ALLOW"
assert_deny "$H" "$(bp 'curl -s http://example.com.evil.net/x' wide)" \
  "R33 but not a host that merely contains it → DENY" "outside the role's network scope"
assert_deny "$H" "$(bp 'curl -s http://notexample.com/x' wide)" \
  "R33 nor one that merely ends with it → DENY" "outside the role's network scope"
