#!/usr/bin/env node
// achilles-uninstall [--global | --project [dir]] [--dry-run]
// Reverses what postinstall recorded in <claude dir>/achilles-install.json: its
// settings.json registrations, then its files (only those still byte-identical to
// what was written), the staged mandate (only when unedited), the hooks' runtime
// state, and last the record. --project (the default; dir defaults to the cwd)
// reverses <dir>/.claude; --global reverses ~/.claude: a global install, or the
// routing skill a local install writes there.
// npm >= 7 runs no uninstall lifecycle script, so this is a command.
import { createRequire } from 'node:module';
import { existsSync, readFileSync, writeFileSync, unlinkSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';

const require = createRequire(import.meta.url);
const { RECORD_FILE, sha256, openRecord, removeRecorded, dropStaleRegistrations } = require('../scripts/install/record.js');
const { STAMP_FILE, MANDATE_FILES } = require('../scripts/install/mandate.js');
const { userClaudeDir } = require('../scripts/install/context.js');

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const projectAt = args.indexOf('--project');
const projectArg = projectAt >= 0 && args[projectAt + 1] && !args[projectAt + 1].startsWith('--') ? args[projectAt + 1] : null;
const unknown = args.filter((a, i) => !['--global', '--dry-run', '--project'].includes(a) && !(projectArg && i === projectAt + 1));
if (unknown.length || (flag('--global') && projectAt >= 0)) {
  console.error('usage: achilles-uninstall [--global | --project [dir]] [--dry-run]');
  process.exit(2);
}

const dryRun = flag('--dry-run');
const projectDir = resolve(projectArg ?? process.cwd());
const claudeDir = flag('--global') ? userClaudeDir : join(projectDir, '.claude');
const say = (verb, what) => console.log(`${dryRun ? 'would ' : ''}${verb} ${what}`);

if (!existsSync(join(claudeDir, RECORD_FILE))) {
  console.error(`achilles-uninstall: no ${RECORD_FILE} in ${claudeDir}; nothing recorded.`);
  process.exit(1);
}
const rec = openRecord(claudeDir);
if (!rec.hadRecord && rec.prevRegistrations.length === 0) {
  console.error(`achilles-uninstall: ${join(claudeDir, RECORD_FILE)} is unusable; left in place.`);
  process.exit(1);
}

const settingsPath = join(claudeDir, 'settings.json');
if (existsSync(settingsPath) && rec.prevRegistrations.length > 0) {
  try {
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    const removed = dropStaleRegistrations(rec, settings);
    if (removed > 0) {
      say('remove', `${removed} registration${removed === 1 ? '' : 's'} from ${settingsPath}`);
      if (!dryRun) writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    }
  } catch (err) {
    console.warn(`achilles-uninstall: ${settingsPath} is not valid JSON; registrations left in place. (${err.message})`);
  }
}

for (const [rel, hash] of Object.entries(rec.prev)) {
  const file = join(claudeDir, rel);
  const probe = removeRecorded(claudeDir, rel, hash, dryRun);
  if (probe.state === 'removed') say('remove', file);
  else if (probe.state === 'modified') console.warn(`kept ${file}: modified after install`);
}

const stampPath = join(claudeDir, STAMP_FILE);
if (existsSync(stampPath)) {
  const names = MANDATE_FILES[flag('--global') ? 'global' : 'project'];
  let stamp = {};
  try { stamp = JSON.parse(readFileSync(stampPath, 'utf8')) ?? {}; } catch { /* unreadable stamp: keep the mandate */ }
  for (const [name, key] of [[names.manifest, 'manifestSha256'], [names.ledger, 'ledgerSha256']]) {
    const file = join(claudeDir, name);
    if (!existsSync(file)) continue;
    if (stamp[key] === sha256(file)) {
      say('remove', file);
      if (!dryRun) unlinkSync(file);
    } else {
      console.warn(`kept ${file}: edited, or not staged by achilles`);
    }
  }
  say('remove', stampPath);
  if (!dryRun) unlinkSync(stampPath);
}

// Runtime state the hooks wrote: the kernel's decision log in a project, session markers user-level.
// The markers serve every project's hooks, so they stay while the user-level record is a local
// install's (the routing skill): projects with Achilles installed remain.
const localRouting = rec.prevScope ? rec.prevScope === 'local' : !Object.keys(rec.prev).some((rel) => rel.startsWith('hooks/'));
const state = flag('--global') ? (localRouting ? null : join(claudeDir, 'achilles')) : join(claudeDir, 'kernel-mandate.state');
if (state && existsSync(state)) {
  say('remove', state);
  if (!dryRun) rmSync(state, { recursive: true, force: true });
}

say('remove', join(claudeDir, RECORD_FILE));
if (!dryRun) unlinkSync(join(claudeDir, RECORD_FILE));

// A local install also wrote the routing skill user-level; --project leaves it, as other projects may use it.
if (!flag('--global') && existsSync(join(userClaudeDir, RECORD_FILE))) {
  console.log(`Achilles files in ${userClaudeDir} remain; remove them with: achilles-uninstall --global`);
}
