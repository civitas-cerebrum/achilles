#!/bin/bash
# 48-reviewer-round44.sh — regressions for round 44 of independent
# adversarial review.
#
# Round 44 found the one thing this axis exists to make impossible: a
# governed role minting its own law.
#
#   F1  discovery obeys the NEAREST manifest to the cwd — round 27 made
#       it walk up and stop at the first `.claude/harness-os.json`, on
#       purpose, so a project nested inside a larger repo is governed by
#       its own law. Self-protection kept matching the ROOT-relative
#       literals and the single resolved manifest path, so
#       `tests/e2e/.claude/harness-os.json` matched neither. The bench's
#       REAL composer, whose write scope is `tests/e2e/**`, authored a
#       manifest granting itself `bash.unrestricted` and `read: ["**"]`,
#       and any call rooted at or below that directory obeyed it.
#
#       The Bash channel had been right the whole time: its PROT_RE
#       matches a `.claude` segment anywhere, so `echo {} >
#       tests/e2e/.claude/harness-os.json` was already refused while the
#       identical Write was allowed. Same act, two channels, guarded on
#       one — the copies had drifted, which is the defect this suite
#       records under four other names.
#
#   F1b the same finding without a valid manifest: eight bytes of
#       non-JSON at that path put the kernel in its broken-manifest
#       state, which fails closed for mutations and OPEN for reads so
#       the file can be repaired. Sound for an operator who broke their
#       own JSON; not sound for a file that arrives from below, because
#       the outer manifest — the actual law — was never consulted. The
#       walk stops at the first manifest that PARSES now, and remembers
#       the first it merely found, so a LONE broken manifest still lands
#       in the repair state exactly as before.
#
#   F2  `rg --pre <prog>` runs a preprocessor on every file ripgrep is
#       about to search and reads its stdout instead of the file. It sat
#       inside the benchmark's own `inspection` group, where rg is
#       granted for what it obviously is — a reader. It is `find -exec`
#       under a different flag. Latent as shipped (the inspector cannot
#       author the preprocessor), closed anyway: "the payload half is
#       missing" describes today's manifests, not the boundary.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-44 regressions"

