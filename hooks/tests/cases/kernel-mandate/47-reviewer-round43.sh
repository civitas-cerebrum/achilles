#!/bin/bash
# 47-reviewer-round43.sh — regressions for round 43 of independent
# adversarial review.
#
# Round 43 found no escape against the shipped grants. It found the
# seam that had been holding them open in principle: **enforcement was
# keyed on the PRESENCE of a declaration, and absence read as open.**
#
#   codeImports absent  ->  import "dotenv/config"    ALLOW
#   codeImports: []     ->  import "dotenv/config"    DENY
#
# `dotenv/config` reads .env inside the package; `execa` spawns inside
# the package. Neither names anything the capability screen scans for,
# because that screen reads authored text for a fixed set of stdlib
# names and cannot see what a third-party module does internally. So an
# author-and-run role that declared nothing was contained by the one
# layer that cannot see the shape of this attack, while a role that
# declared an EMPTY list was contained by all three.
#
# A security kernel's unconfigured state for a capable role must be its
# most restrictive, not its least. Round 37 inverted exactly this shape
# on the environment screen — "an allowlist of dangerous things fails
# open on the unknown" — and the lesson did not migrate to the import
# allowlist or to the config-flag axis it also gates. So: for a role
# that authors executable files AND can run them, a missing list reads
# as an empty one.
#
# The scope of the reversal is deliberate. A role that authors but
# CANNOT run is unchanged: something else runs its output, and holding
# it to an allowlist it never declared would be a deny an operator
# cannot act on from a manifest they may not own.
#
# This reverses a choice this project made on purpose in round 6 ("the
# list cannot break an existing manifest — that is why validate warns
# instead"). Round 43's argument is better: validate is advisory, and
# the runtime default was the dangerous direction. Four fixture
# manifests in this suite had the permissive shape and now declare what
# they always meant to.
#
# Round 43's second finding is forensic and is fixed alongside: the
# decision log was written from exactly one place, the deny renderer.
# **A log of refusals evidences what was stopped, never what got
# through** — every escape in this document resolved to an ALLOW, and
# not one would have left a line. `settings.decisionLog: "all"` records
# allows too, written from the exit trap so it sees every one of the
# dozen `exit 0` sites rather than needing a call at each.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-43 regressions"

