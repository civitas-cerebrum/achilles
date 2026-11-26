#!/usr/bin/env node
// Builds the spec lint's shipped framework tables from the PUBLISHED releases (a release-process step,
// `npm run build:equivalents`; needs the npm registry, so it is not part of check:pack).
//
//   1. `npm view @civitas-cerebrum/element-interactions versions` lists every published release.
//   2. Each release is fetched with `npm pack <pkg>@<v> --ignore-scripts` into its own empty temporary
//      directory and unpacked there; only its type declarations are read (nothing from it runs).
//   3. The public Steps surface of dist/steps/CommonSteps.d.ts (methods, properties, private names) and the
//      private names of the ElementInteractions facade go to bin/lib/spec-lint/surfaces/<v>.json.
//   4. scripts/equivalents.source.json (raw method -> Steps method, hand-curated) is joined with the
//      surfaces into bin/lib/spec-lint/equivalents.json: each target gets the first release that has it.
//
// Releases without a Steps class are skipped and listed. Exit 0 on success, 1 on any failure.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parserFor } from '../bin/lib/spec-lint/ast.mjs';
import { readPackageSurface, PACKAGE, SURFACES_DIR } from '../bin/lib/spec-lint/surface.mjs';
import { deriveEquivalents, EQUIVALENTS_FILE } from '../bin/lib/spec-lint/equivalents.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE = path.join(ROOT, 'scripts', 'equivalents.source.json');
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';

function run(cmd, args, cwd) {
  return execFileSync(cmd, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function main() {
  const parser = parserFor(ROOT);
  const versions = JSON.parse(run(npm, ['view', PACKAGE, 'versions', '--json'], ROOT));
  const surfaces = [];
  const skipped = [];
  const work = mkdtempSync(path.join(os.tmpdir(), 'achilles-equivalents-'));
  try {
    for (const v of versions) {
      const dir = path.join(work, v);
      mkdirSync(dir);
      run(npm, ['pack', `${PACKAGE}@${v}`, '--ignore-scripts', '--silent', '--pack-destination', dir], dir);
      const tgz = readdirSync(dir).find((f) => f.endsWith('.tgz'));
      if (!tgz) { skipped.push(`${v} (npm pack produced no tarball)`); continue; }
      const out = path.join(dir, 'x');
      mkdirSync(out);
      run('tar', ['-xzf', path.join(dir, tgz), '-C', out], dir);
      const s = readPackageSurface(parser, path.join(out, 'package'));
      if (!s) { skipped.push(`${v} (no Steps class in dist/steps/CommonSteps.d.ts)`); continue; }
      if (s.version !== v) throw new Error(`${v}: unpacked package says ${s.version}`);
      surfaces.push(s);
      process.stdout.write(`build-equivalents: ${v} ${s.methods.length} methods\n`);
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
  if (!surfaces.length) throw new Error('no release produced a surface');
  mkdirSync(SURFACES_DIR, { recursive: true });
  for (const f of readdirSync(SURFACES_DIR)) if (f.endsWith('.json')) rmSync(path.join(SURFACES_DIR, f));
  for (const s of surfaces) {
    const body = { package: s.package, version: s.version, source: 'npm', methods: s.methods, properties: s.properties, privates: s.privates };
    writeFileSync(path.join(SURFACES_DIR, `${s.version}.json`), `${JSON.stringify(body, null, 2)}\n`);
  }
  const source = JSON.parse(readFileSync(SOURCE, 'utf8'));
  const table = deriveEquivalents(source, surfaces);
  writeFileSync(EQUIVALENTS_FILE, `${JSON.stringify(table, null, 2)}\n`);
  process.stdout.write(`build-equivalents: ${surfaces.length} surfaces, equivalents.json written${skipped.length ? `; skipped ${skipped.join(', ')}` : ''}\n`);
  if (!existsSync(EQUIVALENTS_FILE)) throw new Error('equivalents.json not written');
}

try { main(); } catch (e) {
  process.stderr.write(`build-equivalents: ${e.message}\n`);
  process.exit(1);
}
