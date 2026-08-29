# Test identity: stable IDs and the `@known-defect` tag

**Scope:** two conventions that make a test addressable across sessions, reports, and tools — the **test ID** every test case carries, and the **`@known-defect`** tag that marks a red test as intentional. Both are consumed by the compliance sweep (Stage 4b), the repair entrypoints (`self-repair`, `test-repair`), `failure-diagnosis`, `bug-discovery`, and `test-catalogue`.

---

## 1. Every test case carries a stable ID

**Rule.** The title of every test case begins with a stable identifier:

```ts
test('TCLG-000420 · a wrong password is rejected', async ({ steps }) => { … });
test.fail('TCSG-000110 · a duplicate registration surfaces a conflict', async ({ steps }) => { … });
```

Shape: **`TC` + up to three more letters of area code (2–5 letters in total), a dash, and a 4–6 digit ordinal** — `TC-0042`, `TCLG-000420`, `TCSGN-000110`. Optionally bracketed (`[TCLG-000420]`). The ID is the **first token of the title**, followed by a separator (space, `·`, `—`, `-`, `:`, `|`) and the sentence describing the behaviour. Describe-block titles need no ID — the case is the unit of identity.

The `TC` stem is load-bearing: it makes an ID greppable across a whole repo with no false positives (no product string looks like `TCLG-000420`), and the wide ordinal means a suite never renumbers to make room. Area codes are the team's to choose — `TCLG` login, `TCSG` signup, `TCCK` checkout.

A suite on another scheme pins its own: `CIVITAS_TEST_ID_PATTERN='^\s*([A-Z]{2,4}-[0-9]{2,4})'` accepts a journey-prefixed `LGN-04` instead. The pattern is a regex source anchored at the start of the title with the ID in capture group 1; an unparseable value falls back to the default rather than failing every write.

**Why the ID exists — four consumers that cannot work without it:**

| Consumer | What the ID buys |
|---|---|
| Targeted runs | `npx playwright test --grep "TCLG-000420"` addresses one case without quoting a whole sentence or knowing its file. No regex-escaping a title full of quotes and em-dashes. |
| Bug evidence | The evidence contract writes to `bug-evidence/<TEST-ID>/<timestamp>-<label>/`. Without an ID, that path is derived from a slugified title, so it moves the moment the wording is edited and the history for a defect scatters across directories. |
| Repair + catalogue reports | `self-repair`, `test-repair`, and `test-catalogue` key their per-test rows on the title. A title is prose; it gets reworded. An ID survives rewording, so a report from three sessions ago still points at the same case. |
| Human traceability | A journey map, a coverage table, a ticket, and a PR comment can all name `TCLG-000420` and mean exactly one test. Quoting a title in four places produces four slowly-diverging quotations. |

**Stability contract.** An ID belongs to a *scenario*, not to a line of code:

- Rewording the title keeps the ID.
- Moving the test to another file keeps the ID.
- Retiring a test **retires its ID** — it is never reassigned to a different scenario, so an ID in an old report never resolves to something else later.
- Splitting one case into two: the original keeps its ID, the new case takes a fresh one.

**IDs are unique within the suite.** The harness enforces uniqueness within a file (see below); cross-file collisions are the reviewer's check — the suite's ID index (typically `tests/e2e/docs/test-ids.md`) is the place to look before minting a new one.

**Harness-enforced by [`hooks/test-id-compliance-gate.sh`](../../../hooks/test-id-compliance-gate.sh)** — a `PreToolUse:Write|Edit` gate that denies a spec write introducing a *new* test case whose title carries no ID, or a duplicate ID within the same file. It scopes itself to newly-added titles, so an existing suite that predates the convention is never held hostage by an unrelated edit; migration is incremental, file by file. Shape comes from `CIVITAS_TEST_ID_PATTERN` when set, the default family otherwise. Kill-switch: `CIVITAS_DISABLE_TEST_ID_GATE=1`.

---

## 2. `@known-defect` marks an intentional red

