# Pass pipeline: the five coverage passes

Per-pass detail for [`../workflows/expand-coverage.md`](../workflows/expand-coverage.md): what each pass does, when it is complete, how grouping and dedup work, and the whole-suite gate. The per-journey author↔reviewer loop is [dual-stage-retry-loop.md](dual-stage-retry-loop.md); the state file is [state-files.md](state-files.md); commit subjects are [commit-conventions.md](commit-conventions.md).

## Per-pass steps

1. **Read the map** (sentinel verified) into an index: `(j-id, priority, pages-touched, test-expectations, risk)`. Nothing else per journey.
2. **Order**: map priority; within a tier `risk: elevated` (2+ risk factors) before `baseline`; risk never promotes across tiers.
3. **Independence graph**: journeys sharing a non-universal page (login, home and global nav are universal) are dependent and serialise; the rest run in parallel.
4. **Scope preview** written to the resume file: journeys, groups, parallel width, expected wall-clock, model mix. Declarative; no prompt.
5. **Per-journey loop** for every journey in the roster; the loop ends in one of four `review_status` values.
6. **Collect** committed paths, `review_status`, cycle counts, `final_must_fix`.
7. **Reconcile**: compositional passes append branches, pages and new `j-`/`sj-` blocks to the map and `app-context.md` (new journeys join the next roster at the reconciliation commit; run a small redundancy revision when overlaps appear); adversarial passes leave the map alone and aggregate the totals counter.
8. **Commit, then state**: one commit per journey (per journey per pass on adversarial passes); rewrite the state file after the commit lands.

## Pass differences

| Pass | Kind | Purpose |
|---|---|---|
| 1 initial perception | compositional | Cover the map as produced. Full variant set per `Test expectations:`. Author loads `test-composer`. Strict per journey in every mode. |
| 2 map-growth widening | compositional | Re-read the enriched map; promote discovered branches and sub-journeys; re-evaluate priorities; re-attempt journeys that deferred stabilisation or returned gaps. Trigger-gated. |
| 3 consolidation | compositional | Cross-journey interactions, residual gaps, data-lifecycle variants that wire several journeys, journeys whose block changed in pass 2. Trigger-gated. |
| 4 adversarial probing | adversarial | After the app-wide prelude, one probe per journey (author loads `bug-discovery` with the negative-case matrix from `../../bug-discovery/references/adversarial-probe-contract.md`). Findings to the ledger; no tests. |
| 5 adversarial consolidation | adversarial + regression | Re-probe ambiguous matrix entries, compound probes, and a passing regression test per verified boundary (passes 4 + 5) in `j-<slug>-regression.spec.ts`. Suspected bugs stay ledger-only; no `test.fail()`. |

## Model hints

| Dispatch | Hint | Why |
|---|---|---|
| Pass 1 author, every reviewer, pass 4 and 5 authors, cleanup, failure diagnosis, reports | strong | foundation quality, review judgement, the durable regression layer, root-cause reasoning |
| Pass 2 and 3 re-pass authors | cheaper | mechanical re-passes where most journeys return `covered-exhaustively` |
| A journey with `final_must_fix` carry-over | strong, whatever the pass | a hard must-fix does not resolve on a mechanical re-pass |

The brief names the hint; the adapter maps it to a model. The user may raise everything to strong for an audit; record the override in the resume file.

## Per-pass completion

- **Pass 1**: the author dispatched and returned for every journey in the roster.
- **Pass 2**: every journey dispatched or gated-skipped with its three triggers recorded; the map reconciled with promoted branches and sub-journeys and the reconciliation commit landed (or `pass 2 reconciliation — no map edits required` logged).
- **Pass 3**: cross-journey and data-lifecycle variants dispatched for every journey whose expectations call for them; every journey with residual gaps from passes 1–2 re-attempted.
- **Pass 4**: the prelude wrote `tests/e2e/docs/app-wide-patterns.md` with its sentinel; the probe ran for every journey in `journeyRoster − adversarialSkippedJourneys` with a terminal `review_status`; every dispatched journey has a ledger section (`no boundaries probed — <reason>` when nothing landed; an empty section is a bug).
- **Pass 5**: every verified pass-4 finding has a committed regression test or a decline line from the four categories (`suspected bug`, `ambiguous`, `duplicate of cross-cutting #N`, `value gate: <reason>` where the reason is low severity on P2/P3, a framework default already exercised by an error-state test, or a boundary subsumed by a stronger-oracle test). The pass summary carries the added suite runtime.
- **Every pass**: every dispatched journey has a terminal `review_status`; the per-pass dedup commit landed; the whole-suite gate passed since the dedup commit.

Only when all of this holds does the pass advance. "Ran some journeys, ran out of budget" is the second exit of the workflow, never a completed pass.

## Whole-suite gate (pass exit)

Procedure: [`test-optimization.md`](test-optimization.md) §7. From the project root `npx playwright test --reporter=json > .stage4a-suite.json`; refuse to advance when `stats.unexpected > 0` or `stats.skipped` exceeds the count of explicit `test.skip(` markers across specs; return the failures to the repair-suite workflow; delete the JSON after parsing. Per-journey stabilisation proves each journey in isolation; only the whole run shows DB pollution, port collisions, fixture drift and shared-resource depletion, and catching them at the pass that introduced them is cheaper than at the end.

