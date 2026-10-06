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

section "import-boundary-gate: the environment, the module wrapper and URL specifiers"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; process.env.NODE_OPTIONS = "--require ./src/app.js"; export default defineConfig({ testDir: "./tests/e2e" });')" \
  "config sets process.env.NODE_OPTIONS (every worker loads src/) → DENY" "process state is written"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; process.env.NODE_PATH = "/x/src"; export default defineConfig({ testDir: "./tests/e2e" });')" \
  "config sets process.env.NODE_PATH → DENY" "process state is written"
assert_deny "$H" "$(code tests/gsenv.ts 'export default async () => { process.env.NODE_OPTIONS = "--require ./src/app.js"; };')" "globalSetup under tests/ sets NODE_OPTIONS → DENY" "process state is written"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'process.env["NODE_OPTIONS"] += " --require ./src/app.js";')" "process.env[k] += … → DENY" "process state is written"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'delete process.env.CI;')" "delete process.env.X → DENY" "process state is written"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'Object.assign(process.env, { NODE_OPTIONS: "--require ./src/app.js" });')" "Object.assign(process.env, …) → DENY" "process.env used as a value"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const e = process.env; e.NODE_OPTIONS = "--require ./src/app.js";')" "process.env bound to a name → DENY" "process.env used as a value"
assert_allow "$H" "$(code tests/e2e/fixtures/env.ts 'const { BASE_URL, API_KEY } = process.env; export { BASE_URL, API_KEY }; export const u = process.env.USER_EMAIL!; export const k = (name: string) => process.env[name]; export const all = { ...process.env }; for (const n in process.env) {}')" \
  "process.env reads (destructuring, member, computed, spread, for-in) → ALLOW"
assert_allow "$H" "$(code tests/e2e/fixtures/dotenv.ts "import 'dotenv/config'; require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); export const u = process.env.USER_EMAIL!;")" \
  "fixture loading .env through dotenv → ALLOW (the designed flow)"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "@playwright/test"; const r = arguments[1]; r("../../src/app.js"); test("a", async () => {});')" \
  "arguments[1] is the CJS wrapper's require → DENY" "arguments"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; arguments[1]("./src/app.js"); export default defineConfig({ testDir: "./tests/e2e" });')" "arguments in the config → DENY" "arguments"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'function f() { return arguments[0]; }')" "arguments inside a function → DENY (denied everywhere; rare in test code)" "arguments"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'await import("file:///p/src/app.js");')" "import() of a file: URL → DENY" "is a URL"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "file:///p/src/app.js";')" "static import of a file: URL → DENY" "is a URL"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "await import('data:text/javascript,import \"file:///p/src/app.js\";');")" "import() of a data: URL → DENY" "is a URL"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "http://localhost:3000/src/app.js";')" "http: specifier → DENY" "is a URL"
assert_allow "$H" "$(code tests/perf/scenarios/smoke.js 'import http from "k6/http"; import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js"; export default function () { http.get("http://localhost:3000"); }')" \
  "k6 scenario with a jslib https: import → ALLOW (Node loads no https: specifier; k6 does)"
assert_deny "$H" "$(cfg 'import "file:///p/src/app.js"; export default { testDir: "./tests" };')" "config import of a file: URL → DENY" "is a URL"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'process.execve(process.execPath, [process.execPath, "./src/app.js"]);')" "process.execve → DENY" ".execve reaches"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; [process.env.NODE_OPTIONS] = ["--require ./src/app.js"]; export default defineConfig({ testDir: "./tests/e2e" });')" "array-pattern write to process.env → DENY" "process state is written"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; ({ o: process.env.NODE_OPTIONS } = { o: "--require ./src/app.js" }); export default defineConfig({ testDir: "./tests/e2e" });')" "object-pattern write to process.env → DENY" "process state is written"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; for (process.env.NODE_OPTIONS of ["--require ./src/app.js"]); export default defineConfig({ testDir: "./tests/e2e" });')" "for-of target process.env → DENY" "process state is written"
assert_deny "$H" "$(code tests/gs/gsds.ts 'export default async function globalSetup() { [process.env.NODE_OPTIONS] = ["--require ./src/app.js"]; }')" "globalSetup array-pattern write → DENY" "process state is written"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'let o; ({ a: [, process.env.X = "1"], ...o } = { a: [0, 1] });')" "nested pattern with default and rest writing process.env → DENY" "process state is written"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'for (process.env.X in { a: 1 }) {}')" "for-in target process.env → DENY" "process state is written"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; process.execArgv.push("--require=./src/app.js"); export default defineConfig({ testDir: "./tests/e2e" });')" "process.execArgv.push in the config → DENY" ".execArgv reaches"
assert_deny "$H" "$(code tests/gs/gsexec.ts 'export default async function () { process.execArgv.push("--require=./src/app.js"); }')" "process.execArgv.push in a globalSetup → DENY" ".execArgv reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'export const n = process.execArgv.length;')" "process.execArgv read → DENY (any reference)" ".execArgv reaches"
assert_deny "$H" "$(code tests/gs/gsexecpath.ts 'import fs from "fs"; import path from "path"; export default async function () { const sh = path.join(__dirname, "n.sh"); fs.writeFileSync(sh, "#!/bin/sh\nexec node --require ./src/app.js \"\$@\"\n", { mode: 0o755 }); process.execPath = sh; }')" \
  "process.execPath = wrapper script → DENY" "process state is written"
