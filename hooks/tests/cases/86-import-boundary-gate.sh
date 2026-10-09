#!/bin/bash
# achilles-import-boundary-gate.sh — code the orchestrator's playwright run loads stays inside tests/.
H="$HOOK_DIR/achilles-import-boundary-gate.sh"
with_tmp_project_into IB_TMP tests/e2e/fixtures src; CP="$IB_TMP/proj"
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
  testDir: './tests/e2e',
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
assert_allow "$H" "$(cfg 'export default { testDir: "./tests/e2e", reporter: [["./tests/e2e/reporter.ts"]] };')" "file reporter under tests/ → ALLOW"
assert_allow "$H" "$(cfg 'import type { PlaywrightTestConfig } from "./tests/types";
const config = { testDir: "./tests/e2e" } satisfies PlaywrightTestConfig;
export default config;')" "import type (elided) and a const with satisfies → ALLOW"
assert_allow "$H" "$(cfg 'const config = { testDir: "./tests/e2e" } as const; export default config as object;')" "as const / as Type wrappers → ALLOW"
assert_allow "$H" "$(cfg 'enum E { A }
@sealed class X { @prop y = 1 }
export default { testDir: "./tests/e2e" };')" "enum and decorators parse → ALLOW"
assert_allow "$H" "$(cfg 'module.exports = { testDir: "./tests/e2e" };')" "module.exports of an object literal → ALLOW"
assert_allow "$H" "$(cfg "import { defineConfig, devices } from '@playwright/test';
import dotenv from 'dotenv';
import path from 'path';
dotenv.config({ path: path.resolve(__dirname, '.env') });
export default defineConfig({
  testDir: './tests',
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [['html', { open: 'never' }], ['list']],
  use: { baseURL: process.env.BASE_URL ?? 'http://localhost:3000', trace: 'on-first-retry' },
  projects: [
    { name: 'setup', testMatch: /.*\\.setup\\.ts/ },
    { name: 'chromium', use: { ...devices['Desktop Chrome'], storageState: 'playwright/.auth/user.json' }, dependencies: ['setup'] },
  ],
  webServer: { command: 'npm run start', url: 'http://localhost:3000', reuseExistingServer: !process.env.CI },
});")" "npm-init-style config (dotenv.config, path.resolve(__dirname), storageState) → ALLOW"
assert_allow "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; import path from "path"; export default defineConfig({ testDir: path.join(import.meta.dirname, "tests/e2e"), globalSetup: path.join(import.meta.dirname, "tests/setup.ts") });')" \
  "import.meta.dirname path helper → ALLOW"
