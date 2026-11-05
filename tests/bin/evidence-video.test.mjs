import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { checkStoryboard, pick, substituter } from '../../bin/evidence-video.mjs';

const CLI = new URL('../../bin/evidence-video.mjs', import.meta.url).pathname;
const base = { name: 'demo', title: 'Demo', baseURL: 'http://127.0.0.1:1', steps: [{ caption: 'Open the page', goto: '/' }], closing: { expected: 'e', actual: 'a' } };

test('a valid storyboard passes; two actions in one step, a secret in a caption and dangling references are refused', () => {
  assert.deepEqual(checkStoryboard(base), []);
  const errs = checkStoryboard({
    ...base,
    steps: [{ caption: 'Two at once', goto: '/', click: { text: 'x' } }, { caption: 'Log in as ${env:USER_EMAIL}', fill: { target: { label: 'Email' }, value: '${env:USER_EMAIL}' } }, { caption: 'Wait', waitFor: { capture: 'nope' } }],
    evidence: { blocks: [{ heading: 'h', capture: 'missing' }, { heading: 'h2', download: 'none.docx' }, { heading: 'h3', text: 't', capture: 'missing' }] },
  }).join('\n');
  assert.match(errs, /more than one action \(goto, click\)/);
  assert.match(errs, /caption uses \$\{env:…\}/);
  assert.match(errs, /waits for capture "nope"/);
  assert.match(errs, /names capture "missing"/);
  assert.match(errs, /names download "none.docx"/);
  assert.match(errs, /exactly one of text, download, capture/);
  assert.match(checkStoryboard({ ...base, steps: [{ goto: '/' }] }).join('\n'), /caption/);
  assert.match(checkStoryboard({ ...base, auth: { steps: [{ caption: 'Log in', goto: '/login' }] } }).join('\n'), /off camera/);
})

test('${env:…} values are substituted and masked; ${run} is replaced; pick walks a dotted path', () => {
  const { sub, mask } = substituter({ PASS: 's3cret-value' }, 'r1')
  assert.equal(sub('pw=${env:PASS} run=${run}'), 'pw=s3cret-value run=r1')
  assert.equal(mask('the s3cret-value leaked'), 'the [REDACTED] leaked')
  assert.throws(() => sub('${env:NOT_SET_ANYWHERE}'), /is not set/)
  assert.equal(pick({ response: { meta: { m: 'x' } }, list: [{ a: 1 }] }, 'response.meta.m'), 'x')
  assert.equal(pick({ list: [{ a: 1 }] }, 'list.0.a'), 1)
})

test('--check validates without a browser; --help exits 0', () => {
  const d = mkdtempSync(join(tmpdir(), 'ev-'))
  writeFileSync(join(d, 'ok.json'), JSON.stringify(base))
  writeFileSync(join(d, 'bad.json'), JSON.stringify({ ...base, steps: [{ caption: 'x', goto: '/', click: { text: 'y' } }] }))
  assert.equal(spawnSync(process.execPath, [CLI, join(d, 'ok.json'), '--check'], { encoding: 'utf8' }).status, 0)
  const bad = spawnSync(process.execPath, [CLI, join(d, 'bad.json'), '--check'], { encoding: 'utf8' })
  assert.equal(bad.status, 2)
  assert.match(bad.stderr, /more than one action/)
  assert.equal(spawnSync(process.execPath, [CLI, '--help'], { encoding: 'utf8' }).status, 0)
})

// A live recording against a small local app: a form that posts and shows the backend's error, and a download.
const APP = `<!doctype html><html><body><h1>Templates</h1>
<label>Template name <input id="name"></label> <button id="save">Create template</button>
<p id="msg"></p><a id="dl" href="/file.txt" download="file.txt">Download</a>
<script>document.getElementById('save').onclick=async()=>{const r=await fetch('/api/save',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({name:document.getElementById('name').value,token:sessionStorage.getItem('t')})});const j=await r.json();document.getElementById('msg').textContent=j.meta.status_message}</script></body></html>`

function serve() {
  return new Promise(res => {
    const s = createServer((req, rsp) => {
      if (req.url === '/api/save') {
        let b = ''
        req.on('data', c => (b += c))
        req.on('end', () => { rsp.writeHead(400, { 'content-type': 'application/json' }); rsp.end(JSON.stringify({ meta: { status_message: 'A variable with this name already exists.' }, echo: JSON.parse(b) })) })
        return
      }
      if (req.url === '/file.txt') { rsp.writeHead(200, { 'content-type': 'text/plain', 'content-disposition': 'attachment; filename="file.txt"' }); rsp.end('Article 2\nThe contract runs for a fixed period.\nArticle 3\nOther text.'); return }
      rsp.writeHead(200, { 'content-type': 'text/html' }); rsp.end(APP)
    })
    s.listen(0, '127.0.0.1', () => res(s))
  })
}

