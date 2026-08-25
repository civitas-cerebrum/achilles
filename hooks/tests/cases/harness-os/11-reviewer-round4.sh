#!/bin/bash
# 11-reviewer-round4.sh — regressions for round 4 of independent
# adversarial review.
#
# Round 4 confirmed the sixteen earlier fixes hold, then found the
# largest hole of the whole exercise plus two more, and two false
# positives severe enough that an operator would have switched the gate
# off within minutes.
#
#   N1  the WRAPPER loop's assignment strip was the twin of the one
#       round 3 hardened, and was missed. `env X=1<.env cat` — any
#       wrapper word in front — had its whole redirection eaten before
#       any check ran. Proven: a read-only role read .env, wrote outside
#       every scope, overwrote .claude/settings.json, and overwrote the
#       vendored kernel with 9 bytes. One command, total disarm.
#   N2  the write-then-execute screen was wired only to Write/Edit, so
#       `echo 'require("fs")…' > tests/e2e/x.spec.ts` put the identical
#       code on disk inside the role's own write scope unscreened, and
#       the role's granted `npx playwright test` ran it
#   N3  capability spellings the matcher had not seen:
#       require(String.fromCharCode(102,115)), computed-member
#       m["read"+"File"+"Sync"](), octal require("\146\163"), and
#       process.binding("fs")
#   FP  the redirect scans read the raw segment, so a quoted `<` or `>`
#       was misread as redirection: `grep '<input' page.json` and
#       `grep '=>' spec.ts` were both denied. The second is fatal —
#       `=>` is the arrow operator, in every spec the composer writes.
#
# The fix for N1 and both FPs is one change: read redirection from a
# quote-masked view of the UN-STRIPPED segment. That is also why the
# calibration cases here matter as much as the escapes — this round is
# the clearest evidence in the whole exercise that a gate people switch
# off enforces nothing.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-4 regressions"

R4=$(mktemp -d)
P="$R4/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/tests/data" "$P/src" "$P/docs" \
         "$P/node_modules/@civitas-cerebrum/harness-os/hooks"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'ok\n' > "$P/tests/a.txt"