assert_allow "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; export default defineConfig({ testDir: "./tests", projects: [{ name: "a", testDir: "./tests/e2e" }, { name: "b", testMatch: "../src/**/*.ts" }], testMatch: ["../src/**/*.ts", "**/*.spec.ts"] });')" \
  "testMatch globs with .. → ALLOW (Playwright only enumerates files under testDir; verified live)"
assert_allow "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; export default defineConfig({ testDir: "./tests/e2e", reporter: [["src/reporter.js"]] });')" \
  "reporter \"src/reporter.js\" → ALLOW (a bare name goes through node resolution, not the config directory; verified live)"

section "import-boundary-gate: config that runs code outside tests/ is denied"
assert_deny "$H" "$(cfg 'import fs from "fs"; export default { testDir: "./tests" };')" "import fs → DENY" 'import "fs"'
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", globalSetup: "./src/index.ts" };')" "globalSetup ./src/index.ts → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", globalSetup: "./tests/../src/index.ts" };')" "globalSetup through tests/.. → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'require("../src/x"); export default { testDir: "./tests" };')" 'require("../src/x") → DENY' 'import "../src/x"'
assert_deny "$H" "$(cfg 'import "./src/app"; export default { testDir: "./tests" };')" "relative import into src/ → DENY" 'import "./src/app"'
assert_deny "$H" "$(cfg 'export default { testDir: "." };')" "testDir . → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", globalSetup: ["./tests/a.ts", "./src/b.ts"] };')" "globalSetup array with an entry in src/ → DENY" '"./src/b.ts"'
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", reporter: [["./src/reporter.js"]] };')" "reporter entry ./src/reporter.js → DENY" '"./src/reporter.js"'
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", reporter: "./src/reporter.js" };')" "reporter string ./src/reporter.js → DENY" '"./src/reporter.js"'
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", reporter: process.env.CI ? "dot" : "./src/r.js" };')" "reporter chosen at runtime → DENY" "ConditionalExpression"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", tsconfig: "./tsconfig.json" };')" "tsconfig key pointing at the root tsconfig → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'const c = {}; c.globalSetup = "./src/x.ts"; export default c;')" "c.globalSetup = ./src/x.ts → DENY" "assigned outside the config literal"
assert_deny "$H" "$(cfg 'export default { ["global" + "Setup"]: "./src/x.ts" };')" "computed key → DENY" "computed property key"
assert_deny "$H" "$(cfg 'const c = {}; c["global" + "Setup"] = "./src/x.ts"; export default c;')" "computed member assignment → DENY" "computed member"
assert_deny "$H" "$(cfg 'export default Object.defineProperty({}, "globalSetup", { value: "./src/x.ts" });')" "defineProperty → DENY" "Object — the config's keys must be literal properties"
assert_deny "$H" "$(cfg 'const base = JSON.parse("{}"); export default { ...base };')" "JSON.parse spread → DENY" "JSON — the config's keys must be literal properties"
assert_deny "$H" "$(cfg 'export default makeConfig();')" "config not readable statically → DENY" "not an object literal or defineConfig"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", globalSetup: process.env.X || "./tests/e2e/playwright.setup.ts" };')" \
  "globalSetup steered by .env → DENY" "LogicalExpression"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", globalSetup: "./tests/a.ts"
  ? "./src/b.ts" : "" };')" "ternary continued on the next line → DENY" "ConditionalExpression"
assert_deny "$H" "$(cfg 'const r = require; r("fs"); export default { testDir: "./tests" };')" "aliased require → DENY" "require used other than"
assert_deny "$H" "$(cfg 'const m = "fs"; import(m); export default { testDir: "./tests" };')" "dynamic import of a non-literal → DENY" "not one string literal"
assert_deny "$H" "$(cfg 'const s = "./src/x.ts"; export default { testDir: "./tests", globalSetup: s };')" "globalSetup from a variable → DENY" "Identifier is not a literal"
assert_deny "$H" "$(cfg 'const __dirname = "/"; export default { testDir: path.join(__dirname, "tests") };')" "__dirname redefined → DENY" "__dirname"
assert_deny "$H" "$(cfg 'import { devices } from "@playwright/test"; const devices = {}; export default { testDir: "./tests", use: { ...devices.x } };')" "devices redeclared → DENY" "devices redeclared"
assert_deny "$H" "$(cfg 'process.binding("fs"); export default { testDir: "./tests" };')" "process.binding → DENY" ".binding reaches the module loader"
assert_deny "$H" "$(cfg 'eval("1"); export default { testDir: "./tests" };')" "eval → DENY" "eval"

section "import-boundary-gate: config indirection — one literal export, no relative module, a testDir"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; export default defineConfig({ retries: 0 });')" \
  "no testDir (Playwright defaults to the config directory) → DENY" "no top-level testDir"
assert_deny "$H" "$(cfg 'module.exports = { projects: [{ name: "p", testDir: "./src", testMatch: /.*\.spec\.ts$/ }], use: {} };')" \
  "projects[].testDir ./src without a top-level testDir → DENY" "no top-level testDir"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests/e2e", projects: [{ name: "p", testDir: "./src" }] };')" \
  "projects[].testDir ./src under a tests/ top-level testDir → DENY" '"./src" resolves outside tests/'
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; import projects from "./tests/projects"; export default defineConfig({ testDir: "./tests/e2e", projects });')" \
  "projects imported from tests/ (its testDir is unread) → DENY" "projects is not an array of object literals"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; export default defineConfig({ testDir: "./tests/e2e" }); exports.default = require("./tests/cfg");')" \
  "exports.default = require(tests/cfg) after export default → DENY" "exports — the config's keys must be literal properties"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; export default defineConfig({ testDir: "./tests/e2e" }); module.exports.default = require("./tests/cfg");')" \
  "module.exports.default = require(tests/cfg) → DENY" "module.exports — the config writes module.exports once"
assert_deny "$H" "$(cfg 'module.exports = require("./tests/cfg");')" "module.exports = require(tests/cfg) → DENY" "not an object literal or defineConfig"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; const config = defineConfig({ testDir: "./tests/e2e" }); Object.assign(config, require("./tests/cfg")); export default config;')" \
  "Object.assign(config, require(tests/cfg)) → DENY" "config is referenced outside its declaration and export"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; let config = defineConfig({ testDir: "./tests/e2e" }); config = require("./tests/cfg"); export default config;')" \
  "let config reassigned from require → DENY" "config is let, not const"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; const config = defineConfig({ testDir: "./tests/e2e" }); export default config; export const _ = require("./tests/mut")(config);')" \
  "export const _ = require(tests/mut)(config) → DENY" "a named export"
assert_deny "$H" "$(cfg 'const config = { testDir: "./tests/e2e" }; const c2 = config; export default c2;')" "export of an alias of the const → DENY" "not an object literal or defineConfig"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; import "./tests/poll"; export default defineConfig({ testDir: "./tests/e2e" });')" \
  "side-effect import of tests/poll (prototype pollution) → DENY" "the config loads no relative module"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; import base from "./tests/base.config"; export default defineConfig({ ...base, testDir: "./tests/e2e" });')" \
  "spread of an imported object → DENY" "object spread"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; import base from "./tests/base.config"; export default defineConfig(base, { testDir: "./tests/e2e" });')" \
  "defineConfig(importedBase, literal) → DENY" "not an object literal or defineConfig"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; import cfg from "./tests/cfg"; export default defineConfig({ testDir: "./tests/e2e", projects: cfg.projects, use: cfg.use });')" \
  "projects: cfg.projects from an import → DENY" "the config loads no relative module"
assert_deny "$H" "$(cfg 'import { users } from "./tests/e2e/fixtures/users"; export default { testDir: "./tests/e2e" };')" "value import from tests/ → DENY" "the config loads no relative module"
assert_deny "$H" "$(cfg 'const p = require.resolve("./tests/x"); export default { testDir: "./tests/e2e" };')" "require.resolve outside a path value → DENY" "require.resolve(\"./tests/x\") outside"
assert_deny "$H" "$(cfg 'export const config = { testDir: "./tests/e2e" }; export default config;')" "named export beside the default → DENY" "a named export"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests/e2e", projects: [...more] };')" "projects with a spread → DENY" "projects is not an array of object literals"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests/e2e", "__proto__": { globalSetup: "./src/x" } };')" "__proto__ key → DENY" "__proto__"
assert_deny "$H" "$(cfg 'Reflect.set(globalThis, "x", 1); export default { testDir: "./tests/e2e" };')" "Reflect → DENY" "Reflect"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/playwright.config.mjs" content='export default { testDir: "./tests/e2e" };' cwd="$CP")" \
  "playwright.config.mjs → DENY (the methodology mandates .ts)" "the runner config is playwright*.config.ts"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/playwright.config.js" content='module.exports = { testDir: "./tests/e2e" };' cwd="$CP")" \
  "playwright.config.js → DENY" "the runner config is playwright*.config.ts"

section "import-boundary-gate: Node builtins under tests/ come from an allowlist"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import cluster from "node:cluster"; cluster.setupPrimary({ exec: "./src/app.js" }); cluster.fork();')" "node:cluster → DENY" "a Node builtin outside the tests/ allowlist"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { run } from "node:test"; run({ files: ["./src/app.js"] });')" "node:test → DENY" "a Node builtin outside the tests/ allowlist"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { Session } from "node:inspector"; new Session();')" "node:inspector → DENY" "a Node builtin outside the tests/ allowlist"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { spawn } from "child_process";')" "child_process → DENY" "a Node builtin outside the tests/ allowlist"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import net from "net"; import { DatabaseSync } from "node:sqlite";')" "net and node:sqlite → DENY" "a Node builtin outside the tests/ allowlist"
assert_allow "$H" "$(code tests/e2e/fixtures/io.ts 'import fs from "fs"; import { readFile } from "node:fs/promises"; import * as path from "path"; import { fileURLToPath } from "node:url"; import os from "os"; import { randomUUID } from "crypto"; import { promisify } from "node:util"; import { setTimeout as sleep } from "timers/promises"; import http from "http"; import assert from "node:assert/strict"; import type { Socket } from "net";
export const users = JSON.parse(fs.readFileSync(path.join(__dirname, "users.json"), "utf8"));')" \
  "allowlisted builtins (fs, fs/promises, path, url, os, crypto, util, timers/promises, http, assert/strict) and a type-only net import → ALLOW"
assert_allow "$H" "$(code tests/e2e/fixtures/pdf.ts "import { test as base, expect } from '@playwright/test'; import fs from 'fs'; import { PDFDocument } from 'pdf-lib';
export const readPdf = async (p: string) => { const doc = await PDFDocument.load(fs.readFileSync(p)); return doc.getPageCount(); };
export const test = base.extend<{ api: string }>({ api: async ({}, use) => { await use(process.env.API_URL!); } });
export class ApiClient { constructor(private base: string) {} }
export { expect };")" "fixture with fs, pdf-lib PDFDocument.load, a class constructor and a bare package → ALLOW"
assert_allow "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "@playwright/test"; import "app"; test.use({ storageState: "../../src/state.json" }); test("a", async () => { const m = await import("./helper"); });')" \
  "bare non-builtin package (kernel codeImports), storageState path (data, read against cwd), import() under tests/ → ALLOW"

section "import-boundary-gate: Edit is screened on the file it produces"
printf '%s' 'import { defineConfig } from "@playwright/test"; export default defineConfig({ testDir: "./tests/e2e", retries: 0, workers: 0 });' > "$CFG"
assert_deny "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='retries: 0' new_string='globalSetup: "./src/index.ts"' cwd="$CP")" \
  "Edit adding globalSetup into src/ → DENY" "resolves outside tests/"
assert_allow "$H" "$(payload tool_name=Edit file_path="$CFG" old_string='retries: 0' new_string='retries: 2' cwd="$CP")" "Edit adding retries → ALLOW"
assert_deny "$H" "$("$JQ" -n --arg f "$CFG" --arg cwd "$CP" '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$f, old_string:"0 }", new_string:"0, globalSetup: \"./src/x.ts\" }", replace_all:true}}')" \
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
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "../../src/app";')" "tests/ screen deny is labelled as such → DENY" "tests/ screen:"

section "import-boundary-gate: every file under tests/ is screened, and loads only code or JSON"
printf '%s' 'export const a = 1;' > "$CP/tests/e2e/auth.setup.ts"
printf '%s' 'module.exports = 1;' > "$CP/tests/helper.txt"
printf '%s' 'module.exports = 1;' > "$CP/tests/h2"
printf '%s' 'export const d = 1;' > "$CP/tests/e2e/data.txt.ts"
assert_deny "$H" "$(code tests/helper.txt 'require("../src/app.js")')" "tests/helper.txt requiring src → DENY (content screened whatever the extension)" "resolves outside tests/"
assert_deny "$H" "$(code tests/h3 'require("../src/app.js")')" "extensionless tests/h3 requiring src → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/notes.md 'Notes.
require/**/("../src/" + "app");')" "prose that parses into a loader call (Notes.require) → DENY" ".require reaches"
assert_deny "$H" "$(code tests/notes.md '// Notes
module["require"]("../src/app");')" "notes hiding module[\"require\"] → DENY" ".require reaches"
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