R43=$(mktemp -d)
P="$R43/proj"
mkdir -p "$P/.claude" "$P/tests" "$P/lib"
printf 'x\n' > "$P/tests/a.txt"
export KERNEL_MANDATE_STATE_DIR="$R43/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r43",
  "settings": { "mainSessionRole": "runner" },
  "commandGroups": { "run": ["^npx playwright test\\b", "^(cat|echo)\\b"] },
  "roles": {
    "runner": {
      "description": "Authors and runs, and declares neither list.",
      "tools": { "allow": ["Bash", "Write", "Edit"] },
      "bash": { "groups": ["run"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/**"] }
    },
    "declaring": {
      "description": "Authors and runs, and says what its code imports.",
      "tools": { "allow": ["Bash", "Write"] },
      "bash": { "groups": ["run"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/**"], "codeImports": ["@playwright/test"] }
    },
    "author-only": {
      "description": "Authors and cannot run. Something else runs its output.",
      "tools": { "allow": ["Write"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["lib/**"] }
    }
  }
}
JSON
for r in runner declaring author-only; do printf '%s\n' "$r" > "$KERNEL_MANDATE_STATE_DIR/agents/$r"; done

wp() { "$JQ" -nc --arg f "$1" --arg c "$2" --arg a "${3:-runner}" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:"'"$P"'",agent_id:$a}'; }
bp() { "$JQ" -nc --arg c "$1" --arg a "${2:-runner}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- An undeclared list is an EMPTY list, for an author+run role -------
for spec in \
  'import "dotenv/config";|dotenv, which reads .env inside the package' \
  'import {execa} from "execa";|execa, which spawns inside the package' \
  'const d = require("dotenv");|the require spelling' \
  'import fetch from "node-fetch";|a network package the screen never names' ; do
  body="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(wp "$P/tests/x.spec.ts" "$body")" \
    "R43 $label → DENY" "declared import list"
done

# ...and the axes that same declaration used to gate come with it.
assert_deny "$H" "$(bp 'npx playwright test -c tests/evil.config.ts')" \
  "R43 the self-authored config axis applies too → DENY" "as configuration"

# --- Calibration: the role's own work is untouched --------------------
assert_allow "$H" "$(wp "$P/tests/x.spec.ts" 'import {h} from "./helpers";')" \
  "R43 calibration: a relative import is not a package → ALLOW"
assert_allow "$H" "$(wp "$P/tests/x.spec.ts" 'export const x = 1;')" \
  "R43 calibration: code that imports nothing → ALLOW"
assert_allow "$H" "$(wp "$P/tests/notes.md" 'import "dotenv/config" is a thing you cannot do')" \
  "R43 calibration: prose in a data file → ALLOW"
assert_allow "$H" "$(wp "$P/tests/x.spec.ts" 'import {test} from "@playwright/test";' declaring)" \
  "R43 calibration: a declared package → ALLOW"
assert_deny "$H" "$(wp "$P/tests/x.spec.ts" 'import "dotenv/config";' declaring)" \
  "R43 calibration: an undeclared one, for the same role → DENY" "declared import list"

# --- A role that authors but cannot RUN is unchanged ------------------
# The reversal is scoped to the write-then-execute shape. Holding an
# author-only role to a list it never declared would be a deny its
# operator may not be able to act on.
assert_allow "$H" "$(wp "$P/lib/x.ts" 'import "dotenv/config";' author-only)" \
  "R43 an author-only role keeps the opt-in default → ALLOW"

# --- The decision log records what got through, when asked ------------
LOGP="$R43/logproj"
mkdir -p "$LOGP/.claude" "$LOGP/tests"
printf 'x\n' > "$LOGP/tests/a.txt"
mklog() {  # mklog <decisionLog-or-empty>
  # Built OUTSIDE the heredoc on purpose: bash applies quote removal to
  # the alternate word of ${x:+word}, so the inline spelling emitted
  # `decisionLog: all` unquoted and the manifest stopped being JSON. The
  # kernel then failed closed and denied BOTH commands — which is the
  # right behaviour, and is why the assertions below caught it.
  local dl=""
  [ -n "${1:-}" ] && dl=', "decisionLog": "'"$1"'"'
  cat > "$LOGP/.claude/kernel-mandate.json" <<JSON
{
  "harnessOsVersion": 1,
  "name": "r43log",
  "settings": { "mainSessionRole": "r"$dl },
  "commandGroups": { "i": ["^(cat|echo)\\\\b"] },
  "roles": {
    "r": {
      "description": "Reads its own tests.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["i"] },
      "read": { "allow": ["tests/**"] }
    }
  }
}
JSON
}
# `grep -c` prints 0 AND exits non-zero when nothing matches, so the
# obvious `grep -c ... || echo 0` prints TWO lines and the assertion
# compares against garbage. Count through a guard instead.
logcount() {  # logcount <state-dir> <decision>
  local f="$1/decision-log.jsonl"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  local n
  n=$(grep -c "\"decision\":\"$2\"" "$f" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}
runlog() {  # runlog <state-dir> <command>
  "$JQ" -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$LOGP"'",agent_id:"a1"}' \
    | KERNEL_MANDATE_STATE_DIR="$1" KERNEL_MANDATE_MANIFEST="$LOGP/.claude/kernel-mandate.json" bash "$H" >/dev/null 2>&1 || true
}

SD1="$R43/logstate-default"; mkdir -p "$SD1/agents"; printf 'r\n' > "$SD1/agents/a1"
mklog ""
runlog "$SD1" 'cat tests/a.txt'
runlog "$SD1" 'cat /etc/passwd'
assert_eq "$(logcount "$SD1" deny)" "1" \
  "R43 the default log records the deny"
assert_eq "$(logcount "$SD1" allow)" "0" \
  "R43 ...and, by default, nothing about what got through"

SD2="$R43/logstate-all"; mkdir -p "$SD2/agents"; printf 'r\n' > "$SD2/agents/a1"
mklog "all"
runlog "$SD2" 'cat tests/a.txt'
runlog "$SD2" 'cat /etc/passwd'
assert_eq "$(logcount "$SD2" allow)" "1" \
  "R43 decisionLog: all records the allow as well"
assert_eq "$(logcount "$SD2" deny)" "1" \
  "R43 ...without losing the deny"

# --- The audit line is bounded where it is WRITTEN, not where it is fed
# Found by probing round 43's own new code before round 44 saw it. The
# logger truncated `detail` at 4000 characters and called the line
# bounded. JSON renders a control character as \uXXXX, so a command
# spelled with 3900 of them produced a single 23 520-byte audit entry —
# 183x an ordinary line, every byte of it chosen by the role being
# audited. That matters beyond tidiness: an append larger than the
# writer's flush buffer goes out as several write() calls, and two of
# those interleave and destroy BOTH lines — including whichever other
# role was logging at that moment. A cap on a renderer's INPUT is not a
# cap on its OUTPUT.
SD3="$R43/logstate-bound"; mkdir -p "$SD3/agents"; printf 'r\n' > "$SD3/agents/a1"
mklog "all"
NOISE=$(awk 'BEGIN{s="";for(i=0;i<3900;i++)s=s sprintf("%c",1);print s}')
runlog "$SD3" "echo $NOISE"
runlog "$SD3" 'cat tests/a.txt'
MAXLEN=$(awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$SD3/decision-log.jsonl")
assert_eq "$([ "$MAXLEN" -le 3500 ] && echo bounded || echo "$MAXLEN")" "bounded" \
  "R43 a control-character command cannot inflate its own audit line"
BAD=0
while IFS= read -r l; do printf '%s' "$l" | "$JQ" -e . >/dev/null 2>&1 || BAD=$((BAD+1)); done < "$SD3/decision-log.jsonl"
assert_eq "$BAD" "0" "R43 ...and every line is still parseable JSON"
assert_eq "$( { grep -c 'cat tests/a.txt' "$SD3/decision-log.jsonl" 2>/dev/null || true; } | head -1 )" "1" \
  "R43 calibration: an ordinary command is still recorded in full"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
