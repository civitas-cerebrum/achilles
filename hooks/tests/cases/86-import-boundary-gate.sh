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
BS='\'  # escapes are built at runtime so no tool on the way decodes them

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
assert_allow "$H" "$(cfg "// playwright.config.ts
export default defineConfig({
  globalSetup: require.resolve('./tests/fixtures/global-setup'),
  // ...
});")" "test-optimization.md global-setup form → ALLOW"
assert_allow "$H" "$(cfg "// playwright.contracts.config.ts
import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './tests/contracts',
  retries: 0,                    // contract tests are deterministic — no retries
  reporter: [['list'], ['html', { outputFolder: 'playwright-report-contracts' }]],
});")" "contract-testing config with trailing // comments → ALLOW"
MANY="import { defineConfig, devices } from \"@playwright/test\";
export default defineConfig({
  testDir: \"./tests/e2e\",
  reporter: [[\"html\"], [\"json\", { outputFile: \"test-results/r.json\" }], [\"@civitas-cerebrum/achilles/reporter\"]],
  projects: ["
for i in $(seq 0 39); do MANY="$MANY
    { name: \"p$i\", testDir: \"./tests/e2e/p$i\", use: { baseURL: \"http://localhost:3000\" } },"; done
MANY="$MANY
  ],
});"
assert_allow "$H" "$(cfg "$MANY")" "40-project config → ALLOW"
assert_allow "$H" "$(cfg "import { users } from './tests/e2e/fixtures/users'; export default { reporter: [['./tests/e2e/reporter.ts']] };")" \
  "relative import and file reporter under tests/ → ALLOW"

section "import-boundary-gate: config that runs code outside tests/ is denied"
assert_deny "$H" "$(cfg 'import fs from "fs"; export default {};')" "import fs → DENY" 'import "fs"'
assert_deny "$H" "$(cfg 'export default { globalSetup: "./src/index.ts" };')" "globalSetup ./src/index.ts → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { globalSetup: "./tests/../src/index.ts" };')" "globalSetup through tests/.. → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'require("../src/x"); export default {};')" 'require("../src/x") → DENY' 'import "../src/x"'
assert_deny "$H" "$(cfg 'import "./src/app"; export default {};')" "relative import into src/ → DENY" 'import "./src/app"'
assert_deny "$H" "$(cfg 'export default { testDir: "." };')" "testDir . → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { globalSetup: ["./tests/a.ts", "./src/b.ts"] };')" "globalSetup array with an entry in src/ → DENY" '"./src/b.ts"'
assert_deny "$H" "$(cfg 'export default { reporter: [["./src/reporter.js"]] };')" "reporter entry ./src/reporter.js → DENY" '"./src/reporter.js"'
assert_deny "$H" "$(cfg 'export default { reporter: "./src/reporter.js" };')" "reporter string ./src/reporter.js → DENY" '"./src/reporter.js"'
assert_deny "$H" "$(cfg 'export default { reporter: process.env.CI ? "dot" : "./src/r.js" };')" "reporter chosen at runtime → DENY" "ConditionalExpression"
assert_deny "$H" "$(cfg 'const c = {}; c.globalSetup = "./src/x.ts"; export default c;')" "c.globalSetup = ./src/x.ts → DENY" "assigned outside the config literal"
assert_deny "$H" "$(cfg 'export default { ["global" + "Setup"]: "./src/x.ts" };')" "computed key → DENY" "computed property key"
assert_deny "$H" "$(cfg 'const c = {}; c["global" + "Setup"] = "./src/x.ts"; export default c;')" "computed member assignment → DENY" "computed member"
assert_deny "$H" "$(cfg 'export default Object.defineProperty({}, "globalSetup", { value: "./src/x.ts" });')" "defineProperty → DENY" "defineProperty"
assert_deny "$H" "$(cfg 'const base = JSON.parse("{}"); export default { ...base };')" "JSON.parse spread → DENY" "JSON.parse"
assert_deny "$H" "$(cfg 'import base from "./tests/base"; export default { ...base };')" "spread of an imported object → DENY" "object spread"
assert_deny "$H" "$(cfg 'export default makeConfig();')" "config not readable statically → DENY" "not an object the screen can read"
assert_deny "$H" "$(cfg 'export default { globalSetup: process.env.X || "./tests/e2e/playwright.setup.ts" };')" \
  "globalSetup steered by .env → DENY" "LogicalExpression"
assert_deny "$H" "$(cfg 'export default { globalSetup: "./tests/a.ts"
  ? "./src/b.ts" : "" };')" "ternary continued on the next line → DENY" "ConditionalExpression"
assert_deny "$H" "$(cfg 'const r = require; r("fs"); export default {};')" "aliased require → DENY" "require used other than"
assert_deny "$H" "$(cfg 'const m = "fs"; import(m); export default {};')" "dynamic import of a non-literal → DENY" "not one string literal"
assert_deny "$H" "$(cfg 'const s = "./src/x.ts"; export default { globalSetup: s };')" "globalSetup from a variable → DENY" "Identifier is not a literal"
assert_deny "$H" "$(cfg 'const __dirname = "/"; export default { testDir: path.join(__dirname, "tests") };')" "__dirname redefined → DENY" "__dirname"
assert_deny "$H" "$(cfg 'import { devices } from "./tests/d"; export default { use: { ...devices.x } };')" "devices bound from a tests/ file → DENY" "devices bound by import"
assert_deny "$H" "$(cfg 'process.binding("fs"); export default {};')" "process.binding → DENY" "process.binding"
assert_deny "$H" "$(cfg 'eval("1"); export default {};')" "eval → DENY" "eval"

section "import-boundary-gate: one string literal per specifier (parsed, not pattern-matched)"
assert_deny "$H" "$(cfg "require('./tests/' + '../src/app'); export default {};")" "config require of a concatenation → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "await import('./' + '../../src/app');")" "test import() of a concatenation → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'require(`./${"../../src/app"}`);')" "test require of a template → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'require(`../../src/app`);')" "test require of a template without substitution → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "./.\x2e/../../src/app.js";')" "test specifier with \\x escape → DENY" "contains an escape"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "import \"./${BS}u002e${BS}u002e/../../src/app.js\";")" "test specifier with \\u escape → DENY" "contains an escape"
assert_deny "$H" "$(cfg 'export default { globalSetup: "./tests/.\x2e/src/x.ts" };')" "config path with \\x escape → DENY" "an escape in a path literal"
assert_deny "$H" "$(cfg 'export default { "globalSetu\x70": "./src/x.ts" };')" "config key globalSetu\\x70 (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg "export default { 'test\x44ir': '.' };")" "config key test\\x44ir (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { "reporte\x72": "./src/r.js" };')" "config key reporte\\x72 (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg "export default { glob${BS}u0061lSetup: \"./src/x.ts\" };")" "config key glob\\u0061lSetup (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests/\101" };')" "config octal escape → DENY" "does not parse"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import x from /* c */ "../../src/app";')" "comment between from and source → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import /* c */ "../../src/app";')" "comment between import and source → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { a /* } */ } from "../../src/app";')" "comment with a brace in the clause → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'export * from /**/ "../../src/app";')" "export * with a comment → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "import x from \"../${BS}
../src/app\";")" "line continuation inside a specifier → DENY" "contains an escape"
assert_deny "$H" "$(cfg "import evil from \"./sr${BS}
c/app\"; export default {};")" "line continuation inside a config import → DENY" "contains an escape"
LONG="./$(printf 'x/../%.0s' $(seq 1 300))../../src/app"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "import x from \"$LONG\";")" "1500-character specifier → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg "import evil from \"$LONG\"; export default {};")" "1500-character config import → DENY" "not in the config import allowlist"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "./x" /* */ + "../src";')" "static import followed by an operator → DENY" "does not parse"

