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

// Install scope, decided by how npm was invoked:
//
//   npm install -g @civitas-cerebrum/achilles
//     GLOBAL: the whole harness lands in ~/.claude (hooks, settings.json
//     registrations, skills, agents, the staged mandate, the record). There is
//     no consumer project: projectRoot is npm's lib/, which never receives a
//     .claude/ tree.
//
//   npm install @civitas-cerebrum/achilles          (no -g)
//     LOCAL: everything lands in <project>/.claude except one routing skill,
//     ~/.claude/skills/achilles (user-trigger.js), so a test request in any
//     project finds Achilles and, where it is not installed, says how to get it.
//
// Either way the hooks enforce nothing outside an achilles-activated session
// (hooks/lib/achilles-activation.sh).
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

// Skills and agent definitions follow the harness.
const methodologyDestinations = (sub) => [path.join(harnessClaudeDir, sub)];

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
