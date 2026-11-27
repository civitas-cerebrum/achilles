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

/** Rules new or promoted in the rulesets after `from` up to and including `to`. */
export function promotedBetween(from, to, rulesets = RULESETS) {
  const a = rulesets.findIndex((r) => r.id === from);
  const b = rulesets.findIndex((r) => r.id === to);
  const out = new Set();
  for (let i = a + 1; i <= b; i++) {
    const r = rulesets[i];
    const prev = new Set(rulesets[i - 1].blocking);
    for (const id of r.promoted || r.blocking) out.add(id);
    for (const id of r.blocking) if (!prev.has(id)) out.add(id);
  }
  return out;
}
