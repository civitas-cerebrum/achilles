# 8b. Dispatch the adversarial test review

Do not self-assess your own tests. **Dispatch subagents whose mission is to attack them.** The rationale is separation of duties, not a measured effect: a reviewer that did not write the tests has no stake in their looking good. NOT claimed: that delegation outperforms instruction. Delegation was never run as its own arm, so there is no evidence either way.

**This §8/§8b machinery COUNTS as the Stage 4c composition-judge loop** (`../achilles-protocol/references/test-composition-standards.md` §4): the six probe missions plus the §8 negative control are a stricter independent review than the generic judge charter, so do NOT impose a second `composition-judge-` dispatch on top of a run that executed this section. The judge's test-data feasibility dimension still applies: include `test-data-conventions` conformance (strategy ladder, per-attempt generation, cleanup, premises) in `probe-assertions`' scope.

Dispatch these **six in parallel**, scoped to the diff and the ACs. Anything outside those two is out of scope: an unbounded critic returns "you didn't test Safari 14 on 3G" forever.

| Mission | Question it must answer | Required output |
|---|---|---|
| `probe-mutation` | For each AC, what concrete one-line change to the app would break it, and does any test catch it? **Make the change, run the suite, revert.** | Per mutation: the diff hunk, and `caught` / `survived` |
| `probe-coverage` | Which AC clauses and which hunks of the diff have **no** assertion pointing at them? | Gap list keyed to AC text and `file:line` |
| `probe-assertions` | Does each assertion prove a structural guarantee, or did it observe one passing render? | Per assertion: `structural` / `incidental`, with the reason |
| `probe-value` | Is each test **worth keeping**: does it protect behaviour a user would notice losing, at a maintenance cost the risk justifies? | Per test: `keep` / `merge` / `delete`, with the reason |
| `probe-outcome` | For each AC: is the **user-visible outcome** asserted anywhere, or only a mechanism standing in for it? Would the suite stay green with the feature visibly broken? | Per AC: `outcome-asserted` / `proxy-only`, naming the proxy |
| `probe-visual` | Review every evidence screenshot for design quality: padding symmetry, alignment, clipping, visual hierarchy, state-transition degradation, responsive integrity (§6e checklist). | Per screenshot: `design-defect` / `cosmetic` / `acceptable`, naming what is wrong |

**On `probe-value` specifically.** The other three ask whether a test *works*; this one asks whether it should *exist*. A test can catch its mutation and still be a liability. The four verdicts it hunts for:

- **Redundant**: another test already fails for the same cause. The second one adds run time and a second thing to update, not a second signal.
- **Testing the framework**: asserting that the router routes or the component library renders. That is someone else's test suite.
- **Cost exceeds risk**: a slow, fragile, environment-sensitive test guarding something trivial or cosmetic. Every future failure of it will be triaged, and most will be noise.
- **Unfalsifiable in practice**: technically green, but it would pass in nearly every world, including broken ones. `probe-mutation` catches the strong form; this catches the weak form the mutation happened not to touch.

Bias it toward **`merge` over `delete`**, and require evidence for either: name the test that already covers it, or the specific reason the risk does not warrant the cost. Deleting cover is the one recommendation here that can lose information permanently, so an unevidenced `delete` is a rejected finding. Coverage counts are not the goal: twelve tests where six would do is worse than six, because the six carry the same signal and half the maintenance.

**The dispatch will be DENIED unless you cite the return schema.** `probe-` is a schema-mapped role: `subagent-schema-preread-gate.sh` blocks any `probe-*` dispatch whose brief does not name `schemas/subagent-returns/probe.schema.json`. This was found the only way it could be, by following this section and being blocked three times in a row. Use this shape:

```
Agent(description: "probe-mutation-<slug>", prompt: "
  ADVERSARIAL REVIEW — <mission>. Your job is to find defects, not to approve.
  Return shape: schemas/subagent-returns/probe.schema.json. Return `handover`
  ({role, status, next-action} — all three required), `findings-emitted`,
  `finding-ids` (REQUIRED whenever status is "findings-emitted"), and
  `summary`. Omitting finding-ids is the easy mistake: it is conditionally
  required exactly when the probe succeeds in finding something.
  <files to read> <the ACs> <the specific question>
  MANDATORY: silence is a failed dispatch. Return findings, or state exactly
  what you examined and why you found nothing. A vague approval is a failure.
")
```

# probe-visual — screenshot design review

Unlike the other probes, `probe-visual` does not read test code; it reads the evidence
screenshots. Its input is the screenshots directory of the evidence bundle, and its job is to
review every image as a designer would.