section "import-boundary-gate: loaders other than import/require"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "@playwright/test";
module.constructor._load("../../src/app", module);')" "module.constructor._load → DENY" "module.constructor"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'module["require"]("../../src/app");')" 'module["require"] → DENY' "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const k = "require"; module[k]("../../src/app");')" "module[k] computed from code → DENY" "computed from code"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const fs = process.getBuiltinModule("fs"); fs.writeFileSync(__dirname + "/h2", "x");')" "process.getBuiltinModule → DENY" "process.getBuiltinModule"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { createRequire } from "module"; const r = createRequire(import.meta.url); r("../../src/app");')" "createRequire → DENY" "createRequire"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'process.mainModule.require("../../src/app");')" "process.mainModule.require → DENY" "process.mainModule"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'new Function("return 1")();')" "Function constructor → DENY" "Function"
assert_allow "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "./fixtures/base"; const cb: Function = () => {}; test("a", cb);')" "Function as a type annotation → ALLOW"

section "import-boundary-gate: Edit is screened on the file it produces"
printf '%s' 'import { defineConfig } from "@playwright/test"; export default defineConfig({ retries: 0, workers: 0 });' > "$CFG"
assert_deny "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='retries: 0' new_string='globalSetup: "./src/index.ts"' cwd="$CP")" \
  "Edit adding globalSetup into src/ → DENY" "resolves outside tests/"
