#!/bin/bash
# 17-reviewer-round10.sh — regressions for round 10 of independent
# adversarial review.
#
# Round 10 landed the sharpest finding of the whole loop, because it
# broke the thing every other round's fix depends on: the code that says
# "no".
#
#   F1  `kernel_mandate_deny` rendered its JSON with `jq --arg r "$reason"`,
#       passing the reason through argv. Every deny reason quotes the
#       thing it is refusing — a command line, a path, a file's body —
#       so its length is set by the caller. Push it past execve's
#       MAX_ARG_STRLEN (128 KiB) and jq never starts, no JSON is
#       printed, and the function's unconditional `exit 0` becomes an
#       ALLOW. `cat .env #AAAA…` — a comment pad, invisible to the
#       executed command — read every planted secret. Round 9's EXIT
#       trap could not catch it: nothing exited non-zero, the failure
#       was entirely inside a successful-looking run.
#
#       Every axis was defeasible this way, read and write alike; the
#       checks all worked perfectly right up until the verdict could not
#       be printed. The decision log even recorded `"decision":"deny"`
#       for calls that went through — the kernel logged a deny it then
#       failed to emit.
#
#       The reason is now bounded and handed to jq on stdin, where no
#       argv limit exists, and if the renderer fails anyway the decision
#       is still emitted by a fixed string that needs no renderer. The
#       explanation is not the decision; losing the former must never
#       discard the latter.
#
#   F2  the Edit reconstruction's `replace_all` restarted `index` from
#       zero after each substitution, so whenever new_string CONTAINS
#       old_string it re-found the needle inside its own replacement and
#       looped forever. That is a plain wrapping rename — `steps.` →
#       `await steps.` — so an agent doing nothing wrong could hang the
#       kernel and peg a core. Whether that ends as a denial of service
#       or a second crash-to-allow depends on how the host treats a
#       timed-out hook, and neither is acceptable. The scan now advances
#       past what it just wrote.
#
#       Beside it, the same fallback round 9 removed had survived: when
#       the reconstruction failed, the kernel screened the FRAGMENT
#       instead. That is the round-9 F1 bug in a second location, and it
#       now fails closed.
#
# The through-line from round 9 is that a gate whose failure mode is
# ALLOW is not a gate. Round 10's contribution is that the rule binds
# the deny path itself, which had been exempt by construction.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-10 regressions"

R10=$(mktemp -d)
P="$R10/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/docs"
printf 'SMTP_PASSWORD=hunter2\nSTRIPE_KEY=sk_test_51Hxyz\n' > "$P/.env"
export KERNEL_MANDATE_STATE_DIR="$R10/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "r10",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "t": ["^npx playwright test\\b", "^echo\\b"] },
  "roles": {
    "composer": {
      "description": "Authors specs in tests/e2e and runs them.",
      "tools": { "allow": ["Bash", "Read", "Write", "Edit"] },
      "bash": { "groups": ["t"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    }
  }
}
JSON

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
printf 'composer\n' > "$KERNEL_MANDATE_STATE_DIR/agents/composer"

# A hang must fail these tests, not stall the suite. Turning a timeout
# into a loud deny means assert_allow rejects it too — a kernel that
# never returns has not allowed anything.
TIMED="$R10/timed-hook.sh"
cat > "$TIMED" <<EOF
#!/bin/bash
out=\$(timeout 25 bash "$H"); rc=\$?
if [ "\$rc" -eq 124 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"TEST-HARNESS: the kernel did not terminate within 25s"}}'
  exit 0
fi
printf '%s' "\$out"; exit "\$rc"
EOF
chmod +x "$TIMED"

# Build oversized payloads without argv — the test rig is subject to the
# very limit it is probing, so the pad reaches jq through --rawfile.
PADFILE="$R10/pad"
yes 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 2>/dev/null | head -n 4000 | tr -d '\n' > "$PADFILE"
PAD_LEN=$(wc -c <"$PADFILE")

