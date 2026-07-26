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
let telemetryFile = null;
let asJson = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--project') project = resolve(args[++i] ?? '.');
  else if (args[i] === '--out') outFile = resolve(args[++i] ?? '');
  else if (args[i] === '--telemetry') telemetryFile = resolve(args[++i] ?? '');
  else if (args[i] === '--json') asJson = true;
  else if (args[i] === '--help' || args[i] === '-h') {
    console.log('usage: harness-atelier.mjs [--project <dir>] [--out <file>] [--telemetry <jsonl>] [--json]');
    console.log('harness-atelier is harness-agnostic: any agent that emits the documented');
    console.log('JSONL event schema can be visualized — point --telemetry at its log.');
    process.exit(0);
  } else {
    console.error(`unknown argument: ${args[i]}`);
    process.exit(1);
  }
}
if (!outFile) outFile = join(project, '.achilles', 'harness-atelier.html');

const TELEMETRY = telemetryFile ?? join(project, '.achilles', 'atelier-telemetry.jsonl');
const SCHEMA_LOG = join(project, '.achilles', 'schema-guard-log.jsonl');
const PROCESS_TABLE = join(project, '.achilles', '.agent-process-table.json');

function readJsonl(path) {
  if (!existsSync(path)) return { rows: [], skipped: 0 };
  const rows = [];
  let skipped = 0;
  const lines = readFileSync(path, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    try { rows.push({ line: i + 1, ...JSON.parse(line) }); } catch { skipped++; }
  }
  return { rows, skipped };
}

// Sizing: every *_bytes field in the telemetry is a character count (the
// collector measures string lengths; ≈ bytes for ASCII payloads). The unit
// that actually bounds an agent's window is TOKENS, so the report displays
// estimated tokens (chars ÷ 4) everywhere, with raw char counts alongside.
const CHARS_PER_TOKEN = 4;
const estTok = n => Math.round((n || 0) / CHARS_PER_TOKEN);

// ---------------------------------------------------------------------------
// Aggregate
// ---------------------------------------------------------------------------
const { rows: events, skipped: telemetrySkipped } = readJsonl(TELEMETRY);
const { rows: schemaLog, skipped: schemaSkipped } = readJsonl(SCHEMA_LOG);

// Agents: pair dispatch + return by tool_use_id.
const agents = new Map();
function agent(id) {
  if (!agents.has(id)) {
    agents.set(id, { tool_use_id: id, role: 'unconfined', description: '',
      brief_bytes: 0, return_bytes: 0, dispatched: false, returned: false, leak: null });
  }
  return agents.get(id);
}
// Per-context ingest (actor = orchestrator | agent_id). bytes_out is Bash
// stdout; tool_bytes_out is everything the generic tool events pulled in
// (Read/Grep/WebFetch/…); skill_bytes_out is instruction content Skill
// invocations injected. total_ingest_bytes sums the three.
const contexts = new Map();
function context(actor, role) {
  if (!contexts.has(actor)) {
    contexts.set(actor, { actor, role, commands: 0, bytes_out: 0,
      tool_calls: 0, tool_bytes_out: 0, skill_bytes_out: 0, total_ingest_bytes: 0 });
  }
  const c = contexts.get(actor);
  if (role && role !== 'unconfined') c.role = role;
  return c;
}

// What to do about each leak channel — attached to every leak so the panel
// is actionable, not just diagnostic.
const REMEDIATION = {
  'bash-ingest': 'Payload content was dumped straight into the orchestrator window. Dispatch a reader-role subagent to ingest this artifact and return a structured summary; keep the privilege guard on so the dump is denied while a pipeline is live.',
  'oversized-return': 'Bulk content flowed up instead of a summary. Tighten this role\'s return schema and brief template ("return the structured summary only"); raise ATELIER_RETURN_BUDGET only if the volume is genuinely required.',
  'pasted-source-return': 'The return pasted a large source block. Brief the role to reference file paths plus line ranges instead of pasting content, and keep code out of the return schema\'s fields.',
};
const REMEDIATION_DEFAULT = 'Tighten the dispatch brief, return schema, or role privileges at the cited event.';

const leaks = [];
let nestedDispatches = 0;
// Orchestrator-window accounting: briefs it authors and returns it ingests
// both occupy its window, alongside its own Bash/tool/skill ingest.
let orchBrief = 0, orchReturn = 0;
// Waste: the full size of each leaking transfer (return payload or dumped
// command stdout) — what the leak channels pushed into the window.
let leakedBytes = 0;

