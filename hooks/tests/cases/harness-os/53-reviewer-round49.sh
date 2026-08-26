#!/bin/bash
# 53-reviewer-round49.sh — regressions for round 49 of independent
# adversarial review.
#
# Round 49 was pointed away from the axis that had absorbed rounds 45-48.
# It found one more escape there anyway — in the Glob flattener, for the
# fourth consecutive round — and then found something worth more than an
# escape: THREE SHIPPED EXAMPLE MANIFESTS COULD NOT AUTHOR THE FIRST
# LINE OF THE CODE THEIR ROLES EXIST TO WRITE, and every measurement
# this project had built was blind to it.
#
#   F1  the flattener's own safety argument was FALSE. It claimed "the
#       flattening can only ADD segment boundaries, so a pattern it
#       misreads is refused rather than admitted" — and adding a
#       boundary is not conservative when the token you are looking for
#       is TWO characters wide:
#
#         docs/acceptance/[.]{,}[.]{,}/internal/*      ALLOW
#         docs/acceptance/[.-.][.-.]/[.-.][.-.]/.env   ALLOW
#
#       A globber deletes an empty alternation and keeps `[.][.]` as one
#       segment; turning `{},` into `/` SPLIT the `..` in half. And a
#       bracket RANGE spells a dot without containing one. Both return
#       the confidential file and the planted secret from the globber in
#       the benchmark's own node_modules. It now tests the braces JOINED
#       and SPLIT, and replaces a bracket with a dot when it can MATCH
#       one — literal, negated, or a range straddling 0x2E.
#
#   F2  the code screen consults `network.allow` whether or not a role
#       can execute anything, and the examples had dropped that block
#       from roles that "cannot run". So a composer whose whole mandate
#       is authoring Playwright specs could not write
#       `page.goto("http://localhost:4173/")` — including in
#       `split-author-run`, shipped LAST ROUND as the structural answer
#       to four rounds of escapes.
#
#   F3  `s/node:/ /g` normalises the code text so the capability scanner
#       reads `node:fs` as `fs`. It also left the SPECIFIER as `" path"`
#       — a leading space — matching neither `node:path` nor `path` in a
#       declared list. The shipped feature-dev implementer could not
#       import two of the three modules its own manifest granted it, in
#       any spelling. And `Path[[:space:]]*\(`, meant for Python's
#       pathlib, matched the tail of `fileURLToPath(` — the canonical
#       ESM __dirname idiom — for a role explicitly granted `node:url`.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-49 regressions"