bigbash() { # $1 = command prefix, the pad is appended as a shell comment
  "$JQ" -nc --rawfile pad "$PADFILE" --arg pre "$1" \
    '{tool_name:"Bash",tool_input:{command:($pre + ($pad|rtrimstr("\n")))},cwd:"'"$P"'",agent_id:"composer"}'
}

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# --- F1: a deny too long to render is still a deny ---------------------
# Guard the fixture itself: if the pad ever stops clearing the syscall
# limit, these probes would pass without reaching the bug at all.
assert_eq "$([ "$PAD_LEN" -gt 131072 ] && echo over || echo under)" "over" \
  "F1 fixture clears MAX_ARG_STRLEN ($PAD_LEN bytes) — the probe reaches the bug"

assert_deny "$H" "$(bigbash 'cat .env #')" \
  "F1 an out-of-group command padded past MAX_ARG_STRLEN → still DENY" \
  "may not run this command"
assert_deny "$H" "$(bigbash 'echo pwned > ../outside.md #')" \
  "F1 the same padding against a WRITE redirect → still DENY" \
  "outside the role's write scope"

# The pad must not itself become a reason to deny: padding is not an
# offence, and a role's own permitted command stays permitted at length.
assert_allow "$H" "$(bigbash 'npx playwright test #')" \
  "F1 calibration: a PERMITTED command of the same length → ALLOW"

# The rendered reason is bounded, and only when it needs to be.
BIG_REASON=$(printf '%s' "$(bigbash 'cat .env #')" | bash "$H" \
  | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason // ""')
assert_eq "$(has "$BIG_REASON" "elided by kernel-mandate")" "yes" \
  "F1 an oversized reason is elided in the middle, not dropped"
assert_eq "$(has "$BIG_REASON" "may not run this command")" "yes" \
  "F1 the elision keeps the opening — what was blocked"
assert_eq "$(has "$BIG_REASON" "commandGroups in the manifest")" "yes" \
  "F1 and keeps the closing — what to do instead"

SMALL_REASON=$(printf '%s' "$("$JQ" -nc \
  '{tool_name:"Bash",tool_input:{command:"cat .env"},cwd:"'"$P"'",agent_id:"composer"}')" \
  | bash "$H" | "$JQ" -r '.hookSpecificOutput.permissionDecisionReason // ""')
assert_eq "$(has "$SMALL_REASON" "elided by kernel-mandate")" "no" \
  "F1 calibration: an ordinary reason is delivered whole"

# --- F2: a wrapping rename terminates ----------------------------------
epay() { "$JQ" -nc --arg f "$1" --arg o "$2" --arg n "$3" --argjson a "$4" \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n,replace_all:$a},cwd:"'"$P"'",agent_id:"composer"}'; }

printf 'steps.fill();\nsteps.click();\n' > "$P/tests/e2e/reg.spec.ts"
assert_allow "$TIMED" "$(epay "$P/tests/e2e/reg.spec.ts" 'steps.' 'await steps.' true)" \
  "F2 replace_all where new_string CONTAINS old_string terminates → ALLOW"

printf 'const x = 1;\nconst y = 1;\n' > "$P/tests/e2e/s.spec.ts"
assert_deny "$TIMED" "$(epay "$P/tests/e2e/s.spec.ts" 'const y = 1;' 'const y = require("dotenv"); // const y = 1;' true)" \
  "F2 a replace_all that smuggles a forbidden import → DENY" \
  "not in this role's declared import list"

printf 'steps.a();\nsteps.b();\n' > "$P/tests/e2e/w.spec.ts"
assert_deny "$TIMED" "$(epay "$P/tests/e2e/w.spec.ts" 'steps.' 'require("dotenv"); steps.' true)" \
  "F2 a wrapping rename that ALSO smuggles → DENY (the new scan still sees it)" \
  "not in this role's declared import list"

