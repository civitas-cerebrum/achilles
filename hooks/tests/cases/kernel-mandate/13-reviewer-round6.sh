#!/bin/bash
# 13-reviewer-round6.sh — regressions for round 6 of independent
# adversarial review.
#
# Round 6 confirmed round 5's module-name inversion holds for BUILTINS,
# then made the argument that should have been obvious five rounds
# earlier and wasn't:
#
#   N1  the capability branches recognise dangerous BUILTIN modules. A
#       plain quoted literal naming a PACKAGE walks past all of them.
#       `require("dotenv").config()` reads .env in one line; so do glob,
#       fs-extra, shelljs, and whatever is published next. Proven: all
#       three planted secrets, from a role whose read scope excludes
#       .env. Non-JS languages were worse — the extension gate opts
#       .rb/.php/.lua/.ps1 into the screen and there were no patterns for
#       any of them at all.
#
# The fix is the same inversion, applied one level up: a role may declare
# `write.codeImports`, the packages its authored code DOES import, and
# everything else is refused. It is opt-in — denying `@playwright/test`
# by default would break every manifest — so `validate` now warns for any
# role that authors and runs code without either that list or the
# `kernel-mandate run` wrapper, and says the screen is advisory until one is
# in place. That honesty is the point: round 6's real contribution was
# the argument that a static screen over authored code cannot be sound,
# which is why `kernel-mandate run` (a runtime permission profile built from
# the same scopes) is now the boundary and this axis is the floor.
#
# Round 6 also found two false positives, both on commands the manifest
# explicitly grants:
#   FP1 `jq .` — jq's filter is a PROGRAM, and `.` resolved to the cwd,
#       so the commonest jq invocation there is was denied as an
#       out-of-scope read. An inspector piping the page repository
#       through `jq .` is doing exactly what its mandate describes.
#   FP2 a bare `git diff` is denied by the vcs-history construct even
#       though the command group grants it. The deny is sound, but the
#       message now says the group grant is being overridden, so nobody
#       wastes a cycle adding another pattern.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-6 regressions"

