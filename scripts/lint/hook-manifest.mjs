import { readFileSync, existsSync } from 'node:fs';
import { makeAjv } from '../lib/ajv.mjs';

const HARNESS_HOOKS = 'skills/achilles-protocol/references/harness-hooks.md';
const HOOK_MANIFEST = 'hooks/data/hook-manifest.json';

// Source: https://code.claude.com/docs/en/hooks (event table).
const HOOK_EVENTS = [
  'SessionStart', 'Setup', 'UserPromptSubmit', 'UserPromptExpansion', 'PreToolUse',
  'PermissionRequest', 'PermissionDenied', 'PostToolUse', 'PostToolUseFailure',
  'PostToolBatch', 'Notification', 'MessageDisplay', 'SubagentStart', 'SubagentStop',
  'TaskCreated', 'TaskCompleted', 'Stop', 'StopFailure', 'TeammateIdle', 'InstructionsLoaded',
  'ConfigChange', 'CwdChanged', 'DirectoryAdded', 'FileChanged', 'WorktreeCreate',
  'WorktreeRemove', 'PreCompact', 'PostCompact', 'PreModelSwitch', 'PostModelSwitch',
  'Elicitation', 'ElicitationResult', 'SessionEnd',
];
const validEntry = makeAjv().compile({
  type: 'object',
  required: ['file', 'event', 'matcher', 'timeout'],
  additionalProperties: false,
  properties: {
    file: { type: 'string', pattern: '^[a-z0-9-]+\\.sh$' },
    event: { enum: HOOK_EVENTS },
    matcher: { type: ['string', 'null'] },
    timeout: { type: 'integer', minimum: 1 },
    async: { type: 'boolean' },
  },
});

// Check 3 — hook manifest  ↔  harness-hooks.md (both ways)
export function run(report) {
  const detail = [];
  const entries = JSON.parse(readFileSync(HOOK_MANIFEST, 'utf8')).hooks;
  let invalid = 0;
  entries.forEach((h, i) => {
    const problems = validEntry(h) ? [] : validEntry.errors.map((e) => `${e.instancePath || '/'} ${e.message}`);
    if (typeof h.file === 'string' && !existsSync(`hooks/${h.file}`)) problems.push(`hooks/${h.file} does not exist`);
    if (problems.length) invalid++;
    for (const p of problems) detail.push(`${HOOK_MANIFEST} hooks[${i}] (${h.file}): ${p}`);
  });
  const manifestFiles = new Set(entries.map((h) => h.file));

  // Documented hooks = markdown links of the form (.../hooks/<file>.sh).
  // Exclude hooks/lib/* (those are library files cited in prose, not
  // registered hooks).
  const hooksMd = readFileSync(HARNESS_HOOKS, 'utf8');
  const documented = new Set(
    [...hooksMd.matchAll(/\((?:\.\.\/)+hooks\/([a-z0-9-]+\.sh)\)/g)].map((m) => m[1]),
  );

  // One bullet per hook: `- **[name](.../hooks/<file>.sh)**`.
  const bulletCount = new Map();
  for (const m of hooksMd.matchAll(/^- \*\*\[[^\]]+\]\((?:\.\.\/)+hooks\/([a-z0-9-]+\.sh)\)\*\*/gm)) {
    bulletCount.set(m[1], (bulletCount.get(m[1]) || 0) + 1);
  }
  for (const f of manifestFiles) {
    const n = bulletCount.get(f) || 0;
    if (n !== 1) detail.push(`harness-hooks.md has ${n} bullets for ${f}, expected exactly 1`);
  }

  const undocumented = [...manifestFiles].filter((f) => !documented.has(f));
  const orphanDocs = [...documented].filter((f) => !manifestFiles.has(f));

  if (undocumented.length) detail.push(`in ${HOOK_MANIFEST} but not documented in harness-hooks.md: ${undocumented.join(', ')}`);
  if (orphanDocs.length) detail.push(`documented in harness-hooks.md but not in ${HOOK_MANIFEST}: ${orphanDocs.join(', ')}`);

  report(
    `hook manifest ↔ harness-hooks.md (${manifestFiles.size} manifest hooks, ${documented.size} documented)`,
    invalid === 0 && undocumented.length === 0 && orphanDocs.length === 0 && detail.length === 0,
    detail,
  );
}
