// pi/extensions/achilles/agent-tool.ts
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Type } from 'typebox';
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';
import { resolveSkill, parseSections, findSection } from './skills.ts';
import { log } from './log.ts';
import { piDepth } from './env.ts';
import { shadowPath } from './transcript.ts';

const LEGACY_CAP = 16 * 1024;
/** Model-facing bytes per subagent return. A real 8-phase run kept 23 returns, 118,319 chars, mean
 * 5,144 under the old 8,192 cap: a third of a 32k window on text whose verdict is one line. The full
 * return stays on disk under .achilles/pi-agent-returns/ and in the tool details. */
const DEFAULT_RESULT_CAP = 3072;
const KILL_GRACE_MS = 5000;
/** Like Claude Code: subagents can load skills but cannot dispatch further subagents (the depth
 * cap stays as a backstop). The allowlist applies to extension tools too. */
const CHILD_TOOLS = 'read,bash,edit,write,grep,find,ls,Skill';

/** Appended to a child brief whose ROLE owes a handover. Children wrapped their handover JSON in
 * ```json fences plus prose, which is what the return-schema guard reported as PARSE_FAIL (9 of 17
 * Agent returns in one measured run) — and prose around the object is the part the orchestrator's
 * result drops anyway.
 *
 * It is unconditional on purpose. A conditional wording ("if your final message is a handover JSON")
 * releases exactly the children that caused the PARSE_FAILs: one writing prose that CONTAINS a fenced
 * handover reads the antecedent as false. What must be conditional is WHICH children get the line —
 * see handoverLine(). An unconditional line sent to a child with nothing to hand over (live check 04:
 * "run echo hi and reply OK") made it go hunting for the return schema instead of finishing. */
export const BARE_HANDOVER_LINE = 'Return the bare handover JSON as your final message: no code fence, no prose before or after.';

/**
 * Role prefixes whose returns the schema guard validates — the mirror of resolve_schema_role in
 * hooks/lib/schema-role-map.sh, restricted to the cases that yield a non-empty schema role. A prefix
 * that maps to "" there (process-validator-, phase1-, stage2-, cleanup-, companion-, fd-) takes the
 * envelope-sanity path only and is NOT owed a handover object, and an unknown prefix owes nothing at
 * all. pi/tests/agent-tool.test.mjs sources the shell file and fails if this list drifts from it.
 */
export const SCHEMA_VALIDATED_ROLES = [
  // `test-composer-` is the kernel-mandate spelling of the composer role and needs its own entry:
  // owesHandover() matches with startsWith, so `composer-` does not cover `test-composer-j-<slug>:`
  // — exactly as the shell's `composer-*` case glob does not cover it either.
  'perf-reviewer-', 'workflow-reviewer-', 'test-composer-', 'composer-', 'reviewer-',
  'composition-judge-', 'probe-', 'repair-worker-', 'phase-validator-',
  'phase4-prioritise-author', 'phase4-cycle-',
] as const;

/** True when a dispatch role's return is schema-validated, so the child owes a bare handover JSON. */
export function owesHandover(role: string): boolean {
  const r = role.trim();
  return SCHEMA_VALIDATED_ROLES.some((p) => r.startsWith(p));
}

/** The formatting line for a child brief: the imperative for a role that owes a handover, else "". */
export function handoverLine(role: string): string {
  return owesHandover(role) ? BARE_HANDOVER_LINE : '';
}

/** This extension's entry point, passed to every child with `-e` so the gates run inside it even
 * when the parent loaded the extension with `-e` rather than from settings. pi de-duplicates an
 * extension that is both in settings and passed with `-e` (verified: one session_start per process). */
const EXTENSION_ENTRY = path.join(path.dirname(fileURLToPath(import.meta.url)), 'index.ts');

export interface AgentToolOptions {
  roots: string[];
  stateDir?: string;
  maxDepth?: number;
  maxConcurrent?: number;
  invocation?: (args: string[]) => { command: string; args: string[] };
}

/** Same resolution the pi subagent example uses: re-run the current pi script under the current runtime. */
function defaultInvocation(args: string[]): { command: string; args: string[] } {
  const script = process.argv[1];
  if (script && fs.existsSync(script)) return { command: process.execPath, args: [script, ...args] };
  return { command: 'pi', args };
}

