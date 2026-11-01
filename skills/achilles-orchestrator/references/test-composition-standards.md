# Test composition standards: single source of truth

The cross-skill standard for every composing exit: the citation contract that keeps composing rules single-homed, the canon index naming each rule's one home, the record of resolved contradictions, the Stage 4c judge loop, and the smoke-versus-e2e depth doctrine.

## §1 Citation contract

Restated rules drift into contradictions (inline-selector policy, `test.fail()`, stability counts, serial-mode annotations, test-data shape; see §3). Every rule shared by two or more composing skills has exactly one canonical home, named in §2.

1. **Cite, never fork.** A skill that needs a shared rule links to its home; it does not re-paste the text.
2. **No one-extra-clause extensions.** A clause, exception or qualifier added inside another skill is a fork; extend the home in its own change.
3. **Short mirrors are allowed** where a rule's violation produces broken state (a one-line restatement with a citation); a change to the rule updates mirror and home together.
4. **Conflicts resolve toward the canon**; the disagreeing text is a bug, and a normative disagreement is recorded in §3.

## §2 Canon index

| Concern | Canonical home |
|---|---|
| Stage 2 inspection, Stage 3 authoring, Stage 4a/4b review, fix mode | [`stages-protocol.md`](stages-protocol.md) |
| Steps API surface (signatures, options, selector formats) | [`api-reference.md`](api-reference.md) |
| Causal verification ("would this assertion pass under a no-op?") | [`stages-protocol.md`](stages-protocol.md) §"Stage 3" item 5 (Stage 4b item 11 is the review-side form) |
| No inline selectors + the one scope exception | [`stages-protocol.md`](stages-protocol.md) §"Stage 3" item 4; exception in `../../evidence-capture/SKILL.md` (§3.1 below) |
| App bugs reported, never worked around | [`../SKILL.md`](../SKILL.md) §7 rule 7; classification in `../../failure-diagnosis/SKILL.md` |
| App-context write-back on every page visit | [`stages-protocol.md`](stages-protocol.md) §"App context" |
| Visual-regression variants (`verifyVisualMatch` + masks) | `../../test-composer/SKILL.md` §"Visual regression" |
| Secrets in `.env`, durable identities in a fixture, created identities per attempt | `../../test-data-conventions/SKILL.md`; extraction in `../../secrets-sweep/SKILL.md` |
| Test-data doctrine (discovery, strategy ladder, generation, cleanup, premises, data plan) | `../../test-data-conventions/SKILL.md` |
| Stability counts (3× new or edited, 5× flaky heal; §3.3) | `../../failure-diagnosis/SKILL.md` §"Stability Validation Protocol" |
| State isolation, shared resources, per-run uniqueness | [`test-optimization.md`](test-optimization.md) §1–§3 |
| Volatile-value assertion forms (round-trip / delta / shape) | [`test-optimization.md`](test-optimization.md) §3b |
| API shortcuts for tested prerequisites (two-of-two gate) | [`test-optimization.md`](test-optimization.md) §4 |
| Serial-mode discipline + `// serial-deliberate:` | `../../test-composer/SKILL.md` Step 3 (mandate); [`test-optimization.md`](test-optimization.md) §6 (review) |
| Whole-suite re-run gate | [`test-optimization.md`](test-optimization.md) §7 |
| Per-journey portfolio (variant order, P0–P3 depth) | `../../test-composer/SKILL.md` Steps 1 and 3 |
| Oracle strength ladder L0–L3 | `../../test-composer/SKILL.md` §"Oracle strength ladder" |
| Deliberate-failure bite check | `../../test-composer/SKILL.md` §"Oracle strength ladder" (UI); `../../contract-testing/SKILL.md` Rule 8 (API); `../../performance-testing/SKILL.md` rule 9 (k6) |
| Input-domain / partition analysis | `../../test-composer/references/input-domain-analysis.md` |
| Tenant cleanup contract (`cleanupViaApiBackdoor`, `cleanup: done \| blocked \| not-needed`) | `../../test-composer/SKILL.md` §"Tenant cleanup" |
| Finding block, severities, evidence rule, return envelope, ledger | [`finding-and-ledger-schema.md`](finding-and-ledger-schema.md) |
| Fresh-eyes reviewer independence | `../../review/SKILL.md` §"Hard constraints" |
| Selector conventions and inertness | `../../selector-development/references/selector-convention.md`, `inertness-contract.md` |
| Selector evidence notes and standing authorisation | [`selector-evidence.md`](selector-evidence.md) |
| Scenario block as the requirement, and the lint | [`scenario-block.md`](scenario-block.md) |
| `test.fail()` policy (one sanctioned use; §3.2) | [`verify-change/phase-7-durable-tests.md`](verify-change/phase-7-durable-tests.md) |
| Style-interaction verification (mock-DOM styling tests) | [`verify-change/style-interaction-verification.md`](verify-change/style-interaction-verification.md) |
| Commit-or-discard gate | [`verify-change/phase-8c-8e-scoring-and-commit.md`](verify-change/phase-8c-8e-scoring-and-commit.md) |
| Deck print-safety rules | `../../qa-reporting/SKILL.md` §"Print-safety rules" |
| Test identity (ids on every case; `@known-defect`) | [`test-identity.md`](test-identity.md) |
| Stage 4b compliance sweep as every mode's exit gate | [`stages-protocol.md`](stages-protocol.md) §"Stage 4b is every mode's exit gate" |
| Smoke-versus-e2e depth doctrine | §5 of this file |
| Stage 4c judge loop | §4 of this file |
| Commit subjects | [`commit-conventions.md`](commit-conventions.md) |

## §3 Contradiction resolutions (normative record)