R49=$(mktemp -d)
P="$R49/proj"
mkdir -p "$P/.claude" "$P/docs/acceptance" "$P/docs/internal" "$P/tests/e2e" "$P/src/lib"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf 'AC-1\n' > "$P/docs/acceptance/reg.md"
printf 'confidential\n' > "$P/docs/internal/roadmap.md"
export HARNESS_OS_STATE_DIR="$R49/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"
mkdir -p "$HARNESS_OS_STATE_DIR/agents"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r49",
  "settings": { "mainSessionRole": "composer" },
  "roles": {
    "reviewer": {
      "description": "Reads the acceptance criteria and the deliverable. Nothing else.",
      "tools": { "allow": ["Read", "Glob", "Grep"] },
      "read": { "allow": ["docs/acceptance/**", "tests/e2e/**"] }
    },
    "composer": {
      "description": "Authors browser specs. Cannot run them.",
      "tools": { "allow": ["Read", "Write"] },
      "read": { "allow": ["tests/**", "docs/acceptance/**"] },
      "network": { "allow": ["localhost:4173"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    },
    "impl": {
      "description": "Authors library code with a declared import list.",
      "tools": { "allow": ["Read", "Write"] },
      "read": { "allow": ["src/**"] },
      "write": { "allow": ["src/**"], "codeImports": ["node:path", "node:url", "zod"] }
    }
  }
}
JSON
for r in reviewer composer impl; do printf '%s\n' "$r" > "$HARNESS_OS_STATE_DIR/agents/$r"; done

glb() { "$JQ" -nc --arg p "$1" '{tool_name:"Glob",tool_input:{pattern:$p},cwd:"'"$P"'",agent_id:"reviewer"}'; }
spec() { "$JQ" -nc --arg c "$1" '{tool_name:"Write",tool_input:{file_path:"tests/e2e/x.spec.ts",content:$c},cwd:"'"$P"'",agent_id:"composer"}'; }
lib()  { "$JQ" -nc --arg c "$1" '{tool_name:"Write",tool_input:{file_path:"src/lib/t.ts",content:$c},cwd:"'"$P"'",agent_id:"impl"}'; }

# --- F1: '..' is two characters, so a boundary is not conservative -----
assert_deny "$H" "$(glb 'docs/acceptance/[.]{,}[.]{,}/internal/*')" \
  "R49 an EMPTY alternation, which a globber deletes → DENY" "traversal"
assert_deny "$H" "$(glb 'docs/acceptance/[.-.][.-.]/[.-.][.-.]/.env')" \
  "R49 a bracket RANGE that spells a dot without containing one → DENY" "traversal"
assert_deny "$H" "$(glb 'docs/acceptance/[!x][!x]/internal/*')" \
  "R49 a NEGATED class, which matches a dot → DENY" "traversal"
for spelling in \
  'docs/acceptance/[.][.]/[.][.]/.env' \
  'docs/acceptance/{..,..}/*' \
  'docs/acceptance/.\./internal/*' \
  'docs/acceptance/../internal/*' ; do
  assert_deny "$H" "$(glb "$spelling")" \
    "R49 calibration: the spellings rounds 46-48 closed → DENY" "traversal"
done
assert_allow "$H" "$(glb 'docs/acceptance/**')" \
  "R49 calibration: an in-scope pattern → ALLOW"
assert_allow "$H" "$(glb 'docs/acceptance/{a,b}/*.md')" \
  "R49 calibration: a real alternation → ALLOW"
assert_allow "$H" "$(glb 'docs/acceptance/[ab]/*.md')" \
  "R49 calibration: a class that cannot match a dot → ALLOW"
assert_allow "$H" "$(glb 'docs/acceptance/[0-9]/x')" \
  "R49 calibration: a range that does not straddle one → ALLOW"

# --- F2: a role must be able to do its own job ------------------------
assert_allow "$H" "$(spec 'import { test, expect } from "@playwright/test";
test("t", async ({ page }) => {
  await page.goto("http://localhost:4173/forms");
  await expect(page.getByRole("table")).toBeVisible();
});')" \
  "R49 an authoring role can write the first line of a spec → ALLOW"
assert_deny "$H" "$(spec 'import { test } from "@playwright/test";
test("t", async ({ page }) => { await page.goto("http://evil.example/x"); });')" \
  "R49 ...and the network scope still bounds where it goes → DENY" "navigation"

# --- F3: a declared grant must be a grant the kernel can honour -------
for body in \
  'import path from "node:path"; export const x = path.join("a","b");' \
  'import { join } from "node:path"; export const x = join("a");' \
  'import * as path from "node:path"; export const x = path;' \
  'import path from "path"; export const x = path.join("a");' \
  'import { pathToFileURL } from "node:url"; export const u = pathToFileURL("a");' \
  'import { z } from "zod"; export const s = z.string();' ; do
  assert_allow "$H" "$(lib "$body")" "R49 a DECLARED import is honoured → ALLOW"
done
# `Path(` is pathlib's; matching it as a bare suffix refused the ESM
# __dirname idiom for a role granted node:url explicitly.
assert_allow "$H" "$(lib 'import { fileURLToPath } from "node:url";
export const d = fileURLToPath(import.meta.url);')" \
  "R49 the ESM __dirname idiom is not filesystem access → ALLOW"
assert_deny "$H" "$(lib 'from pathlib import Path
p = Path("/etc/passwd")')" \
  "R49 calibration: pathlib Path( still is → DENY" "filesystem access"
assert_deny "$H" "$(lib 'import fs from "node:fs"; export const x = fs.readFileSync("/etc/passwd");')" \
  "R49 calibration: an UNdeclared builtin → DENY" "filesystem access"
assert_deny "$H" "$(lib 'import { execa } from "execa"; export const x = execa;')" \
  "R49 calibration: an undeclared package → DENY" "declared import list"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$R49"
