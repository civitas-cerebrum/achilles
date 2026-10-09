const fs   = require('fs');
const path = require('path');
const { packageDir, destinations } = require('./context.js');
const { openRecord, copyTracked, pruneStale, writeRecord } = require('./record.js');

// Auto-discover every skill under skills/. A skill is any direct subdirectory
// of skills/ that contains a SKILL.md at its root. This keeps installs in sync
// with the repo automatically — add a new skill folder and it ships on the next
// publish; no manifest edit required.
function discoverSkills(root) {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => entry.name)
    .filter(name => fs.existsSync(path.join(root, name, 'SKILL.md')));
}

// Recursively copy one skill directory. Copies SKILL.md and the whole
// references/ tree — everything SKILL.md's instructions refer to. Files are
// copied by content and recorded, so an edited skill file is kept (record.js).
function copyDirRecursive(rec, src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirRecursive(rec, srcPath, destPath);
    } else if (entry.isFile()) {
      copyTracked(rec, srcPath, destPath);
    }
  }
}

function installCivitasSkills(dests = destinations, skillsDir = path.join(packageDir, 'skills')) {
  const skills = discoverSkills(skillsDir);
  try {
    const installedSkills = new Set();
    for (const skillsDestBase of dests) {
      const rec = openRecord(path.dirname(skillsDestBase), ['skills']);
      for (const skill of skills) {
        copyDirRecursive(rec, path.join(skillsDir, skill), path.join(skillsDestBase, skill));
        installedSkills.add(skill);
      }
      pruneStale(rec);
      writeRecord(rec);
    }
    if (installedSkills.size > 0) {
      console.log(`[@civitas-cerebrum/achilles] ✔ ${installedSkills.size} skill${installedSkills.size > 1 ? 's' : ''} installed to ${dests.length} locations — restart Claude Code to pick it up.`);
    } else {
      console.warn('[@civitas-cerebrum/achilles] Skill files not found, skipping.');
    }
  } catch (err) {
    console.warn(`[@civitas-cerebrum/achilles] Could not install Claude Code skill: ${err.message}`);
  }
}

module.exports = { installCivitasSkills };
