const fs   = require('fs');
const path = require('path');
const { packageDir, agentDestinations } = require('./context.js');

// Agent definitions (agents/<role>.md): Claude Code resolves a typed
// `subagent_type: <role>` only when <claudeDir>/agents/<role>.md exists. Same
// scoping as skills. Ownership is the marker line build-agents.mjs stamps in
// every shipped file: only marked files are overwritten or pruned, and a
// same-named file without it is the user's own — skipped with a warning.
const AGENT_MARKER = '<!-- installed-by: @civitas-cerebrum/achilles -->';

function installCivitasAgents(dests = agentDestinations, srcDir = path.join(packageDir, 'agents')) {
  const result = { installed: 0, skipped: [], pruned: [] };
  if (!fs.existsSync(srcDir)) return result;
  const shipped = fs.readdirSync(srcDir).filter(f => f.endsWith('.md'));
  for (const dest of dests) {
    try {
      fs.mkdirSync(dest, { recursive: true });
      for (const file of shipped) {
        const target = path.join(dest, file);
        const body = fs.readFileSync(path.join(srcDir, file), 'utf8');
        const current = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : null;
        if (current !== null && !current.includes(AGENT_MARKER)) {
          result.skipped.push(target);
          console.warn(`[@civitas-cerebrum/achilles] ${target} is not managed by achilles — left untouched; \`subagent_type: ${file.slice(0, -3)}\` resolves to your file.`);
          continue;
        }
        if (current !== body) fs.writeFileSync(target, body);
        result.installed++;
      }
      for (const file of fs.readdirSync(dest)) {
        if (!file.endsWith('.md') || shipped.includes(file)) continue;
        const target = path.join(dest, file);
        if (fs.readFileSync(target, 'utf8').includes(AGENT_MARKER)) {
          fs.unlinkSync(target);
          result.pruned.push(target);
        }
      }
    } catch (err) {
      console.warn(`[@civitas-cerebrum/achilles] Could not install agent definitions to ${dest}: ${err.message}`);
    }
  }
  if (result.installed > 0) {
    console.log(`[@civitas-cerebrum/achilles] ✔ agent definitions installed to ${dests.length} location${dests.length > 1 ? 's' : ''} (${shipped.length} roles).`);
  }
  return result;
}

module.exports = { installCivitasAgents };