function parentActive(stateDir: string, sessionId: string): boolean {
  if (/^(1|true|on|active)$/i.test(process.env.ACHILLES_PROTOCOL ?? '')) return true;
  return fs.existsSync(path.join(stateDir, `${sessionId}.active`));
}

/** The child's agent_type for the hook payloads: `subagent_type` when given, otherwise the role
 * prefix of `description` (text before the first `:`), or the whole description when it has none. */
export function agentType(params: { description: string; subagent_type?: string }): string {
  const explicit = params.subagent_type?.trim();
  if (explicit) return explicit;
  const i = params.description.indexOf(':');
  return (i >= 0 ? params.description.slice(0, i) : params.description).trim();
}

/**
 * The forms of a dispatch ROLE to look for in the dispatched skill's headings, longest first.
 *
 * The methodology writes a per-role heading whenever a role has its own contract, and it writes the
 * role prefix into the heading verbatim: workflow-reviewer has 18 of them ("Phase 5 —
 * Coverage-expansion (`workflow-reviewer-phase5`)"), journey-mapping has "Per-section-agent contract
 * (`phase4-cycle-<N>-section-<id>:`)". So the variable parts have to be put back before the lookup:
 *  - a digit run at the end of any segment BUT THE FIRST becomes `<N>` — `pass12` → `pass<N>`,
 *    `cycle-1` → `cycle-<N>`, while `phase4` stays `phase4` because that is a literal name here;
 *  - then the role is truncated segment by segment, keeping the trailing hyphen, so a per-instance
 *    role ("phase4-cycle-1-section-checkout") reaches the contract written for the family
 *    ("phase4-cycle-<N>-section-<id>").
 */
export function roleForms(role: string): string[] {
  const r = role.trim();
  if (r.length < 6 || !r.includes('-')) return [];
  const out = [r];
  const gen = r.split('-').map((seg, i) => (i === 0 ? seg : seg.replace(/(\D*?)\d+$/, '$1<N>'))).join('-');
  if (gen !== r) out.push(gen);
  let t = gen;
  for (;;) {
    const i = t.lastIndexOf('-');
    if (i <= 0) break;
    t = t.slice(0, i + 1);
    if (t.length < 8 || !t.slice(0, -1).includes('-')) break;
    out.push(t);
    t = t.slice(0, -1);
  }
  return [...new Set(out)];
}

/**
 * The section of `body` a dispatch with this role should start from, when the SKILL'S OWN TEXT names
 * that role in a heading — round 4 wired `Agent { section }` and nothing ever passed it.
 *
 * Reading the body here costs no orchestrator context: this runs in the extension, in node, and the
 * orchestrator's model never sees a byte of it. Only an unambiguous resolution counts, and the matched
 * heading must actually contain the role token, so a query that resolved through some other route in
 * findSection (a table-of-contents number, a `parent > child` path) is rejected rather than guessed at.
 * Measured over 25 plausible role prefixes x all 24 skills: 8 resolutions, all of them a heading in
 * which the skill prints that very prefix, and no other match at all.
 */
export function roleSection(body: string, role: string): string | undefined {
  const sections = parseSections(body.trim());
  for (const q of roleForms(role)) {
    const { section } = findSection(sections, q);
    if (section && section.heading.toLowerCase().includes(q.toLowerCase())) return section.heading;
  }
  return undefined;
}

/** The legacy model-facing cap, kept for ACHILLES_PI_VERBOSE=1 (the pre-compaction behaviour). */
function legacyCap(text: string): string {
  if (Buffer.byteLength(text, 'utf8') <= LEGACY_CAP) return text;
  return `${truncateBytes(text, LEGACY_CAP)}\n\n[achilles: output truncated for context; full text kept in tool details]`;
}

function truncateBytes(text: string, max: number): string {
  if (Buffer.byteLength(text, 'utf8') <= max) return text;
  // Slice by bytes and drop a trailing partial UTF-8 sequence (decoded as U+FFFD).
  return Buffer.from(text, 'utf8').subarray(0, max).toString('utf8').replace(/\uFFFD+$/, '');
}

