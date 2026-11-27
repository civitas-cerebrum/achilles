// The rulesets a compliance baseline is recorded under (test-baseline.md §Baseline and ratchet). A ruleset
// names the rules whose blocking findings a baseline counts. A rule that becomes blocking, or whose blocking
// definition widens, is added in a new ruleset that lists it under `promoted`: a baseline recorded under an
// older ruleset does not compare that rule (its counts would rise without any change to the suite) until
// `achilles-spec-lint --update-baseline --ruleset-upgrade` records it from the content. Each new ruleset
// gets a CHANGELOG line.
//
// TB-S8 (a change under the inspect directory) and TB-A13 (a version gap, blocking only in a touched test)
// are decided per change and never counted.

export const RULESETS = [
  {
    id: 'tb-1',
    blocking: [
      'TB-A1', 'TB-A2', 'TB-A3', 'TB-A4', 'TB-A5', 'TB-A7', 'TB-A10', 'TB-A11', 'TB-A12', 'TB-A14',
      'TB-D4', 'TB-F1', 'TB-F3', 'TB-F5', 'TB-F6', 'TB-G0', 'TB-G1', 'TB-I1', 'TB-I2', 'TB-I3', 'TB-I4',
      'TB-N1', 'TB-N4', 'TB-P1', 'TB-P2', 'TB-S1', 'TB-S2', 'TB-S3', 'TB-S4', 'TB-S7', 'TB-X3',
    ],
    promoted: null, // the first ruleset: every rule it lists is new
  },
];

/** Rules decided per change, never counted in a baseline. */
export const PER_CHANGE = new Set(['TB-S8', 'TB-A13']);

export const CURRENT_RULESET = RULESETS[RULESETS.length - 1].id;

/** The position of a ruleset id in the history, or -1 when this engine does not know it. */
export const rulesetIndex = (id) => RULESETS.findIndex((r) => r.id === id);

/** The rules a ruleset counts. */
export function countedRules(id) {
  const r = RULESETS[rulesetIndex(id)];
  return new Set(r ? r.blocking : []);
}

/**
 * Checks a ruleset history: every ruleset after the first lists, as an array under `promoted`, every rule it
 * adds to `blocking` or whose blocking definition it widens. Throws on a malformed history.
 */
export function validateRulesets(rulesets = RULESETS) {
  rulesets.forEach((r, i) => {
    if (i === 0) return;
    if (!Array.isArray(r.promoted)) throw new Error(`ruleset ${r.id}: \`promoted\` must be an array of the rules it adds or widens`);
    const prev = new Set(rulesets[i - 1].blocking);
    const missing = r.blocking.filter((x) => !prev.has(x) && !r.promoted.includes(x));
    if (missing.length) throw new Error(`ruleset ${r.id}: ${missing.join(', ')} become blocking but are not listed under \`promoted\``);
    const unknown = r.promoted.filter((x) => !r.blocking.includes(x));
    if (unknown.length) throw new Error(`ruleset ${r.id}: promoted ${unknown.join(', ')} are not in its \`blocking\` list`);
  });
}

/** Rules added or promoted in the rulesets after `from` up to and including `to`. */
export function promotedBetween(from, to, rulesets = RULESETS) {
  validateRulesets(rulesets);
  const a = rulesets.findIndex((r) => r.id === from);
  const b = rulesets.findIndex((r) => r.id === to);
  const out = new Set();
  for (let i = Math.max(a + 1, 1); i <= b; i++) for (const id of rulesets[i].promoted) out.add(id);
  return out;
}