assert_allow "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='retries: 0' new_string='retries: 2' cwd="$CP")" "Edit adding retries → ALLOW"
assert_deny "$H" "$("$JQ" -n --arg f "$CFG" --arg cwd "$CP" '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$f, old_string:"0 }", new_string:"0, testDir: \"./src\" }", replace_all:true}}')" \
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
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "@playwright/test" test("a")')" "test code that does not parse → DENY" "does not parse"

section "import-boundary-gate: every file under tests/ is screened, and loads only code or JSON"
printf '%s' 'export const a = 1;' > "$CP/tests/e2e/auth.setup.ts"
printf '%s' 'module.exports = 1;' > "$CP/tests/helper.txt"
printf '%s' 'module.exports = 1;' > "$CP/tests/h2"
printf '%s' 'export const d = 1;' > "$CP/tests/e2e/data.txt.ts"
assert_deny "$H" "$(code tests/helper.txt 'require("../src/app.js")')" "tests/helper.txt requiring src → DENY (content screened whatever the extension)" "resolves outside tests/"
assert_deny "$H" "$(code tests/h3 'require("../src/app.js")')" "extensionless tests/h3 requiring src → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/notes.md 'Notes.
require/**/("../src/" + "app");')" "prose that parses into a loader call → DENY" "not one string literal"
assert_deny "$H" "$(code tests/notes.md '// Notes
module["require"]("../src/app");')" "notes hiding module[\"require\"] → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/a.spec.js 'require("../helper.txt");')" "spec requiring an existing .txt → DENY" "not code or JSON"
assert_deny "$H" "$(code tests/e2e/a.spec.js 'require("../notes.md");')" "spec requiring a .md not on disk → DENY" "not code or JSON"
assert_deny "$H" "$(code tests/e2e/a.spec.ts 'import "../h2";')" "spec importing an existing extensionless file → DENY" "not code or JSON"
assert_allow "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "@playwright/test";
import "./data.txt";
test("t", () => {});')" "spec importing ./data.txt while only its data.txt.ts twin exists → ALLOW (the twin is code)"
assert_deny "$H" "$(code tests/e2e/data.txt 'Some notes that are not code')" "data.txt beside a code twin that does not parse → DENY (node loads it in place of the twin)" "does not parse"
assert_deny "$H" "$(code tests/e2e/data.txt 'require("../../src/app")')" "data.txt beside a code twin requiring src → DENY" "resolves outside tests/"
assert_allow "$H" "$(code tests/e2e/a.spec.ts 'import { a } from "./auth.setup"; import data from "./data.json" with { type: "json" };')" \
  "dotted module name with its .ts on disk, JSON import → ALLOW"
assert_allow "$H" "$(code tests/e2e/docs/app-context.md 'Most pages require login. Uploads require a CSV file.')" "prose saying require under tests/ → ALLOW"
assert_allow "$H" "$(code tests/e2e/page-repository.json '{"pages":[{"name":"x","selectors":{"a":"../../src"}}]}')" "page repository JSON → ALLOW (data)"
assert_deny "$H" "$(code tests/e2e/fixtures/package.json '{"main":"../../../src/app.js"}')" "package.json under tests/ pointing into src → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/fixtures/package.json '{"name":"x","main":"../../../src/app.js",}')" "package.json under tests/ with a trailing comma → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/fixtures/tsconfig.json '{"compilerOptions":{"paths":{"@playwright/test":["../../../src/app"]}}}')" \
  "tsconfig paths under tests/ pointing into src → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/tsconfig.json '{
  // tests tsconfig
  "compilerOptions": { "baseUrl": "..", "paths": { "dotenv": ["src/app"] } }
}')" "JSONC tsconfig with a comment → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/tsconfig.json '{ "compilerOptions": { "baseUrl": "..", "paths": { "dotenv": ["src/app"] } }, }')" "tsconfig with a trailing comma → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/tsconfig.json '{ "extends": "../tsconfig.json" }')" "tsconfig extends → DENY" "extends"
assert_deny "$H" "$(code tests/tsconfig.json '{ "references": [ { "path": "../tsconfig.app.json" } ] }')" "tsconfig references → DENY" "references"
assert_deny "$H" "$(code tests/tsconfig.json '{ "compilerOptions": ')" "tsconfig that does not parse → DENY" "does not parse"

