const fs   = require('fs');
const path = require('path');
const os   = require('os');

// __dirname is `<package>/scripts/install/`.
const packageDir = path.resolve(__dirname, '..', '..');

// When installed as a dependency, __dirname is:
//   <project>/node_modules/@civitas-cerebrum/achilles/scripts/install
// so five levels up reaches the consumer's project root.
const projectRoot = path.resolve(__dirname, '..', '..', '..', '..', '..');

const homeDir = os.homedir();
const userClaudeDir = path.join(homeDir, '.claude');

// Install scope — decided by how npm was invoked:
//
//   npm install -g @civitas-cerebrum/achilles
//     → GLOBAL install. The harness (hooks + settings.json registrations +
//       bundled jq) lands system-wide under ~/.claude/, and the methodology
//       (skills) lands user-level under ~/.claude/skills/. There is no
//       consumer project in a global install — projectRoot resolves to npm's
//       own lib/ directory, which must never receive a .claude/ tree.
//
//   npm install @civitas-cerebrum/achilles          (no -g)
//     → LOCAL install. The harness lands in the CURRENT PROJECT ONLY
//       (<project>/.claude/hooks + <project>/.claude/settings.json), so the
//       hooks exist for sessions in this project and nowhere else. The
//       methodology is still installed system-wide as well (project +
//       user-level skills), because skills are inert instructions — they
//       activate only when invoked — while hooks are live processes that
//       belong to the scope that opted in.
//
// Either way the hooks themselves enforce nothing outside an
// achilles-activated session: every gate silent-allows until the achilles
// protocol activates in the session (see hooks/lib/achilles-activation.sh).
function isGlobalInstall() {
  // npm exports every config flag as npm_config_*; -g sets global=true.
  if (process.env.npm_config_global === 'true') return true;
  if (process.env.npm_config_global === 'false') return false;
  // Fallback for package managers that don't export the flag: a local
  // install has a consumer project (package.json) at projectRoot; a global
  // install's projectRoot is npm's lib/ dir, which has none.
  return packageDir.includes('node_modules') &&
    !fs.existsSync(path.join(projectRoot, 'package.json'));
}

const globalInstall = isGlobalInstall();

// Base .claude/ directory the HARNESS (hooks + settings + jq) installs into.
const harnessClaudeDir = globalInstall ? userClaudeDir : path.join(projectRoot, '.claude');

// Methodology (skills, agent definitions) destinations. Local installs write
// project-level (the correct version for this project) AND user-level
// (overwrites stale copies from older installs so outdated user-level files
// never take precedence). Global installs write user-level only — projectRoot
// is npm's lib/ dir.
const methodologyDestinations = (sub) => globalInstall
  ? [path.join(userClaudeDir, sub)]
  : [path.join(projectRoot, '.claude', sub), path.join(userClaudeDir, sub)];

module.exports = {
  packageDir,
  projectRoot,
  homeDir,
  userClaudeDir,
  isGlobalInstall,
  globalInstall,
  harnessClaudeDir,
  destinations: methodologyDestinations('skills'),
  agentDestinations: methodologyDestinations('agents'),
};
