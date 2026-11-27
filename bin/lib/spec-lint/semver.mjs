// The small part of semver the spec lint needs: compare plain versions, and test a version against the
// range forms npm writes into package.json (exact, ^, ~, >=, <=, >, <, x-ranges, hyphen ranges, ||, spaces).
// Pre-release tags sort before their release, as npm does.

const RE = /^v?(\d+)(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/;

export function parse(v) {
  const m = RE.exec(String(v).trim());
  if (!m) return null;
  const n = (s) => (s === undefined || /^[xX*]$/.test(s) ? null : Number(s));
  return { major: Number(m[1]), minor: n(m[2]), patch: n(m[3]), pre: m[4] ? m[4].split('.') : [] };
}

export function valid(v) {
  const p = parse(v);
  return !!p && p.minor !== null && p.patch !== null;
}

export function compare(a, b) {
  const x = typeof a === 'string' ? parse(a) : a;
  const y = typeof b === 'string' ? parse(b) : b;
  for (const k of ['major', 'minor', 'patch']) {
    const d = (x[k] ?? 0) - (y[k] ?? 0);
    if (d) return d < 0 ? -1 : 1;
  }
  if (!x.pre.length && !y.pre.length) return 0;
  if (!x.pre.length) return 1;
  if (!y.pre.length) return -1;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i], q = y.pre[i];
    if (p === undefined) return -1;
    if (q === undefined) return 1;
    if (p === q) continue;
    const pn = /^\d+$/.test(p), qn = /^\d+$/.test(q);
    if (pn && qn) return Number(p) < Number(q) ? -1 : 1;
    if (pn) return -1;
    if (qn) return 1;
    return p < q ? -1 : 1;
  }
  return 0;
}

export const sort = (versions) => [...versions].sort(compare);

// One comparator set ("^0.3.7", ">=0.3.12 <1.0.0", "1.2.x") as a list of [op, version] pairs.
function comparators(set) {
  const out = [];
  const hy = /^\s*(\S+)\s+-\s+(\S+)\s*$/.exec(set);
  if (hy) return [['>=', floor(parse(hy[1]))], ...upper('<=', parse(hy[2]))];
  for (const tok of set.trim().split(/\s+/).filter(Boolean)) {
    const m = /^(\^|~|>=|<=|>|<|=)?\s*(.*)$/.exec(tok);
    const op = m[1] || '';
    const v = parse(m[2]);
    if (!v) { if (/^[xX*]?$/.test(m[2])) continue; throw new Error(`unsupported range "${tok}"`); }
    if (op === '^') {
      const lo = floor(v);
      const hi = v.major > 0 || v.minor === null ? { major: v.major + 1, minor: 0, patch: 0, pre: [] }
        : v.minor > 0 || v.patch === null ? { major: 0, minor: v.minor + 1, patch: 0, pre: [] }
          : { major: 0, minor: 0, patch: v.patch + 1, pre: [] };
      out.push(['>=', lo], ['<', hi]);
    } else if (op === '~') {
      const hi = v.minor === null ? { major: v.major + 1, minor: 0, patch: 0, pre: [] } : { major: v.major, minor: v.minor + 1, patch: 0, pre: [] };
      out.push(['>=', floor(v)], ['<', hi]);
    } else if (op === '' || op === '=') {
      if (v.minor === null || v.patch === null) {
        const hi = v.minor === null ? { major: v.major + 1, minor: 0, patch: 0, pre: [] } : { major: v.major, minor: v.minor + 1, patch: 0, pre: [] };
        out.push(['>=', floor(v)], ['<', hi]);
      } else out.push(['=', v]);
    } else if (op === '<=' || op === '>') out.push(...upper(op, v));
    else out.push([op, floor(v)]);
  }
  return out;
}
const floor = (v) => ({ major: v.major, minor: v.minor ?? 0, patch: v.patch ?? 0, pre: v.pre });
function upper(op, v) {
  if (v.minor !== null && v.patch !== null) return [[op, v]];
  const next = v.minor === null ? { major: v.major + 1, minor: 0, patch: 0, pre: [] } : { major: v.major, minor: v.minor + 1, patch: 0, pre: [] };
  return [[op === '<=' ? '<' : '>=', next]];
}

export function satisfies(version, range) {
  const v = parse(version);
  if (!v) return false;
  return String(range).split('||').some((set) => {
    let cs;
    try { cs = comparators(set); } catch { return false; }
    if (v.pre.length && !cs.some(([, c]) => c.pre.length && c.major === v.major && c.minor === v.minor && c.patch === v.patch)) return false;
    return cs.every(([op, c]) => {
      const d = compare(v, c);
      return op === '>=' ? d >= 0 : op === '<=' ? d <= 0 : op === '>' ? d > 0 : op === '<' ? d < 0 : d === 0;
    });
  });
}

/** The highest version of `versions` that satisfies `range` (npm installs the highest match), or null. */
export function maxSatisfying(versions, range) {
  const ok = versions.filter((v) => satisfies(v, range));
  return ok.length ? sort(ok).at(-1) : null;
}
