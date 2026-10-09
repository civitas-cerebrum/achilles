const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const { packageDir } = require('./context.js');

// <claudeDir>/achilles-install.json records what postinstall wrote:
//   files          — { "<path relative to claudeDir>": "<sha256 of the content written>" }
//   registrations  — [{ event, matcher, command }] added to settings.json
// Copies compare content, not mtime: npm tarballs carry fixed 1985 mtimes, so an
// mtime check leaves an upgraded hook stale. The recorded hash is also how a
// file the user edited is told apart from one Achilles wrote.
const RECORD_FILE = 'achilles-install.json';

const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

function openRecord(claudeDir) {
  let prev = {};
  try {
    prev = JSON.parse(fs.readFileSync(path.join(claudeDir, RECORD_FILE), 'utf8'));
  } catch (_) { /* first install, or an unreadable record: nothing is claimed as ours */ }
  return {
    claudeDir,
    prev: prev.files && typeof prev.files === 'object' ? prev.files : {},
    next: { files: {}, registrations: [] },
  };
}

// Copies src to dest when the content differs and returns whether it did. A
// recorded file whose content no longer matches its recorded hash was edited by
// the user: it is kept, warned about, and stays recorded so it stays protected.
function copyTracked(rec, src, dest) {
  const rel = path.relative(rec.claudeDir, dest);
  const want = sha256(src);
  const have = fs.existsSync(dest) ? sha256(dest) : null;
  if (have === want) {
    rec.next.files[rel] = want;
    return false;
  }
  if (have !== null && rec.prev[rel] && rec.prev[rel] !== have) {
    console.warn(`[civitas-cerebrum] ${dest} was modified after install — left untouched; delete it to take the packaged version.`);
    rec.next.files[rel] = rec.prev[rel];
    return false;
  }
  fs.copyFileSync(src, dest);
  rec.next.files[rel] = want;
  return true;
}

// Deletes files a previous install recorded that this package no longer ships,
// unless the user edited them. Records outside claudeDir are ignored.
function pruneStale(rec) {
  for (const [rel, hash] of Object.entries(rec.prev)) {
    if (rel in rec.next.files) continue;
    const file = path.resolve(rec.claudeDir, rel);
    if (!file.startsWith(rec.claudeDir + path.sep) || !fs.existsSync(file)) continue;
    if (sha256(file) !== hash) {
      console.warn(`[civitas-cerebrum] ${file} is no longer shipped but was modified — left in place.`);
      rec.next.files[rel] = hash;
      continue;
    }
    fs.unlinkSync(file);
    console.log(`[civitas-cerebrum] pruned file dropped from the package: ${rel}`);
  }
}

function writeRecord(rec) {
  const { version } = JSON.parse(fs.readFileSync(path.join(packageDir, 'package.json'), 'utf8'));
  const text = JSON.stringify({ package: '@civitas-cerebrum/achilles', version, ...rec.next }, null, 2) + '\n';
  const file = path.join(rec.claudeDir, RECORD_FILE);
  if (fs.existsSync(file) && fs.readFileSync(file, 'utf8') === text) return;
  fs.writeFileSync(file, text);
}

module.exports = { openRecord, copyTracked, pruneStale, writeRecord };