// Skill segments: a `skill` event marks the start of a segment for its
// actor; every later byte-bearing event by the same actor attributes to
// that skill until the next skill event. This is the "context consumed
// by which skill / stage" view, harness-agnostic.
const skills = new Map();
function skill(name) {
  if (!skills.has(name)) skills.set(name, { skill: name, invocations: 0, injected_bytes: 0, attributed_bytes: 0, dispatches: 0 });
  return skills.get(name);
}
const activeSkill = new Map(); // actor → skill name
const tools = new Map();       // tool  → {calls, bytes_out}
const tsList = [];

function attribute(actor, bytes) {
  const name = activeSkill.get(actor);
  if (name && bytes > 0) skill(name).attributed_bytes += bytes;
}

for (const ev of events) {
  if (ev.ts) { const t = Date.parse(ev.ts); if (!Number.isNaN(t)) tsList.push(t); }
  if (ev.event === 'dispatch') {
    const a = agent(ev.tool_use_id || `dispatch@${ev.line}`);
    a.role = ev.dispatch_role || a.role;
    a.description = ev.description || a.description;
    a.brief_bytes += ev.brief_bytes || 0;
    a.dispatched = true;
    if (ev.actor && ev.actor !== 'orchestrator') nestedDispatches++;
    else orchBrief += ev.brief_bytes || 0;
  } else if (ev.event === 'return') {
    const a = agent(ev.tool_use_id || `return@${ev.line}`);
    a.role = ev.dispatch_role || a.role;
    a.description = a.description || ev.description || '';
    a.return_bytes += ev.return_bytes || 0;
    a.returned = true;
    if (ev.leak) a.leak = ev.leak;
    if ((ev.actor || 'orchestrator') === 'orchestrator') orchReturn += ev.return_bytes || 0;
  } else if (ev.event === 'command') {
    const c = context(ev.actor || 'orchestrator', ev.role);
    c.commands++;
    c.bytes_out += ev.bytes_out || 0;
    attribute(ev.actor || 'orchestrator', ev.bytes_out || 0);
  } else if (ev.event === 'skill') {
    const name = ev.skill || '(unnamed)';
    const sk = skill(name);
    sk.invocations++;
    sk.injected_bytes += ev.bytes_out || 0;
    activeSkill.set(ev.actor || 'orchestrator', name);
    context(ev.actor || 'orchestrator', ev.role).skill_bytes_out += ev.bytes_out || 0;
  } else if (ev.event === 'tool') {
    const t = ev.tool || '(tool)';
    if (!tools.has(t)) tools.set(t, { tool: t, calls: 0, bytes_out: 0 });
    tools.get(t).calls++;
    tools.get(t).bytes_out += ev.bytes_out || 0;
    const c = context(ev.actor || 'orchestrator', ev.role);
    c.tool_calls++;
    c.tool_bytes_out += ev.bytes_out || 0;
    attribute(ev.actor || 'orchestrator', ev.bytes_out || 0);
  }
  if (ev.event === 'dispatch') {
    const actor = ev.actor || 'orchestrator';
    attribute(actor, ev.brief_bytes || 0);
    const name = activeSkill.get(actor);
    if (name) skill(name).dispatches++;
  }
  if (ev.event === 'return') attribute(ev.actor || 'orchestrator', ev.return_bytes || 0);
  if (ev.leak) {
    leakedBytes += ev.event === 'return' ? (ev.return_bytes || 0)
      : ev.event === 'command' ? (ev.bytes_out || 0) : 0;
    leaks.push({ line: ev.line, ts: ev.ts, event: ev.event, actor: ev.actor,
      role: ev.role, channel: ev.leak.channel, evidence: ev.leak.evidence,
      ref: ev.tool_use_id || ev.command_head || '',
      remediation: REMEDIATION[ev.leak.channel] || REMEDIATION_DEFAULT });
  }
}

for (const c of contexts.values()) {
  c.total_ingest_bytes = c.bytes_out + c.tool_bytes_out + c.skill_bytes_out;
}

const agentList = [...agents.values()];
const paired = agentList.filter(a => a.dispatched && a.returned && a.brief_bytes > 0);
const totalBrief = agentList.reduce((s, a) => s + a.brief_bytes, 0);
const totalReturn = agentList.reduce((s, a) => s + a.return_bytes, 0);
const ratios = paired.map(a => a.return_bytes / a.brief_bytes).sort((x, y) => x - y);
const medianRatio = ratios.length ? ratios[Math.floor(ratios.length / 2)] : null;

