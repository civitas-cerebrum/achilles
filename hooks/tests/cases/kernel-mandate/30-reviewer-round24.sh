#!/bin/bash
# 30-reviewer-round24.sh — regressions for round 24 of independent
# adversarial review.
#
# Round 24 was steered deliberately away from rounds 22-23's ground and
# found two things.
#
#   F1  a read that names NO path reads the directory it runs in, and
#       the Bash channel only scope-checked operands. So:
#
#         grep -rn ADMIN_TOKEN .   ->  DENY   (the operand resolves)
#         grep -rn ADMIN_TOKEN     ->  ALLOW  (same act, no operand)
#
#       and the second one printed the planted secret, for the inspector
#       and the composer, against the benchmark's real manifest with
#       their real grants. `rg`, `ls`, `tree` and a bare `find` are the
#       same shape. The Grep TOOL arm has held this exact line since
#       round 1 — no `path` means the search runs from the root, so the
#       root needs a root-wide grant — and the Bash channel never got
#       the copy: round 22's sentence again, on a channel that sweep did
#       not cover, and round 11's too (two spellings of one act, one of
#       them checked).
#
#   F2  `kernel_mandate_glob_to_ere` escaped no regex metacharacters at all.
#       `s/[.[\]()+{}^$|\\]/\\&/g` is not the class containing `]`; POSIX
#       reads it as the class `{. [ \}` followed by the literal text
#       `()+{}^$|\]`, which never occurs. So every `.` in every manifest
#       path scope was a live wildcard, in the one function every path
#       decision flows through. Not weaponizable against THIS manifest —
#       no sensitive file is one wildcard-position from an allowed one —
#       but a `read.deny` glob that silently under-matches is the same
#       defect pointing the other way.
#
# The fix for F1 is stated as an inversion, which is why it needs no
# per-flag knowledge: not "does this look recursive" but "did this
# segment name a path at all". `ls -w 80` and `find -maxdepth 2 -name x`
# are caught without either flag being modelled.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-24 regressions"

