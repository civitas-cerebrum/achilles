#!/bin/bash
# 23-reviewer-round16.sh — regressions for round 16 of independent
# adversarial review.
#
# Round 16 was pointed at the awk/sed screen with the note that it was
# the newest and most pattern-heavy code in the kernel, and that its
# author was uneasy about it. That unease was correct.
#
#   F1  the screen matched constructs and read the LITERAL beside them —
#       `getline < ".env"` — so it saw nothing when the literal moved one
#       inch:
#
#         awk 'BEGIN{c="cat .env"; print "" | c; close(c)}'
#         awk 'BEGIN{c="sh -c \"id; cat .env\""; print | c}'
#         awk 'BEGIN{f=".env"; while((getline l<f)>0) print l}'
#         awk 'BEGIN{f="/tmp/pwned"; print "P" > f}'
#         awk 'BEGIN{f=".claude/kernel-mandate.json"; print "{x}" > f}'
#         sed -n '1r.env' f
#
#       Five ways past it, defeating command groups, read scope, write
#       scope and self-protection — the last of those corrupting the
#       manifest, which is where round 15's takeover began.
#
# The fix is not a better pattern. Round 8 had already ruled on this
# exact shape: a channel that turns data into execution must be CLOSED,
# not pattern-matched. That ruling was made about authoring code through
# Bash and was not carried across to interpreters invoked directly — the
# same failure to migrate a lesson that rounds 4, 12, 13 and 15 each
# recorded in their own way. It is now the second time round 8 has had
# to be learned.
#
# So the question is inverted. INERT is what must be proved: no
# `system`, `getline`, `close` or `ENVIRON`; no `print`/`printf`
# carrying a pipe or a redirect; and for sed no `r`/`R`/`w`/`W`/`e`/`F`
# /`v` command once its `s` and `y` bodies and regex addresses are
# removed. Anything else is refused whatever it names, which is the only
# form of the check indirection cannot walk around. awk and sed join
# `python -c` and `eval` in the indirection list, where a role that
# genuinely needs them opts in through `bash.permit`.
#
# Two details cost a cycle each and are pinned below. String and regex
# literals must be stripped BEFORE the statement scan, because a `}`
# inside `print "{x}" > f` ends the scan early and hid the redirect. And
# `-e` is sed's expression FLAG as well as the first letter of its
# shell-out command; reading the flag as the command refuses `sed -e p`,
# which is as ordinary as sed gets.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-16 regressions"