// Context impact by role — for a pipeline harness the roles ARE the
// stages (composer/reviewer/probe/... map to pipeline passes), so this
// doubles as the per-stage context-impact view.
const byRole = new Map();
for (const a of agentList) {
  if (!byRole.has(a.role)) byRole.set(a.role, { role: a.role, dispatches: 0, brief_bytes: 0, return_bytes: 0, leaks: 0 });
  const r = byRole.get(a.role);
  r.dispatches++;
  r.brief_bytes += a.brief_bytes;
  r.return_bytes += a.return_bytes;
  if (a.leak) r.leaks++;
}

// Session timing.
const sessionStart = tsList.length ? new Date(Math.min(...tsList)).toISOString() : null;
const sessionEnd = tsList.length ? new Date(Math.max(...tsList)).toISOString() : null;
const sessionSeconds = tsList.length ? Math.round((Math.max(...tsList) - Math.min(...tsList)) / 1000) : 0;

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

const orch = contexts.get('orchestrator') || { actor: 'orchestrator', role: 'orchestrator',
  commands: 0, bytes_out: 0, tool_calls: 0, tool_bytes_out: 0, skill_bytes_out: 0, total_ingest_bytes: 0 };

// The one budget the harness protects: everything that landed in the
// orchestrator's window (briefs it authored, returns it ingested, its own
// Bash stdout, tool ingest, and skill injections) — and how much of that
// was leak waste.
const orchWindowBytes = orchBrief + orchReturn + orch.bytes_out + orch.tool_bytes_out + orch.skill_bytes_out;
const wasteShare = orchWindowBytes ? leakedBytes / orchWindowBytes : null;

const worstReturns = agentList.filter(a => a.return_bytes > 0)
  .sort((a, b) => b.return_bytes - a.return_bytes).slice(0, 5)
  .map(a => ({ tool_use_id: a.tool_use_id, role: a.role, description: a.description,
    return_bytes: a.return_bytes, leak_channel: a.leak ? a.leak.channel : null }));
const worstIngest = [...contexts.values()].filter(c => c.total_ingest_bytes > 0)
  .sort((a, b) => b.total_ingest_bytes - a.total_ingest_bytes).slice(0, 5)
  .map(c => ({ actor: c.actor, role: c.role, total_ingest_bytes: c.total_ingest_bytes }));