**3.1 Inline selectors.** Durable suite specs: hard ban; every selector lives in `page-repository.json`. The one exception: `evidence-capture` bundles may carry bundle-scoped inline selector proposals (the bundle is not the suite); they become repository entries when the scenario is authored as a durable test.

**3.2 `test.fail()`.** Legal only as a defect sentinel tied to a tracked ticket with a removed-when-fixed lifecycle (verify-change phase 7). Banned everywhere no ticket owns the marker: coverage passes and bug hunts keep suspected bugs ledger-only.

**3.3 Stability runs.** Two numbers: 3 consecutive greens for any new or edited test; 5 consecutive, in suite order, for a heal of a previously flaky test. Home: `failure-diagnosis`.

**3.4 Serial mode.** Tenant-mutating specs use file-level `test.describe.configure({ mode: 'serial' })` with a `// serial-deliberate: <reason>` comment above it; the annotation satisfies the Stage 4a §6 review. Unannotated serial mode is flagged.

**3.5 Test-data shape.** `tests/fixtures/test-data.ts` may hold env-sourced durable identities (accounts that exist by design). Any identity a test creates is generated per attempt inside the test body; module-scope generation collides on retry.

**3.6 Oracle taxonomies.** L0–L3 is the strength ladder (which layer confirms the effect). `test-optimization.md` §3b's round-trip / delta / shape oracles are assertion forms within a rung. Pick the rung the priority demands, then the form that keeps the assertion stable there.

**3.7 Scaffold prerequisites.** `test-optimization.md`'s HELPER SLOT markers in `base.ts` and the infrastructure audit tags resolve to the onboard workflow's Phase 1 scaffold and the journey-mapping test-infrastructure probe.

## §4 Stage 4c: composition judge (mandatory at every composing exit)

Stages 4a and 4b are author-side self-review. Stage 4c adds the reader the author cannot be: an independent reviewer with an adversarial charter. No composing exit is complete until the judge returns SATISFIED or the escalation bound fires.

**Dispatch.** After 4a + 4b are clean. A fresh `achilles-reviewer` loading `../../review/SKILL.md` in judge mode; never the author, never a reused judge. The brief gives it the specs, the scenario source (approved scenario, journey block, or ticket criteria), the `page-repository.json` slice, `tests/e2e/docs/test-data-plan.md`, and the return schema `schemas/subagent-returns/reviewer-inloop.schema.json`.

**Dimensions.** (1) Intent coverage: every criterion maps to ≥1 test and back. (2) Oracle strength: causal verification on every test; the ladder per priority (an L0-only oracle on a P0 mutating step is a miss). (3) API compliance spot-check against the API reference. (4) Test-data feasibility per `test-data-conventions`, including a test data plan that reflects the specs (a missing plan is a must-fix for the author, never grounds to fail a fresh project).

**Verdict and loop.** `greenlight` ⇔ SATISFIED; `improvements-needed` + `[must-fix]` findings ⇔ NOT SATISFIED. The author fixes, re-runs 4a/4b when code changed, and a new judge is dispatched. Three consecutive NOT SATISFIED → the orchestrator hands back `DONE_WITH_CONCERNS` with the three lists.

**Where it applies.**

| Composing exit | How the judge lands |
|---|---|
| author-scenario | after 4a/4b, before commit |
| `test-composer` Step 6 | Step 6c, unless the invocation runs inside a coverage pass, where the Stage B reviewer (whose calibration includes dimension 4) is the judge; never both |
| onboard Phase 3 | each happy-path spec's cycle ends with the judge |
| verify-change | its phase 8/8b machinery (six probe missions + negative control) counts as the judge loop |
| `evidence-capture` graduation | the durable spec goes through author-scenario, judge included; a bundle itself is not a composing exit |
| `bug-discovery` phase 6 | reproduction specs are judged before the phase 7 report cites them |
| repair-suite whole-rewrite heals | the rewrite goes through `test-composer` and its judge; incremental heals are gated by the stability bar instead |
| `contract-testing`, `database-testing`, `agents-vs-agents` standalone | a judge after their 4b sweep; inside a composer or verify-change flow that flow's judge covers them |
| `performance-testing` pipeline | the perf phase-gate reviews count as the judge for k6 scenarios |

## §5 Smoke versus e2e depth

- **e2e spec: the journey is the subject.** Walk it through the UI end to end, no state-injection shortcuts on the path under test. A journey's full UI walk is the subject of exactly one e2e test.
- **smoke or derivative spec: a surface is the subject.** Reach the target view by API or state injection (`test-optimization.md` §4's gate; `setAuthCookie`, seed helpers) and assert only the surface under test.
- **Auth** is a precondition, not a step of the journeys it unlocks: inject it everywhere except in the tests whose subject is login or signup.
- **Organisation:** one spec file per journey or feature area; e2e and smoke suites split so the depth choice is visible.

Duplicated UI walks multiply run time and flake surface without multiplying signal.

## §6 Dispatch discipline

Specialist work runs as dedicated expert dispatches; the orchestrator routes, gates and integrates. UI inspection → inspector (Stage 2); composing → author with `test-composer`; probing → author with `bug-discovery`; diagnosis and repair → author with `failure-diagnosis`; judging and phase gates → reviewer with `review`; map authoring and reports → doc-writer. An orchestrator that catches itself opening a browser session, writing a spec body, probing a boundary or judging a composition stops and dispatches ([`../SKILL.md`](../SKILL.md) §7 rule 10). Why: context discipline (DOM, spec source and stabilisation transcripts live in worker contexts), separation of duties (an orchestrator that composes has no independent reviewer), and parallelism (absorbed work is serial by construction; if parallel dispatch feels unsafe, fix the cause per `test-optimization.md` §1.A).
