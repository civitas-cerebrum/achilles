const fs   = require('fs');
const path = require('path');
const { packageDir, agentDestinations } = require('./context.js');
const { openRecord, copyTracked, pruneStale, writeRecord } = require('./record.js');

// Agent definitions (agents/<role>.md): Claude Code resolves a typed
// `subagent_type: <role>` only when <claudeDir>/agents/<role>.md exists. Same
// scoping as skills. Files are copied by content and recorded (record.js). The
// marker line build-agents.mjs stamps in every shipped file tells a same-named
// file of the user's, which is skipped with a warning, from one of ours.
const AGENT_MARKER = '<!-- installed-by: @civitas-cerebrum/achilles -->';

function installCivitasAgents(dests = agentDestinations, srcDir = path.join(packageDir, 'agents')) {
  const result = { installed: 0, skipped: [] };
  if (!fs.existsSync(srcDir)) return result;
  const shipped = fs.readdirSync(srcDir).filter(f => f.endsWith('.md'));
  for (const dest of dests) {
    try {
      fs.mkdirSync(dest, { recursive: true });
      const rec = openRecord(path.dirname(dest), ['agents']);
      for (const file of shipped) {
        const target = path.join(dest, file);
        const unrecorded = !rec.prev[path.relative(rec.claudeDir, target)];
        if (unrecorded && fs.existsSync(target) && !fs.readFileSync(target, 'utf8').includes(AGENT_MARKER)) {
          result.skipped.push(target);
          console.warn(`[@civitas-cerebrum/achilles] ${target} is not managed by achilles — left untouched; \`subagent_type: ${file.slice(0, -3)}\` resolves to your file.`);
          continue;
        }
        copyTracked(rec, path.join(srcDir, file), target);
        result.installed++;
      }
      pruneStale(rec);
      writeRecord(rec);
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
