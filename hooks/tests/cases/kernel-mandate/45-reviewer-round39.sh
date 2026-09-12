#!/bin/bash
# 45-reviewer-round39.sh — regressions for round 39 of independent
# adversarial review.
#
# Round 38's lesson was that ONE call — `page.goto` — had two channels
# and only one was modelled. Round 39 found that shape one level up,
# across a whole FAMILY, and on the worse direction.
#
# The screen resolved the READ direction of framework file APIs
# (`setInputFiles`, `attach({path})`) against `read.allow`, carefully,
# over four rounds. It modelled the WRITE direction of none of them:
#
#     await page.screenshot({ path: '/tmp/o.png' })              ALLOW
#     await context.storageState({ path: '/tmp/o.json' })        ALLOW
#     await download.saveAs('docs/e2e-ledger.json')              ALLOW
#     await page.screenshot({ path: '.claude/kernel-mandate.json' }) ALLOW
#
# every one of which the same role's Write tool refuses. The reviewer
# authored a spec inside `tests/e2e/**`, ran it with the composer's own
# granted `npx playwright test`, and put its exact chosen bytes at an
# arbitrary path — an in-page Blob download plus `saveAs`. Arbitrary
# content to an arbitrary path, from a role whose only write grant is a
# test directory.
#
# The write direction is strictly the worse one, which is what makes
# this the sharpest finding of the family. A read leaks. A write to
# `docs/e2e-ledger.json` forges the verdict this whole system exists to
# make trustworthy, and a write to the manifest or the hook registration
# disarms the kernel — the two things round 22's self-protection axis
# promises no role may touch "whatever its other grants".
#
# INVERTED rather than enumerated. `screenshot`, `pdf`, `saveAs`,
# `storageState`, `recordHar`, `recordVideo`, `toMatchSnapshot` and
# whatever ships next have no end. A `path:` option in an authored call
# is a WRITE unless the method is a known READER, and that reader list
# is short, closed, and was already written.
#
# The reviewer's closing argument is recorded rather than answered, and
# `validate` now carries it: a role that authors specs and runs them has
# unbounded write reach in principle, this screen is text over authored
# code rather than a filesystem boundary, and the real answer is
# splitting the authoring role from the running one.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate reviewer round-39 regressions"