section "import-boundary-gate: size and stderr"
BIG=$(head -c 270000 /dev/zero | tr '\0' 'a')
assert_deny "$H" "$(code tests/e2e/big.spec.ts "$BIG")" "content over 256KB → DENY" "too large to screen"
printf '%s' 'process.stderr.write("(node) warning: something\n");' > "$IB_TMP/warn.js"
NODE_OPTIONS="--require $IB_TMP/warn.js" assert_allow "$H" "$(cfg 'export default { testDir: "./tests" };')" "a node warning on stderr does not corrupt the verdict → ALLOW"

section "import-boundary-gate: scope"
assert_allow "$H" "$(code src/x.ts 'import "../../etc";')" "src/** → not this gate's file"
assert_allow "$H" "$(payload tool_name=Read file_path="$CFG" cwd="$CP")" "Read → silent allow"
assert_allow "$H" "$(payload tool_name=Write file_path="$CFG" content='import fs from "fs";' cwd="$CP" session_id=ib-gate-inactive)" \
  "config, protocol inactive in the session → no decision"
assert_allow "$H" "$(payload tool_name=Write file_path="$CP/tests/e2e/fixtures/x.ts" content='import "../../../src/index";' cwd="$CP" session_id=ib-gate-inactive)" \
  "test code, protocol inactive in the session → no decision"

