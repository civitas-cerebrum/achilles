#!/usr/bin/env node
// Export a qa-reporting deck or catalogue (HTML) to PDF with the project's
// `@playwright/test` Chromium. No extra dependency, no prompt.
//
// Usage:  node export-pdf.js <html-path> [pdf-path] [--png-dir <dir>]
//
// Every `section.slide` (or `[data-slide-id]`) becomes one PDF page: the
// script hides every other slide and prints one page per slide, then
// concatenates the single-page PDFs into the output. Chromium's one-shot
// `page.pdf()` truncates long documents, so the per-slide path is the only
// code path. After writing, the page count is read back and compared with the
// slide count; a mismatch exits 1 (a corrupt render is never left on disk as
// if it were fine). With `--png-dir`, one PNG per slide is also written for
// the visual inspection the skill requires.
//
// Output: prints `<pdf-path> pages=<n>` to stdout.

const path = require('path');
const fs = require('fs');

function parseArgs(argv) {
  const out = { html: null, pdf: null, pngDir: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--png-dir') out.pngDir = argv[++i];
    else if (!out.html) out.html = argv[i];
    else if (!out.pdf) out.pdf = argv[i];
  }
  return out;
}

// Concatenate single-page PDFs produced by the same Chromium into one file.
// Each input holds exactly one /Type /Page object; objects are renumbered
// and appended, a new /Pages node lists them, and a classic xref table is
// written. Chromium emits uncompressed object headers, so a byte-level
// renumber is safe for its own output; this is not a general PDF merger.
function mergeSinglePagePdfs(buffers) {
  const objects = []; // { body: Buffer } with renumbered references
  const pageRefs = [];
  for (const buf of buffers) {
    const text = buf.toString('latin1');
    const objRe = /(\d+) 0 obj\b/g;
    const idMap = new Map();
    let m;
    while ((m = objRe.exec(text)) !== null) idMap.set(Number(m[1]), objects.length + idMap.size + 1);
    const chunks = [];
    const bodyRe = /(\d+) 0 obj\b([\s\S]*?)\bendobj/g;
    while ((m = bodyRe.exec(text)) !== null) {
      const newId = idMap.get(Number(m[1]));
      let body = m[2].replace(/(\d+) 0 R\b/g, (_, n) => `${idMap.get(Number(n)) ?? n} 0 R`);
      body = body.replace(/\/Parent \d+ 0 R/, '/Parent PAGESREF');
      if (/\/Type\s*\/Page\b/.test(body) && !/\/Type\s*\/Pages\b/.test(body)) pageRefs.push(newId);
      chunks.push({ id: newId, body });
    }
    // Drop the per-file /Pages and /Catalog nodes; one of each is written below.
    for (const c of chunks) {
      if (/\/Type\s*\/Pages\b/.test(c.body) || /\/Type\s*\/Catalog\b/.test(c.body)) continue;
      objects.push(c);
    }
  }
  const pagesId = objects.length + 1;
  const catalogId = pagesId + 1;
  const parts = ['%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'];
  const offsets = [];
  let pos = Buffer.byteLength(parts[0], 'latin1');
  const push = (s) => { parts.push(s); pos += Buffer.byteLength(s, 'latin1'); };
  for (const o of objects) {
    offsets[o.id] = pos;
    push(`${o.id} 0 obj${o.body.replace(/PAGESREF/g, `${pagesId} 0 R`)}endobj\n`);
  }
  offsets[pagesId] = pos;
  push(`${pagesId} 0 obj\n<< /Type /Pages /Kids [${pageRefs.map((r) => `${r} 0 R`).join(' ')}] /Count ${pageRefs.length} >>\nendobj\n`);
  offsets[catalogId] = pos;
  push(`${catalogId} 0 obj\n<< /Type /Catalog /Pages ${pagesId} 0 R >>\nendobj\n`);
  const xrefPos = pos;
  const total = catalogId + 1;
  let xref = `xref\n0 ${total}\n0000000000 65535 f \n`;
  for (let i = 1; i < total; i++) xref += `${String(offsets[i] ?? 0).padStart(10, '0')} 00000 n \n`;
  push(xref);
  push(`trailer\n<< /Size ${total} /Root ${catalogId} 0 R >>\nstartxref\n${xrefPos}\n%%EOF\n`);
  return Buffer.from(parts.join(''), 'latin1');
}

function countPages(pdfBuffer) {
  const text = pdfBuffer.toString('latin1');
  const m = text.match(/\/Type\s*\/Pages[^>]*\/Count\s+(\d+)/);
  if (m) return Number(m[1]);
  return (text.match(/\/Type\s*\/Page\b/g) || []).length;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.html) {
    console.error('Usage: node export-pdf.js <html-path> [pdf-path] [--png-dir <dir>]');
    process.exit(2);
  }
  const htmlPath = path.resolve(args.html);
  if (!fs.existsSync(htmlPath)) {
    console.error(`HTML file not found: ${htmlPath}`);
    process.exit(2);
  }
  const pdfPath = path.resolve(args.pdf || htmlPath.replace(/\.html?$/i, '.pdf'));

  let chromium;
  try {
    ({ chromium } = require('@playwright/test'));
  } catch {
    console.error('Cannot load `@playwright/test`. Install it first: npm i -D @playwright/test');
    process.exit(2);
  }

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1123, height: 794 } });
    await page.goto('file://' + htmlPath, { waitUntil: 'networkidle' });
    await page.emulateMedia({ media: 'print' });
    await page.evaluate(() => document.fonts.ready);
    const count = await page.evaluate(() => {
      const slides = document.querySelectorAll('section.slide, [data-slide-id]');
      slides.forEach((el, i) => el.setAttribute('data-slide-index', String(i)));
      return slides.length;
    });
    if (count === 0) {
      console.error('No `section.slide` or `[data-slide-id]` elements found; nothing to render.');
      process.exit(1);
    }
    if (args.pngDir) fs.mkdirSync(args.pngDir, { recursive: true });
    const buffers = [];
    for (let i = 0; i < count; i++) {
      const style = await page.addStyleTag({
        content: `[data-slide-index]{display:none!important}[data-slide-index="${i}"]{display:flex!important}`,
      });
      buffers.push(await page.pdf({
        width: '1123px', height: '794px', printBackground: true, preferCSSPageSize: false,
        margin: { top: '0', right: '0', bottom: '0', left: '0' },
      }));
      if (args.pngDir) {
        await page.screenshot({ path: path.join(args.pngDir, `page-${String(i + 1).padStart(2, '0')}.png`) });
      }
      await page.evaluate((el) => el.remove(), style);
    }
    const merged = mergeSinglePagePdfs(buffers);
    fs.writeFileSync(pdfPath, merged);
    const pages = countPages(fs.readFileSync(pdfPath));
    if (pages !== count) {
      fs.unlinkSync(pdfPath);
      console.error(`Render mismatch: HTML has ${count} slides, PDF has ${pages} pages. Output removed.`);
      process.exit(1);
    }
    console.log(`${pdfPath} pages=${pages}`);
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
