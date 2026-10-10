import { readFileSync } from 'node:fs';
const a = process.argv.slice(2);
const id = a[a.indexOf('--id') + 1];
const text = a.filter((x) => x.endsWith('.md')).map((d) => readFileSync(d, 'utf8')).join('\n');
const block = text.split(/^#+ /m).find((b) => b.startsWith(id + ' ')) ?? '';
if (!block.includes('**Oracle**')) { console.log('[specs.shape] ' + id + ': missing **Oracle**'); process.exit(1); }