section "import-boundary-gate: no # imports, no self-reference, root package.json resolution fixed"
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'import "#app";')" "fixture importing #app → DENY" "package imports"
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'import { app } from "proj/server";')" "fixture importing the project's own package → DENY" "self-reference"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"proj","scripts":{},"imports":{"#app":"./src/app.js"}}' cwd="$CP")" \
  "root package.json adding imports → DENY" "imports changed"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"@playwright/test","scripts":{}}' cwd="$CP")" \
  "root package.json renamed (self-reference as an allowed package) → DENY" "name changed"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"proj",' cwd="$CP")" "root package.json that does not parse → DENY" "does not parse"
assert_allow "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"proj","scripts":{"test:repair":"achilles-self-repair"}}' cwd="$CP")" \
  "root package.json adding a script → ALLOW"
PK="$IB_TMP/pk"; mkdir -p "$PK/tests"; git init -q "$PK"
printf '%s' '{"name":"bookhive-frontend","version":"1.0.0","type":"module","exports":{".":"./src/index.js","./util":"./src/util.js"},"scripts":{"dev":"vite"}}' > "$PK/package.json"
assert_allow "$H" "$(payload tool_name=Write file_path="$PK/package.json" content='{
  "name": "bookhive-frontend",
  "version": "1.0.0",
  "type": "module",
  "exports": { "./util": "./src/util.js", ".": "./src/index.js" },
  "scripts": { "dev": "vite", "test:repair": "achilles-self-repair", "test:e2e": "playwright test" },
  "devDependencies": { "@civitas-cerebrum/element-interactions": "^1.0.0", "@playwright/test": "^1.50.0", "dotenv": "^16.4.5" }
}' cwd="$PK")" "Phase 1 package.json (scripts and devDependencies added, exports reordered) → ALLOW"
BOM="$IB_TMP/bom"; mkdir -p "$BOM/tests"; git init -q "$BOM"
printf '\357\273\277%s' '{"name":"dotenvx","exports":{".":"./src/app.js"}}' > "$BOM/package.json"
assert_deny "$H" "$(payload tool_name=Write file_path="$BOM/tests/x.cjs" content='require("dotenvx")' cwd="$BOM")" \
  "self-reference to a package.json with a BOM → DENY" "self-reference"

section "import-boundary-gate: the root does not move with cwd, a gitfile or case"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$CP/tests/e2e")" \
  "cwd inside tests/e2e (git root) → still DENY" "resolves outside tests/"
NG="$IB_TMP/nogit"; mkdir -p "$NG/tests/e2e"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$H" "$(payload tool_name=Write file_path="$NG/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$NG/tests/e2e")" \
  "no git, cwd inside tests/e2e → root cut above tests/, DENY" "resolves outside tests/"
CLAUDE_PROJECT_DIR="$NG" assert_deny "$H" "$(payload tool_name=Write file_path="$NG/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="/")" \
  "CLAUDE_PROJECT_DIR anchors the root → DENY" "resolves outside tests/"
GP="$IB_TMP/gitp"; mkdir -p "$GP/tests/e2e"; git init -q "$GP"; printf '%s' 'gitdir: ../.git' > "$GP/tests/.git"
assert_deny "$H" "$(payload tool_name=Write file_path="$GP/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$GP")" \
  "a gitfile under tests/ does not move the root → DENY" "resolves outside tests/"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/tests/.git" content='gitdir: ../.git' cwd="$CP")" "writing tests/.git → DENY" ".git file under tests/"
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

section "import-boundary-gate: size, adversarial input, stderr"
BIG=$(head -c 270000 /dev/zero | tr '\0' 'a')
assert_deny "$H" "$(code tests/e2e/big.spec.ts "$BIG")" "content over 256KB → DENY" "too large to screen"
for SHAPE in 'import ' 'import a ' 'import {a' 'require( ' "'abc" 'globalSetup: [' 'reporter: [['; do
  ADV=$(node -e 'process.stdout.write(process.argv[1].repeat(Math.floor(250000 / process.argv[1].length)))' "$SHAPE")
  assert_deny "$H" "$(code tests/e2e/adv.spec.ts "$ADV")" "250KB of '$SHAPE' → DENY (does not parse, in linear time)" "does not parse"
done
WS="import$(head -c 120000 /dev/zero | tr '\0' ' ')x"
assert_deny "$H" "$(cfg "$WS")" "120KB of whitespace inside an import → DENY" "does not parse"
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
