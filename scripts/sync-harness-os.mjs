#!/usr/bin/env node
// sync-harness-os.mjs — keep achilles' vendored harness OS in lockstep
// with its canonical home, the @civitas-cerebrum/harness-os package
// (github.com/civitas-cerebrum/harness-os).
//
// Why vendoring + sync (instead of resolving from node_modules at
// postinstall time): the vendored files keep every existing surface
// honest with zero installer churn — HOOK_MANIFEST references a file
// that exists in this repo, the hook test suite exercises the exact
// bytes that ship, and lint-doc-drift's bijections keep holding. The
// price of vendoring is drift, and this script is the payment:
//
//   node scripts/sync-harness-os.mjs           # copy canonical → vendored
//   node scripts/sync-harness-os.mjs --check   # diff only; exit 1 on drift
//
// Source resolution: $HARNESS_OS_SRC (a checkout of the canonical repo)
// beats node_modules/@civitas-cerebrum/harness-os. When neither exists
// the script reports and exits 0 — a contributor without the dependency
// installed must not be blocked, drift is caught wherever the
// dependency IS present (prepack runs --check).
//
// NEVER edit the vendored files in this repo — edit upstream, then sync.

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, chmodSync } from 'node:fs';
import { join, dirname } from 'node:path';

const REPO_ROOT = join(dirname(new URL(import.meta.url).pathname), '..');
const CHECK = process.argv.includes('--check');

function resolveSource() {
  const env = process.env.HARNESS_OS_SRC;
  if (env && existsSync(join(env, 'hooks/harness-os-role-gate.sh'))) return env;
  const dep = join(REPO_ROOT, 'node_modules', '@civitas-cerebrum', 'harness-os');
  if (existsSync(join(dep, 'hooks/harness-os-role-gate.sh'))) return dep;
  return null;
}

const SRC = resolveSource();
if (!SRC) {
  console.log('[sync-harness-os] canonical source not found ($HARNESS_OS_SRC or node_modules/@civitas-cerebrum/harness-os) — skipping.');
  process.exit(0);
}

// Vendored surface. Directories are synced by *.json / listed-extension
// membership from the SOURCE side (a file present upstream but missing
// here is drift too).
// Files copied to the same relative path in this repo.
const FILES = [
  'hooks/harness-os-role-gate.sh',
  'hooks/lib/harness-os.sh',
  'schemas/harness-os.schema.json',
  'schemas/harness-os-bundle.schema.json',
  'skills/harness-designer/SKILL.md',
  'skills/harness-designer/references/architecture.md',
  'skills/harness-designer/references/storage-format.md',
];
// Files vendored under a DIFFERENT path here — the package's own kernel
// test files, which live in their own subdirectory of this repo's cases
// so `npm run test:hooks` gives the vendored kernel identical adversarial
// + benchmark coverage.
//
// DERIVED, not listed. This was a hand-maintained table, and a hand-
// maintained table of "which upstream files matter" is a list that goes
// quietly out of date: every new adversarial-review case file upstream
// was a file this repo's vendored kernel silently stopped being tested
// against, with nothing anywhere to say so.
//
// The subdirectory is the point. These files used to be renumbered into
// the flat cases/ directory with a +70 offset, which gave the vendored
// block twenty-nine slots before it collided with the two-digit
// convention — a ceiling the upstream review loop was going to hit on a
// specific, predictable day. Names now map 1:1 with upstream, there is
// no derivation to get wrong, and there is no ceiling.
const CASES_REL = 'hooks/tests/cases';
const VENDORED_CASES_REL = 'hooks/tests/cases/harness-os';
const RENAMES = readdirSync(join(SRC, CASES_REL))
  .filter((n) => /^\d\d-.+\.sh$/.test(n))
  .sort()
  .map((n) => [join(CASES_REL, n), join(VENDORED_CASES_REL, n)]);
const DIRS = [
  { rel: 'schemas/harness-os.fixtures', ext: '.json' },
  { rel: 'schemas/harness-os-bundle.fixtures', ext: '.json' },
  { rel: 'skills/harness-designer/examples', ext: '.json' },
];

const targets = FILES.map((f) => [f, f]);
for (const [s, d] of RENAMES) targets.push([s, d]);
for (const d of DIRS) {
  for (const f of readdirSync(join(SRC, d.rel)).filter((n) => n.endsWith(d.ext))) {
    targets.push([join(d.rel, f), join(d.rel, f)]);
  }
}

let drift = 0;
for (const [srcRel, dstRel] of targets) {
  const srcPath = join(SRC, srcRel);
  const dstPath = join(REPO_ROOT, dstRel);
  const srcBody = readFileSync(srcPath, 'utf8');
  const dstBody = existsSync(dstPath) ? readFileSync(dstPath, 'utf8') : null;
  if (srcBody === dstBody) continue;
  drift++;
  if (CHECK) {
    console.error(`[sync-harness-os] DRIFT: ${dstRel} ${dstBody === null ? '(missing here)' : 'differs from canonical'}`);
  } else {
    mkdirSync(dirname(dstPath), { recursive: true });
    writeFileSync(dstPath, srcBody);
    if (dstRel.endsWith('.sh') && !dstRel.includes('/lib/')) chmodSync(dstPath, 0o755);
    console.log(`[sync-harness-os] synced ${dstRel}`);
  }
}

if (CHECK && drift) {
  console.error(`[sync-harness-os] ${drift} vendored file(s) drifted from ${SRC}.`);
  console.error('Fix: edit upstream (civitas-cerebrum/harness-os), then run: npm run sync:harness-os');
  process.exit(1);
}
console.log(`[sync-harness-os] ${CHECK ? 'check passed' : drift ? `${drift} file(s) updated` : 'already in sync'} (source: ${SRC})`);
