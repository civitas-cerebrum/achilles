#!/usr/bin/env node
// harness-atelier.mjs — visualize agentic-harness context flows.
//
// Reads the telemetry the collector hook records
// (<project>/.achilles/atelier-telemetry.jsonl — one JSON line per
// context transfer: dispatch briefs DOWN, subagent returns UP, per-context
// Bash activity, leak events) plus the schema-guard calibration log and
// the agentic-OS process table, and renders a self-contained HTML report:
//
//   - context-use per agent/subagent (brief bytes in, return bytes out,
//     Bash bytes pulled into each context)
//   - the context-transfer map (orchestrator ↔ subagents, edge width ∝
//     bytes; leaking edges highlighted)
//   - the leak panel: every leak event with its channel, evidence, and
//     the exact telemetry line it came from — where the leak happened
//   - effectiveness metrics: return/brief compression, return-schema
//     validity, orchestrator ingest volume
//
// Zero dependencies. Usage:
//   node scripts/atelier/harness-atelier.mjs [--project <dir>] [--out <file>] [--json]
//
// --json prints the aggregate to stdout (CI / assertions) and skips HTML.
//
// Canonical reference:
//   skills/element-interactions/references/harness-atelier.md

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
let project = process.cwd();
let outFile = null;
let asJson = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--project') project = resolve(args[++i] ?? '.');
  else if (args[i] === '--out') outFile = resolve(args[++i] ?? '');
  else if (args[i] === '--json') asJson = true;
  else if (args[i] === '--help' || args[i] === '-h') {
    console.log('usage: harness-atelier.mjs [--project <dir>] [--out <file>] [--json]');
    process.exit(0);
  } else {
    console.error(`unknown argument: ${args[i]}`);
    process.exit(1);
  }
}
if (!outFile) outFile = join(project, '.achilles', 'harness-atelier.html');

const TELEMETRY = join(project, '.achilles', 'atelier-telemetry.jsonl');
const SCHEMA_LOG = join(project, '.achilles', 'schema-guard-log.jsonl');
const PROCESS_TABLE = join(project, '.achilles', '.agent-process-table.json');

