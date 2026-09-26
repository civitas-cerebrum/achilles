// pi/tests/fixtures/fake-pi-child.mjs — stands in for `pi --mode json -p` in unit tests.
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
const sd = args[args.indexOf('--session-dir') + 1];
fs.mkdirSync(sd, { recursive: true });
fs.writeFileSync(path.join(sd, '2026-01-01T00-00-00-000Z_child-1.jsonl'),
  JSON.stringify({
    type: 'session', id: 'child-1',
    protocol: process.env.ACHILLES_PROTOCOL ?? '',
    depth: process.env.ACHILLES_PI_DEPTH ?? '',
    agentType: process.env.ACHILLES_PI_AGENT_TYPE ?? '',
    args,
    // Content and mode of the @file prompt argument, read while it still exists.
    prompt: (() => { const a = args.find((x) => x.startsWith('@')); return a ? fs.readFileSync(a.slice(1), 'utf8') : null; })(),
    promptMode: (() => { const a = args.find((x) => x.startsWith('@')); return a ? (fs.statSync(a.slice(1)).mode & 0o777) : null; })(),
  }) + '\n');
if (process.env.FAKE_PI_FAIL) { console.error('boom from child'); process.exit(3); }
console.log(JSON.stringify({ type: 'session', version: 3, id: 'child-1' }));
console.log(JSON.stringify({ type: 'tool_execution_end', toolCallId: 'x', toolName: 'bash', result: {}, isError: false }));
console.log(JSON.stringify({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: process.env.FAKE_PI_LONG ? 'y'.repeat(40 * 1024) : process.env.FAKE_PI_UTF8 ? '€'.repeat(150000) : 'child says hi' }] } }));
console.log(JSON.stringify({ type: 'agent_settled' }));
