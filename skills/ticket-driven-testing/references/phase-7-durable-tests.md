# 7. Durable tests and sentinels

Regression tests go in the project's suite, not the bundle. One test per AC, plus edge cases and close-regression cover for what the diff touched nearby.

**Written is not committed.** Whether these tests land in the suite or stay in the evidence
bundle is §8d's decision, made after they have proven themselves in §8–8c — and the default is
that they stay. Write them to committable standard either way; a test that would embarrass the
suite proves nothing as evidence either.

For each confirmed defect, write a **sentinel**: assert the *correct* behaviour and mark it `test.fail()`. It fails today, keeps the suite green, and flips to a loud "expected to fail but passed" the moment someone fixes the bug — which is the signal to delete it.

**Scope of the `test.fail()` licence.** This section is the ONE sanctioned use of `test.fail()` in the whole suite: a defect sentinel **tied to a tracked ticket**, with a removed-when-fixed lifecycle (the "flips loud → delete" mechanism above IS the lifecycle). Where no ticket owns the marker it is banned — coverage-expansion and its adversarial passes never commit `test.fail()`; their suspected bugs stay ledger-only (see `coverage-expansion/SKILL.md` §"Non-goals"; resolution record: `../achilles-protocol/references/test-composition-standards.md` §3.2).

```ts
test('TCSG-000110 · [SENTINEL <TICKET>-D1] <correct behaviour> @known-defect', async ({ steps }) => {
  test.fail(true, 'Known defect: <what is wrong>. Delete this sentinel once fixed.')
  await steps.verifyCount('stateMarker', 'SomePage', { exactly: 0 })
})
```

Sentinels carry the `@known-defect` tag (canonical: `../achilles-protocol/references/test-identity.md` §2) so `self-repair` / `test-repair` / `failure-diagnosis` exempt them from heal and rerun cycles — the tag marks the intentional relationship to a filed defect; `test.fail()` only inverts the reporting. The title's leading test ID follows `test-identity.md` §1.

**Pick a durable observable.** A sentinel is worthless if the app erases its own evidence — see the session-storage trap below.

**Feature gates must ask the ENVIRONMENT, never the page.** A gate that probes the feature's own
selector and skips when it is missing cannot distinguish "not deployed yet" from "regressed" —
they look identical. Measured: with the feature's root element hidden, a page-probing gate turned a
total AC regression into `2 skipped` instead of `2 failed`. The gate that keeps the nightly green
also blinds the suite to the thing it exists to catch.

Have the environment declare expectation instead, and default to fail-closed:

```ts
const FEATURE_EXPECTED = (process.env.E2E_FEATURE_<TICKET> ?? 'expected') !== 'absent'
// expected + present → run
// expected + absent  → FAIL   ← the regression
// absent   + absent  → skip   ← deliberate, annotated
// absent   + present → FAIL   ← shipped where it should not have
```

The environment without the feature opts out explicitly; removing that opt-out is what arms the
tests at release, and is a one-line change rather than an edit to every spec.

**Every absence assertion needs a positive control in the same test.** `count === 0`,
`toBeHidden` (which passes on ZERO matches) and "element not present" all pass on a 404, an
unhydrated page, a challenge page, and an environment where the feature never existed. Assert the
page is alive first — then absence means something.

If the suite runs against an environment where the feature is not deployed yet, gate it — with
**this** implementation, not one of your own. Copy it verbatim; §8's negative control depends on
the `GATE_OFF` escape being present.

```ts
// ONE gate. Env-declared, fail-closed, with all four outcomes in code.
// Ticket keys contain hyphens, which are illegal in env identifiers — normalise to underscores:
//   ABC-450 -> E2E_FEATURE_ABC_450
const FEATURE_ENV = 'E2E_FEATURE_ABC_450'          // <- your normalised ticket key
const GATE_OFF = process.env.E2E_FEATURE_GATE === 'off'   // §8 negative control uses this
// Legal values: 'expected' (default) | 'absent'. Anything else is a config error, not a silent pass.
const raw = process.env[FEATURE_ENV] ?? 'expected'
if (!['expected', 'absent'].includes(raw)) throw new Error(`${FEATURE_ENV} must be 'expected' or 'absent', got '${raw}'`)
const FEATURE_EXPECTED = raw === 'expected'

test.beforeEach(async ({ steps }, testInfo) => {
  // POSITIVE CONTROL FIRST. Absence assertions below are meaningless on a dead page.
  await steps.verifyState('pageRoot', 'SomePage', 'visible')

  const present = await steps.isVisible('featureRoot', 'SomePage', { timeout: 5000 })
  testInfo.annotations.push({ type: 'feature-gate', description: `expected=${FEATURE_EXPECTED} present=${present}` })

  if (GATE_OFF) return                                   // §8: run regardless, expect failures
  if (FEATURE_EXPECTED && !present) {
    throw new Error('feature expected on this environment but absent — this IS the regression')
  }
  if (!FEATURE_EXPECTED && present) {
    throw new Error('feature not expected here but rendered anyway')
  }
  if (!FEATURE_EXPECTED) test.skip(true, `not deployed here (${FEATURE_ENV}=absent)`)
})
```

| `FEATURE_EXPECTED` | feature present | outcome |
|---|---|---|
| true | yes | run |
| true | **no** | **FAIL** — the regression |
| false | no | skip, annotated |
| false | **yes** | **FAIL** — shipped where it should not have |

The environment lacking the feature sets `E2E_FEATURE_<KEY>=absent` explicitly. **Removing that one
line is what arms the tests at release** — no spec edits.

Why not probe the page and skip? Because that cannot tell "not deployed" from "regressed". Measured:
with the feature's root element hidden, a page-probing gate turned a total AC regression into
`2 skipped` rather than `2 failed`.
