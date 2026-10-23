# 8b. Adversarial review

The orchestrator does not assess the tests it had written. It dispatches experts whose mission is to attack them: separation of duties, not a measured effect (delegation was never run as its own arm, so no claim is made that it outperforms instruction). A reviewer that did not write the tests has no stake in their looking good.

**This §8/§8b machinery counts as the Stage 4c composition-judge loop** (`../test-composition-standards.md` §4): the six probe missions plus the §8 negative control are a stricter independent review than the generic judge charter, so no second judge dispatch is imposed on a run that executed this section. The judge's test-data feasibility dimension still applies: `probe-assertions` includes `test-data-conventions` conformance (strategy ladder, per-attempt generation, cleanup, premises) in its scope.

The mission names and the one-line charter of each are in the workflow ([`../../workflows/verify-change.md`](../../workflows/verify-change.md) step 8b); this file describes how each is run. Scope every mission to the diff and the acceptance criteria: an unbounded critic returns "you didn't test Safari 14 on 3G" forever.

## The mutation run (an author brief, before the probes)

`probe-mutation` judges a mutation report; it does not produce one. One author dispatch produces it:

1. Write `.achilles/mutations.mjs`: for each AC, the concrete one-line change to the app that would break it, with an applied-check (an expression evaluated in the page once the mutation is live; a selector alone is too weak, because most mutations change a computed style rather than adding a node), plus the mandatory `noop` entry.
2. Make sure the project's `page` fixture honours the two hook variables (below); without them browser-level mutation is not runnable. Add the hook as a prerequisite, not as a mid-run discovery.
3. Run `npx achilles-mutate --calibrate` (every applied-check must report `false` with no injection and `true` with its mutation injected; a checker that always says one thing is a rubber stamp or invents holes), then `npx achilles-mutate`. The runner owns the parts that drew blood when this was a prose recipe: owner-based classification, the `noop` control, the per-mutation applied-check, and the four verdicts `CAUGHT` / `SURVIVED` / `VOID` (never took effect) / `UNCHECKED` (the check could not run). `npx achilles-mutate --help` lists the switches; the prose is not re-derived per project.
4. Write the mutation report: per mutation the AC, the hunk or injection, the applied-check result and the verdict; the `noop` result first.
5. Source-level mutation (a locally runnable app, [entry B](entry-b-dev-triggered.md)) binds the mutation to the actual change and is preferred when available; every such mutation is reverted before the author hands back. Where the suite runs against a deployed environment that cannot be rebuilt, mutate at the browser level: inject CSS/JS that re-creates the broken state the AC forbids. Weaker in one way (it binds to behaviour, not to the source change), stronger in another (it tests the deployed artifact).

| Variable | Contains | Applied |
|---|---|---|
| `E2E_MUTATION_CSS` | a CSS string | `page.addStyleTag({ content })` on every `load` |
| `E2E_MUTATION_INIT` | a JS string | `page.addInitScript({ content })`; note the object form: a bare string silently does nothing |

```ts
// in the `page` fixture; inert unless the driver sets these
if (process.env.E2E_MUTATION_INIT) await page.addInitScript({ content: process.env.E2E_MUTATION_INIT })
if (process.env.E2E_MUTATION_CSS) {
  const css = process.env.E2E_MUTATION_CSS
  page.on('load', () => { page.addStyleTag({ content: css }).catch(() => {}) })
}
```

Rules the author's brief carries:

- **Prove each mutation applied.** An un-applied mutation is indistinguishable from an uncaught one and reads as a coverage hole that does not exist. This cost a false finding once: a bare string passed where the API wanted `{ content }`, the injection never ran, and the mutation was reported as surviving.
- **The `noop` control is mandatory.** If the suite goes red with nothing injected, the harness is breaking the page and every other result in the run is void. The runner refuses to start without it.
- **Width- or state-scoped mutations are checked where they apply.** A check performed at a viewport where the media query does not apply reports `false` for a mutation that works; because the suite caught that mutation in every run, the broken check stayed invisible until it mattered.
- **Do not target zero survivors.** A survivor with a written, defensible reason is a decision; one without is a hole. Demanding zero pushes the suite into asserting design tokens and other over-fitted details. When a mutation survives for a good reason, narrow the test's claim and rename the test so it no longer promises what it does not check.

## The six probes (reviewer briefs, in parallel)