assert_deny "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; process.loadEnvFile("./tests/x.env"); export default defineConfig({ testDir: "./tests/e2e" });')" "process.loadEnvFile → DENY" ".loadEnvFile reaches"
assert_allow "$H" "$(cfg 'import { defineConfig } from "@playwright/test"; process.env.NODE_OPTIONS?.length; process.execPath.length; export default defineConfig({ testDir: "./tests/e2e" });')" "process.env / process.execPath reads → ALLOW"
assert_deny "$H" "$(code tests/e2e/caller.js 'function f() { return f.caller; } const w = f(); w.arguments[1]("../../src/app.js");')" "f.caller / .arguments on any object → DENY" ".caller reaches"
assert_deny "$H" "$(code tests/e2e/pst.js 'Error.prepareStackTrace = (e, s) => s; const fn = new Error().stack[0].getFunction(); fn.arguments[1]("../../src/app.js");')" "stack-trace function .arguments → DENY" ".arguments reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'Object.keys(require.cache);')" "require.cache → DENY" "require used other than"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const k = "dl" + "open"; (process as any)[k]; process["dl"+"open"];')" "process[computed] → DENY" "computed from code"

section "import-boundary-gate: bare specifiers never climb out of node_modules"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import * as x from "https://../../src/app.js";')" 'import "https://../../src/app.js" → DENY' "is a URL"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import * as y from "zz/../../src/app.js";')" 'import "zz/../../src/app.js" → DENY' "a bare specifier with a dot segment"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const x = require("lodash/../../src/app.js");')" 'require("lodash/../../src/app.js") → DENY' "a bare specifier with a dot segment"
assert_deny "$H" "$(code tests/e2e/e1.spec.mjs 'import { test } from "@playwright/test"; import y from "ajv/%2e%2e/%2e%2e/src/app.js";')" "static import of ajv/%2e%2e/%2e%2e/src → DENY" "percent-encoding in a module specifier"
assert_deny "$H" "$(code tests/e2e/e2.spec.ts 'test("t", async () => { const y = await import("ajv/%2e%2e/%2e%2e/src/app.js"); });')" "import() of ajv/%2e%2e/%2e%2e/src → DENY" "percent-encoding in a module specifier"
assert_deny "$H" "$(code tests/e2e/e3.spec.ts 'test("t", async () => { const y = await import("./%2e%2e/%2e%2e/src/app.js"); });')" "import() of ./%2e%2e/%2e%2e/src → DENY" "percent-encoding in a module specifier"
assert_deny "$H" "$(code tests/e2e/e4.spec.ts 'test("t", async () => { const y = await import("ajv/.%2E/%2e./src/app.js"); });')" "import() with mixed-case .%2E/%2e. → DENY" "percent-encoding in a module specifier"
assert_deny "$H" "$(cfg 'import x from "dotenv/%2e%2e/src/app"; export default { testDir: "./tests" };')" "config import with percent-encoding → DENY" "percent-encoding in a module specifier"
assert_deny "$H" "$(code tests/perf/scenarios/x.js 'import { textSummary } from "https://jslib.k6.io/../../../src/app.js";')" "https: with dot segments under tests/perf → DENY" "a bare specifier with a dot segment"
assert_deny "$H" "$(cfg 'import x from "zz/../src/app"; export default { testDir: "./tests" };')" "config bare import with a dot segment → DENY" "a bare specifier with a dot segment"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";')" "https: import outside tests/perf → DENY" "is a URL"
assert_allow "$H" "$(code tests/perf/x.js 'import http from "k6/http"; import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js"; export default function () { http.get("http://localhost:3000"); }')" \
  "k6 file directly under tests/perf with a jslib https: import → ALLOW"
