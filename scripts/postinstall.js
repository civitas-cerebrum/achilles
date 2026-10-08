#!/usr/bin/env node

const context = require('./install/context.js');

// Skip when running in the package's own repo (local dev `npm install`).
// The guard only fires when this file is executed directly via `node
// scripts/postinstall.js`. When require()'d (e.g. by scripts/sync-hooks.js
// for an in-repo dev sync), the guard is bypassed and the installers are
// exposed via module.exports for callers to invoke selectively.
if (require.main === module && !context.packageDir.includes('node_modules')) {
  process.exit(0);
}

const { installCivitasSkills } = require('./install/skills.js');
const { installCivitasAgents } = require('./install/agents.js');
const { installCivitasHooks }  = require('./install/hooks.js');
const { stageProjectMandate }  = require('./install/mandate.js');
const { installBundledJq }     = require('./install/jq.js');
const { installChromium }      = require('./install/chromium.js');

module.exports = {
  installCivitasSkills,
  installCivitasAgents,
  installCivitasHooks,
  stageProjectMandate,
  installBundledJq,
  installChromium,
  isGlobalInstall: context.isGlobalInstall,
  harnessClaudeDir: context.harnessClaudeDir,
  skillsDestinations: context.destinations,
  agentsDestinations: context.agentDestinations,
};

// Full postinstall runs only when this file is invoked directly. When
// require()'d, the caller picks which installers to run.
if (require.main === module) {
  (async () => {
    console.log(`[@civitas-cerebrum/achilles] ${context.globalInstall
      ? 'Global install (-g): harness → ~/.claude (system-wide), methodology → user-level skills.'
      : `Local install: harness → ${context.harnessClaudeDir} (this project only), methodology → project + user-level skills.`}`);

    try {
      installCivitasSkills();
    } catch (err) {
      console.warn(`[@civitas-cerebrum/achilles] Could not install skills: ${err.message}`);
    }

    try {
      installCivitasAgents();
    } catch (err) {
      console.warn(`[@civitas-cerebrum/achilles] Could not install agent definitions: ${err.message}`);
    }

    try {
      await installBundledJq(context.harnessClaudeDir);
    } catch (err) {
      console.warn(`[civitas-cerebrum] Could not install bundled jq: ${err.message}`);
      process.exitCode = 1;
    }

    try {
      installCivitasHooks(context.harnessClaudeDir);
    } catch (err) {
      console.warn(`[civitas-cerebrum] Could not install harness hooks: ${err.message}`);
    }

    try {
      stageProjectMandate();
    } catch (err) {
      console.warn(`[civitas-cerebrum] Could not stage the QA role manifest: ${err.message}`);
    }

    try {
      installChromium();
    } catch (err) {
      console.warn(`[@civitas-cerebrum/achilles] Could not install chromium: ${err.message}`);
      process.exitCode = 1;
    }
  })();
}