function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  const lines = readFileSync(path, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    try { out.push({ line: i + 1, ...JSON.parse(line) }); } catch { /* skip corrupt line */ }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Aggregate
// ---------------------------------------------------------------------------
const events = readJsonl(TELEMETRY);
const schemaLog = readJsonl(SCHEMA_LOG);

// Agents: pair dispatch + return by tool_use_id.
const agents = new Map();
function agent(id) {
  if (!agents.has(id)) {
    agents.set(id, { tool_use_id: id, role: 'unconfined', description: '',
      brief_bytes: 0, return_bytes: 0, dispatched: false, returned: false, leak: null });
  }
  return agents.get(id);
}
// Per-context Bash activity (actor = orchestrator | agent_id).
const contexts = new Map();
function context(actor, role) {
  if (!contexts.has(actor)) contexts.set(actor, { actor, role, commands: 0, bytes_out: 0 });
  const c = contexts.get(actor);
  if (role && role !== 'unconfined') c.role = role;
  return c;
}

const leaks = [];
let nestedDispatches = 0;

for (const ev of events) {
  if (ev.event === 'dispatch') {
    const a = agent(ev.tool_use_id || `dispatch@${ev.line}`);
    a.role = ev.dispatch_role || a.role;
    a.description = ev.description || a.description;
    a.brief_bytes += ev.brief_bytes || 0;
    a.dispatched = true;
    if (ev.actor && ev.actor !== 'orchestrator') nestedDispatches++;
  } else if (ev.event === 'return') {
    const a = agent(ev.tool_use_id || `return@${ev.line}`);
    a.role = ev.dispatch_role || a.role;
    a.description = a.description || ev.description || '';
    a.return_bytes += ev.return_bytes || 0;
    a.returned = true;
    if (ev.leak) a.leak = ev.leak;
  } else if (ev.event === 'command') {
    const c = context(ev.actor || 'orchestrator', ev.role);
    c.commands++;
    c.bytes_out += ev.bytes_out || 0;
  }
  if (ev.leak) {
    leaks.push({ line: ev.line, ts: ev.ts, event: ev.event, actor: ev.actor,
      role: ev.role, channel: ev.leak.channel, evidence: ev.leak.evidence,
      ref: ev.tool_use_id || ev.command_head || '' });
  }
}

const agentList = [...agents.values()];
const paired = agentList.filter(a => a.dispatched && a.returned && a.brief_bytes > 0);
const totalBrief = agentList.reduce((s, a) => s + a.brief_bytes, 0);
const totalReturn = agentList.reduce((s, a) => s + a.return_bytes, 0);
const ratios = paired.map(a => a.return_bytes / a.brief_bytes).sort((x, y) => x - y);
const medianRatio = ratios.length ? ratios[Math.floor(ratios.length / 2)] : null;

const schemaByRole = new Map();
for (const s of schemaLog) {
  const k = s.role || 'unknown';
  if (!schemaByRole.has(k)) schemaByRole.set(k, { role: k, valid: 0, invalid: 0 });
  schemaByRole.get(k)[s.valid ? 'valid' : 'invalid']++;
}

let processTable = {};
try {
  if (existsSync(PROCESS_TABLE)) processTable = JSON.parse(readFileSync(PROCESS_TABLE, 'utf8'));
} catch { /* malformed table — report without it */ }

const orch = contexts.get('orchestrator') || { actor: 'orchestrator', role: 'orchestrator', commands: 0, bytes_out: 0 };

const summary = {
  project,
  telemetry_file: TELEMETRY,
  events: events.length,
  agents: agentList.length,
  dispatches: agentList.filter(a => a.dispatched).length,
  returns: agentList.filter(a => a.returned).length,
  nested_dispatches: nestedDispatches,
  total_brief_bytes: totalBrief,
  total_return_bytes: totalReturn,
  orchestrator_bash_ingest_bytes: orch.bytes_out,
  median_return_to_brief_ratio: medianRatio,
  leaks: leaks.length,
  leak_channels: leaks.reduce((m, l) => ((m[l.channel] = (m[l.channel] || 0) + 1), m), {}),
  schema_validity: [...schemaByRole.values()],
  process_table_entries: Object.keys(processTable).length,
  agents_detail: agentList,
  contexts: [...contexts.values()],
  leaks_detail: leaks,
};

if (asJson) {
  console.log(JSON.stringify(summary, null, 2));
  process.exit(0);
}

// ---------------------------------------------------------------------------
// HTML report
// ---------------------------------------------------------------------------
const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const kb = n => n >= 1024 ? `${(n / 1024).toFixed(1)} KiB` : `${n} B`;

// Flow map: orchestrator on the left, one node per agent on the right,
// a down-edge (brief) and an up-edge (return) per agent; edge width ∝
// sqrt(bytes); returns that leaked render red.
const ROW = 46, TOP = 30;
const flowAgents = agentList.slice(0, 40);
const svgH = Math.max(120, TOP + flowAgents.length * ROW + 20);
const maxBytes = Math.max(1, ...flowAgents.flatMap(a => [a.brief_bytes, a.return_bytes]));
const w = b => Math.max(1.2, 14 * Math.sqrt(b / maxBytes));
let svg = `<svg viewBox="0 0 860 ${svgH}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="context transfer map">`;
const orchY = svgH / 2;
svg += `<rect x="20" y="${orchY - 26}" width="170" height="52" rx="8" class="node orch"/>` +
  `<text x="105" y="${orchY - 4}" class="nlabel">orchestrator</text>` +
  `<text x="105" y="${orchY + 14}" class="nsub">${esc(kb(orch.bytes_out))} bash ingest</text>`;
flowAgents.forEach((a, i) => {
  const y = TOP + i * ROW + ROW / 2;
  const leakUp = !!a.leak;
  svg += `<path d="M 190 ${orchY - 6} C 380 ${orchY - 6}, 420 ${y - 6}, 610 ${y - 6}" class="edge down" style="stroke-width:${w(a.brief_bytes)}"><title>brief → ${esc(a.role)}: ${esc(kb(a.brief_bytes))}</title></path>`;
  if (a.returned) {
    svg += `<path d="M 610 ${y + 6} C 420 ${y + 6}, 380 ${orchY + 6}, 190 ${orchY + 6}" class="edge up${leakUp ? ' leak' : ''}" style="stroke-width:${w(a.return_bytes)}"><title>return ← ${esc(a.role)}: ${esc(kb(a.return_bytes))}${leakUp ? ` — LEAK (${esc(a.leak.channel)})` : ''}</title></path>`;
  }
  svg += `<rect x="610" y="${y - 18}" width="230" height="36" rx="6" class="node${leakUp ? ' leaknode' : ''}"/>` +
    `<text x="725" y="${y - 2}" class="nlabel small">${esc(a.role)}</text>` +
    `<text x="725" y="${y + 12}" class="nsub">${esc(kb(a.brief_bytes))} ↓ · ${esc(kb(a.return_bytes))} ↑</text>`;
});
svg += '</svg>';

const tiles = [
  ['agents dispatched', String(summary.dispatches)],
  ['brief bytes ↓', kb(totalBrief)],
  ['return bytes ↑', kb(totalReturn)],
  ['median return/brief', medianRatio == null ? '—' : medianRatio.toFixed(2)],
  ['orchestrator bash ingest', kb(orch.bytes_out)],
  ['leaks', String(leaks.length)],
].map(([k, v]) => `<div class="tile${k === 'leaks' && leaks.length ? ' bad' : ''}"><div class="v">${esc(v)}</div><div class="k">${esc(k)}</div></div>`).join('');

const agentRows = agentList.map(a => `<tr${a.leak ? ' class="leakrow"' : ''}>` +
  `<td><code>${esc(a.role)}</code></td><td>${esc(a.description)}</td>` +
  `<td class="num">${esc(kb(a.brief_bytes))}</td><td class="num">${esc(kb(a.return_bytes))}</td>` +
  `<td class="num">${a.brief_bytes ? (a.return_bytes / a.brief_bytes).toFixed(2) : '—'}</td>` +
  `<td>${a.leak ? `<span class="pill">${esc(a.leak.channel)}</span>` : ''}</td></tr>`).join('');

const ctxRows = [...contexts.values()].map(c => `<tr><td><code>${esc(c.actor)}</code></td>` +
  `<td><code>${esc(c.role)}</code></td><td class="num">${c.commands}</td><td class="num">${esc(kb(c.bytes_out))}</td></tr>`).join('');

const leakItems = leaks.map(l => `<li><span class="pill">${esc(l.channel)}</span> ` +
  `<strong>${esc(l.event)}</strong> by <code>${esc(l.actor)}</code> (role <code>${esc(l.role)}</code>) — ${esc(l.evidence)}<br>` +
  `<span class="where">where: ${esc(TELEMETRY)}:${l.line}${l.ref ? ` · ref <code>${esc(l.ref)}</code>` : ''} · ${esc(l.ts || '')}</span></li>`).join('');

const schemaRows = [...schemaByRole.values()].map(s => {
  const total = s.valid + s.invalid;
  return `<tr><td><code>${esc(s.role)}</code></td><td class="num">${s.valid}</td><td class="num">${s.invalid}</td>` +
    `<td class="num">${total ? Math.round((100 * s.valid) / total) : 0}%</td></tr>`;
}).join('');

const html = `<!doctype html>
<meta charset="utf-8">
<title>harness-atelier — ${esc(project)}</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif; margin: 2rem auto; max-width: 960px; padding: 0 1rem; }
  h1 { font-size: 1.4rem; } h1 small { font-weight: 400; opacity: .6; font-size: .85rem; }
  h2 { font-size: 1.05rem; margin-top: 2rem; border-bottom: 1px solid rgba(127,127,127,.35); padding-bottom: .3rem; }
  .tiles { display: flex; flex-wrap: wrap; gap: .6rem; }
  .tile { border: 1px solid rgba(127,127,127,.35); border-radius: 8px; padding: .6rem .9rem; min-width: 8.5rem; }
  .tile .v { font-size: 1.25rem; font-weight: 600; } .tile .k { opacity: .65; font-size: .78rem; }
  .tile.bad { border-color: #d33; } .tile.bad .v { color: #d33; }
  table { border-collapse: collapse; width: 100%; font-size: .85rem; }
  th, td { text-align: left; padding: .35rem .5rem; border-bottom: 1px solid rgba(127,127,127,.22); vertical-align: top; }
  td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
  tr.leakrow td { background: rgba(221,51,51,.08); }
  .pill { background: #d33; color: #fff; border-radius: 999px; padding: .05rem .55rem; font-size: .72rem; }
  .node { fill: rgba(127,127,127,.12); stroke: rgba(127,127,127,.5); }
  .node.orch { stroke-width: 1.5; } .node.leaknode { stroke: #d33; }
  .nlabel { text-anchor: middle; font-size: 13px; font-weight: 600; fill: currentColor; }
  .nlabel.small { font-size: 11.5px; } .nsub { text-anchor: middle; font-size: 10px; opacity: .65; fill: currentColor; }
  .edge { fill: none; stroke: rgba(90,140,220,.55); } .edge.up { stroke: rgba(90,190,120,.6); }
  .edge.leak { stroke: rgba(221,51,51,.75); }
  .where { opacity: .65; font-size: .78rem; }
  li { margin-bottom: .55rem; }
  .empty { opacity: .6; font-style: italic; }
</style>
<h1>harness-atelier <small>${esc(project)} · ${esc(new Date().toISOString())}</small></h1>
<div class="tiles">${tiles}</div>
<h2>Context-transfer map</h2>
${flowAgents.length ? svg : '<p class="empty">no dispatches recorded yet — run the harness with the atelier collector installed.</p>'}
<h2>Agents — context use</h2>
${agentRows ? `<table><tr><th>role</th><th>dispatch</th><th class="num">brief ↓</th><th class="num">return ↑</th><th class="num">ratio</th><th>leak</th></tr>${agentRows}</table>` : '<p class="empty">none recorded.</p>'}
<h2>Execution contexts — Bash activity</h2>
${ctxRows ? `<table><tr><th>context</th><th>role</th><th class="num">commands</th><th class="num">stdout bytes ingested</th></tr>${ctxRows}</table>` : '<p class="empty">none recorded.</p>'}
<h2>Leak panel — where exactly</h2>
${leakItems ? `<ol>${leakItems}</ol>` : '<p class="empty">no leaks detected. The orchestrator window stayed clean.</p>'}
<h2>Return-schema validity</h2>
${schemaRows ? `<table><tr><th>role</th><th class="num">valid</th><th class="num">invalid</th><th class="num">rate</th></tr>${schemaRows}</table>` : '<p class="empty">no schema-guard log found.</p>'}
`;

mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, html);
console.log(`harness-atelier: ${events.length} events, ${summary.dispatches} dispatches, ${leaks.length} leak(s) → ${outFile}`);