const summary = {
  schema_version: 2,
  sizing: { unit: 'chars', chars_per_token_estimate: CHARS_PER_TOKEN },
  project,
  telemetry_file: TELEMETRY,
  telemetry_skipped_lines: telemetrySkipped,
  schema_log_skipped_lines: schemaSkipped,
  events: events.length,
  agents: agentList.length,
  dispatches: agentList.filter(a => a.dispatched).length,
  returns: agentList.filter(a => a.returned).length,
  nested_dispatches: nestedDispatches,
  total_brief_bytes: totalBrief,
  total_return_bytes: totalReturn,
  total_brief_tokens_est: estTok(totalBrief),
  total_return_tokens_est: estTok(totalReturn),
  orchestrator_bash_ingest_bytes: orch.bytes_out,
  orchestrator_total_ingest_bytes: orch.total_ingest_bytes,
  orchestrator_window_bytes: orchWindowBytes,
  orchestrator_window_tokens_est: estTok(orchWindowBytes),
  leaked_bytes: leakedBytes,
  leaked_tokens_est: estTok(leakedBytes),
  leak_waste_share: wasteShare,
  worst_offenders: { returns: worstReturns, ingest: worstIngest },
  median_return_to_brief_ratio: medianRatio,
  leaks: leaks.length,
  leak_channels: leaks.reduce((m, l) => ((m[l.channel] = (m[l.channel] || 0) + 1), m), {}),
  session: { start: sessionStart, end: sessionEnd, duration_seconds: sessionSeconds },
  skills: [...skills.values()],
  roles: [...byRole.values()],
  tools: [...tools.values()],
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
// Display sizes token-first (the unit that bounds a window), chars alongside.
const fmtTok = n => { const t = (n || 0) / CHARS_PER_TOKEN; return t >= 1000 ? `≈${(t / 1000).toFixed(1)}k tok` : `≈${Math.round(t)} tok`; };
const fmtChars = n => (n || 0) >= 1000 ? `${((n || 0) / 1000).toFixed(1)}k chars` : `${n || 0} chars`;
const szTitle = n => `${fmtTok(n)} (${fmtChars(n)})`;
const tdSz = n => `<td class="num" title="${esc(fmtChars(n))}">${esc(fmtTok(n))}</td>`;

// Flow map: orchestrator on the left, one node per agent on the right,
// a down-edge (brief) and an up-edge (return) per agent; edge width ∝
// sqrt(size); returns that leaked render red. Capped at the 40 largest
// agents by context volume — the cap is stated in the report, and the
// Agents table always lists everything.
const ROW = 46, TOP = 30;
const flowAgents = [...agentList]
  .sort((a, b) => (b.brief_bytes + b.return_bytes) - (a.brief_bytes + a.return_bytes))
  .slice(0, 40);
const flowCapNote = agentList.length > flowAgents.length
  ? `<p class="note">map shows the ${flowAgents.length} largest of ${agentList.length} agents by context volume — the Agents table lists all ${agentList.length}.</p>`
  : '';
const svgH = Math.max(120, TOP + flowAgents.length * ROW + 20);
const maxBytes = Math.max(1, ...flowAgents.flatMap(a => [a.brief_bytes, a.return_bytes]));
const w = b => Math.max(1.2, 14 * Math.sqrt(b / maxBytes));
let svg = `<svg viewBox="0 0 860 ${svgH}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="context transfer map">`;
const orchY = svgH / 2;
svg += `<rect x="20" y="${orchY - 26}" width="170" height="52" rx="8" class="node orch"/>` +
  `<text x="105" y="${orchY - 4}" class="nlabel">orchestrator</text>` +
  `<text x="105" y="${orchY + 14}" class="nsub">${esc(fmtTok(orch.total_ingest_bytes))} ingested</text>`;
flowAgents.forEach((a, i) => {
  const y = TOP + i * ROW + ROW / 2;
  const leakUp = !!a.leak;
  svg += `<path d="M 190 ${orchY - 6} C 380 ${orchY - 6}, 420 ${y - 6}, 610 ${y - 6}" class="edge down" style="stroke-width:${w(a.brief_bytes)}"><title>brief → ${esc(a.role)}: ${esc(szTitle(a.brief_bytes))}</title></path>`;
  if (a.returned) {
    svg += `<path d="M 610 ${y + 6} C 420 ${y + 6}, 380 ${orchY + 6}, 190 ${orchY + 6}" class="edge up${leakUp ? ' leak' : ''}" style="stroke-width:${w(a.return_bytes)}"><title>return ← ${esc(a.role)}: ${esc(szTitle(a.return_bytes))}${leakUp ? ` — LEAK (${esc(a.leak.channel)})` : ''}</title></path>`;
  }
  svg += `<rect x="610" y="${y - 18}" width="230" height="36" rx="6" class="node${leakUp ? ' leaknode' : ''}"/>` +
    `<text x="725" y="${y - 2}" class="nlabel small">${esc(a.role)}</text>` +
    `<text x="725" y="${y + 12}" class="nsub">${esc(fmtTok(a.brief_bytes))} ↓ · ${esc(fmtTok(a.return_bytes))} ↑</text>`;
});
svg += '</svg>';

const dur = sessionSeconds >= 3600 ? `${Math.floor(sessionSeconds / 3600)}h ${Math.floor((sessionSeconds % 3600) / 60)}m`
  : sessionSeconds >= 60 ? `${Math.floor(sessionSeconds / 60)}m ${sessionSeconds % 60}s` : `${sessionSeconds}s`;
const tiles = [
  ['session span', tsList.length ? dur : '—'],
  ['agents dispatched', String(summary.dispatches)],
  ['brief ↓ (est tokens)', fmtTok(totalBrief)],
  ['return ↑ (est tokens)', fmtTok(totalReturn)],
  ['median return/brief', medianRatio == null ? '—' : medianRatio.toFixed(2)],
  ['orchestrator ingest', fmtTok(orch.total_ingest_bytes)],
  ['leaks', String(leaks.length)],
].map(([k, v]) => `<div class="tile${k === 'leaks' && leaks.length ? ' bad' : ''}"><div class="v">${esc(v)}</div><div class="k">${esc(k)}</div></div>`).join('');

const budgetTiles = [
  ['orchestrator window (est tokens)', fmtTok(orchWindowBytes), false],
  ['leaked into window', fmtTok(leakedBytes), leakedBytes > 0],
  ['waste share', wasteShare == null ? '—' : `${(wasteShare * 100).toFixed(1)}%`, leakedBytes > 0],
].map(([k, v, bad]) => `<div class="tile${bad ? ' bad' : ''}"><div class="v">${esc(v)}</div><div class="k">${esc(k)}</div></div>`).join('');

const budgetRows = [
  ['briefs authored ↓', orchBrief],
  ['returns ingested ↑', orchReturn],
  ['bash stdout', orch.bytes_out],
  ['other-tool ingest', orch.tool_bytes_out],
  ['skill injections', orch.skill_bytes_out],
].map(([k, v]) => `<tr><td>${esc(k)}</td>${tdSz(v)}<td class="num">${orchWindowBytes ? Math.round((100 * v) / orchWindowBytes) : 0}%</td></tr>`).join('');

const offenderReturnRows = worstReturns.map(o => `<tr${o.leak_channel ? ' class="leakrow"' : ''}>` +
  `<td><code>${esc(o.role)}</code></td><td>${esc(o.description)}</td>${tdSz(o.return_bytes)}` +
  `<td>${o.leak_channel ? `<span class="pill">${esc(o.leak_channel)}</span>` : ''}</td></tr>`).join('');
const offenderIngestRows = worstIngest.map(o => `<tr><td><code>${esc(o.actor)}</code></td>` +
  `<td><code>${esc(o.role)}</code></td>${tdSz(o.total_ingest_bytes)}</tr>`).join('');

const agentRows = agentList.map(a => `<tr${a.leak ? ' class="leakrow"' : ''}>` +
  `<td><code>${esc(a.role)}</code></td><td>${esc(a.description)}</td>` +
  `${tdSz(a.brief_bytes)}${tdSz(a.return_bytes)}` +
  `<td class="num">${a.brief_bytes ? (a.return_bytes / a.brief_bytes).toFixed(2) : '—'}</td>` +
  `<td>${a.leak ? `<span class="pill">${esc(a.leak.channel)}</span>` : ''}</td></tr>`).join('');

const ctxRows = [...contexts.values()].map(c => `<tr><td><code>${esc(c.actor)}</code></td>` +
  `<td><code>${esc(c.role)}</code></td><td class="num">${c.commands}</td>${tdSz(c.bytes_out)}` +
  `<td class="num">${c.tool_calls}</td>${tdSz(c.tool_bytes_out)}${tdSz(c.skill_bytes_out)}${tdSz(c.total_ingest_bytes)}</tr>`).join('');

const skillRows = [...skills.values()].sort((a, b) => (b.injected_bytes + b.attributed_bytes) - (a.injected_bytes + a.attributed_bytes))
  .map(sk => `<tr><td><code>${esc(sk.skill)}</code></td><td class="num">${sk.invocations}</td>` +
    `${tdSz(sk.injected_bytes)}${tdSz(sk.attributed_bytes)}` +
    `<td class="num">${sk.dispatches}</td></tr>`).join('');

const roleRows = [...byRole.values()].sort((a, b) => b.brief_bytes - a.brief_bytes)
  .map(r => `<tr${r.leaks ? ' class="leakrow"' : ''}><td><code>${esc(r.role)}</code></td><td class="num">${r.dispatches}</td>` +
    `${tdSz(r.brief_bytes)}${tdSz(r.return_bytes)}` +
    `<td class="num">${r.brief_bytes ? (r.return_bytes / r.brief_bytes).toFixed(2) : '—'}</td><td class="num">${r.leaks}</td></tr>`).join('');

const toolRows = [...tools.values()].sort((a, b) => b.bytes_out - a.bytes_out)
  .map(t => `<tr><td><code>${esc(t.tool)}</code></td><td class="num">${t.calls}</td>${tdSz(t.bytes_out)}</tr>`).join('');

const leakItems = leaks.map(l => `<li><span class="pill">${esc(l.channel)}</span> ` +
  `<strong>${esc(l.event)}</strong> by <code>${esc(l.actor)}</code> (role <code>${esc(l.role)}</code>) — ${esc(l.evidence)}<br>` +
  `<span class="where">where: ${esc(TELEMETRY)}:${l.line}${l.ref ? ` · ref <code>${esc(l.ref)}</code>` : ''} · ${esc(l.ts || '')}</span>` +
  `<span class="fix">fix: ${esc(l.remediation)}</span></li>`).join('');

const skippedNote = telemetrySkipped
  ? `<p class="warn">⚠ ${telemetrySkipped} malformed telemetry line(s) skipped — every count below is an undercount until the log is repaired.</p>`
  : '';

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
  .fix { display: block; opacity: .8; font-size: .78rem; margin-top: .15rem; }
  .note { opacity: .65; font-size: .8rem; }
  .warn { color: #d33; font-weight: 600; }
  li { margin-bottom: .55rem; }
  .empty { opacity: .6; font-style: italic; }
</style>
<h1>harness-atelier <small>${esc(project)}${sessionStart ? ` · session ${esc(sessionStart)} → ${esc(sessionEnd)}` : ''}</small></h1>
<p class="note">sizes are recorded as character counts and shown as estimated tokens (chars ÷ ${CHARS_PER_TOKEN}) — tokens are the unit that actually bounds an agent's window; hover any size for the raw chars.</p>
${skippedNote}
<div class="tiles">${tiles}</div>
<h2>Context budget &amp; waste</h2>
<div class="tiles">${budgetTiles}</div>
<table><tr><th>orchestrator window source</th><th class="num">size</th><th class="num">share</th></tr>${budgetRows}</table>
<h3>Worst offenders — returns</h3>
${offenderReturnRows ? `<table><tr><th>role</th><th>dispatch</th><th class="num">return ↑</th><th>leak</th></tr>${offenderReturnRows}</table>` : '<p class="empty">no returns recorded.</p>'}
<h3>Worst offenders — context ingest</h3>
${offenderIngestRows ? `<table><tr><th>context</th><th>role</th><th class="num">total ingest</th></tr>${offenderIngestRows}</table>` : '<p class="empty">no ingest recorded.</p>'}
<h2>Context-transfer map</h2>
${flowAgents.length ? svg + flowCapNote : '<p class="empty">no dispatches recorded yet — run the harness with the atelier collector installed.</p>'}
<h2>Agents — context use</h2>
${agentRows ? `<table><tr><th>role</th><th>dispatch</th><th class="num">brief ↓</th><th class="num">return ↑</th><th class="num">ratio</th><th>leak</th></tr>${agentRows}</table>` : '<p class="empty">none recorded.</p>'}
<h2>Execution contexts — per-actor ingest</h2>
${ctxRows ? `<table><tr><th>context</th><th>role</th><th class="num">commands</th><th class="num">bash ingest</th><th class="num">tool calls</th><th class="num">tool ingest</th><th class="num">skill inject</th><th class="num">total ingest</th></tr>${ctxRows}</table>` : '<p class="empty">none recorded.</p>'}
<h2>Context by skill</h2>
${skillRows ? `<table><tr><th>skill</th><th class="num">invocations</th><th class="num">injected</th><th class="num">attributed</th><th class="num">dispatches</th></tr>${skillRows}</table>` : '<p class="empty">no skill events recorded — the collector tags Skill-tool invocations automatically.</p>'}
<h2>Context impact by role (pipeline stage)</h2>
${roleRows ? `<table><tr><th>role / stage</th><th class="num">dispatches</th><th class="num">brief ↓</th><th class="num">return ↑</th><th class="num">ratio</th><th class="num">leaks</th></tr>${roleRows}</table>` : '<p class="empty">none recorded.</p>'}
<h2>Tool mix — context ingestion by tool</h2>
${toolRows ? `<table><tr><th>tool</th><th class="num">calls</th><th class="num">ingested</th></tr>${toolRows}</table>` : '<p class="empty">no generic tool events recorded.</p>'}
<h2>Leak panel — where exactly</h2>
${leakItems ? `<ol>${leakItems}</ol>` : '<p class="empty">no leaks detected. The orchestrator window stayed clean.</p>'}
<h2>Return-schema validity</h2>
${schemaRows ? `<table><tr><th>role</th><th class="num">valid</th><th class="num">invalid</th><th class="num">rate</th></tr>${schemaRows}</table>` : '<p class="empty">no schema-guard log found.</p>'}
`;

mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, html);
console.log(`harness-atelier: ${events.length} events, ${summary.dispatches} dispatches, ${leaks.length} leak(s)${telemetrySkipped ? `, ${telemetrySkipped} malformed line(s) skipped` : ''} → ${outFile}`);
