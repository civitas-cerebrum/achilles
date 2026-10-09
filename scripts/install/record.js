const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const { packageDir } = require('./context.js');

// <claudeDir>/achilles-install.json records what postinstall wrote:
//   files          — { "<path relative to claudeDir>": "<sha256 of the content written>" }
//   registrations  — [{ event, matcher, command }] the manifest registers in settings.json
//   kept           — { "<path>": "<sha256 of the user's content>" } files left alone, so the warning prints once
// Each installer owns a section — the top-level dir it writes under (hooks, skills,
// agents) — so installers sharing one claudeDir (and a local install touching the
// user-level ~/.claude) carry each other's entries through untouched.
// Copies compare content, not mtime: npm tarballs carry fixed 1985 mtimes, so an
// mtime check leaves an upgraded hook stale. The recorded hash is also how a
// file the user edited is told apart from one Achilles wrote.
const RECORD_FILE = 'achilles-install.json';

const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const registrationKey = (r) => JSON.stringify([r.event, r.matcher || null, r.command]);

function openRecord(claudeDir, sections) {
  let prev = null;
  try {
    prev = JSON.parse(fs.readFileSync(path.join(claudeDir, RECORD_FILE), 'utf8'));
  } catch (_) { /* first install, or an unreadable record: nothing is claimed as ours */ }
  if (!isObject(prev)) prev = {};
  const prevFiles = isObject(prev.files) ? prev.files : {};
  const prevKept = isObject(prev.kept) ? prev.kept : {};
  const prevRegistrations = Array.isArray(prev.registrations)
    ? prev.registrations.filter((r) => isObject(r) && typeof r.command === 'string')
    : [];
  const rec = {
    claudeDir: path.resolve(claudeDir),
    hadRecord: isObject(prev.files),
    prev: prevFiles,
    prevKept,
    prevRegistrations,
    next: { files: {}, registrations: [], kept: {} },
    adopted: 0,
  };
  if (sections) {
    const foreign = (rel) => !sections.includes(rel.split('/')[0]);
    for (const [rel, hash] of Object.entries(prevFiles)) if (foreign(rel)) rec.next.files[rel] = hash;
    for (const [rel, hash] of Object.entries(prevKept)) if (foreign(rel)) rec.next.kept[rel] = hash;
    if (!sections.includes('hooks')) rec.next.registrations = [...prevRegistrations];
  }
  return rec;
}

function keep(rec, rel, file, have, recordedHash, why, remedy) {
  rec.next.files[rel] = recordedHash;
  rec.next.kept[rel] = have;
  if (rec.prevKept[rel] !== have) console.warn(`[civitas-cerebrum] ${file} ${why} — left untouched; ${remedy}.`);
}

// Copies src to dest when the content differs and returns whether it did. A
// recorded file whose content no longer matches its recorded hash was edited by
// the user: it is kept and stays recorded so it stays protected.
function copyTracked(rec, src, dest) {
  const rel = path.relative(rec.claudeDir, dest);
  const want = sha256(src);
  const have = fs.existsSync(dest) ? sha256(dest) : null;
  if (have === want) {
    rec.next.files[rel] = want;
    return false;
  }
  if (have !== null && rec.prev[rel] && rec.prev[rel] !== have) {
    keep(rec, rel, dest, have, rec.prev[rel], 'was modified after install', 'delete it to take the packaged version');
    return false;
  }
  if (have !== null && !rec.prev[rel]) rec.adopted++;
  fs.copyFileSync(src, dest);
  rec.next.files[rel] = want;
  return true;
}

// The absolute path of a recorded file when it is safe to act on, else null.
// The key must be the canonical form copyTracked writes (`hooks/./x` would dodge
// the still-shipped check), name a regular file, and sit under claudeDir by real
// path: a symlinked directory in the tree must not redirect a delete outside it.
function ownedFile(claudeDir, rel) {
  const file = path.resolve(claudeDir, rel);
  if (path.relative(claudeDir, file) !== rel || rel.startsWith('..')) return null;
  try {
    if (!fs.lstatSync(file).isFile()) return null;
    const realDir = fs.realpathSync(path.dirname(file));
    return (realDir + path.sep).startsWith(fs.realpathSync(claudeDir) + path.sep) ? file : null;
  } catch (_) {
    return null;
  }
}

