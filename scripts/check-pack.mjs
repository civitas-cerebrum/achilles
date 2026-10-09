#!/usr/bin/env node
// Asserts the tarball holds what installed hooks load and nothing from the test tree.
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, existsSync } from 'node:fs';

const packed = new Set(JSON.parse(execFileSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { encoding: 'utf8' }))[0].files.map((f) => f.path));
const manifest = JSON.parse(readFileSync('hooks/data/hook-manifest.json', 'utf8'));
const pkg = JSON.parse(readFileSync('package.json', 'utf8'));

const required = new Set(['hooks/lib/validator.bundle.mjs', 'scripts/postinstall.js', 'reporter/index.js', 'hooks/data/hook-manifest.json']);
for (const h of manifest.hooks) required.add(`hooks/${h.file}`);
for (const c of manifest.companions) required.add(`hooks/${c}`);
for (const f of manifest.factory) required.add(`hooks/factory/${f.file}`);
for (const f of readdirSync('hooks/lib')) required.add(`hooks/lib/${f}`);
for (const f of readdirSync('scripts/install')) required.add(`scripts/install/${f}`);
for (const b of Object.values(pkg.bin)) required.add(b.replace(/^\.\//, ''));
for (const d of readdirSync('skills')) if (existsSync(`skills/${d}/SKILL.md`)) required.add(`skills/${d}/SKILL.md`);

const missing = [...required].filter((p) => !packed.has(p)).sort();
const forbidden = [...packed].filter((p) => /(^|\/)tests?\/|fixtures\/|^scripts\/lint|^scripts\/check-pack|node_modules\//.test(p)).sort();
for (const p of missing) console.error(`check-pack: MISSING ${p}`);
for (const p of forbidden) console.error(`check-pack: FORBIDDEN ${p}`);
console.log(`check-pack: ${packed.size} files, ${missing.length} missing, ${forbidden.length} forbidden`);
process.exit(missing.length || forbidden.length ? 1 : 0);
