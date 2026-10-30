// The import-boundary scanner the spec-hygiene hook runs as a child process, against the cases of
// the 0.2.x spec 86 (cases.json, the single-quoted ones) and the designed configs.
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const scanner = path.join(__dirname, '../../../lib/import-boundary-scan.js');
const proj = fs.mkdtempSync(path.join(os.tmpdir(), 'ib-scan-'));
const put = (rel, text) => { fs.mkdirSync(path.dirname(path.join(proj, rel)), { recursive: true }); fs.writeFileSync(path.join(proj, rel), text); };
put('package.json', '{"name":"proj","scripts":{}}');
put('tests/e2e/fixtures/.keep', '');
put('src/.keep', '');
put('tests/e2e/auth.setup.ts', 'export const a = 1;');
put('tests/helper.txt', 'module.exports = 1;');
put('tests/h2', 'module.exports = 1;');
put('tests/e2e/data.txt.ts', 'export const d = 1;');

const designed = [
  ["import 'dotenv/config';\nimport { defineConfig, devices } from '@playwright/test';\nexport default defineConfig({\n  testDir: './tests/e2e',\n  retries: process.env.CI ? 2 : 0,\n  reporter: [['html', { open: 'never' }], ['json', { outputFile: 'test-results/results.json' }], ['@civitas-cerebrum/achilles/reporter']],\n  use: { baseURL: process.env.BASE_URL ?? 'http://localhost:3000', trace: 'retain-on-failure' },\n  projects: [{ name: 'setup', testMatch: /playwright\\.setup\\.ts/ }, { name: 'chromium', use: { ...devices['Desktop Chrome'] }, dependencies: ['setup'] }],\n  webServer: { command: 'npm run dev', url: 'http://localhost:3000', reuseExistingServer: !process.env.CI },\n});", 'onboarding Phase 1 config'],
  ["import path from 'node:path';\nimport { fileURLToPath } from 'node:url';\nimport { defineConfig } from '@playwright/test';\nconst __dirname = path.dirname(fileURLToPath(import.meta.url));\nexport default defineConfig({ testDir: path.join(__dirname, 'tests/e2e'), globalSetup: path.resolve(__dirname, './tests/e2e/global-setup.ts') });", 'fileURLToPath form'],
  ["import { defineConfig } from '@playwright/test';\nexport default defineConfig({\n  testDir: './tests/contracts',\n  retries: 0,                    // deterministic\n  reporter: [['list'], ['html', { outputFolder: 'playwright-report-contracts' }]],\n});", 'contract-testing config with trailing comments'],
].map(([content, name]) => ({ name, expect: 'allow', file: 'playwright.config.ts', content }));

const cases = [...designed, ...JSON.parse(fs.readFileSync(path.join(__dirname, 'cases.json'), 'utf8'))];
let failed = 0;
for (const c of cases) {
  const file = path.join(proj, c.file);
  const r = spawnSync(process.execPath, [scanner, file, proj], { input: JSON.stringify({ tool_name: 'Write', tool_input: { file_path: file, content: c.content } }), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: proj } });
  let out = { offenders: [] };
  try { out = JSON.parse(r.stdout); } catch { out = { offenders: [`no verdict: ${r.stderr.trim()}`] }; }
  const denied = out.offenders.length > 0;
  const ok = (c.expect === 'deny') === denied && (!c.contains || out.offenders.join('\n').includes(c.contains));
  if (!ok) failed++;
  console[ok ? 'log' : 'error'](`  ${ok ? '✓' : '✗'} ${c.name}${ok ? '' : ` — got ${JSON.stringify(out.offenders).slice(0, 200)}`}`);
}
fs.rmSync(proj, { recursive: true, force: true });
console.log(`\n${cases.length - failed}/${cases.length} passed`);
process.exit(failed === 0 ? 0 : 1);
