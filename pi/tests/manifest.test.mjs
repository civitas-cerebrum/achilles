import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const root = path.resolve(import.meta.dirname, '..', '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'hooks', 'manifest.json'), 'utf8'));
test('manifest has 51 entries, each naming an existing hook', () => {
  assert.equal(manifest.length, 51);
  for (const e of manifest) {
    assert.ok(fs.existsSync(path.join(root, 'hooks', e.file)), e.file);
    assert.ok(['PreToolUse','PostToolUse','Stop','SubagentStop','UserPromptSubmit'].includes(e.event), e.event);
    assert.ok(e.matcher === null || typeof e.matcher === 'string');
  }
});
test('postinstall exports the same manifest', () => {
  const post = require(path.join(root, 'scripts', 'postinstall.js'));
  assert.deepEqual(post.HOOK_MANIFEST, manifest);
});
