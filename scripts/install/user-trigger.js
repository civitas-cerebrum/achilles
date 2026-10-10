const fs   = require('fs');
const path = require('path');
const { packageDir, userClaudeDir } = require('./context.js');
const { openRecord, copyTracked, pruneStale, writeRecord } = require('./record.js');

// A local install writes one file user-level: the routing skill
// ~/.claude/skills/achilles/SKILL.md (trigger-skill.md). Its own name keeps it
// from shadowing the project's achilles-protocol, since a user-level skill wins
// over a project skill of the same name.
const TRIGGER_SRC = path.join(__dirname, 'trigger-skill.md');
const TRIGGER_REL = path.join('skills', 'achilles', 'SKILL.md');

// A global install's record lists hooks or registrations; the user-level
// methodology is then that install's, and a local install leaves it alone.
const hasGlobalHarness = (rec) =>
  rec.prevRegistrations.length > 0 || Object.keys(rec.prev).some((rel) => rel.startsWith('hooks/'));

// Also migrates a pre-0.2.0 local install, which copied every skill and agent
// user-level: the recorded copies are pruned (record.js keeps any the user edited).
function installUserTrigger(claudeDir = userClaudeDir, src = TRIGGER_SRC, skillsDir = path.join(packageDir, 'skills')) {
  const shippedSkills = fs.existsSync(skillsDir)
    ? fs.readdirSync(skillsDir).filter((name) => fs.existsSync(path.join(skillsDir, name, 'SKILL.md')))
    : [];
  const rec = openRecord(claudeDir, ['skills', 'agents']);
  if (hasGlobalHarness(rec)) {
    console.log(`[@civitas-cerebrum/achilles] ${claudeDir} holds a global install; no user-level routing skill written.`);
    return;
  }
  const dest = path.join(claudeDir, TRIGGER_REL);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  copyTracked(rec, src, dest);
  const pruned = pruneStale(rec, { quiet: true });
  writeRecord(rec);
  if (pruned > 0) {
    console.log(`[@civitas-cerebrum/achilles] Removed ${pruned} user-level skill and agent file${pruned === 1 ? '' : 's'} an earlier local install wrote; they now live in this project's .claude/.`);
  }
  // 0.1.8 kept no record, so its user-level copies cannot be told from the user's own; they
  // shadow the project's copies, so they are named.
  const shadowing = shippedSkills.filter((name) => !rec.next.files[`skills/${name}/SKILL.md`] && fs.existsSync(path.join(claudeDir, 'skills', name, 'SKILL.md')));
  if (shadowing.length > 0) {
    console.warn(`[@civitas-cerebrum/achilles] ${claudeDir}/skills holds ${shadowing.join(', ')}, not recorded as Achilles'. A user-level skill wins over this project's copy of the same name; delete them if an earlier Achilles install left them.`);
  }
}

module.exports = { installUserTrigger, TRIGGER_REL };
