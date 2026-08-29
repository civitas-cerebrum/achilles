#!/bin/bash
# 24-reviewer-round17.sh — regressions for round 17 of independent
# adversarial review.
#
#   F1  the `interpreter-inline` construct matched the code-bearing flag
#       as an exact whole-word token — `-c`, `-e`, `-p`, `--eval`. Every
#       one of these interpreters also accepts that letter BUNDLED with
#       its other short options, as a single argv token equal to none of
#       them:
#
#         perl -ne 'system("cat .env")'      perl -pe '…'
#         ruby -ne 'system("cat .env")'      python3 -Ic '…'
#         perl -nE 'say qx(cat .env)'        python3 -uc '…'
#
#       So the screen saw nothing, and a role whose command groups grant
#       an interpreter had an unrestricted shell — the exact outcome
#       that construct exists to prevent.
#
# This is the third axis to be defeated by an exact spelling where a
# cluster was possible. `sort -oFILE` was the write side (round 15),
# `grep -f.env` the read side (my own audit after round 11), and this
# the construct list. Each was found separately, and each fix was
# written without anyone noticing the other two were the same sentence.
#
# The match is now on the cluster: any short-option group ending in a
# letter that means "here is code" (c, e, E) or "run this module"
# (m, M, r, p). Module execution is included because `python3 -m
# http.server` and `perl -MFoo` run code just as surely as `-c` does,
# and neither was covered before. A plain `interpreter script.ext`
# stays permitted, because that path is scope-checked like any other.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-17 regressions"

R17=$(mktemp -d)
P="$R17/proj"
mkdir -p "$P/.claude" "$P/tests"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'print(1)\n' > "$P/tests/a.py"
export KERNEL_MANDATE_STATE_DIR="$R17/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r17",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "inspect": ["^perl\\b", "^ruby\\b", "^python3?\\b", "^node\\b", "^cat\\b"] },
  "roles": {
    "inspector": {
      "description": "Runs project scripts. Text processing is its job.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspect"] },
      "read": { "allow": ["tests/**"] }
    },
    "trusted": {
      "description": "Explicitly opted in to interpreter one-liners.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspect"], "permit": ["interpreter-inline"] },
      "read": { "allow": ["tests/**"] }
    }
  }
}
JSON

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
printf 'inspector\n' > "$KERNEL_MANDATE_STATE_DIR/agents/inspector"
printf 'trusted\n' > "$KERNEL_MANDATE_STATE_DIR/agents/trusted"
bpay() { "$JQ" -nc --arg c "$1" --arg a "${2:-inspector}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- F1: the code flag counts inside a cluster ------------------------
for spec in \
  "perl -pe 'BEGIN{system(\"cat .env\"); exit}'|perl -pe" \
  "perl -ne 'system(\"cat .env\")'|perl -ne" \
  "perl -nE 'say qx(cat .env)'|perl -nE, the capital spelling" \
  "perl -ane 'print'|perl -ane, three flags deep" \
  "ruby -ne 'system(\"cat .env\")'|ruby -ne" \
  "ruby -pe '\$_.upcase!'|ruby -pe" \
  "python3 -Ic 'print(open(\".env\").read())'|python3 -Ic" \
  "python3 -uc 'print(open(\".env\").read())'|python3 -uc" \
  "python3 -OOc 'print(1)'|python3 -OOc" \
  "node -pe '1+1'|node -pe" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bpay "$cmd")" \
    "F1 $label carries code → DENY" "interpreter one-liner"
done

# Module execution runs code just as surely, and was never covered at
# all — not even in the exact-token form.
assert_deny "$H" "$(bpay 'python3 -m http.server')" \
  "F1 python -m runs a module → DENY" "running or preloading a module"
assert_deny "$H" "$(bpay 'perl -MFoo::Bar -e 1')" \
  "F1 perl -M loads and runs a module → DENY" "running or preloading a module"

# The forms that already worked must keep working.
assert_deny "$H" "$(bpay 'perl -e '"'"'system("id")'"'"'')" \
  "F1 the plain -e spelling still → DENY" "interpreter one-liner"
assert_deny "$H" "$(bpay 'python3 -c '"'"'print(1)'"'"'')" \
  "F1 and plain -c" "interpreter one-liner"

