#!/usr/bin/env node
// evidence-video.mjs — play a storyboard (schemas/evidence-video.schema.json) into a captioned
// reproduction video a developer with no context can watch.
//
//   npx achilles-video tests/e2e/evidence/ABC-1-D1.video.json
//   npx achilles-video <storyboard.json> --check      validate only, no browser
//   npx achilles-video <storyboard.json> --headed     watch it while it records
//   npx achilles-video --help
//
// WHAT A VIDEO IS. An opening card with the title; then each step's caption alone on screen for
// pace.captionMs, then its action at pace.actionMs (slowMo) with the caption still showing; then an
// evidence page built from what the run captured (a downloaded .docx read as paragraphs, an API
// response, plain text), with the decisive text highlighted and scrolled into view; then a closing
// caption with the expected and the actual result. Defaults are the ones that read well: 1280x800,
// 600 ms per action, 2.2 s per caption, 9 s of evidence, 6 s of closing.
//
// WHAT IT NEVER DOES. Log in on camera (auth runs in a separate, unrecorded context or comes from a
// storage state), show or keep a ${env:NAME} value (masked in captions, captures and the manifest),
// or keep request and response headers.
//
// OUTPUTS (in `out`, default the storyboard's directory): <name>.webm, <name>.mp4 (when ffmpeg is
// available: ffmpeg-static or PATH), downloads/<as>, and <name>.json, the manifest: every step with
// its start time in the video, the expectations and whether they held, the captures, and the decode
// check of each video file. Exit 0 when every step ran and every expectation was evaluated; 1 when a
// step failed (the video is still finished, ending on the failure); 2 for a storyboard that does not
// validate or an unusable environment.
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync, mkdtempSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import Ajv from 'ajv/dist/2020.js';

const require = createRequire(import.meta.url);
const SCHEMA = join(dirname(fileURLToPath(import.meta.url)), '..', 'schemas', 'evidence-video.schema.json');
const VERBS = ['goto', 'click', 'fill', 'press', 'select', 'check', 'uncheck', 'upload', 'waitFor', 'expect', 'download', 'pause'];
const DEFAULTS = { actionMs: 600, captionMs: 2200, evidenceMs: 9000, closingMs: 6000, timeoutMs: 30000, waitMs: 180000 };
const CAP_CSS = 'position:fixed;left:50%;transform:translateX(-50%);bottom:24px;z-index:2147483647;max-width:1100px;background:rgba(17,24,39,.93);color:#fff;font:600 20px/1.35 -apple-system,Segoe UI,Arial,sans-serif;padding:14px 22px;border-radius:10px;box-shadow:0 6px 24px rgba(0,0,0,.35);pointer-events:none;white-space:pre-wrap;text-align:center';

const HELP = `achilles-video <storyboard.json> [--check] [--headed]

Plays an evidence-video storyboard (schemas/evidence-video.schema.json) into <name>.webm, <name>.mp4
and the <name>.json manifest. --check validates the storyboard and exits. Rules:
skills/evidence-capture/references/evidence-video.md`;

function fail(msg, code = 2) {
  process.stderr.write(`achilles-video: ${msg}\n`);
  process.exit(code);
}

// ── storyboard: validate, then substitute ${run} and ${env:NAME} ──

export function verbOf(action) {
  const verbs = VERBS.filter(v => action[v] !== undefined);
  return verbs;
}

