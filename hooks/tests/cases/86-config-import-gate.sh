#!/bin/bash
# achilles-config-import-gate.sh — the root runner config runs nothing outside tests/.
H="$HOOK_DIR/achilles-config-import-gate.sh"
CI_TMP=$(mktemp -d); CP="$CI_TMP/proj"
mkdir -p "$CP/tests/e2e" "$CP/src"
CFG="$CP/playwright.config.ts"
cfg() { payload tool_name=Write file_path="$CFG" content="$1" cwd="$CP"; }

section "config-import-gate: the designed config passes"
assert_allow "$H" "$(cfg 'import "dotenv/config";
import { defineConfig, devices } from "@playwright/test";
export default defineConfig({ testDir: "./tests/e2e", reporter: [["@civitas-cerebrum/achilles/reporter"]], projects: [{ use: devices["Desktop Chrome"] }] });')" \
  "dotenv/config + @playwright/test + reporter by string → ALLOW"
assert_allow "$H" "$(cfg 'import dotenv from "dotenv"; import path from "node:path"; dotenv.config();
export default { globalSetup: "./tests/setup.ts", globalTeardown: require.resolve("./tests/e2e/teardown.ts"), testDir: path.join(__dirname, "tests", "e2e") };')" \
  "globalSetup ./tests/setup.ts, require.resolve and path.join under tests/ → ALLOW"
assert_allow "$H" "$(cfg 'import { users } from "./tests/e2e/fixtures/users"; export default {};')" "relative import under tests/ → ALLOW"

section "config-import-gate: config that runs code outside tests/ is denied"
assert_deny "$H" "$(cfg 'import fs from "fs"; export default {};')" "import fs → DENY" 'import "fs"'
assert_deny "$H" "$(cfg 'export default { globalSetup: "./src/index.ts" };')" "globalSetup ./src/index.ts → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'require("../src/x"); export default {};')" 'require("../src/x") → DENY' 'import "../src/x"'
assert_deny "$H" "$(cfg 'import "./src/app"; export default {};')" "relative import into src/ → DENY" 'import "./src/app"'
assert_deny "$H" "$(cfg 'export default { testDir: "." };')" "testDir . → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { globalSetup: ["./tests/a.ts", "./src/b.ts"] };')" "globalSetup array with one entry in src/ → DENY" '"./src/b.ts"'
assert_deny "$H" "$(cfg 'const r = require; r("fs"); export default {};')" "aliased require → DENY" "require used other than"
assert_deny "$H" "$(cfg 'const m = "fs"; import(m); export default {};')" "dynamic import of a non-literal → DENY" "non-literal"
assert_deny "$H" "$(cfg 'const s = process.env.SETUP; export default { globalSetup: s };')" "globalSetup from a variable → DENY" "not a string literal"

section "config-import-gate: Edit is screened on the file it produces"
printf '%s' 'import { defineConfig } from "@playwright/test"; export default defineConfig({});' > "$CFG"
assert_deny "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='defineConfig({})' new_string='defineConfig({ globalSetup: "./src/index.ts" })' cwd="$CP")" \
  "Edit adding globalSetup into src/ → DENY" "resolves outside tests/"
assert_allow "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='defineConfig({})' new_string='defineConfig({ retries: 2 })' cwd="$CP")" \
  "Edit adding retries → ALLOW"

section "config-import-gate: scope"
assert_allow "$H" "$(payload tool_name=Write file_path="$CP/tests/e2e/fixtures/x.ts" content='import fs from "fs";' cwd="$CP")" "a fixture → not this gate's file"
assert_allow "$H" "$(payload tool_name=Write file_path="$CP/tests/e2e/playwright.config.ts" content='import fs from "fs";' cwd="$CP")" "a nested config → not the root config"
assert_allow "$H" "$(payload tool_name=Read file_path="$CFG" cwd="$CP")" "Read → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$CFG" content='import fs from "fs";' cwd="$CP" session_id=cfg-gate-inactive)" \
  "protocol inactive in the session → no decision"

rm -rf "$CI_TMP"