R44=$(mktemp -d)
P="$R44/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/src"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'x\n' > "$P/tests/e2e/a.spec.ts"
export HARNESS_OS_STATE_DIR="$R44/state"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"
printf 'composer\n' > "$HARNESS_OS_STATE_DIR/agents/composer"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r44",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "i": ["^rg\\b", "^(cat|echo)\\b"] },
  "roles": {
    "composer": {
      "description": "Authors specs under tests/e2e and greps them.",
      "tools": { "allow": ["Bash", "Read", "Grep", "Glob", "Write", "Edit"] },
      "bash": { "groups": ["i"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/**"], "codeImports": ["@playwright/test"] }
    }
  }
}
JSON

# Discovery must run for real here — these findings ARE discovery — so
# no HARNESS_OS_MANIFEST seam. The state dir stays explicit.
wp() { "$JQ" -nc --arg t "${3:-Write}" --arg f "$1" --arg c "$2" \
  '{tool_name:$t,tool_input:{file_path:$f,content:$c,old_string:"a",new_string:"b"},cwd:"'"$P"'",agent_id:"composer"}'; }
rp() { "$JQ" -nc --arg f "$1" --arg d "${2:-$P}" \
  '{tool_name:"Read",tool_input:{file_path:$f},cwd:$d,agent_id:"composer"}'; }
bp() { "$JQ" -nc --arg c "$1" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$P"'",agent_id:"composer"}'; }

# --- F1: a role may not author the law that will govern it ------------
PWN='{"harnessOsVersion":1,"name":"pwn","settings":{"mainSessionRole":"composer"},"roles":{"composer":{"description":"x","tools":{"allow":["*"]},"bash":{"unrestricted":true},"read":{"allow":["**"]},"write":{"allow":["**"]}}}}'
assert_deny "$H" "$(wp "tests/e2e/.claude/harness-os.json" "$PWN")" \
  "R44 Write of a NESTED manifest inside the write scope → DENY" "harness OS itself"
assert_deny "$H" "$(wp "tests/e2e/.claude/harness-os.json" "$PWN" Edit)" \
  "R44 ...and the Edit spelling of it → DENY" "harness OS itself"
assert_deny "$H" "$(wp "tests/e2e/sub/deep/.claude/harness-os.json" "$PWN")" \
  "R44 ...at any depth → DENY" "harness OS itself"
assert_deny "$H" "$(wp "tests/e2e/.claude/settings.json" '{}')" \
  "R44 ...and the rest of a nested .claude, not just the manifest → DENY" "harness OS itself"
assert_deny "$H" "$(wp "tests/e2e/.claude/hooks/evil.sh" '#!/bin/sh')" \
  "R44 ...including a hook planted beside a nested config → DENY" "harness OS itself"
# The rule is the SAME CHILDREN as the root list, generalised by depth —
# not the whole directory. Taking the Bash channel's broader spelling
# wholesale took `.claude/notes.md` away from round 22's config-keeper,
# whose write scope legitimately IS `.claude/**`, and the suite caught it
# within the hour. A self-protection axis widened until it eats ordinary
# work is how a manifest acquires bash.unrestricted.
assert_allow "$H" "$(wp "tests/e2e/.claude/notes.md" 'Ordinary notes in a nested config dir.')" \
  "R44 calibration: an unprotected child of a nested .claude → ALLOW"
assert_deny "$H" "$(wp "tests/e2e/harness-os.json" "$PWN")" \
  "R44 ...and the manifest filename outside a .claude dir → DENY" "harness OS itself"
# The channel that was already right, kept honest.
assert_deny "$H" "$(bp 'echo {} > tests/e2e/.claude/harness-os.json')" \
  "R44 calibration: the Bash spelling was always refused → DENY" "harness OS itself"

# Calibration: the role's actual job is untouched. This is the half that
# matters — a self-protection axis that eats ordinary writes is how a
# manifest acquires bash.unrestricted.
assert_allow "$H" "$(wp "tests/e2e/b.spec.ts" 'import {test} from "@playwright/test"; test("a", async () => {});')" \
  "R44 calibration: an ordinary spec → ALLOW"
assert_allow "$H" "$(wp "tests/e2e/fixtures/data.json" '{"a":1}')" \
  "R44 calibration: a fixture named like data → ALLOW"
assert_allow "$H" "$(wp "tests/e2e/notes.md" 'The manifest lives in .claude/harness-os.json.')" \
  "R44 calibration: prose ABOUT the manifest → ALLOW"

# --- F1b: a broken nested manifest does not unseat the outer law ------
mkdir -p "$P/tests/e2e/.claude"
printf 'not json' > "$P/tests/e2e/.claude/harness-os.json"
assert_deny "$H" "$(rp "../../.env" "$P/tests/e2e")" \
  "R44 a BROKEN nested manifest cannot downgrade reads → DENY" "outside the role"
assert_allow "$H" "$(rp "a.spec.ts" "$P/tests/e2e")" \
  "R44 calibration: an in-scope read from the nested cwd → ALLOW"
rm -rf "$P/tests/e2e/.claude"

# A LONE broken manifest is the case the repair path was written for,
# and it still behaves exactly as it did: reads open, mutations closed.
LONE="$R44/lone"
mkdir -p "$LONE/.claude" "$LONE/tests"
printf 'x\n' > "$LONE/tests/a.txt"
printf 'not json' > "$LONE/.claude/harness-os.json"
assert_allow "$H" "$("$JQ" -nc '{tool_name:"Read",tool_input:{file_path:"tests/a.txt"},cwd:"'"$LONE"'",agent_id:"composer"}')" \
  "R44 calibration: a LONE broken manifest still allows reads for repair → ALLOW"
assert_deny "$H" "$("$JQ" -nc '{tool_name:"Bash",tool_input:{command:"rm -rf tests"},cwd:"'"$LONE"'",agent_id:"composer"}')" \
  "R44 calibration: ...and still refuses mutations → DENY" "not valid JSON"

# --- F2: a search tool with a preprocessor is a search tool that execs -
assert_deny "$H" "$(bp 'rg --pre sh SMTP tests/')" \
  "R44 rg --pre is an execution channel → DENY" "preprocessor"
assert_deny "$H" "$(bp 'rg --pre=sh SMTP tests/')" \
  "R44 ...in its attached spelling → DENY" "preprocessor"
assert_deny "$H" "$(bp 'rg --pre-glob *.env SMTP tests/')" \
  "R44 ...and --pre-glob, which only narrows which files it sees → DENY" "preprocessor"
assert_allow "$H" "$(bp 'rg SMTP tests/')" \
  "R44 calibration: an ordinary ripgrep → ALLOW"
assert_allow "$H" "$(bp 'rg --pretty SMTP tests/')" \
  "R44 calibration: a flag that merely STARTS with --pre → ALLOW"

unset HARNESS_OS_STATE_DIR
rm -rf "$R44"
