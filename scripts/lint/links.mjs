import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { walk, SKILLS_DIR } from './util.mjs';

// Check 2 — relative .md links under skills/**, docs/**, CONTRIBUTING.md resolve.
export function run(report) {
  const detail = [];
  const mdFiles = [
    ...walk(SKILLS_DIR, (f) => f.endsWith('.md')),
    ...walk('docs', (f) => f.endsWith('.md')),
    ...(existsSync('CONTRIBUTING.md') ? ['CONTRIBUTING.md'] : []),
  ];
  const linkRe = /\]\(([^)]+)\)/g;
  let checked = 0;

  for (const file of mdFiles) {
    // Links inside fenced code are templates, not references.
    const text = readFileSync(file, 'utf8').replace(/^\s*(```|~~~)[\s\S]*?^\s*\1\s*$/gm, '');
    let m;
    while ((m = linkRe.exec(text)) !== null) {
      let target = m[1].trim();
      if (/^[a-z][a-z0-9+.-]*:\/\//i.test(target) || target.startsWith('#') || target.startsWith('mailto:')) continue;
      const hash = target.indexOf('#');
      if (hash !== -1) target = target.slice(0, hash);
      if (target === '') continue;
      if (!/\.(md|json|js|mjs|html)$/.test(target) && !target.endsWith('/')) continue;
      checked++;
      const resolved = resolve(dirname(file), target);
      if (!existsSync(resolved)) detail.push(`${file}: dead link → ${m[1]}`);
    }
  }

  report(`relative links resolve (${checked} links across ${mdFiles.length} files)`, detail.length === 0, detail);
}
