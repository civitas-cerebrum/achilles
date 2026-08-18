// test-id-scan.js — spec-file test-identity scanner for
// hooks/test-id-compliance-gate.sh.
//
// Given the before/after content of a spec file, reports which test cases the
// pending write would ADD without a stable test ID, and which IDs the write
// would duplicate inside that file. Scoped to added-or-changed titles on
// purpose: a suite that predates the convention must never block an unrelated
// edit, so migration is incremental (see
// skills/element-interactions/references/test-identity.md §1).
//
// Usage: node test-id-scan.js <before-file> <after-file>
//   → {"untagged":[...], "duplicates":[{"id":"LGN-04","titles":[...]}]}
// A missing before-file is treated as empty content (new-file Write).

'use strict';

const fs = require('fs');

// test(...) / test.only / test.skip / test.fail / test.fixme with a string
// literal first argument. test.describe, test.step and the hook variants
// (beforeEach, afterAll, …) are deliberately absent — the case is the unit of
// identity, and a `test.skip(condition, 'reason')` call inside a body has a
// non-string first argument, so it never matches.
const TEST_RE = /\btest(?:\.(?:only|skip|fail|fixme))?\s*\(\s*(['"`])((?:\\.|(?!\1)[^\\])*)\1/g;

// TC-prefixed ID as the first token, optionally bracketed, followed by a
// separator or the end of the title. The shape is `TC` plus up to three more
// uppercase letters of area code (2-5 letters in total), a dash, and a 4-6
// digit ordinal: TC-0042, TCLG-000420, TCSGNP-… is too long.
//
// The `TC` stem makes an ID greppable across a whole repo with no false
// positives — no product string looks like `TCLG-000420` — and the 4-6 digit
// ordinal leaves room to number by area without renumbering later.
//
// A project on another scheme pins its own with CIVITAS_TEST_ID_PATTERN, a
// regex source anchored at the start of the title with the ID in group 1 —
// e.g. CIVITAS_TEST_ID_PATTERN='^\\s*([A-Z]{2,4}-[0-9]{2,4})' for a
// journey-prefixed suite (LGN-04). An unparseable pattern falls back to the
// default rather than failing every write.
const DEFAULT_ID_RE = /^\s*[[(]?(TC[A-Z]{0,3}-\d{4,6})[\])]?(?=[\s:·—|-]|$)/;

function resolveIdPattern(source) {
  if (!source) return DEFAULT_ID_RE;
  try {
    return new RegExp(source);
  } catch {
    return DEFAULT_ID_RE;
  }
}

const ID_RE = resolveIdPattern(process.env.CIVITAS_TEST_ID_PATTERN);

// Drop whole-line comments so a commented-out test is not read as a real one.
// Only leading-comment lines are stripped: blanking every `//` occurrence
// would mangle a title that legitimately contains a URL.
function stripCommentLines(src) {
  return src
    .split('\n')
    .filter((line) => !/^\s*(\/\/|\/\*|\*)/.test(line))
    .join('\n');
}

function titles(src) {
  const out = [];
  const scannable = stripCommentLines(src);
  let m;
  TEST_RE.lastIndex = 0;
  while ((m = TEST_RE.exec(scannable)) !== null) out.push(m[2]);
  return out;
}

function idOf(title) {
  const m = ID_RE.exec(title);
  if (!m) return null;
  // An ID with no behaviour sentence after it is not a titled test.
  const rest = title.slice(m[0].length).replace(/^[\s:·—|-]+/, '').trim();
  return rest.length > 0 ? m[1] : null;
}

function tally(list) {
  const counts = new Map();
  for (const item of list) counts.set(item, (counts.get(item) ?? 0) + 1);
  return counts;
}

function scan(before, after) {
  const beforeTitles = titles(before);
  const afterTitles = titles(after);

  // Untagged titles this write introduces: an untagged title already present
  // in `before` is pre-existing and out of scope, occurrence for occurrence.
  const beforeUntagged = tally(beforeTitles.filter((t) => idOf(t) === null));
  const untagged = [];
  for (const t of afterTitles) {
    if (idOf(t) !== null) continue;
    const seen = beforeUntagged.get(t) ?? 0;
    if (seen > 0) beforeUntagged.set(t, seen - 1);
    else untagged.push(t);
  }

  // Duplicate IDs this write introduces: a collision that already existed at
  // the same multiplicity is not this edit's doing.
  const beforeIds = tally(beforeTitles.map(idOf).filter(Boolean));
  const afterById = new Map();
  for (const t of afterTitles) {
    const id = idOf(t);
    if (!id) continue;
    if (!afterById.has(id)) afterById.set(id, []);
    afterById.get(id).push(t);
  }
  const duplicates = [];
  for (const [id, ts] of afterById) {
    if (ts.length > 1 && ts.length > (beforeIds.get(id) ?? 0)) duplicates.push({ id, titles: ts });
  }

  return { untagged, duplicates };
}

module.exports = { scan, titles, idOf, DEFAULT_ID_RE, resolveIdPattern };

if (require.main === module) {
  const read = (p) => {
    try {
      return fs.readFileSync(p, 'utf8');
    } catch {
      return '';
    }
  };
  process.stdout.write(JSON.stringify(scan(read(process.argv[2]), read(process.argv[3]))));
}