R16=$(mktemp -d)
P="$R16/proj"
mkdir -p "$P/.claude" "$P/tests"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'x\n' > "$P/tests/a.txt"
export KERNEL_MANDATE_STATE_DIR="$R16/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r16",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "inspect": ["^awk\\b", "^sed\\b", "^grep\\b", "^cat\\b"] },
  "roles": {
    "inspector": {
      "description": "Inspects the app surface. awk and sed are its tools.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspect"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/**"] }
    },
    "trusted": {
      "description": "Explicitly opted in to interpreter constructs.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspect"], "permit": ["awk-program", "sed-program"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/**"] }
    }
  }
}
JSON

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
printf 'inspector\n' > "$KERNEL_MANDATE_STATE_DIR/agents/inspector"
printf 'trusted\n' > "$KERNEL_MANDATE_STATE_DIR/agents/trusted"
bpay() { "$JQ" -nc --arg c "$1" --arg a "${2:-inspector}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- F1: indirection through a variable is refused --------------------
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{c="cat .env"; print "" | c; close(c)}'"'"'')" \
  "F1 a command pipe whose target is a VARIABLE → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{c="sh -c \"id; cat .env\""; print | c}'"'"'')" \
  "F1 the same shape reaching a whole shell → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{f=".env"; while((getline l<f)>0) print l}'"'"'')" \
  "F1 getline from a variable path → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{f="/tmp/x"; print "P" > f}'"'"'')" \
  "F1 print INTO a variable path → DENY" "run a command or open a file"
# Round 45 moved this one's deny a gate EARLIER: naming the manifest as
# an operand of a command whose operands are not provably read-only is
# refused by self-protection before the awk screen is consulted. Denied
# either way, and the more specific message is the better one to show.
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{f=".claude/kernel-mandate.json"; print "{x}" > f}'"'"'')" \
  "F1 the same, aimed at the manifest — note the brace INSIDE the string → DENY" \
  "kernel mandate itself"
assert_deny "$H" "$(bpay 'sed -n '"'"'1r.env'"'"' tests/a.txt')" \
  "F1 sed's r with no space before the filename → DENY" "run a command or open a file"

# The literal forms round 14 caught must still be caught.
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{system("cat .env")}'"'"'')" \
  "F1 the literal system() still → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'sed -n '"'"'1e cat .env'"'"' tests/a.txt')" \
  "F1 the literal sed e still → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{print ENVIRON["HOME"]}'"'"'')" \
  "F1 ENVIRON reads the environment the role never granted → DENY" \
  "run a command or open a file"

# --- calibration: awk and sed must stay usable ------------------------
# These outnumber the escapes deliberately. awk and sed are the tools an
# inspection role reaches for first, and a screen that refuses their
# ordinary use is worse than the hole it closes.
assert_allow "$H" "$(bpay 'awk '"'"'{print $1}'"'"' tests/a.txt')" \
  "calibration: the commonest awk program there is → ALLOW"
assert_allow "$H" "$(bpay 'awk -F, '"'"'{print $2}'"'"' tests/a.txt')" \
  "calibration: a field separator → ALLOW"
assert_allow "$H" "$(bpay 'awk '"'"'/a|b/{print}'"'"' tests/a.txt')" \
  "calibration: a regex ALTERNATION is not a command pipe → ALLOW"
assert_allow "$H" "$(bpay 'awk '"'"'{if ($1 > 5) print $2}'"'"' tests/a.txt')" \
  "calibration: a COMPARISON is not a redirect → ALLOW"
assert_allow "$H" "$(bpay 'awk '"'"'{printf "%s\n", $1}'"'"' tests/a.txt')" \
  "calibration: printf with no redirect → ALLOW"
assert_allow "$H" "$(bpay 'awk '"'"'NR>1{print $1}'"'"' tests/a.txt')" \
  "calibration: a range comparison before the block → ALLOW"
assert_allow "$H" "$(bpay 'sed '"'"'s/a/b/'"'"' tests/a.txt')" \
  "calibration: a substitution → ALLOW"
assert_allow "$H" "$(bpay 'sed -n '"'"'1,5p'"'"' tests/a.txt')" \
  "calibration: an address range → ALLOW"
assert_allow "$H" "$(bpay 'sed -e p tests/a.txt')" \
  "calibration: -e is sed's FLAG, not its shell-out command → ALLOW"
assert_allow "$H" "$(bpay 'sed '"'"'/pattern/d'"'"' tests/a.txt')" \
  "calibration: a delete → ALLOW"
assert_allow "$H" "$(bpay 'sed '"'"'y/abc/xyz/'"'"' tests/a.txt')" \
  "calibration: a transliteration, whose body holds letters → ALLOW"
assert_allow "$H" "$(bpay 'sed -i '"'"'s/a/b/'"'"' tests/a.txt')" \
  "calibration: -i in-place, which the write axis governs separately → ALLOW"
assert_allow "$H" "$(bpay 'grep -rn foo tests')" \
  "calibration: grep is untouched by any of this → ALLOW"

# --- the opt-out exists, and it is per-role ---------------------------
# Refusing a construct outright is only defensible when a role that
# genuinely needs it can be granted it deliberately, the way every other
# indirection in that list works.
assert_allow "$H" "$(bpay 'awk '"'"'BEGIN{f="tests/out.txt"; print "P" > f}'"'"'' trusted)" \
  "a role that permits awk-program may use the construct → ALLOW"
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{f="tests/out.txt"; print "P" > f}'"'"'')" \
  "and the role beside it, which does not, may not" "run a command or open a file"

# --- self-probe: what the inversion itself still missed ---------------
# Written straight after the fix above, before the next reviewer saw it.
# gawk can LOAD A SHARED LIBRARY — `@load`, `@include`, `extension()`,
# and the -l/--load/-i/--include flags — which reaches code this kernel
# never sees and is strictly worse than `system()`. All four read as
# perfectly inert to a scan looking for redirects and pipes, which is
# how they survived an inversion written to be exhaustive. Proving a
# program inert is only as good as the list of ways it can stop being
# inert.
assert_deny "$H" "$(bpay 'awk '"'"'@load "filefuncs"; BEGIN{x=1}'"'"'')" \
  "self-probe gawk @load reaches a shared library → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'awk -l filefuncs '"'"'BEGIN{x=1}'"'"'')" \
  "self-probe the -l flag form → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'awk '"'"'@include "other.awk"; BEGIN{x=1}'"'"'')" \
  "self-probe @include pulls in unscreened source → DENY" "run a command or open a file"
assert_deny "$H" "$(bpay 'awk '"'"'BEGIN{extension("x","y")}'"'"'')" \
  "self-probe the extension() builtin → DENY" "run a command or open a file"

# gawk and GNU sed both ship --sandbox, which disables these constructs
# in the interpreter itself. That is a better guarantee than any scan of
# ours, so it is accepted — but only where the command word names an
# implementation known to HAVE it. A bare `awk` may be mawk or busybox,
# and trusting a flag a binary might ignore is the sort of unverifiable
# assumption this loop keeps punishing.
assert_allow "$H" "$(bpay 'sed --sandbox -n '"'"'1r.env'"'"' tests/a.txt')" \
  "self-probe GNU sed --sandbox refuses e/r/w itself → ALLOW"
assert_deny "$H" "$(bpay 'awk --sandbox '"'"'BEGIN{system("id")}'"'"'')" \
  "self-probe but a bare awk is not known to implement it → DENY" \
  "run a command or open a file"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R16"