const hasChromium = (() => {
  try { return spawnSync(process.execPath, ['-e', "require('@playwright/test').chromium.executablePath()&&process.exit(require('fs').existsSync(require('@playwright/test').chromium.executablePath())?0:1)"], { encoding: 'utf8' }).status === 0 } catch { return false }
})()

test('a storyboard plays into a captioned webm and mp4, with captures, downloads, expectations and no secret in the manifest', { skip: !hasChromium && 'no Playwright Chromium installed', timeout: 120000 }, async () => {
  const server = await serve()
  const d = mkdtempSync(join(tmpdir(), 'ev-live-'))
  const board = {
    name: 'NAME-CLASH-demo', title: 'Demo: the save fails on a duplicate name', baseURL: `http://127.0.0.1:${server.address().port}`,
    pace: { actionMs: 50, captionMs: 200, evidenceMs: 400, closingMs: 300 },
    auth: { steps: [{ goto: '/' }, { click: { text: 'Remind me later' }, optional: true, timeoutMs: 300 }] },
    capture: [{ id: 'save', url: '/api/save', method: 'POST' }],
    steps: [
      { caption: 'Open the templates page', goto: '/' },
      { caption: 'Type a template name', fill: { target: { label: 'Template name' }, value: 'demo-${run}-${env:EV_SECRET}' } },
      { caption: 'Bring the button into view', scroll: { css: 'button#save[data-run="${run}"], button#save' } },
      { caption: 'Click Create template', click: { role: 'button', name: 'Create template' } },
      { caption: 'Wait for the save to answer', waitFor: { capture: 'save' } },
      { caption: 'The error names the duplicate', expect: { text: 'already exists' } },
      { caption: 'A message that is not there', expect: { text: 'Template saved' } },
      { caption: 'Download the file', download: { click: { text: 'Download' }, as: 'file.txt' } },
      { caption: 'An optional dialog that never appears', click: { text: 'Dismiss' }, optional: true, timeoutMs: 300 },
    ],
    evidence: { blocks: [
      { heading: 'Save response', capture: 'save', pick: 'response.meta.status_message', highlight: ['already exists'], bad: true },
      { heading: 'Request body', capture: 'save', pick: 'request' },
      { heading: 'Downloaded file, Article 2', download: 'file.txt', match: 'fixed period', highlight: ['fixed period'] },
    ] },
    closing: { expected: 'the template saves', actual: 'the save fails with a 400' },
  }
  writeFileSync(join(d, 'board.json'), JSON.stringify(board))
  // Asynchronous: the app under test runs in this process, so a blocking spawn would starve it.
  const r = await new Promise(res => {
    const child = spawn(process.execPath, [CLI, join(d, 'board.json')], { env: { ...process.env, EV_SECRET: 'hunter2-secret' } })
    let stdout = '', stderr = ''
    child.stdout.on('data', c => (stdout += c))
    child.stderr.on('data', c => (stderr += c))
    child.on('close', status => res({ status, stdout, stderr }))
  })
  server.close()
  assert.equal(r.status, 0, r.stderr + r.stdout)
  const manifest = JSON.parse(readFileSync(join(d, 'NAME-CLASH-demo.json'), 'utf8'))
  assert.equal(manifest.status, 'ok')
  assert.equal(manifest.steps.length, 9)
  assert.equal(manifest.steps[0].caption, 'Step 1: Open the templates page')
  assert.ok(manifest.steps.every((s, i) => i === 0 || s.atMs >= manifest.steps[i - 1].atMs))
  assert.ok(manifest.steps[8].skipped, 'the optional step is skipped, not failed')
  assert.deepEqual(manifest.expectations.map(e => e.held), [true, false])
  assert.equal(manifest.captures[0].status, 400)
  assert.match(manifest.captures[0].request.name, /\[REDACTED\]/)
  assert.ok(!readFileSync(join(d, 'NAME-CLASH-demo.json'), 'utf8').includes('hunter2-secret'))
  assert.ok(existsSync(join(d, 'downloads', 'file.txt')))
  assert.ok(existsSync(manifest.video.webm.file) && manifest.video.webm.bytes > 0)
  // One expectation did not hold, so the closing card must not claim the scripted actual.
  assert.equal(manifest.closing.shown, false)
  assert.match(manifest.closing.actual, /^Not shown in this recording: the check at step 7 did not hold/)
  // A second run with the same name refuses to overwrite.
  const again = spawnSync(process.execPath, [CLI, join(d, 'board.json')], { encoding: 'utf8' })
  assert.equal(again.status, 2)
  assert.match(again.stderr, /never overwritten/)
  if (manifest.video.mp4) assert.equal(manifest.video.mp4.decoded, true)
})
