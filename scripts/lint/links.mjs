import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { walk, SKILLS_DIR } from './util.mjs';

// Check 2 — relative .md links under skills/** resolve
export function run(report) {
  const detail = [];
  const mdFiles = walk(SKILLS_DIR, (f) => f.endsWith('.md'));
  // Markdown link target: ](path) — capture path, strip any #anchor.
  const linkRe = /\]\(([^)]+)\)/g;
  let checked = 0;

  for (const file of mdFiles) {
    const text = readFileSync(file, 'utf8');
    let m;
    while ((m = linkRe.exec(text)) !== null) {
      let target = m[1].trim();
      // Skip absolute URLs, anchors-only, and mailto.
      if (/^[a-z][a-z0-9+.-]*:\/\//i.test(target)) continue;
      if (target.startsWith('#')) continue;
      if (target.startsWith('mailto:')) continue;
      // Strip anchor fragment.
      const hash = target.indexOf('#');
      if (hash !== -1) target = target.slice(0, hash);
      if (target === '') continue;
      // Only validate relative links that point at a .md file.
      if (!target.endsWith('.md')) continue;
      checked++;
      const resolved = resolve(dirname(file), target);
      if (!existsSync(resolved)) {
        detail.push(`${file}: dead link → ${m[1]}`);
      }
    }
  }

  report(
    `skills/** relative .md links resolve (${checked} links across ${mdFiles.length} files)`,
    detail.length === 0,
    detail,
  );
}