assert_allow "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "@playwright/test"; import lodash from "lodash/fp"; import { a } from "@scope/pkg/sub/v1.0.0/index.js"; import fs from "fs";
test("t", async () => { fs.writeFileSync(__dirname + "/gen.js", "1"); await import("./gen.js"); });')" \
  "bare subpaths with dots inside segments, and a runtime fs write (KL-03: not seen) → ALLOW"

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

section "import-boundary-gate: one string literal per specifier (parsed, not pattern-matched)"
assert_deny "$H" "$(cfg "require('./tests/' + '../src/app'); export default { testDir: './tests' };")" "config require of a concatenation → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "await import('./' + '../../src/app');")" "test import() of a concatenation → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'require(`./${"../../src/app"}`);')" "test require of a template → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'require(`../../src/app`);')" "test require of a template without substitution → DENY" "not one string literal"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "./.\x2e/../../src/app.js";')" "test specifier with \\x escape → DENY" "contains an escape"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "import \"./${BS}u002e${BS}u002e/../../src/app.js\";")" "test specifier with \\u escape → DENY" "contains an escape"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", globalSetup: "./tests/.\x2e/src/x.ts" };')" "config path with \\x escape → DENY" "an escape in a path literal"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", "globalSetu\x70": "./src/x.ts" };')" "config key globalSetu\\x70 (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg "export default { 'test\x44ir': '.' };")" "config key test\\x44ir (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests", "reporte\x72": "./src/r.js" };')" "config key reporte\\x72 (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg "export default { testDir: './tests', glob${BS}u0061lSetup: \"./src/x.ts\" };")" "config key glob\\u0061lSetup (decoded) → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg 'export default { testDir: "./tests/\101" };')" "config octal escape → DENY" "does not parse"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import x from /* c */ "../../src/app";')" "comment between from and source → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import /* c */ "../../src/app";')" "comment between import and source → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { a /* } */ } from "../../src/app";')" "comment with a brace in the clause → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'export * from /**/ "../../src/app";')" "export * with a comment → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "import x from \"../${BS}
../src/app\";")" "line continuation inside a specifier → DENY" "contains an escape"
assert_deny "$H" "$(cfg "import evil from \"./sr${BS}
c/app\"; export default { testDir: './tests' };")" "line continuation inside a config import → DENY" "contains an escape"
LONG="./$(printf 'x/../%.0s' $(seq 1 300))../../src/app"
assert_deny "$H" "$(code tests/e2e/x.spec.ts "import x from \"$LONG\";")" "1500-character specifier → DENY" "resolves outside tests/"
assert_deny "$H" "$(cfg "import evil from \"$LONG\"; export default { testDir: './tests' };")" "1500-character config import → DENY" "the config loads no relative module"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import "./x" /* */ + "../src";')" "static import followed by an operator → DENY" "does not parse"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import x = require("../../src/app");')" "import = require into src/ → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'export import y = require("../../src/app");')" "export import = require into src/ → DENY" "resolves outside tests/"
assert_deny "$H" "$(code tests/e2e/x.mjs 'await import(import.meta.resolve("../../src/app.js"));')" "import() of import.meta.resolve → DENY" "not one string literal"

