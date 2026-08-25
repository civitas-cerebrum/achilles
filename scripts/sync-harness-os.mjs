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
// test files, renamed into this repo's numeric cases convention so the
// vendored kernel gets identical adversarial + benchmark coverage under
// `npm run test:hooks`.
const RENAMES = [
  ['hooks/tests/cases/02-adversarial.sh', 'hooks/tests/cases/72-harness-os-adversarial.sh'],
  ['hooks/tests/cases/03-benchmark-registration.sh', 'hooks/tests/cases/73-harness-os-benchmark.sh'],
  ['hooks/tests/cases/04-identity.sh', 'hooks/tests/cases/74-harness-os-identity.sh'],
  ['hooks/tests/cases/05-mcp-scoping.sh', 'hooks/tests/cases/75-harness-os-mcp-scoping.sh'],
  ['hooks/tests/cases/06-bash-permit.sh', 'hooks/tests/cases/76-harness-os-bash-permit.sh'],
  ['hooks/tests/cases/07-write-then-execute.sh', 'hooks/tests/cases/77-harness-os-write-then-execute.sh'],
  ['hooks/tests/cases/08-reviewer-round1.sh', 'hooks/tests/cases/78-harness-os-reviewer-round1.sh'],
  ['hooks/tests/cases/09-reviewer-round2.sh', 'hooks/tests/cases/79-harness-os-reviewer-round2.sh'],
  ['hooks/tests/cases/10-reviewer-round3.sh', 'hooks/tests/cases/80-harness-os-reviewer-round3.sh'],
  ['hooks/tests/cases/11-reviewer-round4.sh', 'hooks/tests/cases/81-harness-os-reviewer-round4.sh'],
];
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