The brief must include:
- The path to the screenshots directory
- The §6e checklist items (padding/spacing symmetry, alignment, clipping/overflow, visual
  hierarchy, state transitions, responsive integrity)
- Instruction to compare "before" and "after" screenshots for layout degradation on state changes
- The standard return schema citation

```
Agent(description: "probe-visual-<ticket>", prompt: "
  ADVERSARIAL REVIEW — visual design inspection. Your job is to find design
  defects in evidence screenshots, not to approve them.
  Return shape: schemas/subagent-returns/probe.schema.json. Return `handover`
  ({role, status, next-action} — all three required), `findings-emitted`,
  `finding-ids` (REQUIRED whenever status is 'findings-emitted'), and `summary`.

  Read every screenshot in <screenshots-dir>.
  For EACH screenshot, check the §6e checklist:
  1. Padding and spacing symmetry — are insets consistent left/right, top/bottom?
  2. Alignment — do sibling elements (buttons, labels, icons) line up?
  3. Clipping and overflow — is content cut off? Rounded corners correct?
  4. Visual hierarchy — is the primary action visually dominant?
  5. State transitions — compare before/after shots. Does layout degrade on expand, error, load?
  6. Responsive integrity — does the layout look intentional at this viewport?

  For each finding: name the screenshot, describe what is wrong, and classify as
  'design-defect' (broken layout/padding), 'cosmetic' (minor visual inconsistency),
  or 'acceptable' (intentional design choice).

  MANDATORY: silence is a failed dispatch. If every screenshot passes inspection,
  list each one you reviewed and what you checked. A vague 'looks fine' is a failure.
")
```

This probe populates `uiReviewed: true` in the adversarial verification receipt. The
`adversarial-verification-gate.sh` already enforces this field; sign-off is denied without it.
A test suite with passing functional assertions but unreviewed screenshots cannot ship.

**Non-negotiables for these dispatches:**

- **They must execute, not just read.** The most dangerous defect found in the run this skill came from was a sentinel that *passed while the bug was live*: the destination page consumed the session-storage flag it asserted on before the assertion ran. No amount of reading would have caught that; running it did.
- **Prove each mutation APPLIED.** An un-applied mutation is indistinguishable from an uncaught
  one, and reads as a coverage hole that does not exist. This cost a false finding: a mutation was
  reported as surviving when its injection had silently never run (a bare string passed where the
  API wanted `{ content }`). Give every mutation a selector that must match once it is live, and
  assert that before believing any "survived" result, the same control logic as `noop`, applied
  per mutation instead of per run.
- **Do not target zero survivors.** A survivor with a written, defensible reason is a decision; a
  survivor without one is a hole. Demanding zero pushes you into asserting design tokens and other
  over-fitted details, producing tests that fail on legitimate change. When a mutation survives for
  a good reason, narrow the test's CLAIM rather than widening its assertion, and rename the test
  so it no longer promises what it does not check.
- **Mutation needs a target you can break.** Source-level mutation needs a locally runnable app. Where the suite runs against a *deployed* environment you cannot rebuild, mutate at the **browser** level instead: inject CSS/JS that re-creates the broken state the AC forbids, then check the suite goes red. Weaker in one way (it binds to behaviour, not to the source change) and stronger in another (it tests the deployed artifact). Either way, **include a no-op mutation as the harness's own control**: if the suite goes red with nothing injected, the harness is breaking the page and every other result in the run is void.
**Use the shipped runner: do not hand-roll this per project:**

```bash
npx achilles-mutate                     # reads .achilles/mutations.mjs
npx achilles-mutate --only pills-hidden # one mutation, while iterating
```

It owns the parts that drew blood here: owner-based classification, the `noop` control, the
per-mutation applied-check, and the VOID verdict. This was a prose recipe first, and every
subtlety in the prose was re-derived wrongly at least once; that is the evidence for shipping it
as code. The runner refuses to start without a `noop` mutation, because without one there is no
way to tell "the suite catches mutations" from "the harness breaks the page".

