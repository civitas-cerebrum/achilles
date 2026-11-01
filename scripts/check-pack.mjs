#!/usr/bin/env node
// Asserts the tarball holds what a consumer loads (the CLIs, every skill, the agent definitions, the
// schemas, the reporter, the plugin manifests and the adapter) and nothing from the test trees, the
// lints, the inert hook specs or the package's own fixtures; and the declared engines.
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, existsSync } from 'node:fs';

// npm 11 prints an array, npm 12 an object keyed by package name.
const report = JSON.parse(execFileSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { encoding: 'utf8' }));
const packed = new Set((Array.isArray(report) ? report[0] : Object.values(report)[0]).files.map((f) => f.path));
const pkg = JSON.parse(readFileSync('package.json', 'utf8'));

const required = new Set([
  'scripts/postinstall.js', 'scripts/install/chromium.js', 'reporter/index.js',
  '.claude-plugin/plugin.json', '.claude-plugin/marketplace.json',
  'claude-code/hooks.json', 'claude-code/hooks.ts', 'claude-code/types/index.d.ts', 'claude-code/register.js',
]);
for (const b of Object.values(pkg.bin)) required.add(b.replace(/^\.\//, ''));
for (const d of readdirSync('skills')) if (existsSync(`skills/${d}/SKILL.md`)) required.add(`skills/${d}/SKILL.md`);
for (const f of readdirSync('agents')) if (f.endsWith('.md')) required.add(`agents/${f}`);
for (const f of readdirSync('claude-code/lib')) required.add(`claude-code/lib/${f}`);
for (const f of readdirSync('claude-code/data')) required.add(`claude-code/data/${f}`);
for (const f of readdirSync('schemas')) if (/\.(json|txt)$/.test(f)) required.add(`schemas/${f}`);
for (const f of readdirSync('schemas/subagent-returns')) if (f.endsWith('.json')) required.add(`schemas/subagent-returns/${f}`);

const missing = [...required].filter((p) => !packed.has(p)).sort();
const forbidden = [...packed].filter((p) => /(^|\/)tests?\/|fixtures\/|^scripts\/lint|^scripts\/check-pack|node_modules\/|^\.claude-plugin\/types\//.test(p)).sort();
const engines = pkg.engines?.node === '>=20' ? [] : [`engines.node is ${JSON.stringify(pkg.engines?.node)}, expected ">=20"`];
for (const p of missing) console.error(`check-pack: MISSING ${p}`);
for (const p of forbidden) console.error(`check-pack: FORBIDDEN ${p}`);
for (const e of engines) console.error(`check-pack: ${e}`);
console.log(`check-pack: ${packed.size} files, ${missing.length} missing, ${forbidden.length} forbidden`);
process.exit(missing.length || forbidden.length || engines.length ? 1 : 0);
