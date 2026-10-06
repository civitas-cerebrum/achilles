#!/usr/bin/env node
// build-agents.mjs — renders agents/<role>.md, one Claude Code agent definition
// per QA-mandate role, from the manifest (tool grants, read/write scope) and
// the workflow table (role description). Claude Code only resolves
// `subagent_type: <role>` when such a file is installed; postinstall ships them.
//   node scripts/build-agents.mjs           write agents/*.md
//   node scripts/build-agents.mjs --check   exit 1 on any missing, stale or orphan file
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const MANDATE = 'hooks/data/achilles-qa.kernel-mandate.json';
const WORKFLOW = 'hooks/data/achilles-qa.workflow.json';
const LEDGER = 'hooks/data/achilles-qa.kernel-mandate.md';
const AGENTS = path.join(root, 'agents');
// Ownership marker: postinstall prunes/overwrites only files that carry it.
export const AGENT_MARKER = '<!-- installed-by: @civitas-cerebrum/achilles -->';

const readJson = (p) => JSON.parse(readFileSync(path.join(root, p), 'utf8'));
const list = (a) => (a?.length ? a.map((x) => `\`${x}\``).join(', ') : null);

export function renderAgents() {
  const mandate = readJson(MANDATE);
  const workflow = readJson(WORKFLOW);
  const main = mandate.settings.mainSessionRole;
  const out = new Map();
  for (const [role, m] of Object.entries(mandate.roles)) {
    if (role === main) continue;
    const desc = workflow.roles[role]?.description;
    if (!desc) throw new Error(`${role}: no description in ${WORKFLOW}`);
    const tools = m.tools?.allow ?? [];
    const reads = list(m.read?.allow);
    const writes = list(m.write?.allow);
    out.set(`${role}.md`, [
      '---',
      `name: ${role}`,
      `description: ${JSON.stringify(desc)}`,
      ...(tools.length ? [`tools: ${tools.join(', ')}`] : []),
      '---',
      '',
      `You are the \`${role}\` role of the achilles QA pipeline; the description above is your mandate.`,
      '',
      `- Reads: ${reads ? `${reads}.` : 'nothing beyond what your brief hands you.'}`,
      `- Writes: ${writes ? `only ${writes}.` : 'nothing.'}`,
      `- Your dispatch brief opens with the \`<<kernel-mandate-role: ${role}#<nonce>>>\` tag; follow it.`,
      `- The kernel refuses anything outside this scope; the full grant and refusals are in \`${LEDGER}\` under \`${role}\`.`,
      '',
      AGENT_MARKER,
      '',
    ].join('\n'));
  }
  return out;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const want = renderAgents();
  const have = existsSync(AGENTS) ? readdirSync(AGENTS).filter((f) => f.endsWith('.md')) : [];
  if (process.argv.includes('--check')) {
    const bad = [];
    for (const [f, text] of want) {
      if (!have.includes(f)) bad.push(`${f}: missing`);
      else if (readFileSync(path.join(AGENTS, f), 'utf8') !== text) bad.push(`${f}: stale`);
    }
    for (const f of have) if (!want.has(f)) bad.push(`${f}: no such role in ${MANDATE}`);
    if (bad.length) {
      console.error(`agents/ out of date (run node scripts/build-agents.mjs):\n  ${bad.join('\n  ')}`);
      process.exit(1);
    }
    console.log(`agents/ up to date (${want.size} roles)`);
  } else {
    mkdirSync(AGENTS, { recursive: true });
    for (const [f, text] of want) writeFileSync(path.join(AGENTS, f), text);
    for (const f of have) if (!want.has(f)) unlinkSync(path.join(AGENTS, f));
    console.log(`wrote ${want.size} agent definitions to agents/`);
  }
}