/** ACHILLES_PI_AGENT_RESULT_CAP (bytes), default 3072; unparseable or non-positive values use the default. */
export function resultCap(): number {
  const n = Number(process.env.ACHILLES_PI_AGENT_RESULT_CAP);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : DEFAULT_RESULT_CAP;
}

export const verbose = (): boolean => process.env.ACHILLES_PI_VERBOSE === '1';

/** End index (exclusive) of the balanced JSON object starting at `start`, string-aware, or -1. */
function objectEnd(text: string, start: number): number {
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return i + 1; }
  }
  return -1;
}

/** The last JSON object in `text` with a top-level `handover` key (bare, fenced in ```json, or after
 * prose), with its source span; undefined when there is none. */
export function extractHandover(text: string): { obj: Record<string, unknown>; start: number; end: number } | undefined {
  let found: { obj: Record<string, unknown>; start: number; end: number } | undefined;
  let i = text.indexOf('{');
  for (let tries = 0; i >= 0 && tries < 500; tries++) {
    const end = objectEnd(text, i);
    let obj: unknown;
    // An unbalanced "{" in prose never closes from here, but a later one still may: try the next.
    if (end > 0) { try { obj = JSON.parse(text.slice(i, end)); } catch { obj = undefined; } }
    if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
      if (Object.prototype.hasOwnProperty.call(obj, 'handover')) found = { obj: obj as Record<string, unknown>, start: i, end };
      i = text.indexOf('{', end); // a parsed object's nested objects are not top-level candidates
    } else {
      i = text.indexOf('{', i + 1);
    }
  }
  return found;
}

export interface LeanResult {
  text: string;
  dropped: boolean;
  handover: boolean;
  truncated: boolean;
  /** Chars of prose (or fences) around the handover object that were left out. */
  proseChars: number;
  /** Long string / array values shortened inside the handover JSON to fit the cap. */
  shortened: number;
  /** Chars of plain (non-handover) text cut from the end. */
  cutChars: number;
}

const bytes = (t: string) => Buffer.byteLength(t, 'utf8');
/** Top-level scalars up to this size (verdict, status, phase, …) are never shortened. */
const KEEP_SCALAR = 200;

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

/** Top-level keys whose whole subtree is spared while anything else can still be shrunk: the handover
 * envelope and the caller's next move are the two things the orchestrator acts on. Spelling variants
 * are covered because different roles write the key differently. */
export const PROTECTED_KEYS: readonly string[] = ['handover', 'next-action', 'next_action', 'nextAction'];

/**
 * Shrink `obj` until its compact JSON fits `cap` bytes, keeping it valid JSON: repeatedly halve the
 * largest string or array value (by serialised size) anywhere in the tree, except short top-level
 * scalars and the subtrees of `protect`. A shortened string ends in "…[truncated]"; a shortened array
 * ends with a "…[N more items omitted]" entry. When everything else is already minimal and the JSON
 * still does not fit, a second pass drops the protection rather than returning over the cap.
 * Returns the JSON and how many values were shortened.
 */
export function shrinkJson(obj: Record<string, unknown>, cap: number, protect: readonly string[] = PROTECTED_KEYS): { json: string; shortened: number } {
  const root = JSON.parse(JSON.stringify(obj)) as { [k: string]: Json };
  let shortened = shrinkPass(root, cap, protect);
  let json = JSON.stringify(root);
  if (bytes(json) > cap && protect.length > 0) {
    shortened += shrinkPass(root, cap, []);
    json = JSON.stringify(root);
  }
  return { json, shortened };
}