R39=$(mktemp -d)
P="$R39/proj"
mkdir -p "$P/.claude" "$P/tests/e2e/data" "$P/docs"
printf 'x\n' > "$P/tests/e2e/data/cv.pdf"
export KERNEL_MANDATE_STATE_DIR="$R39/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"
mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "r39",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": { "t": ["^npx playwright test\\b"] },
  "roles": {
    "composer": {
      "description": "Authors specs in tests/e2e and runs them.",
      "tools": { "allow": ["Bash", "Write", "Edit"] },
      "bash": { "groups": ["t"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"], "codeImports": ["@playwright/test"] }
    },
    "readonly": {
      "description": "Authors code but has no write grants at all.",
      "tools": { "allow": ["Write"] },
      "read": { "allow": ["tests/**"] },
      "write": { "codeImports": ["@playwright/test"] }
    }
  }
}
JSON
for r in composer readonly; do printf '%s\n' "$r" > "$KERNEL_MANDATE_STATE_DIR/agents/$r"; done

wp() { "$JQ" -nc --arg c "$1" --arg a "${2:-composer}" \
  '{tool_name:"Write",tool_input:{file_path:"'"$P"'/tests/e2e/x.spec.ts",content:$c},cwd:"'"$P"'",agent_id:$a}'; }
spec() { printf 'import { test } from "@playwright/test";\ntest("t", async ({ page, context }) => {\n  %s\n});\n' "$1"; }

# --- Every output path in the family, aimed outside the write scope ----
for body in \
  'await page.screenshot({ path: "/tmp/hos-pwn.png" });|a screenshot to an absolute path' \
  'await page.screenshot({ path: "../../outside.png" });|and to a relative one that climbs out' \
  'await page.pdf({ path: "/tmp/o.pdf" });|a pdf' \
  'await context.storageState({ path: "/tmp/s.json" });|storage state, which carries session cookies' \
  'await page.locator("x").screenshot({ path: "/tmp/e.png" });|an element screenshot' \
  'const d = await page.waitForEvent("download"); await d.saveAs("/tmp/c.txt");|saveAs, the arbitrary-CONTENT primitive' ; do
  b="${body%%|*}"; label="${body##*|}"
  assert_deny "$H" "$(wp "$(spec "$b")")" "R39 $label → DENY" "write scope"
done

# --- The root of trust, on this channel too ---------------------------
# These are the ones that matter: the manifest disarms the kernel and the
# ledger forges the verdict.
assert_deny "$H" "$(wp "$(spec 'await page.screenshot({ path: "../../.claude/kernel-mandate.json" });')")" \
  "R39 aimed at the manifest → DENY" "the kernel mandate itself"
assert_deny "$H" "$(wp "$(spec 'await page.screenshot({ path: "../../.claude/settings.json" });')")" \
  "R39 aimed at the hook registration → DENY" "the kernel mandate itself"
assert_deny "$H" "$(wp "$(spec 'const d = await page.waitForEvent("download"); await d.saveAs("../../docs/e2e-ledger.json");')")" \
  "R39 aimed at the judge's ledger → DENY" "write scope"

# A path that does not exist until the test runs cannot be scoped —
# round 20's inversion, on the write side of the same family.
assert_deny "$H" "$(wp "$(spec 'await page.screenshot({ path: out });')")" \
  "R39 an output path built at run time → DENY" "built at run time"
assert_deny "$H" "$(wp "$(spec 'await page.screenshot({ path: "/tmp/" + name + ".png" });')")" \
  "R39 ...and one assembled by concatenation → DENY" "built at run time"

# --- Calibration: producing artifacts IS the job ----------------------
# The rule is about where the file lands, not about the API.
#
# REBASED BY ROUND 47, and the change is not cosmetic. These cases were
# written when the screen resolved a framework path against the SPEC
# FILE'S directory, so `screenshot({ path: "shot.png" })` from a spec in
# tests/e2e/ read as a write to tests/e2e/shot.png. Playwright resolves
# it against `process.cwd()`, so it is a write to the PROJECT ROOT —
# genuinely outside a `tests/e2e/**` write scope, and now refused. The
# old base was not being generous here; it was concealing where the file
# lands. The artifacts a composer legitimately produces are named the
# way the runtime names them.
assert_allow "$H" "$(wp "$(spec 'await page.screenshot({ path: "tests/e2e/shot.png" });')")" \
  "R39 calibration: a screenshot inside the write scope → ALLOW"
assert_allow "$H" "$(wp "$(spec 'await page.screenshot({ path: "tests/e2e/artifacts/shot.png" });')")" \
  "R39 calibration: ...in a subdirectory of it → ALLOW"
assert_deny "$H" "$(wp "$(spec 'await page.screenshot({ path: "shot.png" });')")" \
  "R39 ...and a bare name lands in the PROJECT ROOT, which is not the write scope → DENY" "write scope"
assert_allow "$H" "$(wp "$(spec 'await page.screenshot({ fullPage: true });')")" \
  "R39 calibration: a screenshot with no path writes nothing → ALLOW"
assert_allow "$H" "$(wp "$(spec 'await test.info().attach("cv", { path: "tests/data/cv.pdf" });')")" \
  "R39 calibration: attach names a READ, and is still read-checked → ALLOW"
assert_deny "$H" "$(wp "$(spec 'await page.locator("#f").setInputFiles("../../.env");')")" \
  "R39 calibration: the read direction still holds → DENY" "read scope"

# --- A role with no write grants at all -------------------------------
assert_deny "$H" "$(wp "$(spec 'await page.screenshot({ path: "shot.png" });')" readonly)" \
  "R39 a role with no write grants may not produce files either → DENY" "no write grants at all"