R6=$(mktemp -d)
P="$R6/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/tests/data" "$P/docs/internal"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf '{}\n' > "$P/tests/data/page-repository.json"
printf '{}\n' > "$P/package.json"
printf 'confidential\n' > "$P/docs/internal/roadmap.md"
export KERNEL_MANDATE_STATE_DIR="$R6/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r6",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": {
    "inspection": ["^(ls|find|cat|head|tail|grep|wc|stat|echo|jq)\\b", "^git (status|log|diff|show)\\b"]
  },
  "roles": {
    "composer": {
      "description": "Authors specs in tests/e2e and runs them.",
      "tools": { "allow": ["Bash", "Read", "Write", "Edit"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["tests/**", "package.json"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    },
    "loose": {
      "description": "Authors specs but declares no import list.",
      "tools": { "allow": ["Bash", "Write"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"] }
    },
    "inspector": {
      "description": "Reads what its task needs. No writes at all.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["inspection"] },
      "read": { "allow": ["tests/**", "package.json"] }
    }
  }
}
JSON

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
for r in composer loose inspector; do printf '%s\n' "$r" > "$KERNEL_MANDATE_STATE_DIR/agents/$r"; done
I="agent_id=inspector"; C="agent_id=composer"
wpay() { "$JQ" -nc --arg f "$1" --arg c "$2" --arg a "$3" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- N1: a package name is an open set, so declare what you import -----
assert_deny "$H" "$(wpay "$P/tests/e2e/a.spec.ts" 'require("dotenv").config();
console.log(process.env.SMTP_PASSWORD);' composer)" \
  "N1 require(\"dotenv\") — one line, reads .env → DENY" "not in this role's declared import list"
assert_deny "$H" "$(wpay "$P/tests/e2e/b.spec.ts" 'import "dotenv/config";' composer)" \
  "N1 the side-effect form, subpath normalised → DENY" "not in this role's declared import list"
assert_deny "$H" "$(wpay "$P/tests/e2e/c.spec.ts" 'const g = require("glob");' composer)" \
  "N1 'glob' — an fs wrapper no builtin list names → DENY" "not in this role's declared import list"
assert_deny "$H" "$(wpay "$P/tests/e2e/d.spec.ts" 'const fse = require("fs-extra");' composer)" \
  "N1 'fs-extra' → DENY" "not in this role's declared import list"

# Declared packages and relative imports are the whole point of the list.
assert_allow "$H" "$(wpay "$P/tests/e2e/ok.spec.ts" 'import { test, expect } from "@playwright/test";
test("AC-1", async ({ page }) => { await page.goto("/forms"); expect(1).toBe(1); });' composer)" \
  "N1 the DECLARED package → ALLOW"
assert_allow "$H" "$(wpay "$P/tests/e2e/ok2.spec.ts" 'import { test } from "../fixtures/base";
import { helper } from "./helper";' composer)" \
  "N1 relative imports are never package imports → ALLOW"

# This assertion USED to read "a role that declares NO list is unchanged
# (opt-in) → ALLOW", on the reasoning that the list must not break an
# existing manifest. Round 43 showed what that reasoning cost: absence
# was the permissive state, so `codeImports` omitted meant no allowlist
# while `codeImports: []` meant a closed one — the unconfigured state of
# a capable role was its least restrictive. Round 37 had already
# inverted exactly that shape on the environment screen.
#
# The reversal is scoped to the shape where it matters: a role that
# authors executable files AND can run them. `loose` here is that shape,
# so a missing list now reads as an empty one.
assert_deny "$H" "$(wpay "$P/tests/e2e/e.spec.ts" 'const d = require("dotenv");' loose)" \
  "N1 an author+run role that declares NO list is held to an empty one → DENY" "declared import list"

# --- N1a: the loader reached through an alias --------------------------
# Found by probing the import allowlist before the next reviewer saw it.
# `const r = require; r("dotenv")` defeats BOTH the capability branches
# and the allowlist, because nothing downstream can follow the name to
# see what it loads. Verified semantically: it really did print the
# secret. Same shape as a capability method bound before use.
assert_deny "$H" "$(wpay "$P/tests/e2e/al.spec.ts" 'const r = require;
r("dotenv").config();' composer)" \
  "N1a 'const r = require' — the loader bound to a name → DENY" "bound to a name"
assert_deny "$H" "$(wpay "$P/tests/e2e/al2.spec.ts" 'globalThis.R = require;' composer)" \
  "N1a assigned onto a global → DENY" "bound to a name"
assert_deny "$H" "$(wpay "$P/tests/e2e/al3.spec.ts" 'const o = { load: require };' composer)" \
  "N1a stashed in an object property → DENY" "bound to a name"
assert_deny "$H" "$(wpay "$P/tests/e2e/al4.spec.ts" 'register(require);' composer)" \
  "N1a passed as an argument → DENY" "bound to a name"

# The check is bounded to VALUE position, because prose is full of the
# word. A gate that denies a spec for its comments is a gate people edit
# around.
assert_allow "$H" "$(wpay "$P/tests/e2e/al5.spec.ts" '// this test requires a logged-in user
import { test } from "@playwright/test";' composer)" \
  "N1a calibration: \"requires a logged-in user\" in a comment → ALLOW"
assert_allow "$H" "$(wpay "$P/tests/e2e/al6.spec.ts" '// we deliberately do not require anything here
import { test } from "@playwright/test";' composer)" \
  "N1a calibration: \"do not require anything\" in a comment → ALLOW"
assert_allow "$H" "$(wpay "$P/tests/e2e/al7.spec.ts" 'const helper = require("./helper");' composer)" \
  "N1a calibration: an ordinary relative require CALL → ALLOW"

# --- N1b: the non-JS languages the extension gate had opted in --------
assert_deny "$H" "$(wpay "$P/tests/e2e/r.rb" 'puts File.read("../../.env")' composer)" \
  "N1b Ruby File.read → DENY" "Ruby filesystem access"
assert_deny "$H" "$(wpay "$P/tests/e2e/p.php" '<?php echo file_get_contents("../../.env");' composer)" \
  "N1b PHP file_get_contents → DENY" "PHP filesystem access"
assert_deny "$H" "$(wpay "$P/tests/e2e/l.lua" 'local f = io.open("../../.env")' composer)" \
  "N1b Lua io.open → DENY" "Lua filesystem access"
assert_deny "$H" "$(wpay "$P/tests/e2e/s.ps1" 'Get-Content ../../.env' composer)" \
  "N1b PowerShell Get-Content → DENY" "PowerShell filesystem access"
assert_deny "$H" "$(wpay "$P/tests/e2e/py.py" 'import codecs
f = codecs.open("../../.env")' composer)" \
  "N1b Python reached through codecs → DENY" "reached indirectly"
assert_deny "$H" "$(wpay "$P/tests/e2e/att.spec.ts" 'await testInfo.attach("x", { path: "../../.env" });' composer)" \
  "N1b the framework's own file-attachment API → DENY" "test-framework file API"

# --- FP1: jq's filter is a program, not a path ------------------------
assert_allow "$H" "$(payload tool_name=Bash command='cat tests/data/page-repository.json | jq .' cwd="$P" $I)" \
  "FP1 'jq .' — the commonest jq there is → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="jq -r '.FormsPage' tests/data/page-repository.json" cwd="$P" $I)" \
  "FP1 a jq filter with a flag before it → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='cat package.json | jq .' cwd="$P" $I)" \
  "FP1 same shape on another in-scope file → ALLOW"
assert_deny "$H" "$(payload tool_name=Bash command='jq -f docs/internal/roadmap.md tests/data/page-repository.json' cwd="$P" $I)" \
  "FP1 but 'jq -f FILE' IS a read and stays scoped → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='jq . docs/internal/roadmap.md' cwd="$P" $I)" \
  "FP1 and an out-of-scope INPUT file is still caught → DENY" "outside the role's read scope"

# --- FP2: say when a construct deny overrides a command grant ---------
assert_deny "$H" "$(payload tool_name=Bash command='git diff' cwd="$P" $I)" \
  "FP2 a granted 'git diff' denied by the construct explains the override" "your command group DOES grant"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R6"
