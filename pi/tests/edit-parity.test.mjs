import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { applyPiEdits, resolveToCwd } from '../extensions/achilles/edit-match.ts';
import { wholeFileEdit } from '../extensions/achilles/payload.ts';

// edit-match.ts is a port of pi's edit pipeline. When pi is installed globally, run one table through
// both and require the same bytes and the same accept/reject decision.
let root = '';
try { root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim(); } catch { /* no npm */ }
const dist = path.join(root, '@earendil-works', 'pi-coding-agent', 'dist');
const have = root !== '' && fs.existsSync(path.join(dist, 'core', 'tools', 'edit-diff.js'));

const table = [
  ['exact multi', 'alpha o1 beta o2 gamma\n', [['o2', 'n2'], ['o1', 'n1']]],
  ['duplicate', 'x o1 o1 y\n', [['o1', 'n1'], ['y', 'Y']]],
  ['duplicate single', 'o1 o1\n', [['o1', 'n1']]],
  ['overlap abc+bcd', 'xabcdx\n', [['abc', 'A'], ['bcd', 'B']]],
  ['self-overlap aa', 'aaa b\n', [['aa', 'X'], ['b', 'B']]],
  ['empty oldText', 'abc\n', [['', 'A'], ['c', 'C']]],
  ['not found', 'abc\n', [['zz', 'A'], ['c', 'C']]],
  ['no-op', 'k1 k2\n', [['k1', 'k1'], ['k2', 'k2']]],
  ['crlf multi-line', 'a\r\nb\r\nc\r\nd\r\n', [['a\nb', 'A\nB'], ['d', 'D']]],
  ['crlf newText with LF', 'a\r\nb\r\nc\r\n', [['a', 'x\ny'], ['c', 'C']]],
  ['crlf oldText given as CRLF', 'a\r\nb\r\nc\r\n', [['a\r\nb', 'AB']]],
  ['mixed endings', 'a\r\nb\nc\r\n', [['b', 'B']]],
  ['cr only', 'a\rb\rc', [['b', 'B']]],
  ['fuzzy trailing ws', 'foo  \nbar\nbaz\n', [['foo\nbar', 'F'], ['baz', 'Z']]],
  ['fuzzy smart quotes', 'say “hi”\nkeep  \n', [['say "hi"', 'say "bye"']]],
  ['fuzzy dashes + nbsp', 'a—b c\nz\n', [['a-b c', 'X']]],
  ['fuzzy duplicate', 'x = "q"\nx = “q”\nend\n', [['x = "q"', 'y'], ['end', 'E']]],
  ['bom', '﻿k1 k2\n', [['k1', 'K1'], ['k2', 'K2']]],
  ['bom crlf', '﻿k1\r\nk2\r\n', [['k1\nk2', 'K']]],
  ['nfkc', 'ﬁle\nx\n', [['file', 'F']]],
  ['deletion', 'keep\ndrop\nkeep2\n', [['drop\n', '']]],
];

test('edit-match.ts matches the installed pi edit pipeline', { skip: have ? false : 'pi is not installed globally' }, async () => {
  const diff = await import(pathToFileURL(path.join(dist, 'core', 'tools', 'edit-diff.js')).href);
  const { splitBom } = await import(pathToFileURL(path.join(dist, 'utils', 'text.js')).href);
  const piApply = (raw, edits) => {
    const { bom, text } = splitBom(raw);
    const ending = diff.detectLineEnding(text);
    const { newContent } = diff.applyEditsToNormalizedContent(diff.normalizeToLF(text), edits, 'f');
    return bom + diff.restoreLineEndings(newContent, ending);
  };
  const outcome = (fn) => { try { return { ok: true, out: fn() }; } catch { return { ok: false }; } };
  let accepted = 0;
  for (const [name, raw, pairs] of table) {
    const edits = pairs.map(([oldText, newText]) => ({ oldText, newText }));
    const theirs = outcome(() => piApply(raw, edits));
    const ours = outcome(() => applyPiEdits(raw, edits));
    assert.deepEqual(ours, theirs, name);
    // The hook-facing old_string/new_string, applied Claude-style to the raw file, yields pi's bytes.
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'parity-'));
    fs.writeFileSync(path.join(dir, 'f'), raw);
    const span = wholeFileEdit('f', pairs.map(([o, n]) => ({ old_string: o, new_string: n })), dir);
    fs.rmSync(dir, { recursive: true, force: true });
    assert.equal(span !== undefined, theirs.ok, `${name}: translation accepts iff pi accepts`);
    if (theirs.ok) {
      accepted++;
      assert.equal(raw.split(span.old_string).length - 1, 1, `${name}: old_string unique in the raw file`);
      assert.equal(raw.replace(span.old_string, () => span.new_string), theirs.out, `${name}: span reproduces pi's write`);
    }
    if (process.env.PARITY_VERBOSE) console.log(`${name.padEnd(28)} pi=${theirs.ok ? 'accept' : 'reject'} ours=${ours.ok ? 'accept' : 'reject'} same=${JSON.stringify(ours) === JSON.stringify(theirs)}`);
  }
  assert.ok(accepted >= 8 && accepted < table.length, `table exercises both outcomes (${accepted}/${table.length} accepted)`);
});

test('resolveToCwd matches pi', { skip: have ? false : 'pi is not installed globally' }, async () => {
  const { resolveToCwd: piResolve } = await import(pathToFileURL(path.join(dist, 'core', 'tools', 'path-utils.js')).href);
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'parity-'));
  for (const p of ['a.md', '@a.md', '~/x', '~', '/abs/p', '@/abs/p', 'sub/../b', 'with space', 'file:///tmp/f.txt']) {
    assert.equal(resolveToCwd(p, cwd), piResolve(p, cwd), p);
  }
});
