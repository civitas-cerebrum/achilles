#!/bin/bash
# 14-reviewer-round7.sh — regressions for round 7 of independent
# adversarial review.
#
# Round 7 attacked the two things round 6 had just added, and broke both.
#
#   F1  `harness-os run` — the layer round 6 elevated to "the boundary" —
#       granted --allow-worker by default, and a Worker thread does NOT
#       inherit the permission model's filesystem restrictions. Three
#       lines of ordinary Node read any file on the box, with no
#       child-process grant and nothing for the static screen to catch.
#       Node prints a SecurityWarning about that flag for exactly this
#       reason; defaulting it on made the profile advisory while it
#       claimed to be a boundary. Now off by default, reported by
#       --dry-run, and `worker_threads` is a gated capability so
#       AUTHORING one is caught too. (The `run` half is covered in
#       scripts/test-cli.mjs, which can actually execute a profile.)
#
#   F2  a BLOCK COMMENT bypassed the import allowlist entirely.
#       `require/**/("dotenv")` — a comment is whitespace to the parser
#       and not to a regex, so nothing matched. Proven: the planted
#       secrets, through both the Write tool and the bash authoring
#       route.
#
#   FP  the same blindness ran the other way, and produced three false
#       positives a composer meets on day one: `import type` (erased at
#       compile time, imports nothing at run time), a package named in a
#       COMMENT, and a package named inside a STRING literal — an
#       error-message fixture reading `to fix, import Button from
#       "@mui/material"` refused the whole spec.
#
# F2 and the false positives were one bug: the screen could not tell code
# from commentary. Stripping comments before matching, and anchoring
# `from "x"` to a statement that actually starts with import/export,
# fixes the escape and the friction together — which is the shape most of
# the good fixes in this kernel have had.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-7 regressions"

R7=$(mktemp -d)
P="$R7/proj"
mkdir -p "$P/.claude" "$P/tests/e2e"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
export HARNESS_OS_STATE_DIR="$R7/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r7",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "t": ["^(echo|printf|cat)\\b", "^node tests/"] },
  "roles": {
    "composer": {
      "description": "Authors specs in tests/e2e and runs them.",
      "tools": { "allow": ["Bash", "Write", "Edit"] },
      "bash": { "groups": ["t"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    }
  }
}
JSON

mkdir -p "$HARNESS_OS_STATE_DIR/agents"
printf 'composer\n' > "$HARNESS_OS_STATE_DIR/agents/composer"
C="agent_id=composer"
wpay() { "$JQ" -nc --arg f "$1" --arg c "$2" --arg a "$3" \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c},cwd:"'"$P"'",agent_id:$a}'; }

# --- F1: a worker thread escapes the runtime profile -------------------
assert_deny "$H" "$(wpay "$P/tests/e2e/w1.spec.ts" 'const { Worker } = require("worker_threads");
new Worker("...", { eval: true });' composer)" \
  "F1 requiring worker_threads → DENY" "does NOT inherit the runtime permission profile"
assert_deny "$H" "$(wpay "$P/tests/e2e/w2.spec.ts" 'new Worker(src, { eval: true });' composer)" \
  "F1 'new Worker(' with no visible require → DENY" "worker thread"
assert_deny "$H" "$(wpay "$P/tests/e2e/w3.spec.ts" 'import { Worker } from "worker_threads";' composer)" \
  "F1 the import form → DENY" "worker thread"

# --- F2: a comment is whitespace to the parser, not to a regex ---------
assert_deny "$H" "$(wpay "$P/tests/e2e/c1.spec.ts" 'const d = require/**/("dotenv"); d.config();' composer)" \
  "F2 'require/**/(\"dotenv\")' → DENY" "not in this role's declared import list"
assert_deny "$H" "$(wpay "$P/tests/e2e/c2.spec.ts" 'import cfg from/**/"dotenv";' composer)" \
  "F2 a comment between 'from' and the specifier → DENY" "not in this role's declared import list"
assert_deny "$H" "$(wpay "$P/tests/e2e/c3.spec.ts" 'import/**/"dotenv/config";' composer)" \
  "F2 the side-effect form with a comment → DENY" "not in this role's declared import list"
assert_deny "$H" "$(wpay "$P/tests/e2e/c4.spec.ts" 'const d = require //x
("dotenv");' composer)" \
  "F2 a LINE comment before the argument → DENY" "not in this role's declared import list"
