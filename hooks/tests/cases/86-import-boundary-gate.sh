#!/bin/bash
# achilles-import-boundary-gate.sh — code the orchestrator's playwright run loads stays inside tests/.
H="$HOOK_DIR/achilles-import-boundary-gate.sh"
IB_TMP=$(mktemp -d); CP="$IB_TMP/proj"
mkdir -p "$CP/tests/e2e/fixtures" "$CP/src"
CFG="$CP/playwright.config.ts"
cfg() { payload tool_name=Write file_path="$CFG" content="$1" cwd="$CP"; }
code() { payload tool_name=Write file_path="$CP/$1" content="$2" cwd="$CP"; }

section "import-boundary-gate: the designed configs pass"
assert_allow "$H" "$(cfg "import 'dotenv/config';
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  retries: process.env.CI ? 2 : 0,
  reporter: [
    ['html', { open: 'never' }],
    ['json', { outputFile: 'test-results/results.json' }],
    ['@civitas-cerebrum/achilles/reporter'],
  ],
  use: { baseURL: process.env.BASE_URL ?? 'http://localhost:3000', trace: 'retain-on-failure' },
  projects: [
    { name: 'setup', testMatch: /playwright\.setup\.ts/ },
    { name: 'chromium', use: { ...devices['Desktop Chrome'] }, dependencies: ['setup'] },
  ],
  webServer: { command: 'npm run dev', url: 'http://localhost:3000', reuseExistingServer: !process.env.CI },
});")" "onboarding Phase 1 config (dotenv, runner, package reporters) → ALLOW"
assert_allow "$H" "$(cfg "import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from '@playwright/test';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
export default defineConfig({
  testDir: path.join(__dirname, 'tests/e2e'),
  globalSetup: path.resolve(__dirname, './tests/e2e/global-setup.ts'),
});")" "fileURLToPath form → ALLOW"
assert_allow "$H" "$(cfg "export default defineConfig({ globalSetup: require.resolve('./tests/fixtures/global-setup'), globalTeardown: './tests/setup.ts' });")" \
  "globalSetup via require.resolve, globalTeardown ./tests/setup.ts → ALLOW"
assert_allow "$H" "$(cfg "import { users } from './tests/e2e/fixtures/users'; export default { reporter: [['./tests/e2e/reporter.ts']] };")" \
  "relative import and file reporter under tests/ → ALLOW"

section "import-boundary-gate: config that runs code outside tests/ is denied"
assert_deny "$H" "$(cfg 'import fs from "fs"; export default {};')" "import fs → DENY" 'import "fs"'
assert_deny "$H" "$(cfg 'export default { globalSetup: "./src/index.ts" };')" "globalSetup ./src/index.ts → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { globalSetup: "./tests/../src/index.ts" };')" "globalSetup through tests/.. → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'require("../src/x"); export default {};')" 'require("../src/x") → DENY' 'import "../src/x"'
assert_deny "$H" "$(cfg 'import "./src/app"; export default {};')" "relative import into src/ → DENY" 'import "./src/app"'
assert_deny "$H" "$(cfg 'export default { testDir: "." };')" "testDir . → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { globalSetup: ["./tests/a.ts", "./src/b.ts"] };')" "globalSetup array with an entry in src/ → DENY" '"src/b.ts"'
assert_deny "$H" "$(cfg 'export default { reporter: [["./src/reporter.js"]] };')" "reporter entry ./src/reporter.js → DENY" '"./src/reporter.js"'
assert_deny "$H" "$(cfg 'export default { reporter: "./src/reporter.js" };')" "reporter string ./src/reporter.js → DENY" '"./src/reporter.js"'
assert_deny "$H" "$(cfg 'export default { reporter: process.env.CI ? "dot" : "./src/r.js" };')" "reporter chosen at runtime → DENY" "must be a string literal"
assert_deny "$H" "$(cfg 'const c = {}; c.globalSetup = "./src/x.ts"; export default c;')" "c.globalSetup = ./src/x.ts → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { ["global" + "Setup"]: "./src/x.ts" };')" "computed key → DENY" "computed property key"
assert_deny "$H" "$(cfg 'const c = {}; c["global" + "Setup"] = "./src/x.ts"; export default c;')" "computed member assignment → DENY" "computed member"
assert_deny "$H" "$(cfg 'export default Object.defineProperty({}, "globalSetup", { value: "./src/x.ts" });')" "defineProperty → DENY" "reflective"
assert_deny "$H" "$(cfg 'export default { globalSetup: process.env.X || "./tests/e2e/playwright.setup.ts" };')" \
  "globalSetup steered by .env → DENY" "only string literals and path helpers"
