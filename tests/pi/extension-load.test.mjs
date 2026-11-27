// pi/index.ts loaded the way pi loads an extension: jiti, the loader pi ships (same version), with
// pi's alias map, which resolves pi's own packages and nothing else. A runtime import of a module
// only the Claude Code host provides (`claude-code`) fails here as it fails under pi, and then the
// whole extension (delegate_qa and every guard) does not load.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createJiti } from 'jiti';

const EXTENSION = fileURLToPath(new URL('../../pi/index.ts', import.meta.url));
const STUB = fileURLToPath(new URL('./pi-stub.mjs', import.meta.url));

// The keys of pi's getAliases() (dist/core/extensions/loader.js); pi is not installed here, so each
// points at a stub. 'claude-code' is deliberately absent, as it is in pi's map.
const PI_PACKAGES = ['pi-coding-agent', 'pi-agent-core', 'pi-tui', 'pi-ai/providers/all', 'pi-ai/compat', 'pi-ai/models', 'pi-ai/oauth', 'pi-ai'];
const alias = Object.fromEntries([
  ...PI_PACKAGES.flatMap((p) => [[`@earendil-works/${p}`, STUB], [`@mariozechner/${p}`, STUB]]),
  ...['typebox', 'typebox/compile', 'typebox/value', '@sinclair/typebox', '@sinclair/typebox/compile', '@sinclair/typebox/value'].map((p) => [p, STUB]),
]);

async function load() {
  const jiti = createJiti(import.meta.url, { moduleCache: false, alias });
  return jiti.import(EXTENSION, { default: true });
}

// The slice of pi's ExtensionAPI the extension touches while it loads.
function fakePi() {
  const handlers = new Map();
  const tools = [];
  const commands = [];
  return {
    handlers,
    tools,
    commands,
    on: (event, fn) => handlers.set(event, [...(handlers.get(event) ?? []), fn]),
    registerTool: (t) => tools.push(t.name),
    registerCommand: (name) => commands.push(name),
    getThinkingLevel: () => undefined,
  };
}

async function withRole(role, fn) {
  const before = process.env.ACHILLES_ROLE;
  if (role === undefined) delete process.env.ACHILLES_ROLE;
  else process.env.ACHILLES_ROLE = role;
  try {
    return await fn();
  } finally {
    if (before === undefined) delete process.env.ACHILLES_ROLE;
    else process.env.ACHILLES_ROLE = before;
  }
}

test('pi loads the extension: the main session gets delegate_qa and /achilles', async () => {
  const factory = await load();
  assert.equal(typeof factory, 'function');
  const pi = fakePi();
  await withRole(undefined, () => factory(pi));
  assert.deepEqual(pi.tools, ['delegate_qa']);
  assert.deepEqual(pi.commands, ['achilles']);
});

test('in an expert process the guards load and the Bash judge refuses a commit-check bypass; a plain commit passes', async () => {
  const factory = await load();
  const pi = fakePi();
  await withRole('achilles-author', () => factory(pi));
  const [guard] = pi.handlers.get('tool_call') ?? [];
  assert.equal(typeof guard, 'function');
  const ctx = { cwd: mkdtempSync(join(tmpdir(), 'ach-pi-load-')) };
  const call = (command) => guard({ toolName: 'bash', toolCallId: command, input: { command } }, ctx);
  const denied = await call('git commit --no-verify -m "fix: x"');
  assert.equal(denied?.block, true);
  assert.match(denied.reason, /^achilles: /);
  assert.doesNotMatch(denied.reason, /Bash judge failed/);
  assert.equal(await call('git commit -m "fix: x"'), undefined);
});