# --- calibration: running a script is not running a one-liner ---------
assert_allow "$H" "$(bpay 'python3 tests/a.py')" \
  "calibration: a plain script invocation → ALLOW"
assert_allow "$H" "$(bpay 'python3 -u tests/a.py')" \
  "calibration: -u is unbuffered output, not code → ALLOW"
assert_allow "$H" "$(bpay 'perl -w tests/a.py')" \
  "calibration: -w is warnings → ALLOW"
assert_allow "$H" "$(bpay 'perl -n tests/a.py')" \
  "calibration: -n alone is the loop, with the program in the file → ALLOW"
assert_allow "$H" "$(bpay 'python3 --version')" \
  "calibration: --version → ALLOW"
assert_allow "$H" "$(bpay 'node --version')" \
  "calibration: node --version → ALLOW"
assert_allow "$H" "$(bpay 'cat -e tests/a.py')" \
  "calibration: -e on a NON-interpreter is untouched → ALLOW"

# --- the opt-in is per-role, like every other construct ---------------
assert_allow "$H" "$(bpay 'python3 -c '"'"'print(1)'"'"'' trusted)" \
  "a role that permits interpreter-inline may use it → ALLOW"
assert_deny "$H" "$(bpay 'python3 -uc '"'"'print(1)'"'"'')" \
  "and the role beside it may not, in any spelling" "interpreter one-liner"

# --- self-probe: the same sentence, a fourth time ---------------------
# Round 17's finding named a class — a flag's value can be attached to
# it, and a check that knows only the separated spelling is not a check
# — so the rest of the kernel was audited for it before the next
# reviewer arrived. Two more, both writes, both in archive tools:
#
#   tar -cf out.tar .    the `f` is clustered with the mode letter, so
#   tar cf  out.tar .    it matches no output-flag arm; the second form
#                        drops the dash entirely
#   zip out.zip files    the archive is the first POSITIONAL
#
# and the file each creates does not exist yet, so the read-token scan
# cannot see it either: the existence test that keeps that scan quiet is
# exactly what hides a write.
#
# These are modelled per-tool rather than generically, because the
# operand's role depends on the mode — `tar -c`'s archive is written,
# `tar -x`'s is read — and no rule can tell those apart from the token.
ARCH='{
  "harnessOsVersion": 1,
  "name": "r17b",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": { "inspect": ["^tar\\b", "^zip\\b", "^cat\\b"] },
  "roles": {
    "inspector": {
      "description": "Packages test artefacts.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspect"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/**"] }
    }
  }
}'
printf '%s\n' "$ARCH" > "$P/.claude/kernel-mandate.json"
mkdir -p "$P/tests"
printf 'x\n' > "$P/tests/a.txt"

assert_deny "$H" "$(bpay 'tar -cf /tmp/hos-evil.tar tests')" \
  "self-probe tar -cf writes outside the write scope → DENY" "write"
assert_deny "$H" "$(bpay 'tar -czf /tmp/hos-evil.tar tests')" \
  "self-probe with the compression letter in the cluster too → DENY" "write"
assert_deny "$H" "$(bpay 'tar cf /tmp/hos-evil.tar tests')" \
  "self-probe the dashless spelling → DENY" "write"
assert_deny "$H" "$(bpay 'tar -cf/tmp/hos-evil.tar tests')" \
  "self-probe the archive attached to the cluster → DENY" "write"
assert_deny "$H" "$(bpay 'tar --file=/tmp/hos-evil.tar -c tests')" \
  "self-probe the long spelling → DENY" "write"
assert_deny "$H" "$(bpay 'zip -r /tmp/hos-evil.zip tests')" \
  "self-probe zip's archive is its first positional → DENY" "write"

assert_allow "$H" "$(bpay 'tar -cf tests/out.tar tests')" \
  "self-probe calibration: archiving INSIDE the write scope → ALLOW"
assert_allow "$H" "$(bpay 'tar -czf tests/out.tgz tests')" \
  "self-probe calibration: the compressed form → ALLOW"
assert_allow "$H" "$(bpay 'tar cf tests/out.tar tests')" \
  "self-probe calibration: dashless and in scope → ALLOW"
assert_allow "$H" "$(bpay 'zip -r tests/out.zip tests')" \
  "self-probe calibration: zip in scope → ALLOW"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R17"