Six fresh reviewers, dispatched in one message, each loading [`../../../review/SKILL.md`](../../../review/SKILL.md) §"Mode 4: adversarial probe". Every brief names: the mission, the files to read, the ACs verbatim, the specific question, the return schema `schemas/subagent-returns/probe.schema.json` (`handover { role, status, next-action }`, `findings-emitted`, `finding-ids` required whenever the status is `findings-emitted`, `summary`), and the rule that silence is a failed dispatch: findings, or exactly what was examined and why nothing was found. A brief without the schema produces unparseable returns that cost a re-dispatch.

### probe-mutation

Reads the mutation report and the suite. Every `SURVIVED` with an applied-check `true` is a finding: a stated AC has no test that can fail for it. Every `VOID` or `UNCHECKED` is a finding against the run, not against the suite: the orchestrator re-dispatches the author to fix the injection or the check before anything is read from that mutation. The probe confirms the `noop` was green and calibration ran, judges each survivor's written reason, and may re-run the suite or a single mutation's owning test read-only to confirm a verdict. It never applies a mutation itself.

### probe-coverage

Which AC clauses and which hunks of the diff have no assertion pointing at them. Output: a gap list keyed to AC text and `file:line`.

### probe-assertions

Per assertion: `structural` (proves a guarantee) or `incidental` (observed one passing render), with the reason; plus the test-data conformance check named above.

### probe-value

Per test: `keep` / `merge` / `delete`, with the reason. The other probes ask whether a test works; this one asks whether it should exist. The four verdicts it hunts for:

- **Redundant**: another test already fails for the same cause; the second adds run time and a second thing to update, not a second signal.
- **Testing the framework**: asserting that the router routes or the component library renders.
- **Cost exceeds risk**: a slow, fragile, environment-sensitive test guarding something trivial; every future failure will be triaged and most will be noise.
- **Unfalsifiable in practice**: green in nearly every world, including broken ones; the weak form `probe-mutation` happened not to touch.

Bias toward `merge` over `delete`, and require evidence for either: name the test that already covers it, or the specific reason the risk does not warrant the cost. An unevidenced `delete` is a rejected finding; deleting cover is the one recommendation here that loses information permanently. Twelve tests where six would do is worse than six.

### probe-outcome

Per AC: `outcome-asserted` or `proxy-only`, naming the proxy. Would the suite stay green with the feature visibly broken?

### probe-visual

Does not read test code; reads every evidence screenshot in the bundle's screenshots directory as a designer would, against the §6e checklist ([phase-6-understanding](phase-6-understanding.md)): padding and spacing symmetry, alignment, clipping and overflow, visual hierarchy, state transitions (compare before/after shots for layout degradation), responsive integrity. Per screenshot: `design-defect` / `cosmetic` / `acceptable`, naming what is wrong; when every screenshot passes, the report lists each one reviewed and what was checked. Its report is what populates `review.uiReviewed` in the receipt; a suite with passing functional assertions but unreviewed screenshots does not ship.

## Rules for every probe

- **Execute, do not just read.** The most dangerous defect found in the run this method came from was a sentinel that passed while the bug was live: the destination page consumed the session-storage flag it asserted on before the assertion ran. Running it caught it; reading would not have.
- **Silence is not a pass.** A report with nothing in it is indistinguishable from a lazy one. Require the shape: findings, or "I attempted these N things and found nothing", with the list.
- **A surviving mutation is a finding, not a suggestion.** Fix the test before the verdict is written.

## After the probes

The orchestrator reads the six reports and the mutation report, dispatches the author for every must-fix finding, re-runs the affected probe with a fresh reviewer, and then records the sign-off receipt (or the harness adapter records it on the orchestrator's behalf from the reviewers' hand-backs; which one is in the harness doc). The receipt shape:

```json
{
  "ticket": "<KEY>", "ranAt": "<ISO-8601>",
  "negativeControl": { "environment": "<url>", "failed": 5, "passed": 1, "skipped": 0 },
  "mutations": [{ "ac": "AC-2", "hunk": "…", "caught": true }],
  "coverageGaps": [], "incidentalAssertions": [], "lowValueTests": [],
  "review": { "reviewer": "<probe report paths>", "uiReviewed": true, "coverageSufficient": true, "scores": { "R1": 3 } }
}
```

`negativeControl` comes from the author's §8 report, `mutations` from the mutation report, the three lists from `probe-coverage` / `probe-assertions` / `probe-value`, `uiReviewed` from `probe-visual`, `scores` from §8c. A receipt written without the probes having run defeats the check, and the failure it catches is the run's own.
