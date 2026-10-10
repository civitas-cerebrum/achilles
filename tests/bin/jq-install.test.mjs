// jq-install.test.mjs — the bundled jq is moved into place only when its sha256 is the pinned one.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const { finalizeJq } = createRequire(import.meta.url)('../../scripts/install/jq.js');

// A fake download that would leave a marker behind if it were ever run.
function fakeDownload() {
  const dir = mkdtempSync(path.join(tmpdir(), 'jq-install-'));
  const tmp = path.join(dir, 'jq.part');
  const marker = path.join(dir, 'ran');
  writeFileSync(tmp, `#!/bin/sh\ntouch '${marker}'\n`);
  return { tmp, dest: path.join(dir, 'jq'), marker, sha: createHash('sha256').update(`#!/bin/sh\ntouch '${marker}'\n`).digest('hex') };
}

test('a checksum mismatch deletes the download without making it executable or running it', () => {
  const f = fakeDownload();
  const r = finalizeJq(f.tmp, f.dest, '0'.repeat(64));
  assert.equal(r.ok, false);
  assert.match(r.message, /failed its checksum/);
  assert.equal(existsSync(f.tmp), false);
  assert.equal(existsSync(f.dest), false);
  assert.equal(existsSync(f.marker), false);
});

test('a matching checksum lands the binary executable, still unrun', () => {
  const f = fakeDownload();
  const r = finalizeJq(f.tmp, f.dest, f.sha);
  assert.equal(r.ok, true);
  assert.equal(statSync(f.dest).mode & 0o111, 0o111);
  assert.equal(existsSync(f.marker), false);
});