export function checkStoryboard(board) {
  const ajv = new (Ajv.default || Ajv)({ strict: true, allErrors: true, allowUnionTypes: true });
  const validate = ajv.compile(JSON.parse(readFileSync(SCHEMA, 'utf8')));
  const errors = [];
  if (!validate(board)) for (const e of validate.errors ?? []) errors.push(`${e.instancePath || '/'} ${e.message}`);
  const actions = [...(board.steps ?? []).map((s, i) => [`/steps/${i}`, s]), ...((board.auth?.steps ?? []).map((s, i) => [`/auth/steps/${i}`, s]))];
  for (const [at, a] of actions) {
    if (a && typeof a === 'object' && verbOf(a).length > 1) errors.push(`${at} has more than one action (${verbOf(a).join(', ')}); one step, one action`);
    if (typeof a?.caption === 'string' && /\$\{env:/.test(a.caption)) errors.push(`${at} caption uses \${env:…}; a secret is never shown on screen`);
  }
  for (const s of board.auth?.steps ?? []) if (s.caption) errors.push('/auth/steps: login steps are off camera and take no caption');
  const ids = new Set((board.capture ?? []).map(c => c.id));
  const downloads = new Set((board.steps ?? []).filter(s => s.download).map(s => s.download.as));
  for (const [i, b] of (board.evidence?.blocks ?? []).entries()) {
    const sources = ['text', 'download', 'capture'].filter(k => b[k] !== undefined);
    if (sources.length !== 1) errors.push(`/evidence/blocks/${i} needs exactly one of text, download, capture`);
    if (b.capture && !ids.has(b.capture)) errors.push(`/evidence/blocks/${i} names capture "${b.capture}", which /capture does not declare`);
    if (b.download && !downloads.has(b.download)) errors.push(`/evidence/blocks/${i} names download "${b.download}", which no step saves`);
  }
  for (const [i, s] of (board.steps ?? []).entries()) if (s.waitFor?.capture && !ids.has(s.waitFor.capture)) errors.push(`/steps/${i} waits for capture "${s.waitFor.capture}", which /capture does not declare`);
  return errors;
}

export function substituter(env, run) {
  const secrets = new Set();
  const sub = value => (typeof value !== 'string' ? value : value.replace(/\$\{run\}/g, run).replace(/\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) => {
    const v = env[name];
    if (v === undefined || v === '') throw new Error(`\${env:${name}} is not set`);
    if (v.length >= 4) secrets.add(v);
    return v;
  }));
  const mask = text => {
    let out = String(text);
    for (const s of secrets) out = out.split(s).join('[REDACTED]');
    return out;
  };
  return { sub, mask, secrets };
}

// ── locators ──

function repository(file) {
  if (!file) return new Map();
  const data = JSON.parse(readFileSync(file, 'utf8'));
  const map = new Map();
  for (const p of data.pages ?? []) for (const e of p.elements ?? []) map.set(`${p.name}.${e.elementName}`, e.selector);
  return map;
}

function locate(page, target, repo) {
  let t = target;
  if (t.page !== undefined) {
    const sel = repo.get(`${t.page}.${t.element}`);
    if (!sel) throw new Error(`page repository has no ${t.page}.${t.element}`);
    t = { ...sel, nth: target.nth };
  }
  const exact = t.exact === true || t.exact === 'true';
  let loc;
  if (t.role) loc = page.getByRole(t.role, t.name !== undefined ? { name: t.name, exact } : {});
  else if (t.text !== undefined) loc = page.getByText(t.text, { exact });
  else if (t.label !== undefined) loc = page.getByLabel(t.label, { exact });
  else if (t.placeholder !== undefined) loc = page.getByPlaceholder(t.placeholder);
  else if (t.testId !== undefined) loc = page.getByTestId(t.testId);
  else if (t.css !== undefined) loc = page.locator(t.css);
  else if (t.xpath !== undefined) loc = page.locator(`xpath=${t.xpath}`);
  else if (t.id !== undefined) loc = page.locator(`#${t.id}`);
  else throw new Error(`unusable target ${JSON.stringify(target)}`);
  return t.nth !== undefined ? loc.nth(t.nth) : loc.first();
}

// ── on-screen layers ──

async function caption(page, text) {
  await page.evaluate(([t, css]) => {
    let d = document.getElementById('__achilles_caption');
    if (!d) { d = document.createElement('div'); d.id = '__achilles_caption'; document.documentElement.appendChild(d); }
    d.setAttribute('style', css); d.textContent = t;
  }, [text, CAP_CSS]).catch(() => {});
}