section "import-boundary-gate: loader aliases under tests/"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "@playwright/test";
module.constructor._load("../../src/app", module);')" "module.constructor._load → DENY" ".constructor reaches the module loader"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'module["require"]("../../src/app");')" 'module["require"] → DENY' ".require reaches the module loader"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const k = "require"; module[k]("../../src/app");')" "module[k] computed from code → DENY" "computed from code"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const fs = process.getBuiltinModule("fs"); fs.writeFileSync(__dirname + "/h2", "x");')" "process.getBuiltinModule → DENY" ".getBuiltinModule reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { createRequire } from "module"; const r = createRequire(import.meta.url); r("../../src/app");')" "createRequire → DENY" "createRequire"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'process.mainModule.require("../../src/app");')" "process.mainModule.require → DENY" ".mainModule reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'new Function("return 1")();')" "Function constructor → DENY" "Function"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const { constructor: F } = function(){}; F("return process")();')" "{ constructor: F } destructured from a function → DENY" "{ constructor } destructured"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const F = (function(){}).constructor; F("return process")();')" ".constructor of a function → DENY" ".constructor reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const F = Object.getPrototypeOf(async function(){}).constructor; F("return 1")();')" ".constructor via getPrototypeOf → DENY" ".constructor reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'globalThis.process.mainModule.require("../../src/app");')" "globalThis.process.mainModule → DENY" ".mainModule reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const r = globalThis["require"]; r("../../src/app");')" 'globalThis["require"] → DENY' ".require reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const p = globalThis.process; p.binding("fs");')" "globalThis.process bound to a name → DENY" "globalThis.process — the global reached through another name"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const p = global.process; p.env;')" "global.process → DENY" "global.process — the global reached through another name"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const m = require.main; m.require("../../src/app");')" "require.main → DENY" "require used other than"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const M = require("module"); const m = new M("x"); m.load(require("path").resolve("src/app.js"));')" "require(\"module\") → DENY" 'import "module" — a Node builtin outside the tests/ allowlist'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const vm = require("vm"); vm.runInThisContext("1");')" "require(\"vm\") → DENY" 'import "vm"'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'require("child_process").execSync("node src/app.js");')" "require(\"child_process\") → DENY" 'import "child_process"'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const w = require("worker_threads"); new w.Worker("./src/app.js");')" "require(\"worker_threads\") → DENY" 'import "worker_threads"'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import * as M from "node:module"; const L = M.Module; L["_l" + "oad"]("../../src/app");')" "import node:module → DENY" 'import "node:module"'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import { Module } from "module"; Module._load("../../src/app");')" "Module._load → DENY" 'import "module"'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'import p from "node:process"; p.binding("fs");')" "import node:process → DENY" 'import "node:process"'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const r = module.require.bind(module);')" "module.require read without a call → DENY" ".require reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'process["mainModule"];')" 'process["mainModule"] → DENY' ".mainModule reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const k = "mainModule"; process[k].require("../../src/app");')" "process[k] computed from code → DENY" "computed from code"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const { mainModule } = process; mainModule.require("../../src/app");')" "{ mainModule } = process → DENY" "process used as a value"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const { require: r } = module; r("../../src/app");')" "{ require: r } = module → DENY" "module used as a value"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const { require: r } = module; r.call(module, "../../src/app");')" "r.call(module, …) → DENY" "module used as a value"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'function f(p) { return p.binding("fs"); } f(process);')" "process passed as an argument → DENY" "process used as a value"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const m = { require: (x) => x }; m.require("../../src/app");')" ".require(…) on any object → DENY" ".require reaches"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const k = "constructor"; const F = (() => 1)[k];')" '"constructor" as a bare string → DENY' '"constructor" names a loader member'
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const F = (() => 1)["construct" + "or"];')" "computed key assembled from strings → DENY" "a computed member key assembled from strings"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const o = "or"; const F = (() => 1)[`construct${o}`];')" "computed key from a template with an expression → DENY" "a computed member key assembled from strings"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const F = Reflect.get(function(){}, "constructor");')" "Reflect in a spec → DENY" "Reflect"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'globalThis.eval("1");')" "globalThis.eval → DENY" "globalThis.eval — the global reached through another name"
assert_deny "$H" "$(code tests/e2e/x.spec.ts 'const M = require("module"); const m = new M("x"); m._compile("process.binding", "x");')" "_compile → DENY" 'import "module"'
assert_allow "$H" "$(code tests/e2e/x.spec.ts 'import { test } from "./fixtures/base"; const cb: Function = () => {}; test("a", cb);')" "Function as a type annotation → ALLOW"
assert_allow "$H" "$(code tests/e2e/x.spec.ts 'export const isFn = (x: unknown) => x instanceof Function; export const cjs = typeof require !== "undefined" && typeof process !== "undefined";')" \
  "instanceof Function, typeof require, typeof process → ALLOW"
assert_allow "$H" "$(code tests/e2e/fixtures/x.ts 'export const base = process.env.BASE_URL ?? "http://localhost:3000"; export const ci = process.platform === "linux" && process.argv.length > 1; module.exports.ok = process.cwd();')" \
  "process.env / process.platform / process.argv / module.exports → ALLOW"
assert_allow "$H" "$(code tests/e2e/pages/login.ts 'import type { Page } from "@playwright/test";
export class LoginPage {
  constructor(private readonly page: Page) {}
  async open(): Promise<void> { await this.page.goto("/login"); }
  get title() { return this.page.title(); }
}
export const rows: Record<string, number> = {}; export const pick = (k: string, i: number, users: string[]) => rows[k] + [1, 2][i] + [[1]][0][0] + users[(i + 1) % users.length].length;
export const onLoad = (page: Page) => page.on("load", () => {}); export const doc = { load: (b: Buffer) => b }; export const d = doc.load(Buffer.from(""));')" \
  "page object: class constructor, identifier / numeric / arithmetic computed keys, \"load\" string, .load() call → ALLOW"

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