## Parallelism

Independence groups run in priority order, each exhausting parallelism before the next starts. Within a group both stages are parallel: a journey's reviewer fires as soon as its author returns and a slot is free; its author retry fires as soon as its reviewer returns `improvements-needed`. Finishing every author first and then starting reviewers is a different, slower protocol. One pool of slots, FIFO, host maximum width unless the infrastructure audit tags (single credential per role, rate limits, CSRF serialisation) cap it; reviewers compete for the same credentials.

## Trigger-gated re-pass (passes 2 and 3)

Before dispatching a journey, check: **map delta** (`git diff <pass-1-reconciliation-commit> -- tests/e2e/docs/journey-map.md` filtered to the block), **sibling ledger update** (a finding added since pass 1 naming this journey as a regression candidate), **must-fix carry-over** (`final_must_fix` non-empty in the prior pass). All false → a gated-skip entry with `triggers_checked`; no dispatch. Any true → dispatch with the evidence in the brief and this preamble:

> You are a re-pass author. Pass 1 already composed this journey. Work is valuable only when the map was materially enriched, pass 1 reported gaps or deferred stabilisation, a sibling journey surfaced a bug that should be regressed here, or the prior reviewer's must-fix items are unresolved. Perform the full inspection regardless (journey block, pass-1 return, sibling findings); only then may you return `covered-exhaustively`, with the per-expectation mapping table and an explicit line per trigger (`trigger 1` … `trigger 4`). Cost is not the optimisation target; disciplined evidence is.

The orchestrator rejects a pass-2/3 return missing the four trigger lines or the mapping table and re-dispatches once.

## Grouping (standard mode, passes 2–5)

Pass 1 never groups; `depth` mode never groups. Elsewhere, when a priority tier holds more than five journeys:

- **Relevance group** (`test-composer` authors, passes 2–3) or **adversarial group** (`bug-discovery` authors, passes 4–5): same priority, same section or overlapping `Pages touched`, at most seven per brief, no journey carrying a re-pass trigger or remediation work, no `risk: elevated` journey. A nine-journey cluster is 7 + 2.
- **P3 batch** (passes 2–5): adjacent low-impact P3 journeys sharing one Playwright project, at most seven; P0/P1/P2 are never batched this way.
- Each group is one author dispatch; groups run in parallel. Reviewers stay per journey inside a group (the cycle-1 batch reviewer is for individually dispatched journeys only). A group is accepted only when every member's cycle-1 review is `greenlight`; a flagged member breaks out and runs its own author from cycle 2 while the rest stay accepted.
- **Safeguard**: three of seven members in one group returning `improvements-needed` ends grouping for the rest of the pass; persistent rationing forces `strict-adversarial` for the next pass. The symptom of a bad group is reviewers flagging skipped expectation bullets (mobile, error states, edge cases) across siblings.

## Pre-pass-4: P3 adversarial opt-out

Evaluate, for `risk: baseline` P3 journeys only, the four criteria `priority-p3`, `page-subset-covered` (every page already probed by a larger journey and covered by an app-wide pattern), `zero-prior-findings`, `low-surface-shape` (logout, role chooser, single modal, single info display, breadcrumb nav). Journeys meeting all four are candidates; the user's approval (the coverage plan, or a `NEEDS_CONTEXT` hand-back: approve all / name exclusions / deny) lands them in `adversarialSkippedJourneys[]` in their own commit before the prelude. Default is include all; the orchestrator never opts a journey out by itself. Compositional passes always run on every journey.

## Per-pass dedup

One author dispatch after the pass's reviews and the whole-suite gate, before the next pass:

- **Compositional (1–3)**: inputs are the pass's commit range (`git log <pass-start>..HEAD --grep '^test('`), the authored journey blocks and the state file. Merge semantically identical tests across the pass's journeys into one canonical test with a `// dedup: see j-<canonical>.spec.ts § <test name>` comment in the others; touch nothing from earlier passes; keep tests that look alike but exercise different invariants. Commit `docs(ledger): pass <N> test dedup`.
- **Adversarial (4–5)**: inputs are the pass's ledger appends. Consolidate duplicate findings across journeys into one entry with cross-references; never drop, edit or re-classify substantive content. Commit `docs(ledger): pass <N> findings dedup`.
- A `no consolidation needed` outcome still produces its commit (empty diff plus a log line) so the record shows the step ran.

## Cross-pass cleanup (once, after pass 5)

One author dispatch reads the whole ledger, consolidates near-duplicate findings across journey sections into `## Cross-cutting findings` with a one-line backref in each source section, fixes ordering and formatting, and changes no substance. Strong model: semantic clustering is judgement. Commit `docs(ledger): dedupe cross-cutting findings`. Then the state file records all five passes + cleanup, the phase review runs, and the coverage checkpoint follows.

## Breadth mode

One invocation per priority tier, serial, one commit per tier, no adversarial passes, no app-wide scan: P0 `happy-path,error-states,edge-cases,mobile`; P1 `happy-path,error-states`; P2 `happy-path`; P3 `smoke`. The no-skip rule still holds per tier: every journey in the tier is dispatched and returns one of the four results.
