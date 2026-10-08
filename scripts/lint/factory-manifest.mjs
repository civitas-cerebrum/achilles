import { readFileSync, readdirSync, existsSync } from 'node:fs';

const HARNESS_HOOKS = 'skills/achilles-protocol/references/harness-hooks.md';
const HOOK_MANIFEST = 'hooks/data/hook-manifest.json';
const FACTORY_DIR = 'hooks/factory';

// Check 13 — manifest.factory  ↔  hooks/factory/*.sh  ↔  harness-hooks.md
// Check 3's link pattern has no directory segment, so it cannot see a
// factory gate; this check holds that family on all three sides. A gate on
// disk the manifest omits ships and never runs.
export function run(report) {
  const detail = [];
  const registered = new Set((JSON.parse(readFileSync(HOOK_MANIFEST, 'utf8')).factory ?? []).map((e) => e.file));
  const onDisk = new Set(existsSync(FACTORY_DIR) ? readdirSync(FACTORY_DIR).filter((f) => f.endsWith('.sh')) : []);
  const hooksMd = readFileSync(HARNESS_HOOKS, 'utf8');
  const documented = new Set(
    [...hooksMd.matchAll(/\((?:\.\.\/)+hooks\/factory\/([a-z0-9-]+\.sh)\)/g)].map((m) => m[1]),
  );

  const diff = (a, b) => [...a].filter((f) => !b.has(f)).sort();
  const unregistered = diff(onDisk, registered);
  const phantom = diff(registered, onDisk);
  const undocumented = diff(registered, documented);
  const orphanDocs = diff(documented, onDisk);

  if (unregistered.length) detail.push(`in ${FACTORY_DIR}/ but not in ${HOOK_MANIFEST} .factory (ships, never registered): ${unregistered.join(', ')}`);
  if (phantom.length) detail.push(`in ${HOOK_MANIFEST} .factory but no such file under ${FACTORY_DIR}/: ${phantom.join(', ')}`);
  if (undocumented.length) detail.push(`in ${HOOK_MANIFEST} .factory but not documented in harness-hooks.md: ${undocumented.join(', ')}`);
  if (orphanDocs.length) detail.push(`documented in harness-hooks.md but no such file under ${FACTORY_DIR}/: ${orphanDocs.join(', ')}`);

  report(
    `manifest.factory ↔ ${FACTORY_DIR}/ ↔ harness-hooks.md (${onDisk.size} on disk, ${registered.size} registered, ${documented.size} documented)`,
    detail.length === 0,
    detail,
  );
}