section "import-boundary-gate: no # imports, no self-reference, root package.json resolution fixed"
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'import "#app";')" "fixture importing #app → DENY" "package imports"
assert_deny "$H" "$(code tests/e2e/fixtures/x.ts 'import { app } from "proj/server";')" "fixture importing the project's own package → DENY" "self-reference"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/package.json" content='{"name":"proj","scripts":{},"imports":{"#app":"./src/app.js"}}' cwd="$CP")" \
  "root package.json adding imports → DENY" "package.json screen:"
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
NG="$IB_TMP/nogit"; mkdir -p "$NG/tests/e2e"; printf '%s' '{"name":"nogit"}' > "$NG/package.json"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$H" "$(payload tool_name=Write file_path="$NG/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$NG/tests/e2e")" \
  "no git, cwd inside tests/e2e → root cut above tests/ (its parent holds package.json), DENY" "resolves outside tests/"
CLAUDE_PROJECT_DIR="$NG" assert_deny "$H" "$(payload tool_name=Write file_path="$NG/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="/")" \
  "CLAUDE_PROJECT_DIR anchors the root → DENY" "resolves outside tests/"
GP="$IB_TMP/gitp"; mkdir -p "$GP/tests/e2e"; git init -q "$GP"; printf '%s' '{"name":"gitp"}' > "$GP/package.json"; printf '%s' 'gitdir: ../.git' > "$GP/tests/.git"
assert_deny "$H" "$(payload tool_name=Write file_path="$GP/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$GP")" \
  "a gitfile under tests/ does not move the root → DENY" "resolves outside tests/"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/tests/.git" content='gitdir: ../.git' cwd="$CP")" "writing tests/.git → DENY" ".git entry under tests/"
assert_deny "$H" "$(payload tool_name=Write file_path="$CP/tests/.git/HEAD" content='ref: refs/heads/main' cwd="$CP")" "writing tests/.git/HEAD → DENY" ".git entry under tests/"
UT="$IB_TMP/tests/proj"; mkdir -p "$UT/tests/e2e/fixtures"; git init -q "$UT"; printf '%s' '{"name":"under-tests"}' > "$UT/package.json"
assert_deny "$H" "$(payload tool_name=Write file_path="$UT/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$UT")" \
  "project itself under a tests/ segment: the git toplevel stays the root → DENY" "resolves outside tests/"
assert_allow "$H" "$(payload tool_name=Write file_path="$UT/tests/e2e/x.spec.ts" content='import { test } from "./fixtures/base";' cwd="$UT")" \
  "project itself under a tests/ segment: its own tests/ is in scope → ALLOW"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$H" "$(payload tool_name=Write file_path="$UT/tests/e2e/x.spec.ts" content='import "../../src/app";' cwd="$UT/tests/e2e")" \
  "no git, project under a tests/ segment, cwd in tests/e2e → cut to the project (no package.json above the outer tests/) → DENY" "resolves outside tests/"
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
cp "$H" "$INST/"; cp "$HOOK_DIR/lib/achilles-activation.sh" "$HOOK_DIR/lib/import-boundary-scan.js" "$INST/lib/"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$INST/achilles-import-boundary-gate.sh" "$(code tests/e2e/x.spec.ts 'import { test } from "./fixtures/base";')" \
  "installed copy without the parser bundle or node_modules → DENY with one reason line" "@babel/parser not found; reinstall @civitas-cerebrum/achilles"
cp "$HOOK_DIR/lib/babel-parser.bundle.js" "$INST/lib/"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_allow "$INST/achilles-import-boundary-gate.sh" "$(code tests/e2e/x.spec.ts 'import { test } from "./fixtures/base";')" \
  "installed copy with the parser bundle, no node_modules anywhere → ALLOW on a clean spec"
GIT_CEILING_DIRECTORIES="$IB_TMP" assert_deny "$INST/achilles-import-boundary-gate.sh" "$(code tests/e2e/x.spec.ts 'import "../../src/app";')" \
  "installed copy with the parser bundle → DENY on a spec reaching src/" "resolves outside tests/"

rm -rf "$IB_TMP"