// Deletes a file ownedFile approved, then the directories it leaves empty (never claudeDir).
// Check-to-delete is not atomic; exploiting the gap needs concurrent write access to claudeDir.
function removeFile(claudeDir, file) {
  fs.unlinkSync(file);
  for (let dir = path.dirname(file); dir !== claudeDir && dir.startsWith(claudeDir + path.sep); dir = path.dirname(dir)) {
    try { fs.rmdirSync(dir); } catch (_) { break; }
  }
}

// Removes a recorded file unless the user edited it since. Returns 'removed',
// 'modified' (kept; the file's current hash is in `have`) or 'skipped'
// (untrusted key, missing, or not a regular file).
function removeRecorded(claudeDir, rel, hash, dryRun = false) {
  const file = ownedFile(claudeDir, rel);
  if (!file) return { state: 'skipped' };
  const have = sha256(file);
  if (have !== hash) return { state: 'modified', file, have };
  if (!dryRun) removeFile(claudeDir, file);
  return { state: 'removed', file };
}

// Deletes files a previous install recorded that this package no longer ships,
// unless the user edited them.
function pruneStale(rec) {
  for (const [rel, hash] of Object.entries(rec.prev)) {
    if (rel in rec.next.files) continue;
    const r = removeRecorded(rec.claudeDir, rel, hash);
    if (r.state === 'modified') keep(rec, rel, r.file, r.have, hash, 'is no longer shipped but was modified', 'delete it if you no longer want it');
    else if (r.state === 'removed') console.log(`[civitas-cerebrum] pruned file dropped from the package: ${rel}`);
  }
}

// Removes registrations an earlier install made that the manifest no longer
// asks for; registrations the user added are not in the record and stay.
// Returns whether settings changed.
function dropStaleRegistrations(rec, settings) {
  const current = new Set(rec.next.registrations.map(registrationKey));
  let changed = false;
  for (const r of rec.prevRegistrations) {
    if (current.has(registrationKey(r)) || !settings.hooks || !Array.isArray(settings.hooks[r.event])) continue;
    for (const group of settings.hooks[r.event]) {
      if (!group || !Array.isArray(group.hooks) || (group.matcher || null) !== (r.matcher || null)) continue;
      const before = group.hooks.length;
      group.hooks = group.hooks.filter((h) => !(h && h.type === 'command' && h.command === r.command));
      if (group.hooks.length !== before) changed = true;
    }
    settings.hooks[r.event] = settings.hooks[r.event].filter((g) => !g || !Array.isArray(g.hooks) || g.hooks.length > 0);
  }
  return changed;
}

function writeRecord(rec) {
  if (!rec.hadRecord && rec.adopted > 0) {
    console.log(`[civitas-cerebrum] First install with a record: ${rec.adopted} existing file${rec.adopted === 1 ? '' : 's'} from an earlier version replaced by the packaged content.`);
  }
  const { version } = JSON.parse(fs.readFileSync(path.join(packageDir, 'package.json'), 'utf8'));
  const out = { package: '@civitas-cerebrum/achilles', version, ...rec.next };
  if (Object.keys(out.kept).length === 0) delete out.kept;
  const text = JSON.stringify(out, null, 2) + '\n';
  const file = path.join(rec.claudeDir, RECORD_FILE);
  if (fs.existsSync(file) && fs.readFileSync(file, 'utf8') === text) return;
  fs.writeFileSync(file, text);
}

module.exports = { RECORD_FILE, sha256, openRecord, copyTracked, removeRecorded, pruneStale, dropStaleRegistrations, writeRecord };