assert_deny "$H" "$(cfg 'export default { globalSetup: "./tests/a.ts"
  ? "./src/b.ts" : "" };')" "ternary continued on the next line → DENY" "only string literals and path helpers"
assert_deny "$H" "$(cfg 'const r = require; r("fs"); export default {};')" "aliased require → DENY" "require used other than"
assert_deny "$H" "$(cfg 'const m = "fs"; import(m); export default {};')" "dynamic import of a non-literal → DENY" "non-literal"
assert_deny "$H" "$(cfg 'const s = "./src/x.ts"; export default { globalSetup: s };')" "globalSetup from a variable → DENY" "only string literals and path helpers"
assert_deny "$H" "$(cfg 'const __dirname = "/"; export default { testDir: path.join(__dirname, "tests") };')" "__dirname redefined → DENY" "__dirname"

section "import-boundary-gate: Edit is screened on the file it produces"
printf '%s' 'import { defineConfig } from "@playwright/test"; export default defineConfig({ retries: 0, workers: 0 });' > "$CFG"
assert_deny "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='retries: 0' new_string='globalSetup: "./src/index.ts"' cwd="$CP")" \
  "Edit adding globalSetup into src/ → DENY" "resolves outside tests/"
assert_allow "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='retries: 0' new_string='retries: 2' cwd="$CP")" "Edit adding retries → ALLOW"
assert_deny "$H" "$("$JQ" -n --arg f "$CFG" --arg cwd "$CP" '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$f, old_string:": 0", new_string:": 0, testDir: \"./src\"", replace_all:true}}')" \
  "Edit with replace_all into src/ → DENY" "resolves outside tests/"

section "import-boundary-gate: test code imports only from tests/"
assert_allow "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "./fixtures/base"; import { expect } from "@playwright/test";')" \
  "spec importing ./fixtures/base → ALLOW"
assert_allow "$H" "$(code tests/e2e/fixtures/x.ts 'import fs from "fs";')" "bare package in tests/ → not this gate's screen"
assert_deny "$H" "$(code tests/e2e/playwright.setup.ts 'import "../../src/index";')" \
  'scaffolder setup importing ../../src/index → DENY' 'import "../../src/index"'
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'import { app } from "../../../src/index";')" \
  'composer fixture importing ../../../src/index → DENY' 'import "../../../src/index"'
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'const m = require("../../../src/db");')" 'fixture require into src/ → DENY' "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/playwright.config.ts 'import cfg from "../../playwright.base";')" \
  "nested config importing past tests/ → DENY (screened as test code)" "resolves outside tests/"

section "import-boundary-gate: scope"
assert_allow "$H" "$(code src/x.ts 'import "../../etc";')" "src/** → not this gate's file"
assert_allow "$H" "$(payload tool_name=Read file_path="$CFG" cwd="$CP")" "Read → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$CFG" content='import fs from "fs";' cwd="$CP" session_id=ib-gate-inactive)" \
  "config, protocol inactive in the session → no decision"
assert_allow "$H" "$(payload tool_name=Write file_path="$CP/tests/e2e/fixtures/x.ts" content='import "../../../src/index";' cwd="$CP" session_id=ib-gate-inactive)" \
  "test code, protocol inactive in the session → no decision"

section "import-boundary-gate: the screen fails closed"
NONODE="$IB_TMP/bin"; mkdir -p "$NONODE"
for d in /usr/bin /bin "$(dirname "$JQ")"; do
  for b in "$d"/*; do
    n=$(basename "$b"); [ "$n" = node ] || [ -e "$NONODE/$n" ] || ln -s "$b" "$NONODE/$n"
  done
done
PATH="$NONODE" assert_deny "$H" "$(cfg 'export default {};')" "node not on PATH → DENY" "config screen could not run"

rm -rf "$IB_TMP"
