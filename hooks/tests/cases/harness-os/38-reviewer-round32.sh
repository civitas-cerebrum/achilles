#!/bin/bash
# 38-reviewer-round32.sh — regressions for round 32 of independent
# adversarial review.
#
# Round 31 found the vein — audit the manifests this project SHIPS, and
# ask what a granted verb can DO rather than how it is spelled. Round 32
# mined the same vein one tool over and broke the templates again.
#
# `registration-form-qa` — the one SKILL.md calls "the template when
# onboarding any test-automation harness" — gives its INSPECTOR a group
# named `form-probe`:
#
#     ^(npx|yarn|pnpm exec) playwright (codegen|open|show-trace)\b
#
# The inspector has no `write` block at all and a read scope of
# `tests/**` + `docs/**`. `playwright codegen` is not a test runner; it
# is a browser driver that writes wherever it is pointed:
#
#     npx playwright codegen --save-har docs/leak.har file:///…/.env
#
# One granted command performed a write the role has no grant for AND a
# read outside its scope, and the reviewer ran it: `docs/leak.har` came
# out holding all three planted secrets, then `cat docs/leak.har` is an
# ordinary in-scope read.
#
# Three separate holes composed, and the fixes are deliberately generic
# rather than aimed at playwright:
#
#   1. `-o` carried a LIST of commands whose `-o` names a file, and
#      playwright was not on it — so `codegen -o docs/x.js` wrote where
#      `codegen --output docs/x.js` was refused. Two spellings of one
#      act, one checked, for the fifth time in this series. The list is
#      INVERTED now: `-o` takes a path unless the command is one of the
#      few where it means something else (grep's only-matching, find's
#      OR). An unknown tool is treated as writing.
#
#   2. `--save-har` / `--save-storage` / `--save-trace` were modelled
#      nowhere. They are unambiguous spellings, so they need no list.
#
#   3. a `file://` operand was skipped by the read scan with every other
#      URL scheme. It is a PATH wearing a URL's clothes, and the WebFetch
#      axis has unwrapped it since round 22 — one more channel that had
#      the rule and one that did not.
#
# And the fourth finding is about round 31's own fix: it pinned
# `qa-pipeline`'s playwright pattern to `playwright test` and did not
# carry that to `feature-dev`, whose `test-execution` still granted every
# subcommand. The fix that closes a channel and misses its twin, in the
# same commit that closed the first one.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-32 regressions"

R32=$(mktemp -d)
P="$R32/proj"
mkdir -p "$P/.claude" "$P/tests" "$P/docs" "$P/out"
printf 'ADMIN_TOKEN=tok_9f8e7d\n' > "$P/.env"
printf 'x\n' > "$P/tests/a.spec.ts"
export HARNESS_OS_STATE_DIR="$R32/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r32",
  "settings": { "mainSessionRole": "inspector" },
  "commandGroups": {
    "inspection": ["^(ls|cat|grep|echo|sort|find)\\b"],
    "form-probe": ["^(npx|yarn|pnpm exec) playwright (codegen|open|show-trace)\\b"]
  },
  "roles": {
    "inspector": {
      "description": "Probes the live form. No write block at all.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["inspection", "form-probe"] },
      "read": { "allow": ["tests/**", "docs/**"] }
    },
    "author": {
      "description": "Has a narrow write scope for its artifacts.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["inspection", "form-probe"] },
      "read": { "allow": ["tests/**", "out/**"] },
      "write": { "allow": ["out/**"] }
    }
  }
}
JSON
for r in inspector author; do printf '%s\n' "$r" > "$HARNESS_OS_STATE_DIR/agents/$r"; done

bp() { "$JQ" -nc --arg c "$1" --arg a "${2:-inspector}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- The command that was proven, and every spelling of its halves -----
assert_deny "$H" "$(bp "npx playwright codegen --save-har docs/leak.har file://$P/.env")" \
  "R32 the command that was proven → DENY" "write"
for spec in \
  "npx playwright codegen -o docs/gen.js|a bare -o, which --output already refused" \
  "npx playwright codegen -odocs/gen.js|the attached spelling of it" \
  "npx playwright codegen --output docs/gen.js|the long spelling that always denied" \
  "npx playwright codegen --save-har docs/x.har|--save-har" \
  "npx playwright codegen --save-har=docs/x.har|its = spelling" \
  "npx playwright codegen --save-storage docs/s.json|--save-storage" \
  "npx playwright codegen --save-trace docs/t.zip|--save-trace" ; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R32 $label → DENY" "write"
done

# The read half, on its own.
assert_deny "$H" "$(bp "npx playwright open file://$P/.env")" \
  "R32 a file:// operand is a read, not a URL → DENY" "outside the role's read scope"
assert_deny "$H" "$(bp "npx playwright codegen file://$P/.env")" \
  "R32 and through codegen too → DENY" "outside the role's read scope"
assert_deny "$H" "$(bp "cat file://$P/.env")" \
  "R32 the same wrapper through any command → DENY" "outside the role's read scope"

# --- Calibration: the role's actual job, and -o that is not a path ----
assert_allow "$H" "$(bp 'npx playwright open http://localhost:4173/forms')" \
  "R32 calibration: probing the live form → ALLOW"
assert_allow "$H" "$(bp 'npx playwright codegen http://localhost:4173/forms')" \
  "R32 calibration: codegen against the app → ALLOW"
assert_allow "$H" "$(bp "npx playwright open file://$P/tests/a.spec.ts")" \
  "R32 calibration: a file:// inside the read scope → ALLOW"
assert_allow "$H" "$(bp 'grep -o TODO tests/a.spec.ts')" \
  "R32 calibration: grep -o is only-matching, not an output → ALLOW"
assert_allow "$H" "$(bp 'find tests -name a -o -name b')" \
  "R32 calibration: find -o is OR, not an output → ALLOW"
assert_allow "$H" "$(bp 'cat tests/a.spec.ts')" \
  "R32 calibration: an ordinary read → ALLOW"

# --- A role WITH a write scope may produce its artifacts --------------
# The fix is about where the output lands, not about banning the tool.
assert_allow "$H" "$(bp 'npx playwright codegen --save-har out/run.har http://localhost:4173/' author)" \
  "R32 a role with a write scope may save into it → ALLOW"
assert_deny "$H" "$(bp 'npx playwright codegen --save-har docs/run.har http://localhost:4173/' author)" \
  "R32 ...and not outside it → DENY" "write"

# --- -O is NOT -o, and inverting the wrong one costs a false deny ----
# `-O` is an output for a couple of downloaders and an OPTIMISATION
# level for every interpreter and compiler. Inverting it turned
# `python3 -OO script.py` into a write of a file called `O` — caught by
# a calibration case from an earlier round, which is what those exist
# for.
assert_allow "$H" "$(bp 'sort -o out/x.txt tests/a.spec.ts' author)" \
  "R32 -o still writes, for a role that may → ALLOW"
assert_deny "$H" "$(bp 'wget -O docs/x.html http://localhost:4173/')" \
  "R32 wget -O is an output → DENY" "write"

# --- The inverted -o list applies to every tool, not to playwright ----
# The point of inverting was that the next tool is always unknown.
for spec in "somenewtool -o docs/x|an unknown tool" "cc -o docs/a.out a.c|one that was on the old list"; do
  cmd="${spec%%|*}"; label="${spec##*|}"
  assert_deny "$H" "$(bp "$cmd")" "R32 $label writes through -o → DENY" "write"
done