# The reconstruction must be textually right, not merely fast: every
# occurrence replaced, none replaced twice.
RECON=$(OLD_S='steps.' NEW_S='await steps.' ALL=true perl -0777 -e '
  local $/; my $f = <STDIN>;
  my ($o,$n,$all)=($ENV{OLD_S},$ENV{NEW_S},$ENV{ALL} eq "true");
  exit 3 unless length $o;
  if ($all) { my $pos=0; while ((my $i=index($f,$o,$pos))>=0) { substr($f,$i,length($o))=$n; $pos=$i+length($n); } }
  else { my $i=index($f,$o); substr($f,$i,length($o))=$n if $i>=0; }
  print $f;' <<<'steps.a();
steps.b();')
assert_eq "$RECON" 'await steps.a();
await steps.b();' "F2 the offset scan replaces every occurrence exactly once"

# --- self-probe: the kernel's own preconditions ------------------------
# Round 10's lesson, applied outward. Two paths reported "this project is
# not governed" about a project that plainly is, because the kernel could
# not do its job: jq missing, and a manifest version this kernel does not
# implement. Both are silent total losses of enforcement, and both are
# reachable by an operator with no adversary anywhere.

# A PATH with every binary except jq. Removing PATH wholesale would only
# prove that bash needs `cat`.
NOJQ="$R10/nojq"; mkdir -p "$NOJQ"
for d in $(printf '%s' "$PATH" | tr ':' ' '); do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=$(basename "$f")
    [ "$b" = "jq" ] && continue
    [ -e "$NOJQ/$b" ] || ln -s "$f" "$NOJQ/$b" 2>/dev/null
  done
done

nojq_run() { # $1 = payload, rest = extra env assignments
  local pay="$1"; shift
  printf '%s' "$pay" | env -u JQ PATH="$NOJQ" "$@" bash "$H" 2>/dev/null
}
GOV=$("$JQ" -nc '{tool_name:"Bash",tool_input:{command:"cat .env"},cwd:"'"$P"'",agent_id:"composer"}')

OUT=$(nojq_run "$GOV" KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json")
assert_eq "$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecision // "ALLOW"' 2>/dev/null || echo ALLOW)" \
  "deny" "self-probe jq missing with a manifest present → DENY, not a silent unenforced session"
assert_eq "$(has "$OUT" "Install jq")" "yes" \
  "self-probe and the refusal names its own remedy"

# The other direction matters as much: a hook installed over a project
# that never opted in must not start failing because of a dependency
# that project does not use. That is how a global hook gets uninstalled.
mkdir -p "$R10/plain"
UNGOV=$("$JQ" -nc '{tool_name:"Bash",tool_input:{command:"ls"},cwd:"'"$R10"'/plain",agent_id:"x"}')
assert_eq "$(nojq_run "$UNGOV" -u KERNEL_MANDATE_MANIFEST | wc -c | tr -d ' ')" "0" \
  "self-probe calibration: jq missing and NO manifest → still a silent allow"
assert_eq "$(nojq_run "$GOV" KERNEL_MANDATE=0 KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json" | wc -c | tr -d ' ')" "0" \
  "self-probe calibration: the kill-switch still wins when jq is missing"

# A manifest version this kernel does not implement was treated as
# "inactive" — so shipping kernelMandateVersion: 2 to an older kernel bought
# no enforcement and no warning, the one outcome worse than either.
V2="$R10/v2"; mkdir -p "$V2/.claude"
"$JQ" '.kernelMandateVersion = 2' "$P/.claude/kernel-mandate.json" > "$V2/.claude/kernel-mandate.json"
OUT=$(printf '%s' "$("$JQ" -nc '{tool_name:"Bash",tool_input:{command:"cat .env"},cwd:"'"$V2"'",agent_id:"composer"}')" \
  | KERNEL_MANDATE_MANIFEST="$V2/.claude/kernel-mandate.json" bash "$H" 2>/dev/null)
assert_eq "$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecision // "ALLOW"' 2>/dev/null || echo ALLOW)" \
  "deny" "self-probe a manifest version this kernel cannot implement → DENY, not silently unenforced"
assert_eq "$(has "$OUT" "kernelMandateVersion")" "yes" \
  "self-probe and it names the mismatch rather than failing vaguely"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R10"
