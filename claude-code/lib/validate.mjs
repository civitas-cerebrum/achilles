#!/usr/bin/env node
// validate.mjs — schema validation for the adapter's ledger and return-review hooks, which run
// where no npm package can be imported and so call this as a child process.
//
// Usage: node validate.mjs <schema> < text
//   <schema>  onboarding-status | perf-onboarding-status | subagent-returns/<role> (a file under
//             schemas/, without .schema.json)
//   stdin     the document: JSON, YAML, or Markdown whose first ```json / ```yaml fence (or a
//             leading YAML front block) holds it
// Prints {"ok":true} or {"ok":false,"parse":"…"} or {"ok":false,"errors":["<path> <message>", …]}.
// Exit 0 whatever the verdict; exit 2 when the schema name is unknown.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { parse as parseYaml } from 'yaml';

const schemas = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'schemas');
const name = process.argv[2] ?? '';
const file = join(schemas, `${name}.schema.json`);
if (!/^[a-z0-9-]+(\/[a-z0-9-]+)?$/.test(name) || !existsSync(file)) {
  process.stderr.write(`validate.mjs: unknown schema ${name}\n`);
  process.exit(2);
}

const ajv = new (Ajv.default || Ajv)({ strict: true, allErrors: true, allowUnionTypes: true, strictSchema: false });
(addFormats.default || addFormats)(ajv);
for (const f of readdirSync(join(schemas, 'subagent-returns'))) {
  if (f.endsWith('.schema.json') && `subagent-returns/${f}` !== `${name}.schema.json`) ajv.addSchema(JSON.parse(readFileSync(join(schemas, 'subagent-returns', f), 'utf8')));
}
const validate = ajv.compile(JSON.parse(readFileSync(file, 'utf8')));

function documentOf(text) {
  const fence = /```(json|ya?ml)\s*\n([\s\S]*?)```/i.exec(text);
  const body = fence ? fence[2] : text.replace(/^---\n([\s\S]*?)\n---[\s\S]*$/, '$1');
  try { return { doc: JSON.parse(body) }; } catch { /* YAML next */ }
  try { return { doc: parseYaml(body) }; } catch (e) { return { parse: String(e.message).split('\n')[0] }; }
}

let text = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { text += c; });
process.stdin.on('end', () => {
  const { doc, parse } = documentOf(text);
  if (parse !== undefined) return void process.stdout.write(JSON.stringify({ ok: false, parse }));
  if (validate(doc)) return void process.stdout.write(JSON.stringify({ ok: true }));
  const errors = (validate.errors ?? []).slice(0, 8).map((e) => `${e.instancePath || '/'} ${e.message}${e.params?.allowedValues ? ` (${e.params.allowedValues.join(', ')})` : ''}`);
  process.stdout.write(JSON.stringify({ ok: false, errors }));
});