- **Browser-level mutation needs a hook in the project's fixture**, because a Playwright config cannot add one; this part the runner cannot do for you. Two variables, exact names and grammar:

  | Variable | Contains | Applied |
  |---|---|---|
  | `E2E_MUTATION_CSS` | a CSS string | `page.addStyleTag({ content })` on every `load` |
  | `E2E_MUTATION_INIT` | a JS string | `page.addInitScript({ content })`; note the object form; a bare string silently does nothing |

  ```ts
  // in your `page` fixture — inert unless the driver sets these, so it costs nothing when unused
  if (process.env.E2E_MUTATION_INIT) await page.addInitScript({ content: process.env.E2E_MUTATION_INIT })
  if (process.env.E2E_MUTATION_CSS) {
    const css = process.env.E2E_MUTATION_CSS
    page.on('load', () => { page.addStyleTag({ content: css }).catch(() => {}) })
  }
  ```

  The `noop` control is simply both variables empty. The applied-check is an expression evaluated
  **in the page** once the mutation is live: a selector alone is too weak, because most mutations
  change a computed style rather than adding a node (`getComputedStyle(el).display === 'none'`,
  not `[data-x][hidden]`).

  **Give the un-applied case its own verdict.** Do not fold it into SURVIVED: an un-applied
  mutation is a **VOID** measurement that says nothing about coverage, and calling it a survivor
  manufactures a coverage hole that does not exist. Three outcomes, not two:

  | Suite red? | Applied? | Verdict |
  |---|---|---|
  | yes | — (self-evident) | CAUGHT |
  | no | true | SURVIVED: a real finding |
  | no | false | **VOID**: fix the injection and re-run before reading anything |

  Only SURVIVED needs the check, and only then is it worth the browser launch.

  **The applied-check is itself an instrument, so it needs its own control**: this is the rule
  that keeps getting missed, including by the code written to enforce the rule above it. Two
  cheap calibrations before believing any result: run it with **no injection** (must report
  `false`) and with the mutation injected (must report `true`). A checker that always returns
  true is a rubber stamp; one that always returns false invents holes. `achilles-mutate
  --calibrate` runs both points for every mutation and exits non-zero on any that cannot produce
  both answers.

  **Run the calibration as its own command, not opportunistically.** The applied-check only fires
  when a mutation SURVIVES, so a check that is broken for a mutation the suite reliably catches is
  never exercised: no number of full runs will surface it. Measured: a width-scoped mutation
  (`@media (max-width:1400px)`) had its check performed at the run's 1440 viewport, where the rule
  does not apply. It reported false for a mutation that works. Because that mutation had been
  caught in every run since it was written, the fault was invisible and would have surfaced only
  on the one future run where it mattered, as a VOID verdict on a perfectly good mutation. If
  your mutation is scoped to a width, a media query, or a state, **check it where it applies**. Give it the same
  page-level control as any other probe: if the page never rendered, the result is void rather
  than false.

  **And keep "could not check" separate from "checked, did not apply".** Collapsing them puts an
  infrastructure failure into a coverage verdict, which is the same error VOID exists to prevent,
  one level up. Measured: a resolution bug made every applied-check return "unknown", the runner
  read unknown as VOID, and a documented intentional survivor was reported as a broken injection.
  Four outcomes, and the last one is a bug report about the harness rather than a fact about the
  suite:

  | | meaning |
  |---|---|
  | CAUGHT | the OWNING test failed |
  | SURVIVED | applied, and nothing failed: a finding |
  | VOID | checked: it never took effect. Fix the injection |
  | UNCHECKED | the check could not run. Says nothing either way; print the reason, not a verdict | Add this hook as a **prerequisite**, not a mid-probe discovery: without it,
  §8b's first mission is not runnable at all on a deployed-only project.
- **Silence is not a pass.** A reviewer that reports nothing is indistinguishable from a lazy one. Require the shape: findings, **or** an explicit *"I attempted these N mutations and the suite caught all N"* with the list. An empty return is a failed dispatch, not a clean bill of health.
- **A surviving mutation is a finding, not a suggestion.** It means a stated AC has no test that can fail for it. Fix the test before reporting the verdict.

Write the outcome to `.achilles/adversarial-verification/<ticket-key>.json`:

```json
{
  "ticket": "<KEY>", "ranAt": "<ISO-8601>",
  "negativeControl": { "environment": "<url>", "failed": 5, "passed": 1, "skipped": 0 },
  "mutations": [{ "ac": "AC-2", "hunk": "…", "caught": true }],
  "coverageGaps": [], "incidentalAssertions": [], "lowValueTests": [],
  "review": { "uiReviewed": true }
}
```

That receipt is what the harness gate looks for. **The gate DENIES a tracker transition to a
completed state without it**, so an adopter who has not read this section meets it as an
unexplained denial: kill-switch `CIVITAS_DISABLE_ADVERSARIAL_GATE=1` if you need out.

The gate also checks `review.uiReviewed: true` (populated by `probe-visual`; see §8b).
Without it, sign-off is denied even when all functional probes pass.

**Gitignore `.achilles/`.** The receipt is a local run artifact: git does not preserve mtimes, so a
committed receipt would arrive on CI with a rewritten timestamp and defeat the staleness check
outright. It is evidence for the run that produced it, not a shared artifact. Writing it by hand without running the probes defeats the check entirely, and the failure it catches is *your own*.