R24=$(mktemp -d)
P="$R24/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/docs/acceptance" "$P/docs/internal"
printf 'ADMIN_TOKEN=tok_9f8e7d\n' > "$P/.env"
printf '# Roadmap (confidential)\n'  > "$P/docs/internal/roadmap.md"
printf 'x\n' > "$P/tests/e2e/a.spec.ts"
printf 'x\n' > "$P/docs/acceptance/ac.md"
printf 'x\n' > "$P/ledgerXjson"
printf '{}\n' > "$P/ledger.json"
export KERNEL_MANDATE_STATE_DIR="$R24/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "r24",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": {
    "inspection": [
      "^(ls|find|wc|file|stat|tree|echo|du)\\b",
      "^(cat|head|tail|grep|rg|ag|ack|fd|jq|sort|uniq)\\b"
    ]
  },
  "roles": {
    "inspector": {
      "description": "Reads its own corner of the tree and nothing else.",
      "tools": { "allow": ["Bash", "Read", "Grep", "Glob"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["tests/**", "docs/acceptance/**"] }
    },
    "judge": {
      "description": "Alone updates the ledger.",
      "tools": { "allow": ["Bash", "Read", "Write"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["ledger.json"] },
      "write": { "allow": ["ledger.json"] }
    },
    "surveyor": {
      "description": "Legitimately granted the whole tree.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["**"] }
    }
  }
}
JSON
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
for r in inspector judge surveyor; do printf '%s\n' "$r" > "$KERNEL_MANDATE_STATE_DIR/agents/$r"; done

bp() { "$JQ" -nc --arg c "$1" --arg a "${2:-inspector}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }
wp() { "$JQ" -nc --arg f "$1" --arg a "${2:-judge}" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:"{}"},cwd:"'"$P"'",agent_id:$a}'; }

# --- F1: the read that names no path ----------------------------------
#
# Each of these really does print .env or the confidential subtree when
# run in this directory. None of them names an operand the old scan
# could see.
for spec in \
  "grep -rn ADMIN_TOKEN|grep -r, the one that was proven" \
  "grep -R ADMIN_TOKEN|the uppercase spelling" \
  "grep --recursive ADMIN_TOKEN|the long spelling" \
  "grep -rn -e ADMIN_TOKEN|with the pattern behind -e" \
  "rg ADMIN_TOKEN|rg, which recurses with no flag at all" \
  "rg --hidden ADMIN_TOKEN|rg reaching dotfiles" \
  "ag ADMIN_TOKEN|ag" \
  "ls|a bare ls lists the root" \
  "ls -R|and -R walks all of it" \
  "ls -w 80|a flag whose value is not modelled" \
  "tree|tree" \
  "find -name x|find defaults its path to ." \
  "find -maxdepth 2 -name x|and a predicate in front does not change that" \
  "du -sh|du" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "F1 $label → DENY" "without naming a path"
done

# The explicit spelling was ALREADY refused. These pin that the two
# spellings now agree, which is the whole point of the fix.
assert_deny "$H" "$(bp 'grep -rn ADMIN_TOKEN .')" \
  "F1 the explicit spelling still denies" "outside the role's read scope"
assert_deny "$H" "$(bp 'ls .')" \
  "F1 and so does ls ." "outside the role's read scope"

# Calibration. A command that NAMES a path is scope-checked as before —
# the new axis must not fire for it — and the pathless forms that read
# STDIN rather than the cwd are untouched.
assert_allow "$H" "$(bp 'grep -rn ADMIN_TOKEN tests/')" \
  "F1 calibration: recursive INSIDE the scope → ALLOW"
assert_allow "$H" "$(bp 'rg ADMIN_TOKEN docs/acceptance')" \
  "F1 calibration: rg inside the scope → ALLOW"
assert_allow "$H" "$(bp 'ls tests/')" \
  "F1 calibration: ls of a scoped directory → ALLOW"
assert_allow "$H" "$(bp 'find tests -name "*.ts"')" \
  "F1 calibration: find with a path and a pattern → ALLOW"
assert_allow "$H" "$(bp 'grep ADMIN_TOKEN')" \
  "F1 calibration: grep with no -r reads STDIN, not the tree → ALLOW"
assert_allow "$H" "$(bp 'cat tests/e2e/a.spec.ts')" \
  "F1 calibration: an ordinary named read → ALLOW"
assert_allow "$H" "$(bp 'wc -l')" \
  "F1 calibration: a pathless read of STDIN → ALLOW"
assert_allow "$H" "$(bp 'echo hi')" \
  "F1 calibration: a command that reads nothing → ALLOW"

# A role legitimately granted the whole tree may do all of it. The axis
# is about holding a pathless read to a ROOT-WIDE grant, not about
# banning the commands.
assert_allow "$H" "$(bp 'grep -rn ADMIN_TOKEN' surveyor)" \
  "F1 a role whose scope IS the tree may search it → ALLOW"
assert_allow "$H" "$(bp 'ls' surveyor)" \
  "F1 and may list it → ALLOW"

# --- F2: the glob escaping that escaped nothing ------------------------
#
# `ledger.json` is the judge's entire scope. With `.` live, `ledgerXjson`
# matched it — a file one character away from the ledger was writable by
# the one role whose mandate is that single file.
assert_deny "$H" "$(wp "$P/ledgerXjson")" \
  "F2 a metacharacter in a scope is a LITERAL, not a wildcard → DENY" "outside"
assert_allow "$H" "$(wp "$P/ledger.json")" \
  "F2 calibration: the file the scope names → ALLOW"
assert_deny "$H" "$(bp 'cat ledgerXjson' judge)" \
  "F2 and the read axis agrees → DENY" "outside the role's read scope"
assert_allow "$H" "$(bp 'cat ledger.json' judge)" \
  "F2 calibration: the ledger itself → ALLOW"