section "import-boundary-gate: the screen fails closed, and runs from an installed copy"
NONODE="$IB_TMP/bin"; mkdir -p "$NONODE"
for d in /usr/bin /bin "$(dirname "$JQ")"; do
  for b in "$d"/*; do
    n=$(basename "$b"); [ "$n" = node ] || [ -e "$NONODE/$n" ] || ln -s "$b" "$NONODE/$n"
  done
done
PATH="$NONODE" assert_deny "$H" "$(cfg 'export default { testDir: "./tests" };')" "node not on PATH → DENY" "import-boundary screen could not run"
# ~/.claude/hooks has no node_modules above it and the project may have none
# either (global or pnpm install): the parser comes from the bundle beside the scanner.
INST="$IB_TMP/installed/hooks"; mkdir -p "$INST/lib"
cp "$H" "$INST/"; cp "$HOOK_DIR/lib/hook-io.sh" "$HOOK_DIR/lib/hook-emit.sh" "$HOOK_DIR/lib/achilles-activation.sh" "$HOOK_DIR/lib/dispatch-prefix.sh" "$HOOK_DIR/lib/import-boundary-scan.js" "$INST/lib/"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$INST/achilles-import-boundary-gate.sh" "$(code tests/e2e/x.spec.ts 'import { test } from "./fixtures/base";')" \
  "installed copy without the parser bundle or node_modules → DENY with one reason line" "@babel/parser not found; reinstall @civitas-cerebrum/achilles"
cp "$HOOK_DIR/lib/babel-parser.bundle.js" "$INST/lib/"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_allow "$INST/achilles-import-boundary-gate.sh" "$(code tests/e2e/x.spec.ts 'import { test } from "./fixtures/base";')" \
  "installed copy with the parser bundle, no node_modules anywhere → ALLOW on a clean spec"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$INST/achilles-import-boundary-gate.sh" "$(code tests/e2e/x.spec.ts 'import "../../src/app";')" \
  "installed copy with the parser bundle → DENY on a spec reaching src/" "resolves outside tests/"