/** One shrink loop over `root`, sparing `protect`'s subtrees; returns how many values it shortened. */
function shrinkPass(root: { [k: string]: Json }, cap: number, protect: readonly string[]): number {
  let json = JSON.stringify(root);
  let shortened = 0;
  for (let round = 0; bytes(json) > cap && round < 2000; round++) {
    // Find the largest shrinkable value.
    let best: { parent: Json[] | { [k: string]: Json }; key: string | number; size: number } | undefined;
    const visit = (parent: Json[] | { [k: string]: Json }, key: string | number, v: Json, top: boolean) => {
      if (typeof v === 'string' || Array.isArray(v)) {
        const size = JSON.stringify(v).length;
        const protectedScalar = top && typeof v === 'string' && v.length <= KEEP_SCALAR;
        const shrinkable = typeof v === 'string' ? v.length > 24 : v.length > 1;
        if (!protectedScalar && shrinkable && (!best || size > best.size)) best = { parent, key, size };
      }
      if (Array.isArray(v)) v.forEach((x, i) => visit(v, i, x, false));
      else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) visit(v, k, x, false);
    };
    for (const [k, v] of Object.entries(root)) if (!protect.includes(k)) visit(root, k, v, true);
    if (!best) break;
    const { parent, key } = best as { parent: Record<string | number, Json>; key: string | number };
    const v = parent[key];
    if (typeof v === 'string') {
      const base = v.replace(/…\[truncated\]$/, '');
      parent[key] = `${base.slice(0, Math.max(12, Math.floor(base.length / 2)))}…[truncated]`;
    } else if (Array.isArray(v)) {
      const marker = v.length && typeof v[v.length - 1] === 'string' && /^…\[(\d+) more items omitted\]$/.exec(v[v.length - 1] as string);
      const already = marker ? Number(marker[1]) : 0;
      const items = marker ? v.slice(0, -1) : v;
      const keep = Math.max(1, Math.floor(items.length / 2));
      parent[key] = [...items.slice(0, keep), `…[${already + items.length - keep} more items omitted]`];
    }
    shortened++;
    json = JSON.stringify(root);
  }
  return shortened;
}

/** Plain text cut to `cap` bytes at the last line boundary (or the last whole character). */
function cutText(text: string, cap: number): string {
  if (bytes(text) <= cap) return text;
  const head = Buffer.from(text, 'utf8').subarray(0, cap).toString('utf8').replace(/\uFFFD+$/, '');
  const nl = head.lastIndexOf('\n');
  return nl > cap / 2 ? head.slice(0, nl) : head;
}

/** The model-facing form of a subagent's final text: the handover JSON alone (compact) when there is
 * one, shrunk as valid JSON to `cap` bytes; other text is cut at a line boundary. */
export function leanResult(full: string, cap = resultCap()): LeanResult {
  const h = extractHandover(full);
  if (h) {
    // Only whitespace around the object (and the object's own formatting) is not a loss.
    const proseChars = (full.slice(0, h.start) + full.slice(h.end)).trim().length;
    const { json, shortened } = shrinkJson(h.obj, cap);
    return { text: json, dropped: proseChars > 0 || shortened > 0, handover: true, truncated: shortened > 0, proseChars, shortened, cutChars: 0 };
  }
  const text = cutText(full, cap);
  const cutChars = full.length - text.length;
  return { text, dropped: cutChars > 0, handover: false, truncated: cutChars > 0, proseChars: 0, shortened: 0, cutChars };
}

/** What a lean result left out, for the pointer line. */
export function omittedNote(l: LeanResult): string {
  const parts: string[] = [];
  if (l.proseChars) parts.push(`${l.proseChars} chars of prose around the handover omitted`);
  if (l.shortened) parts.push(`${l.shortened} long value${l.shortened === 1 ? '' : 's'} in the return shortened`);
  if (l.cutChars) parts.push(`last ${l.cutChars} chars cut`);
  return parts.join('; ');
}

export const KEEP_RETURNS = 20;

/** Keep the newest KEEP_RETURNS `.md` files in `dir` by mtime (never `justWritten`); delete the rest.
 * Only regular `.md` files directly in `dir` are touched. Best-effort: a failure is logged, not thrown. */
export function pruneReturns(dir: string, justWritten?: string, keep = KEEP_RETURNS): void {
  try {
    if (!realDir(dir)) { log('agent_return_prune_refused', { dir, reason: 'not a real directory (symlink?)' }); return; }
    const files = fs.readdirSync(dir, { withFileTypes: true })
      .filter((d) => d.isFile() && d.name.endsWith('.md'))
      .map((d) => { const p = path.join(dir, d.name); return { p, m: fs.statSync(p).mtimeMs }; })
      .sort((x, y) => y.m - x.m || (y.p === justWritten ? 1 : x.p === justWritten ? -1 : 0));
    for (const f of files.slice(keep)) if (f.p !== justWritten) fs.rmSync(f.p, { force: true });
  } catch (err) {
    log('agent_return_prune_failed', { dir, error: String(err) });
  }
}

