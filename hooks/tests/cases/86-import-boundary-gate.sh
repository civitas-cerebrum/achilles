#!/bin/bash
# achilles-import-boundary-gate.sh — code the orchestrator's playwright run loads stays inside tests/.
H="$HOOK_DIR/achilles-import-boundary-gate.sh"
IB_TMP=$(mktemp -d); CP="$IB_TMP/proj"
mkdir -p "$CP/tests/e2e/fixtures" "$CP/src"
# The root is $CLAUDE_PROJECT_DIR, else the git toplevel: pin both for the fixture.
unset CLAUDE_PROJECT_DIR
git init -q "$CP"
printf '%s' '{"name":"proj","scripts":{}}' > "$CP/package.json"
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
assert_deny "$H" "$(cfg 'export default { reporter: process.env.CI ? "dot" : "./src/r.js" };')" "reporter chosen at runtime → DENY" "must be a plain string literal"
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

section "import-boundary-gate: a specifier is one plain literal"
BS='\'  # escapes are built at runtime so no tool on the way decodes them
assert_deny "$H" "$(cfg "require('./tests/' + '../src/app'); export default {};")" "config require of a concatenation → DENY" "not a single literal argument"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "await import('./' + '../../src/app');")" "test import() of a concatenation → DENY" "not a single literal argument"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'require(`./${"../../src/app"}`);')" "test require of a template substitution → DENY" "template with a substitution"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "./.\x2e/../../src/app.js";')" "test specifier with \\x escape → DENY" "contains an escape"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "import \"./${BS}u002e${BS}u002e/../../src/app.js\";")" "test specifier with \\u escape → DENY" "contains an escape"
assert_deny "$H" "$(cfg 'export default { globalSetup: "./tests/.\x2e/src/x.ts" };')" "config path with \\x escape → DENY" "escape sequence"
assert_deny "$H" "$(cfg 'export default { "globalSetu\x70": "./src/x.ts" };')" "config key globalSetu\\x70 → DENY" "escape sequence"
assert_deny "$H" "$(cfg "export default { 'test\x44ir': '.' };")" "config key test\\x44ir → DENY" "escape sequence"
assert_deny "$H" "$(cfg 'export default { "reporte\x72": "./src/r.js" };')" "config key reporte\\x72 → DENY" "escape sequence"
assert_deny "$H" "$(cfg "export default { glob${BS}u0061lSetup: \"./src/x.ts\" };")" "config key glob\\u0061lSetup → DENY" "escape sequence"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests/\101" };')" "config octal escape → DENY" "escape sequence"

section "import-boundary-gate: every file under tests/ is screened, and loads only code or JSON"
printf '%s' 'export const a = 1;' > "$CP/tests/e2e/auth.setup.ts"
printf '%s' 'module.exports = 1;' > "$CP/tests/helper.txt"
printf '%s' 'module.exports = 1;' > "$CP/tests/h2"
assert_deny "$H" "$(code tests/helper.txt 'require("../src/app.js")')" "tests/helper.txt requiring src → DENY (content screened whatever the extension)" "resolves outside tests/"
assert_deny "$H" "$(code tests/h3 'require("../src/app.js")')" "extensionless tests/h3 requiring src → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/a.spec.js 'require("../helper.txt");')" "spec requiring an existing .txt → DENY" "not code or JSON"
assert_deny "$H" "$(code tests/e2e/a.spec.js 'require("../notes.md");')" "spec requiring a .md not on disk → DENY" "not code or JSON"
assert_deny "$H" "$(code tests/e2e/a.spec.ts 'import "../h2";')" "spec importing an existing extensionless file → DENY" "not code or JSON"
assert_allow "$H" "$(code tests/e2e/a.spec.ts 'import { a } from "./auth.setup"; import data from "./data.json" with { type: "json" };')" \
  "dotted module name with its .ts on disk, JSON import → ALLOW"
assert_allow "$H" "$(code tests/e2e/docs/app-context.md 'Most pages require login. Uploads require a CSV file.')" "prose saying require under tests/ → ALLOW"
assert_allow "$H" "$(code tests/e2e/page-repository.json '{"pages":[{"name":"x","selectors":{"a":"../../src"}}]}')" "page repository JSON → ALLOW (data)"
assert_deny "$H" "$(code tests/e2e/fixtures/package.json '{"main":"../../../src/app.js"}')" "package.json under tests/ pointing into src → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/fixtures/tsconfig.json '{"compilerOptions":{"paths":{"@playwright/test":["../../../src/app"]}}}')" \
  "tsconfig paths under tests/ pointing into src → DENY" "resolves outside tests/"

section "import-boundary-gate: no # imports, no self-reference, root package.json resolution fixed"
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'import "#app";')" "fixture importing #app → DENY" "package imports"
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'import { app } from "proj/server";')" "fixture importing the project's own package → DENY" "self-reference"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"proj","scripts":{},"imports":{"#app":"./src/app.js"}}' cwd="$CP")" \
  "root package.json adding imports → DENY" "imports changed"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"@playwright/test","scripts":{}}' cwd="$CP")" \
  "root package.json renamed (self-reference as an allowed package) → DENY" "name changed"
assert_allow "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"proj","scripts":{"test:repair":"achilles-self-repair"}}' cwd="$CP")" \
  "root package.json adding a script → ALLOW"

section "import-boundary-gate: the root does not move with cwd or case"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$CP/tests/e2e")" \
  "cwd inside tests/e2e (git root) → still DENY" "resolves outside tests/"
NG="$IB_TMP/nogit"; mkdir -p "$NG/tests/e2e"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$H" "$(payload tool_name=Write file_path="$NG/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$NG/tests/e2e")" \
  "no git, cwd inside tests/e2e → root cut above tests/, DENY" "resolves outside tests/"
CLAUDE_PROJECT_DIR="$NG" assert_deny "$H" "$(payload tool_name=Write file_path="$NG/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="/")" \
  "CLAUDE_PROJECT_DIR anchors the root → DENY" "resolves outside tests/"
if [ "$(uname)" = Darwin ]; then
  assert_deny "$H" "$(payload tool_name=Write file_path="$CP/Tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$CP")" \
    "Tests/e2e on a case-insensitive filesystem → DENY" "resolves outside tests/"
  assert_deny "$H" "$(payload tool_name=Write file_path="$CP/Playwright.config.ts" content='import fs from "fs";' cwd="$CP")" \
    "Playwright.config.ts on a case-insensitive filesystem → DENY" 'import "fs"'
else
  assert_allow "$H" "$(payload tool_name=Write file_path="$CP/Tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$CP")" \
    "Tests/ is another directory on a case-sensitive filesystem → not this gate's file"
  assert_allow "$H" "$(payload tool_name=Write file_path="$CP/Playwright.config.ts" content='import fs from "fs";' cwd="$CP")" \
    "Playwright.config.ts is not the runner's config on a case-sensitive filesystem → not this gate's file"
fi

section "import-boundary-gate: size and stderr"
BIG=$(head -c 270000 /dev/zero | tr '\0' 'a')
assert_deny "$H" "$(code tests/e2e/big.spec.ts "$BIG")" "content over 256KB → DENY" "too large to screen"
printf '%s' 'process.stderr.write("(node) warning: something\n");' > "$IB_TMP/warn.js"
NODE_OPTIONS="--require $IB_TMP/warn.js" assert_allow "$H" "$(cfg 'export default {};')" "a node warning on stderr does not corrupt the verdict → ALLOW"

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