const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const asRegex = s => (/^\/.+\/[a-z]*$/.test(s) ? new RegExp(s.slice(1, s.lastIndexOf('/')), s.slice(s.lastIndexOf('/') + 1).replace('g', '') + 'g') : new RegExp(s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'));
function marked(text, highlight = []) {
  let html = esc(text);
  for (const h of highlight) html = html.replace(asRegex(esc(h)), x => `<mark>${x}</mark>`);
  return html;
}

const PAGE_CSS = `body{font:16px/1.5 -apple-system,Segoe UI,Arial,sans-serif;margin:0;background:#f3f4f6;color:#111}
header{background:#111827;color:#fff;padding:18px 28px;font-size:22px;font-weight:700}
main{padding:20px 28px 160px} .b{background:#fff;border-radius:8px;padding:14px 18px;margin:0 0 14px;box-shadow:0 1px 3px rgba(0,0,0,.12)}
.b.bad{border-left:6px solid #b91c1c} .b h3{margin:0 0 8px;font-size:15px;color:#374151;text-transform:uppercase;letter-spacing:.04em}
pre{white-space:pre-wrap;margin:0;font:14px/1.45 ui-monospace,Menlo,monospace} mark{background:#fde047;padding:0 2px;font-weight:700}
.card{display:flex;flex-direction:column;justify-content:center;align-items:center;height:100vh;background:#111827;color:#fff;text-align:center;padding:0 80px}
.card h1{font-size:34px;margin:0 0 14px} .card p{font-size:18px;color:#d1d5db;margin:0}`;

async function titleCard(page, title, sub, hold) {
  await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>${PAGE_CSS}</style></head><body><div class="card"><h1>${esc(title)}</h1><p>${esc(sub)}</p></div></body></html>`);
  await page.waitForTimeout(hold);
}

// ── evidence sources ──

export function docxParagraphs(file) {
  const r = spawnSync('unzip', ['-p', file, 'word/document.xml'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`cannot read ${file} as .docx`);
  return r.stdout.split(/<\/w:p>/).map(p => p.replace(/<w:tab\/>/g, '\t').replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&').trim()).filter(Boolean);
}

export function pick(obj, path) {
  if (!path) return obj;
  return path.split('.').reduce((v, k) => (v === undefined || v === null ? undefined : Array.isArray(v) && /^\d+$/.test(k) ? v[Number(k)] : v[k]), obj);
}

function blockText(block, ctx) {
  if (block.text !== undefined) return ctx.sub(block.text);
  if (block.capture !== undefined) {
    const c = ctx.captures.get(block.capture);
    if (!c) return `(not captured: no ${block.capture} response was seen in this run)`;
    const v = pick(c, block.pick);
    return typeof v === 'string' ? v : JSON.stringify(v ?? null, null, 2);
  }
  const file = ctx.downloads.get(block.download);
  if (!file) return `(not downloaded: the ${block.download} download did not happen in this run)`;
  let paras = /\.docx$/i.test(file) ? docxParagraphs(file) : readFileSync(file, 'utf8').split('\n');
  if (block.match) paras = paras.filter(p => asRegex(block.match).test(p));
  return paras.join('\n\n');
}

async function evidencePage(page, board, ctx, hold) {
  const blocks = board.evidence.blocks.map(b => {
    const text = ctx.mask(blockText(b, ctx));
    return `<div class="b${b.bad ? ' bad' : ''}"><h3>${esc(b.heading)}</h3><pre>${marked(text, (b.highlight ?? []).map(ctx.sub))}</pre></div>`;
  });
  await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>${PAGE_CSS}</style></head><body><header>${esc(board.evidence.title ?? `Evidence: ${board.title}`)}</header><main>${blocks.join('')}</main></body></html>`);
  await page.waitForTimeout(1500);
  const m = page.locator('mark').first();
  if (await m.count()) await m.scrollIntoViewIfNeeded().catch(() => {});
  await page.waitForTimeout(hold);
}

// ── actions ──

async function act(page, a, ctx) {
  const t = a.timeoutMs ?? (a.waitFor ? DEFAULTS.waitMs : DEFAULTS.timeoutMs);
  const L = target => locate(page, target, ctx.repo);
  if (a.goto !== undefined) return page.goto(new URL(ctx.sub(a.goto), ctx.baseURL).toString(), { timeout: t });
  if (a.click) return L(a.click).click({ timeout: t });
  if (a.fill) return L(a.fill.target).fill(ctx.sub(a.fill.value), { timeout: t });
  if (a.press) return a.press.target ? L(a.press.target).press(a.press.key, { timeout: t }) : page.keyboard.press(a.press.key);
  if (a.select) return L(a.select.target).selectOption(ctx.sub(a.select.value), { timeout: t });
  if (a.check) return L(a.check).check({ timeout: t });
  if (a.uncheck) return L(a.uncheck).uncheck({ timeout: t });
  if (a.upload) {
    const file = resolve(ctx.dir, ctx.sub(a.upload.file));
    if (!existsSync(file)) throw new Error(`upload file ${a.upload.file} does not exist`);
    if (a.upload.target) return L(a.upload.target).setInputFiles(file, { timeout: t });
    const [chooser] = await Promise.all([page.waitForEvent('filechooser', { timeout: t }), L(a.upload.click).click({ timeout: t })]);
    return chooser.setFiles(file);
  }
  if (a.waitFor) {
    const w = a.waitFor;
    if (w.capture) {
      const until = Date.now() + t;
      while (!ctx.captures.has(w.capture)) {
        if (Date.now() > until) throw new Error(`no ${w.capture} response within ${t} ms`);
        await page.waitForTimeout(250);
      }
      return;
    }
    if (w.url) return page.waitForURL(u => u.toString().includes(ctx.sub(w.url)), { timeout: t });
    const loc = w.target ? L(w.target) : page.getByText(ctx.sub(w.text)).first();
    return loc.waitFor({ state: w.state ?? 'visible', timeout: t });
  }
  if (a.expect) {
    const e = a.expect;
    let held;
    if (e.notText !== undefined) held = (await page.getByText(ctx.sub(e.notText)).count()) === 0;
    else {
      const loc = e.target ? L(e.target) : page.getByText(ctx.sub(e.text)).first();
      held = await loc.waitFor({ state: 'visible', timeout: Math.min(t, 10000) }).then(() => true, () => false);
    }
    ctx.expectations.push({ step: ctx.n, caption: ctx.mask(ctx.cap), held, what: ctx.mask(JSON.stringify(e)) });
    return;
  }
  if (a.download) {
    const [dl] = await Promise.all([page.waitForEvent('download', { timeout: t }), L(a.download.click).click({ timeout: t })]);
    const to = join(ctx.out, 'downloads', a.download.as);
    mkdirSync(dirname(to), { recursive: true });
    await dl.saveAs(to);
    ctx.downloads.set(a.download.as, to);
    return;
  }
  if (a.pause !== undefined) return page.waitForTimeout(a.pause);
}

// ── video files ──

function ffmpegBinary() {
  try {
    const p = require('ffmpeg-static');
    if (p && existsSync(p)) return p;
  } catch { /* optional dependency absent */ }
  const r = spawnSync('ffmpeg', ['-version'], { encoding: 'utf8' });
  return r.status === 0 ? 'ffmpeg' : undefined;
}

function decodeCheck(ffmpeg, file) {
  if (!ffmpeg) return { decoded: null, reason: 'no ffmpeg' };
  const r = spawnSync(ffmpeg, ['-v', 'error', '-i', file, '-f', 'null', '-'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  const info = spawnSync(ffmpeg, ['-i', file], { encoding: 'utf8' });
  const m = /Duration: (\d+):(\d+):([\d.]+)/.exec(info.stderr ?? '');
  const durationS = m ? Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) : null;
  return { decoded: r.status === 0 && (r.stderr ?? '').trim() === '', durationS, bytes: statSync(file).size, ...(r.status === 0 ? {} : { reason: (r.stderr ?? '').split('\n')[0] }) };
}

// ── the run ──

export async function play(file, { headed = false, env = process.env } = {}) {
  const board = JSON.parse(readFileSync(file, 'utf8'));
  const errors = checkStoryboard(board);
  if (errors.length > 0) return { code: 2, errors };
  const dir = dirname(resolve(file));
  const out = resolve(dir, board.out ?? '.');
  mkdirSync(out, { recursive: true });
  const run = Math.random().toString(36).slice(2, 8);
  const { sub, mask } = substituter(env, run);
  const pace = { ...DEFAULTS, ...(board.pace ?? {}) };
  const viewport = { width: board.viewport?.width ?? 1280, height: board.viewport?.height ?? 800 };
  const ctx = { dir, out, sub, mask, baseURL: board.baseURL, repo: repository(board.pageRepository && resolve(dir, board.pageRepository)), captures: new Map(), captureLog: [], downloads: new Map(), expectations: [], n: 0, cap: '' };
  const { chromium } = await import('@playwright/test');
  const browser = await chromium.launch({ headless: !headed, slowMo: pace.actionMs });
  const scratch = mkdtempSync(join(tmpdir(), 'achilles-video-'));
  const manifest = { name: board.name, title: board.title, run, startedAt: new Date().toISOString(), status: 'ok', steps: [], expectations: ctx.expectations, captures: ctx.captureLog, downloads: {}, video: {} };
  const common = { viewport, ignoreHTTPSErrors: board.ignoreHTTPSErrors === true, acceptDownloads: true };
  try {
    // Off camera: the login, in its own context, never recorded.
    let storageState;
    if (board.auth?.storageState) storageState = resolve(dir, sub(board.auth.storageState));
    else if (board.auth?.steps) {
      const login = await browser.newContext(common);
      const lp = await login.newPage();
      for (const s of board.auth.steps) await act(lp, s, { ...ctx, n: 0, cap: '' });
      storageState = join(scratch, 'state.json');
      await login.storageState({ path: storageState });
      await login.close();
    }
    const rec = await browser.newContext({ ...common, ...(storageState ? { storageState } : {}), recordVideo: { dir: scratch, size: viewport } });
    const page = await rec.newPage();
    const started = Date.now();
    page.on('response', async res => {
      const req = res.request();
      for (const c of board.capture ?? []) {
        const url = req.url();
        const hit = c.url.startsWith('/') && c.url.endsWith('/') && c.url.length > 2 ? new RegExp(c.url.slice(1, -1)).test(url) : url.includes(sub(c.url));
        if (!hit || (c.method && req.method() !== c.method)) continue;
        let request = req.postData() ?? null;
        try { request = request === null ? null : JSON.parse(request); } catch { /* not JSON */ }
        let response;
        try { response = await res.json(); } catch { response = (await res.text().catch(() => '')).slice(0, 65536); }
        const entry = JSON.parse(mask(JSON.stringify({ id: c.id, method: req.method(), url: url.replace(/\?.*$/, ''), status: res.status(), request, response, atMs: Date.now() - started })));
        ctx.captures.set(c.id, entry);
        ctx.captureLog.push(entry);
      }
    });
    page.on('load', () => { if (ctx.cap) caption(page, ctx.cap); });
    await titleCard(page, board.title, 'Reproduction', 2500);
    for (const [i, s] of board.steps.entries()) {
      ctx.n = i + 1;
      ctx.cap = mask(/^step\s*\d+/i.test(s.caption) ? s.caption : `Step ${i + 1}: ${s.caption}`);
      const entry = { n: ctx.n, caption: ctx.cap, action: verbOf(s)[0] ?? 'narration', atMs: Date.now() - started };
      manifest.steps.push(entry);
      await caption(page, ctx.cap);
      await page.waitForTimeout(pace.captionMs);
      try {
        await act(page, s, ctx);
        await caption(page, ctx.cap);
      } catch (err) {
        const why = mask(String(err?.message ?? err).split('\n')[0]);
        if (s.optional) { entry.skipped = why; continue; }
        entry.error = why;
        manifest.status = 'failed';
        await caption(page, `${ctx.cap}\nThe run stopped here: ${why}`);
        await page.waitForTimeout(pace.closingMs);
        break;
      }
    }
    if (board.evidence) await evidencePage(page, board, ctx, pace.evidenceMs);
    await caption(page, mask(`Expected: ${sub(board.closing.expected)}\nActual: ${sub(board.closing.actual)}`));
    await page.waitForTimeout(pace.closingMs);
    const video = page.video();
    await rec.close();
    const webm = join(out, `${board.name}.webm`);
    renameSync(await video.path(), webm);
    const ffmpeg = ffmpegBinary();
    manifest.video.webm = { file: webm, ...decodeCheck(ffmpeg, webm) };
    if (ffmpeg) {
      const mp4 = join(out, `${board.name}.mp4`);
      const r = spawnSync(ffmpeg, ['-loglevel', 'error', '-y', '-i', webm, '-c:v', 'libx264', '-preset', 'medium', '-crf', '23', '-pix_fmt', 'yuv420p', '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-movflags', '+faststart', '-an', mp4], { encoding: 'utf8' });
      manifest.video.mp4 = r.status === 0 ? { file: mp4, ...decodeCheck(ffmpeg, mp4) } : { file: null, reason: (r.stderr ?? '').split('\n')[0] };
    }
    for (const [k, v] of ctx.downloads) manifest.downloads[k] = v;
  } finally {
    await browser.close();
    rmSync(scratch, { recursive: true, force: true });
  }
  manifest.finishedAt = new Date().toISOString();
  writeFileSync(join(out, `${board.name}.json`), `${mask(JSON.stringify(manifest, null, 2))}\n`);
  const bad = manifest.status !== 'ok' || manifest.video.webm?.decoded === false || manifest.video.mp4?.decoded === false;
  return { code: bad ? 1 : 0, manifest };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const args = process.argv.slice(2);
  if (args.includes('--help') || args.includes('-h')) {
    process.stdout.write(`${HELP}\n`);
    process.exit(0);
  }
  const file = args.find(a => !a.startsWith('--'));
  if (!file) fail(`no storyboard given\n\n${HELP}`);
  if (!existsSync(file)) fail(`${file} does not exist`);
  let board;
  try { board = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { fail(`${file} is not JSON: ${e.message}`); }
  if (args.includes('--check')) {
    const errors = checkStoryboard(board);
    if (errors.length > 0) fail(`${file} does not validate:\n${errors.map(e => `  - ${e}`).join('\n')}`);
    process.stdout.write(`${file}: valid storyboard, ${board.steps.length} steps\n`);
    process.exit(0);
  }
  play(file, { headed: args.includes('--headed') }).then(r => {
    if (r.errors) fail(`${file} does not validate:\n${r.errors.map(e => `  - ${e}`).join('\n')}`);
    const m = r.manifest;
    const failedStep = m.steps.find(s => s.error);
    process.stdout.write(`${m.status === 'ok' ? 'recorded' : `recorded, stopped at step ${failedStep?.n}: ${failedStep?.error}`}\n  ${m.video.webm?.file} (${m.video.webm?.durationS ?? '?'} s, decoded: ${m.video.webm?.decoded})\n${m.video.mp4?.file ? `  ${m.video.mp4.file} (decoded: ${m.video.mp4.decoded})\n` : ''}  expectations: ${m.expectations.map(e => `${e.held ? 'held' : 'FAILED'} (step ${e.step})`).join(', ') || 'none'}\n  manifest: ${join(dirname(m.video.webm?.file ?? '.'), `${m.name}.json`)}\n`);
    process.exit(r.code);
  }, e => fail(String(e?.stack ?? e)));
}