function isSymlink(p: string): boolean {
  try { return fs.lstatSync(p).isSymbolicLink(); } catch { return false; }
}

/** True when `p` exists and is a directory itself, not a symlink to one (lstat). */
function realDir(p: string): boolean {
  try { return fs.lstatSync(p).isDirectory(); } catch { return false; }
}

/** Writes the full subagent return to <cwd>/.achilles/pi-agent-returns/<id>.md (dir 0700, file 0600)
 * and returns its path relative to cwd, or undefined when it could not be written. */
export function saveFullReturn(cwd: string, id: string, text: string): string | undefined {
  try {
    // Refuse a symlinked .achilles or pi-agent-returns: writing and pruning must stay inside the project.
    const parent = path.join(cwd, '.achilles');
    const dir = path.join(parent, 'pi-agent-returns');
    for (const d of [parent, dir]) {
      if (!fs.existsSync(d) && !isSymlink(d)) fs.mkdirSync(d, { mode: 0o700 });
      if (!realDir(d)) { log('agent_return_save_refused', { dir: d, reason: 'not a real directory (symlink?)' }); return undefined; }
    }
    const safe = id.replace(/[^A-Za-z0-9._-]/g, '_') || `child-${Date.now()}`;
    const file = path.join(dir, `${safe}.md`);
    fs.writeFileSync(file, text, { mode: 0o600 });
    fs.chmodSync(file, 0o600);
    pruneReturns(dir, file);
    return path.relative(cwd, file) || file;
  } catch (err) {
    log('agent_return_save_failed', { cwd, id, error: String(err) });
    return undefined;
  }
}

/** Model-facing content for a subagent return (see leanResult); verbose mode keeps the old behaviour. */
export function modelFacing(full: string, cwd: string, childSessionId: string): string {
  if (verbose()) return legacyCap(full);
  const lean = leanResult(full);
  if (!lean.dropped) return lean.text;
  const rel = saveFullReturn(cwd, childSessionId || `child-${process.pid}-${Date.now()}`, full);
  const what = omittedNote(lean);
  return rel
    ? `${lean.text}\n[achilles] full subagent return: ${rel} (${what})`
    : `${lean.text}\n[achilles] subagent return shortened for context (${what}); the full text is in the tool details.`;
}