**Rule.** A test that asserts the behaviour the app *should* have, while a confirmed and reported defect makes it fail today, carries the `@known-defect` tag — on the test title or on its enclosing `describe`:

```ts
test.describe('Signup — duplicate email @known-defect', () => {
  test('TCSG-000110 · registering an already-used email surfaces a conflict', async ({ steps }) => { … });
});
```

This is the regression-guard pattern: the test is not weakened to agree with the bug, and it is not skipped. It fails today and turns green — unedited — the day the defect is fixed. Weakening or skipping it makes the suite agree with the bug, at which point it can no longer detect it.

**Every `@known-defect` test points at a filed defect.** A tag with no report behind it is indistinguishable from a broken test that someone silenced. The pointer lives in a comment at the top of the spec (bug report path, ticket key, or `adversarial-findings.md` anchor).

### The no-rerun contract

**A `@known-defect` failure never triggers a rerun, a repair worker, or a diagnosis cycle.** It is a *known* red — the classification work is already done, and repeating it burns wall-clock, browser sessions, and worker budget on a conclusion that is already written down.

Concretely, every consumer treats it as its own terminal classification, distinct from both green and failing:

| Consumer | Behaviour |
|---|---|
| `self-repair` (`bin/self-repair.mjs`) | Classified `known-defect` at baseline. Excluded from the red set, so no focused failure reruns, no worker dispatch, no verification runs. Reported under its own total; never counted as `unresolved`, so it cannot hold the exit code red. A tagged test with *any* baseline pass instead classifies `known-defect-passed` — a non-terminal anomaly that ENTERS the repair scope with a purpose-built stability-probe brief (see below). |
| `test-repair` | Excluded from the Stage-2 failure clusters. Listed in the session summary under known defects, not under anything awaiting a heal. |
| `failure-diagnosis` | Terminal classification before any evidence gathering: a `@known-defect` red is neither a test issue to fix nor a new app bug to report. Diagnose it only when the failure *signature* has changed — a different error than the filed defect means a second, unfiled problem. |
| `bug-discovery` | Authors the tag when a confirmed finding earns a regression guard, and links the finding. |
| `test-catalogue` | Renders the case with the `Failing-expected` status chip, never `Active`. |
| Achilles reporter (`reporter/index.js`) | Counts `@known-defect` tests and prints them in the end-of-run warning block; a known-defect that *passed* this run gets its own anomaly warning naming the test. |

### A passing `@known-defect` is never silently green

The tag predicts red, so a pass is an anomaly with exactly two honest readings — and the consumer's job is to establish which, never to fold the pass into the green count:

- **The defect is actually fixed.** Prove it with the stability bar — the same two-number evidence `test-repair` Stage 5.5 demands before releasing a quarantined flake: **3/3 targeted reruns plus 5/5 suite-order runs, all green**. Then drop the tag (from the test title, the enclosing describe title, or the `{ tag: … }` option — wherever it sits), change nothing else, and surface the filed ticket for closing. The test continues as an ordinary regression guard.
- **The pass is nondeterministic.** Any red inside that bar means the tag is lying about determinism: retag `@known-defect` → `@flaky` at the same site (the suite's quarantine tag), append a quarantine-ledger entry to `tests/e2e/docs/flake-quarantine.md` per the `failure-diagnosis` template, and carry the original defect pointer into the entry — the filed defect may still be real; what changed is that the red is no longer deterministic.

`self-repair` gives the anomaly its own **non-terminal** pattern, `known-defect-passed`: unlike `known-defect`, it enters the red-file set and gets a worker brief that runs exactly this probe. The reporter surfaces the same anomaly at run end with a warning naming the test.

**Distinct from `@flaky`.** `@flaky` marks an *unexplained* intermittent whose root cause resisted two heal strategies; it carries a quarantine-ledger entry and a release path (`test-repair` Stage 5.5). `@known-defect` marks a *fully explained* deterministic red whose cause lives in the application. Never use one for the other: a flake tagged `@known-defect` disappears from the repair pipeline that would eventually have fixed it.