# And through the other authoring channel, which round 4 opened.
assert_deny "$H" "$(payload tool_name=Bash command='echo "const d = require/**/(\"dotenv\");" > tests/e2e/c5.spec.ts' cwd="$P" $C)" \
  "F2 the same trick through the bash authoring route → DENY" "not in this role's declared import list"

# --- FP: the screen must tell code from commentary --------------------
assert_allow "$H" "$(wpay "$P/tests/e2e/f1.spec.ts" 'import type { Page } from "playwright-core";
import { test } from "@playwright/test";' composer)" \
  "FP 'import type' is erased at compile time → ALLOW"
assert_allow "$H" "$(wpay "$P/tests/e2e/f2.spec.ts" '// see also the helpers from "lodash"
import { test } from "@playwright/test";' composer)" \
  "FP a package named in a COMMENT → ALLOW"
assert_allow "$H" "$(wpay "$P/tests/e2e/f3.spec.ts" 'import { test } from "@playwright/test";
const msg = "to fix, import Button from \"@mui/material\"";' composer)" \
  "FP a package named inside a STRING literal → ALLOW"
assert_allow "$H" "$(wpay "$P/tests/e2e/f4.spec.ts" '/* This spec deliberately does not require dotenv. */
import { test, expect } from "@playwright/test";
test("AC-1", async ({ page }) => { await page.goto("/forms"); expect(1).toBe(1); });' composer)" \
  "FP a block comment mentioning the escape → ALLOW"

# The comment strip must match STRING LITERALS FIRST, or it spans from a
# `/*` inside one string to a `*/` inside another and swallows the code
# between them. Found by probing the strip right after adding it — it
# really did print the secret. This is the shape every non-parsing tool
# gets wrong, and the fix is the ordering a lexer would use.
assert_deny "$H" "$(wpay "$P/tests/e2e/sp.spec.ts" 'const a = "x /* y";
const d = require("dotenv");
const b = "z */ w";' composer)" \
  "FP comment markers spanning two STRINGS do not hide the code between → DENY" "not in this role's declared import list"
assert_allow "$H" "$(wpay "$P/tests/e2e/sp2.spec.ts" 'import { test } from "@playwright/test";
const url = "http://localhost:4173/forms";
const note = `see // the docs`;' composer)" \
  "FP a URL and a template literal are not comments → ALLOW"

# The plain forms must still deny, or the comment-stripping went too far.
assert_deny "$H" "$(wpay "$P/tests/e2e/ctl.spec.ts" 'const d = require("dotenv");' composer)" \
  "FP control: the plain form is still refused → DENY" "not in this role's declared import list"

# --- A role may only install its OWN runtime profile -------------------
# `harness-os run --role X` installs X's path scopes as the process's
# permission profile, so invoking it with another role's name borrows
# that role's scopes — turning the runtime profile into a way AROUND the
# boundary rather than part of it. A command group written loosely
# (`^harness-os run\b`) permits exactly that, and that is a shape an
# operator will write, so the kernel refuses it rather than relying on
# the pattern being tight. Found by probing `run` after adding it.
R7B="$R7/proj-b"
mkdir -p "$R7B/.claude" "$R7B/tests/e2e"
cat > "$R7B/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r7b",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "t": ["^harness-os run\\b", "^npx harness-os run\\b"] },
  "roles": {
    "composer": { "description": "narrow", "tools": { "allow": ["Bash"] }, "bash": { "groups": ["t"] },
                  "read": { "allow": ["tests/**"] }, "write": { "allow": ["tests/e2e/**"] } },
    "admin":    { "description": "wide",   "tools": { "allow": ["Bash"] }, "bash": { "groups": ["t"] },
                  "read": { "allow": ["**"] },      "write": { "allow": ["**"] } }
  }
}
JSON
HARNESS_OS_MANIFEST="$R7B/.claude/harness-os.json" assert_deny "$H" \
  "$(payload tool_name=Bash command='harness-os run --role admin -- node x.js' cwd="$R7B" $C)" \
  "RUN a role may not install another role's profile → DENY" "runtime profile"
HARNESS_OS_MANIFEST="$R7B/.claude/harness-os.json" assert_deny "$H" \
  "$(payload tool_name=Bash command='harness-os run --role=admin -- node x.js' cwd="$R7B" $C)" \
  "RUN the attached --role=X form → DENY" "runtime profile"
HARNESS_OS_MANIFEST="$R7B/.claude/harness-os.json" assert_deny "$H" \
  "$(payload tool_name=Bash command='npx harness-os run --role admin -- node x.js' cwd="$R7B" $C)" \
  "RUN through npx → DENY" "runtime profile"
HARNESS_OS_MANIFEST="$R7B/.claude/harness-os.json" assert_allow "$H" \
  "$(payload tool_name=Bash command='harness-os run --role composer -- node x.js' cwd="$R7B" $C)" \
  "RUN calibration: a role installing its OWN profile → ALLOW"
HARNESS_OS_MANIFEST="$R7B/.claude/harness-os.json" assert_allow "$H" \
  "$(payload tool_name=Bash command='harness-os run --role composer --dry-run -- node x.js' cwd="$R7B" $C)" \
  "RUN calibration: --dry-run on its own profile → ALLOW"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$R7"