export function registerAgentTool(pi: ExtensionAPI, opts: AgentToolOptions): void {
  const stateDir = opts.stateDir ?? process.env.ACHILLES_SESSION_STATE_DIR ?? path.join(os.homedir(), '.claude', 'achilles', 'sessions');
  const maxDepth = opts.maxDepth ?? 2;
  const maxConcurrent = opts.maxConcurrent ?? 4;
  const invocation = opts.invocation ?? defaultInvocation;
  let running = 0;
  const waiters: Array<() => void> = [];
  const acquire = () => new Promise<void>((res) => { if (running < maxConcurrent) { running++; res(); } else waiters.push(() => { running++; res(); }); });
  const release = () => { running--; waiters.shift()?.(); };

  pi.registerTool({
    name: 'Agent',
    label: 'Agent',
    description: 'Dispatch a subagent with an isolated context. `description` is a short label that starts with the role prefix (e.g. "workflow-reviewer-phase1: ..."); `prompt` is the full brief; `skill` names an achilles skill the subagent should load; `section` names the one section of that skill the subagent should start from, so a large skill does not fill its window.',
    promptSnippet: 'Agent: dispatch a subagent ({ description, prompt, skill?, section? })',
    parameters: Type.Object({
      description: Type.String({ description: 'Short label; starts with the role prefix' }),
      prompt: Type.String({ description: 'The complete brief for the subagent' }),
      subagent_type: Type.Optional(Type.String({ description: 'Subagent role; defaults to the description role prefix' })),
      skill: Type.Optional(Type.String({ description: 'achilles skill to advertise in the subagent' })),
      section: Type.Optional(Type.String({ description: 'Heading of `skill` the subagent should start from' })),
    }),
    async execute(_id, params, signal, onUpdate, ctx: ExtensionContext) {
      const depth = piDepth();
      if (depth >= maxDepth) throw new Error(`Agent nesting cap (${maxDepth}) reached; do this work inline instead of dispatching another subagent.`);
      let skillDir: string | undefined;
      let skillBody: string | undefined;
      if (params.skill) {
        const s = resolveSkill(params.skill, opts.roots);
        if (!s) throw new Error(`Unknown skill "${params.skill}" for Agent.skill`);
        skillDir = s.dir;
        skillBody = s.body;
      }
      // A start section only means something against a named skill; silently dropping it would send
      // the child off without the chapter the brief assumes it is reading.
      if (params.section && !params.skill) throw new Error('Agent.section names a section of Agent.skill; pass `skill` as well, or drop `section`.');
      const type = agentType(params);
      // An explicit `section` always wins. Otherwise the role prefix picks one, when the skill's own
      // text writes a contract for that role — the affordance round 4 added and nothing used.
      const derived = !params.section && skillBody ? roleSection(skillBody, type) : undefined;
      const section = params.section ?? derived;
      const active = parentActive(stateDir, ctx.sessionManager.getSessionId());
      const env: NodeJS.ProcessEnv = {
        ...process.env,
        ACHILLES_PI_DEPTH: String(depth + 1),
        ...(type ? { ACHILLES_PI_AGENT_TYPE: type } : {}),
        ...(active ? { ACHILLES_PROTOCOL: '1' } : {}),
        // The child's shadow transcript is seeded with this one's context signals (transcript.ts
        // seedShadow), including this Agent tool_use, which the parent's bridge recorded at tool_call,
        // before execute runs.
        ACHILLES_PI_PARENT_SHADOW: shadowPath(ctx.sessionManager.getSessionId(), stateDir),
      };
      // The start section is a per-dispatch instruction, not a session-wide setting: when this call
      // names none, whatever THIS process inherited (it may itself be a subagent that was given one)
      // must not reach the child. _FOR pins it to the skill it was named for, so a child that goes on
      // to load a different skill is not handed a section of that one.
      delete env.ACHILLES_PI_SKILL_SECTION;
      delete env.ACHILLES_PI_SKILL_SECTION_FOR;
      if (section && params.skill) {
        env.ACHILLES_PI_SKILL_SECTION = section;
        env.ACHILLES_PI_SKILL_SECTION_FOR = params.skill;
      }

      await acquire();
      let tmp: string | undefined;
      try {
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'achilles-agent-'));
        const sessionDir = path.join(tmp, 'session');
        // --no-skills: the child's system prompt lists only the skill it was given (--skill below), not every
        // discovered skill; the Skill tool still resolves any achilles skill from its own roots.
        const args = ['--mode', 'json', '-p', '--session-dir', sessionDir, '--no-skills', '--tools', CHILD_TOOLS, '-e', EXTENSION_ENTRY];
        if (ctx.isProjectTrusted()) args.push('-a');
        const model = process.env.ACHILLES_PI_SUBAGENT_MODEL ?? (ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined);
        if (model) args.push('--model', model);
        if (ctx.thinkingLevel) args.push('--thinking', ctx.thinkingLevel);
        if (skillDir) args.push('--skill', skillDir);
        // The prompt always goes by @file: as a raw argv word, a brief starting with "--x", "@/etc/passwd"
        // or "- item" would be parsed by pi as a flag or a file include. The file is private (0600).
        const pf = path.join(tmp, 'prompt.md');
        // The handover imperative goes only to a role the schema guard validates: a child with nothing
        // to hand over must not be sent looking for a return schema (live check 04).
        const fmt = handoverLine(type);
        fs.writeFileSync(pf, `${params.prompt.trimEnd()}${fmt ? `\n\n${fmt}` : ''}\n`, { mode: 0o600 });
        args.push(`@${pf}`);
        log('agent_spawn', { description: params.description, agentType: type, skill: params.skill, section, ...(section ? { sectionFrom: params.section ? 'call' : 'role' } : {}), active, depth: depth + 1 });

        let lastText = '', stderr = '', childSessionId = '';
        const exitCode = await new Promise<number | null>((resolve) => {
          const inv = invocation(args);
          // stdin must be closed: `pi -p` reads piped stdin as extra prompt text and would wait on it.
          const child = spawn(inv.command, inv.args, { cwd: ctx.cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
          let buf = '';
          let killTimer: NodeJS.Timeout | undefined;
          const line = (l: string) => {
            if (!l.trim()) return;
            let ev: Record<string, unknown>; try { ev = JSON.parse(l); } catch { return; }
            if (ev.type === 'session' && typeof ev.id === 'string') childSessionId = ev.id;
            if (ev.type === 'message_end') {
              const m = ev.message as { role?: string; content?: Array<{ type: string; text?: string }> };
              if (m?.role === 'assistant') { const t = (m.content ?? []).filter((c) => c.type === 'text').map((c) => c.text ?? '').join('\n'); if (t.trim()) lastText = t; }
            }
            if (ev.type === 'tool_execution_end' && onUpdate) onUpdate({ content: [{ type: 'text', text: `… ${String(ev.toolName)} done` }], details: undefined });
          };
          const kill = () => {
            child.kill('SIGTERM');
            // child.killed only means a signal was sent; check for an actual exit before escalating.
            killTimer = setTimeout(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); }, KILL_GRACE_MS);
            killTimer.unref();
          };
          child.stdout.setEncoding('utf8');
          child.stderr.setEncoding('utf8');
          child.stdout.on('data', (d) => { buf += d; const parts = buf.split('\n'); buf = parts.pop() ?? ''; parts.forEach(line); });
          child.stderr.on('data', (d) => { stderr += d; });
          child.on('error', (e) => { stderr += String(e); resolve(127); });
          child.on('close', (code) => {
            if (killTimer) clearTimeout(killTimer);
            signal?.removeEventListener('abort', kill);
            if (buf) line(buf);
            resolve(code);
          });
          if (signal) { if (signal.aborted) kill(); else signal.addEventListener('abort', kill, { once: true }); }
        });
        const transcript = fs.existsSync(sessionDir) ? fs.readdirSync(sessionDir).filter((f) => f.endsWith('.jsonl')).map((f) => path.join(sessionDir, f))[0] : undefined;
        // SubagentStop hooks run inside the child at its own settle (bridge.ts), with blocks honoured;
        // nothing runs them again here. The child's bridge wrote its own Claude-shaped shadow under its
        // own session id: that, not pi's session file, is the transcript a hook understands.
        const childShadow = childSessionId ? shadowPath(childSessionId, stateDir) : undefined;
        log('agent_done', { description: params.description, exitCode, childSessionId, chars: lastText.length });
        if (exitCode !== 0 || !lastText) throw new Error(`Subagent "${params.description}" failed (exit ${exitCode}): ${stderr.trim().slice(-2000) || 'no output'}`);
        // Opt-in copy of the transcript for details/debugging (the temp dir is removed in finally).
        let transcriptCopy: string | undefined;
        if (transcript && process.env.ACHILLES_PI_KEEP_TRANSCRIPTS === '1') {
          // A private dir of its own (not a guessable name in the shared /tmp) and a 0600 file.
          const keepDir = fs.mkdtempSync(path.join(os.tmpdir(), 'achilles-transcript-'));
          transcriptCopy = path.join(keepDir, `${childSessionId || 'child'}.jsonl`);
          fs.copyFileSync(transcript, transcriptCopy);
          fs.chmodSync(transcriptCopy, 0o600);
        }
        return { content: [{ type: 'text', text: modelFacing(lastText, ctx.cwd, childSessionId) }], details: { description: params.description, exitCode, childSessionId, text: lastText, shadowTranscript: childShadow, transcriptCopy, ...(section ? { section, sectionFrom: params.section ? 'call' : 'role' } : {}) } };
      } finally {
        // release() must run even when mkdtemp or the cleanup itself throws, or the slot leaks.
        try { if (tmp) fs.rmSync(tmp, { recursive: true, force: true }); } catch (err) { log('agent_cleanup_failed', { tmp, error: String(err) }); }
        release();
      }
    },
  });
}