printf '{}\n' > "$P/tests/data/page-repository.json"
printf '{"verdicts":[]}\n' > "$P/docs/e2e-ledger.json"
printf 'confidential\n' > "$P/docs/roadmap.md"
printf '#!/bin/bash\n# the kernel\n' > "$P/node_modules/@civitas-cerebrum/harness-os/hooks/harness-os-role-gate.sh"
printf '{"hooks":{}}\n' > "$P/.claude/settings.json"
export HARNESS_OS_STATE_DIR="$R4/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r4",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": {
    "inspection": ["^(ls|find|cat|head|tail|grep|wc|stat|echo|printf|sort)\\b"],
    "build": ["^(cp|mv|tee)\\b"],
    "test-execution": ["^npx playwright test\\b"]
  },
  "roles": {
    "composer": {
      "description": "Authors specs in tests/e2e and runs them.",
      "tools": { "allow": ["Bash", "Read", "Write", "Edit"] },
      "bash": { "groups": ["inspection", "build", "test-execution"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"] }
    },
    "inspector": {
      "description": "Reads what its task needs. No writes at all.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["tests/**"] }
    }
  }
}
JSON

mkdir -p "$HARNESS_OS_STATE_DIR/agents"
for r in composer inspector; do printf '%s\n' "$r" > "$HARNESS_OS_STATE_DIR/agents/$r"; done
I="agent_id=inspector"; C="agent_id=composer"
wpay() { "$JQ" -nc --arg f "$1" --arg c "$2" --arg a "$3" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- N1: a wrapper word hid a whole redirection -------------------------
# The assignment forms now keep their `<`/`>`, so the segment no longer
# reduces to a bare permitted verb and the allow-set refuses it first.
# Which axis speaks is not the invariant; reaching the shell is.
assert_deny "$H" "$(payload tool_name=Bash command='env X=1<.env cat' cwd="$P" $I)" \
  "N1 'env X=1<.env cat' — wrapper + assignment ate the redirect → DENY" "[BLOCKED] Role 'inspector'"
assert_deny "$H" "$(payload tool_name=Bash command='nohup X=1<.env cat' cwd="$P" $I)" \
  "N1 a different wrapper word ('nohup') → DENY" "[BLOCKED] Role 'inspector'"
assert_deny "$H" "$(payload tool_name=Bash command='sudo nice A=1<.env cat' cwd="$P" $I)" \
  "N1 stacked wrappers → DENY" "[BLOCKED] Role 'inspector'"
assert_deny "$H" "$(payload tool_name=Bash command='timeout 5 B=x<docs/roadmap.md cat' cwd="$P" $I)" \
  "N1 wrapper with its own numeric argument → DENY" "[BLOCKED] Role 'inspector'"

# And the redirect axis itself now sees a wrapped redirect, proven on
# forms whose allow-set check passes so the axis is reached.
assert_deny "$H" "$(payload tool_name=Bash command='env cat<.env' cwd="$P" $I)" \
  "N1 'env cat<.env' — allow-set passes, redirect axis catches it → DENY" "read"
assert_deny "$H" "$(payload tool_name=Bash command='env echo owned>/tmp/hos-r4-pwn.txt' cwd="$P" $I)" \
  "N1 read-only role writing outside every scope → DENY" "no write grants"
assert_deny "$H" "$(payload tool_name=Bash command='nohup echo forged>docs/e2e-ledger.json' cwd="$P" $C)" \
  "N1 composer forging the judge's ledger through a wrapper → DENY" "outside the role's write scope"

# Self-protection: this is the one that took the kernel over.
assert_deny "$H" "$(payload tool_name=Bash command='env echo x>.claude/settings.json' cwd="$P" $C)" \
  "N1 overwriting the hook REGISTRATION → DENY" "harness OS itself"
assert_deny "$H" "$(payload tool_name=Bash command='env echo disabled>node_modules/@civitas-cerebrum/harness-os/hooks/harness-os-role-gate.sh' cwd="$P" $C)" \
  "N1 overwriting the vendored KERNEL → DENY" "harness OS itself"
assert_deny "$H" "$(payload tool_name=Bash command='env echo x>.claude/harness-os.json' cwd="$P" $C)" \
  "N1 overwriting the MANIFEST → DENY" "harness OS itself"
assert_deny "$H" "$(payload tool_name=Bash command='env X=1>.claude/settings.json echo {}' cwd="$P" $C)" \
  "N1 the assignment form of the same attack → DENY" "[BLOCKED] Role 'composer'"

# --- FP: a quoted redirect character is text, not syntax ----------------
# The composer cannot grep the arrow operator out of its own spec if `>`
# inside quotes counts as a redirection — and `=>` is in every spec.
assert_allow "$H" "$(payload tool_name=Bash command="grep '=>' tests/e2e" cwd="$P" $C)" \
  "FP \"grep '=>' \" — the arrow operator is not a redirect → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="grep '<input' tests/data/page-repository.json" cwd="$P" $I)" \
  "FP \"grep '<input'\" — markup is not input redirection → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='grep "<div>" tests/a.txt' cwd="$P" $I)" \
  "FP double-quoted markup → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="echo 'a > b'" cwd="$P" $I)" \
  "FP a quoted '>' in echoed text → ALLOW"
# ...but an unquoted one is still a redirect, and still scoped.
assert_deny "$H" "$(payload tool_name=Bash command='echo x > docs/e2e-ledger.json' cwd="$P" $C)" \
  "FP but an UNQUOTED '>' is still a write → DENY" "outside the role's write scope"
assert_deny "$H" "$(payload tool_name=Bash command='cat <.env' cwd="$P" $I)" \
  "FP and an UNQUOTED '<' is still a read → DENY" "read"
# A quoted TARGET must survive the mask — the path is still a real write.
assert_deny "$H" "$(payload tool_name=Bash command='echo x > "docs/e2e-ledger.json"' cwd="$P" $C)" \
  "FP a quoted redirect TARGET is still scope-checked → DENY" "outside the role's write scope"

# --- Quote-aware segmentation -------------------------------------------
# A separator inside quotes is not a separator. Splitting on it refused
# most lines of JavaScript with a message about command patterns.
assert_allow "$H" "$(payload tool_name=Bash command='echo "await steps.click(\"submitButton\");" >> tests/e2e/ok.spec.txt' cwd="$P" $C)" \
  "SEG a quoted ';' does not split the command → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='grep "a;b" tests/a.txt' cwd="$P" $I)" \
  "SEG a quoted ';' in a search string → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='grep "a|b" tests/a.txt' cwd="$P" $I)" \
  "SEG a quoted '|' is not a pipe → ALLOW"
assert_deny "$H" "$(payload tool_name=Bash command='cat tests/a.txt; cat .env' cwd="$P" $I)" \
  "SEG but an UNQUOTED ';' still splits → DENY" "read scope"
assert_deny "$H" "$(payload tool_name=Bash command='cat tests/a.txt && cat .env' cwd="$P" $I)" \
  "SEG '&&' still splits → DENY" "read scope"
assert_deny "$H" "$(payload tool_name=Bash command='cat tests/a.txt | cat .env' cwd="$P" $I)" \
  "SEG '|' still splits → DENY" "read scope"
assert_deny "$H" "$(payload tool_name=Bash command='cat tests/a.txt & cat .env' cwd="$P" $I)" \
  "SEG a background '&' still splits → DENY" "read scope"

# Backslash escaping — found by probing the quote-aware split before the
# next reviewer saw it, and it was an escape of my own making. A
# backslash escapes the next character everywhere except inside single
# quotes, so `\"` is a literal quote and does NOT open a string. A naive
# scanner thinks it does, swallows the following `;`, and hides a whole
# command inside a string bash never saw. Verified end to end: the
# command really did print the secret.
assert_deny "$H" "$(payload tool_name=Bash command='echo \" ; cat .env' cwd="$P" $I)" \
  "SEG an escaped quote does not open a string → the ';' still splits → DENY" "read scope"
assert_allow "$H" "$(payload tool_name=Bash command='echo \" ; cat tests/a.txt' cwd="$P" $I)" \
  "SEG calibration: same shape, in-scope read → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='echo "a\" ; cat tests/a.txt"' cwd="$P" $I)" \
  "SEG an escaped quote INSIDE a string does not end it → one command → ALLOW"
assert_deny "$H" "$(payload tool_name=Bash command='cat \.env' cwd="$P" $I)" \
  "SEG an escaped path character is still that path → DENY" "read scope"
assert_deny "$H" "$(payload tool_name=Bash command='echo x \> tests/e2e/a.txt; cat .env' cwd="$P" $C)" \
  "SEG an escaped '>' is not a redirect, and the live ';' still splits → DENY" "read scope"

# An UNTERMINATED quote makes the whole tail read as inert string. A
# shell refuses such a command, so refusing it here costs nothing — and
# not resting on "the shell will error anyway" is the point.
assert_deny "$H" "$(payload tool_name=Bash command='echo "unterminated ; cat .env' cwd="$P" $I)" \
  "SEG an unterminated double quote → DENY" "unterminated quote"
assert_deny "$H" "$(payload tool_name=Bash command="echo 'unterminated ; cat .env" cwd="$P" $I)" \
  "SEG an unterminated single quote → DENY" "unterminated quote"
assert_allow "$H" "$(payload tool_name=Bash command='echo "balanced" ; cat tests/a.txt' cwd="$P" $I)" \
  "SEG calibration: balanced quotes → ALLOW"

# --- N2: the bash authoring route is screened too -----------------------
assert_deny "$H" "$(payload tool_name=Bash command='echo "require(\"fs\").readFileSync(\".env\");" > tests/e2e/evil.spec.ts' cwd="$P" $C)" \
  "N2 code authored via bash redirect, INSIDE the write scope → DENY" "filesystem access"
assert_deny "$H" "$(payload tool_name=Bash command='printf "%s" "const fs=require(\"fs\");" > tests/e2e/e2.spec.ts' cwd="$P" $C)" \
  "N2 printf instead of echo → DENY" "filesystem access"
assert_deny "$H" "$(payload tool_name=Bash command='echo "import { readFileSync } from \"fs\";" >> tests/e2e/e3.spec.ts' cwd="$P" $C)" \
  "N2 append rather than truncate → DENY" "filesystem access"
assert_deny "$H" "$(payload tool_name=Bash command='echo "const cp=require(\"child_process\");" | tee tests/e2e/e4.spec.ts' cwd="$P" $C)" \
  "N2 via tee → DENY" "process spawning"
assert_allow "$H" "$(payload tool_name=Bash command='echo "expect(cell).not.toBeNull();" >> tests/e2e/ok.spec.ts' cwd="$P" $C)" \
  "N2 calibration: an ordinary spec line authored via bash → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='echo hello > tests/e2e/notes.txt' cwd="$P" $C)" \
  "N2 calibration: a non-executable file is not screened → ALLOW"

# --- N3: capability spellings the matcher had not seen ------------------
assert_deny "$H" "$(wpay "$P/tests/e2e/a.spec.ts" 'const m = require(String.fromCharCode(102,115));
const d = m["read"+"File"+"Sync"](".env","utf8");' composer)" \
  "N3 fromCharCode module name + computed-member method → DENY" "filesystem access"
assert_deny "$H" "$(wpay "$P/tests/e2e/b.spec.ts" 'const m = require("\146\163"); m.readFileSync(".env");' composer)" \
  "N3 OCTAL escapes in the module name → DENY" "filesystem access"
assert_deny "$H" "$(wpay "$P/tests/e2e/c.spec.ts" 'const b = process.binding("fs"); b.open(".env");' composer)" \
  "N3 process.binding(\"fs\") → DENY" "filesystem access"
assert_deny "$H" "$(wpay "$P/tests/e2e/d.spec.ts" 'const d = fs["readFileSync"](".env");' composer)" \
  "N3 computed-member method access alone → DENY" "filesystem access"

# The real framework-driven spec must survive every one of those matchers.
assert_allow "$H" "$(wpay "$P/tests/e2e/ok.spec.ts" 'import { test, expect } from "@playwright/test";
test.describe("Submission Form", () => {
  test("AC-1: a valid submission appears in the table", async ({ steps, repo }) => {
    await steps.navigateTo("/forms");
    await steps.fill("nameInput", "FormsPage", "Jane Doe");
    await steps.click("submitButton", "FormsPage");
    const cell = await repo.getByText("submissionValue", "FormsPage", "Jane Doe", true);
    expect(cell).not.toBeNull();
  });
});' composer)" \
  "N3 calibration: the real Playwright spec → ALLOW (no false positive)"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$R4"
