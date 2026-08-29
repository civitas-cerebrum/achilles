# Test Composition Standards — Single Source of Truth

**Status:** authoritative cross-skill standard for every composing exit in the suite. Cited from `achilles-protocol/SKILL.md`, `stages-protocol.md`, `test-composer`, `coverage-expansion`, `onboarding`, `ticket-driven-testing`, `companion-mode`, `bug-discovery`, `test-repair`, and `self-repair`.
**Scope:** (1) the citation contract that keeps composing rules single-homed, (2) the canon index mapping every shared composing rule to its one canonical home, (3) the normative record of resolved cross-skill contradictions, (4) the mandatory Stage 4c composition-judge loop, (5) the smoke-vs-e2e depth doctrine, (6) the orchestrator dispatch discipline for specialist task families, (7) the kernel-resident invariants block citing skills mirror.

---

## §1 Purpose + citation contract

Composing rules used to be restated per skill, and the restatements drifted into contradictions (inline-selector policy, `test.fail()` policy, stability counts, serial-mode annotations, test-data shape — see §3). This file ends that: **every rule shared by two or more composing skills has exactly one canonical home, named in the canon index below.**

The contract, patterned on [`subagent-return-schema.md`](subagent-return-schema.md) §4:

1. **Cite, never fork.** A composing skill that needs a shared rule links to the canonical home (or to this file's index). It does not re-paste the rule's full text into its own SKILL.md.
2. **No "one extra field" extensions.** A skill that adds a clause, exception, or qualifier to a shared rule inside its own SKILL.md is forking the standard. If a new clause is genuinely necessary, extend the canonical home (and this index if the home moves) in a dedicated PR — do not ship the extension as a de-facto per-skill override.
3. **Kernel mirrors carry a dual-update obligation.** Short restated invariants inside a skill's `### Hard rules — kernel-resident` block (per `coverage-expansion/SKILL.md` §"Kernel-resident invariants — convention") are deliberate redundancy, not forks. When a mirrored rule changes, the editor updates BOTH the kernel mirror AND the canonical text in the same PR.
4. **Conflicts resolve toward the canon.** If a skill's text disagrees with the canonical home, the canonical home wins and the skill's text is a bug — fix it via the contribution workflow (`../../contributing-to-achilles-protocol/SKILL.md`), recording the resolution in §3 if the disagreement was normative.

## §2 Canon index

One row per shared composing concern. "Canonical home" is where the full rule text lives; everything else cites or mirrors.

| Concern | Canonical home |
|---|---|
| Stages 1–4 process, hard gates, fix/edit mode | [`stages-protocol.md`](stages-protocol.md) |
| Steps API surface (signatures, options, selector formats) | [`api-reference.md`](api-reference.md) |
| Causal-verification / tautology doctrine ("would this assertion pass under a no-op?") | [`stages-protocol.md`](stages-protocol.md) Stage 3 item 5 (Stage 4b item 11 is the review-side checklist form and cites it) |
| No-inline-selectors rule + its one scope exception | `../SKILL.md` §"Hard rules — kernel-resident" + Rule 6 (exception documented in `../../companion-mode/SKILL.md` §"Selector handling"; see §3.1) |
| App bugs reported, never worked around | `../SKILL.md` Rule 9 |
| App-context write-back on every page visit / discovery | `../SKILL.md` Rule 10 |
| Visual-regression variants (`verifyVisualMatch` + masks) | `../SKILL.md` Rule 16 |
| Secrets in `.env`, test-data variables centralised, durable-identity fixture carve-out | `../SKILL.md` Rule 15 (doctrine: `../../test-data-conventions/SKILL.md`) |
| Test-data doctrine (discovery, strategy ladder, generation, cleanup, premises, data plan) | [`../../test-data-conventions/SKILL.md`](../../test-data-conventions/SKILL.md) |
| Stability counts (3× new/edited, 5× flaky-heal — see §3.3) | `../../failure-diagnosis/SKILL.md` §"Stability Validation Protocol" |
| State isolation, hardcoded shared resources, per-run uniqueness | [`test-optimization.md`](test-optimization.md) §1–§3 |
| Volatile-value assertion forms (round-trip / delta / shape oracles) | [`test-optimization.md`](test-optimization.md) §3b |
| API shortcuts for tested prerequisites (two-of-two gate) | [`test-optimization.md`](test-optimization.md) §4 |
| Serial-mode discipline + `// serial-deliberate:` annotation | `../../test-composer/SKILL.md` Step 3 (mandate); [`test-optimization.md`](test-optimization.md) §6 (review) |
| Whole-suite re-run gate | [`test-optimization.md`](test-optimization.md) §7 |
| Per-journey portfolio (variant order, P0–P3 depth mapping) | `../../test-composer/SKILL.md` Steps 1 + 3 |
| Oracle strength ladder L0–L3 | `../../test-composer/SKILL.md` §"Oracle strength ladder" |
| Deliberate-failure bite check (mutate expected value, confirm the test fails, revert) | `../../test-composer/SKILL.md` §"Oracle strength ladder" (UI); `../../contract-testing/SKILL.md` Rule 8 (API) |
| Input-domain / partition analysis | `../../test-composer/references/input-domain-analysis.md` |
| Tenant cleanup contract (`cleanupViaApiBackdoor`, `cleanup: done \| blocked \| not-needed`) | `../../test-composer/SKILL.md` §"Tenant cleanup hooks are non-negotiable" |
| Evidence-required rule for findings | [`subagent-return-schema.md`](subagent-return-schema.md) §1 "Evidence rule" |
| Fresh-eyes reviewer independence | `../../coverage-expansion/references/reviewer-subagent-contract.md` §"Hard constraints" |
| Subagent return + ledger shapes | [`subagent-return-schema.md`](subagent-return-schema.md) |
| Selector conventions | `../../selector-development/references/selector-convention.md` |
| Skill names + sentinel strings | [`skill-registry.md`](skill-registry.md) |
| `test.fail()` policy (one sanctioned use — see §3.2) | `../../ticket-driven-testing/SKILL.md` §7 |
| Smoke-vs-e2e depth doctrine | §5 of this file |
| Stage 4c composition-judge loop | §4 of this file |
| Orchestrator dispatch discipline (specialist task families) | §6 of this file (precedent: `../../coverage-expansion/SKILL.md` §"Orchestrator context budget" → "Hard rules — kernel-resident") |
| Test-identity conventions (test IDs on every case; `@known-defect` intentional reds — no heal, no rerun, passed = anomaly) | [`test-identity.md`](test-identity.md) (§1 stable IDs; §2 `@known-defect`) |
| Style-interaction verification (mock-DOM styling tests as a documented fallback) | `../../ticket-driven-testing/SKILL.md` §"Style-interaction verification — mock the page, test the styling" |
| Commit-or-discard gate (CX/revenue impact) + brief-report contract | `../../ticket-driven-testing/SKILL.md` §8d "Commit or discard — the CX/revenue impact gate" |
| Deck print-safety rules | `../../work-summary-deck/SKILL.md` §"Print-safety rules" |
| Stage-4b compliance sweep as every mode's exit gate | [`stages-protocol.md`](stages-protocol.md) §"Stage 4b is every mode's exit gate" (harness-backed by `hooks/compliance-sweep-exit-gate.sh`) |

## §3 Contradiction resolutions (normative record)

The diffs in the citing files are the enforcement; this section is the rationale record. Each resolution below is normative — a future edit that re-introduces the losing side is a regression.

**3.1 Inline selectors.** Durable suite specs: **hard ban** — every selector lives in `page-repository.json`; inline selectors in committed spec files are a hard-rule violation (kernel rule in `../SKILL.md`). The one documented exception: `companion-mode` evidence bundles may carry bundle-scoped inline selector proposals (the bundle is not the suite); those proposals graduate to repo entries at Stage-3 graduation. The former "this is a preference, not a hard ban" language in Rule 6 was the contradiction and has been replaced with this scope-based rule.

**3.2 `test.fail()`.** Legal **only** as a defect sentinel tied to a tracked ticket with a removed-when-fixed lifecycle — `../../ticket-driven-testing/SKILL.md` §7 owns it. Banned everywhere no ticket owns the marker: coverage-expansion / adversarial passes never commit `test.fail()` (suspected bugs stay ledger-only). Both sides cross-cite.

**3.3 Stability runs.** The "3-5 consecutive runs" range collapsed to a two-number rule: **3 consecutive green minimum for any new or edited test; 5 consecutive green for a heal of a previously-flaky test** (suite order for flaky heals, per `test-repair`). Canonical text: `../../failure-diagnosis/SKILL.md` §"Stability Validation Protocol".

**3.4 Serial mode.** Tenant-mutating specs use file-level `test.describe.configure({ mode: 'serial' })` AND carry a `// serial-deliberate: <reason>` comment above the configure line. Stage 4a's §6 review treats that annotation as satisfying review — no `stage4a:serial-mode-review` flag for annotated files. Unannotated serial mode is still flag-only per `test-optimization.md` §6.

**3.5 Test-data shape.** `tests/fixtures/test-data.ts` may hold **env-sourced durable identities** — accounts that exist by design (an admin account, a seeded catalog user), loaded from `process.env`. Any identity a test **creates** is generated per-attempt **inside the test body** — module-scope generation is banned because retries reuse the module value and collide. Full doctrine: `../../test-data-conventions/SKILL.md`; the fixture carve-out is stated in `../SKILL.md` Rule 15.

**3.6 Oracle taxonomies.** L0–L3 (`../../test-composer/SKILL.md` §"Oracle strength ladder") is the **strength ladder** — which layer confirms the effect (UI paint / UI round-trip / API / DB). `test-optimization.md` §3b's round-trip / delta / shape oracles are **assertion forms** for volatile values *within* a rung. They are orthogonal: first pick the rung the priority table demands, then pick the §3b form that keeps the assertion stable at that rung. Both files carry a one-line cross-citation.

**3.7 Dangling references.** `test-optimization.md`'s prerequisites (HELPER SLOT markers in `base.ts`; the onboarding shared-resource audit tags) now resolve: `onboarding/SKILL.md` Phase 1 scaffolds `base.ts` with the HELPER SLOT markers, and its §"Shared-resource audit" subsection (delegating to `../../journey-mapping/references/test-infrastructure-probe.md`) owns the audit-tag surface.

## §4 Stage 4c — composition judge loop (mandatory at every composing exit)

Stages 4a (optimization) and 4b (API compliance) are author-side self-review. **Stage 4c adds the reviewer the author cannot be: an independent judge subagent with an adversarial charter.** No composing exit is complete until the judge returns SATISFIED (or the escalation bound below fires).

### Dispatch

- Runs **after 4a + 4b are clean** (tests green, optimized, API-compliant).
- Dispatch an independent judge subagent with description prefix **`composition-judge-<scope>:`** — fresh context, never the author, never a reused prior judge (fresh-eyes property per `../../coverage-expansion/references/reviewer-subagent-contract.md` §"Hard constraints").
- The brief gives the judge: the specs under review, the scenario source (approved scenario / journey block / ticket ACs), `page-repository.json` slice, `tests/e2e/docs/test-data-plan.md`, and the four review dimensions below. The brief MUST cite the return schema `schemas/subagent-returns/reviewer-inloop.schema.json` (the harness preread gate denies schema-mapped dispatches whose brief omits the citation).
- The judge's charter is adversarial: its job is to find defects in the composition, not to approve it. A vague approval is a failed dispatch.

### Review dimensions

1. **Acceptance-criteria / scenario-intent coverage.** Every stated AC, `Test expectations:` item, or approved-scenario clause maps to ≥1 test — and every test maps back to a stated intent. Orphans in either direction are findings.
2. **Coverage & oracle strength.** Causal verification on every test (no vacuous or tautological asserts — per `stages-protocol.md` Stage 3 item 5), oracle-ladder calibration per priority (the must-fix calibration rubric in `reviewer-subagent-contract.md` §"Behavior" step 6 applies: an L0-only oracle on a P0 mutating step is a verification miss).
3. **API compliance spot-check.** Sampled cross-reference against [`api-reference.md`](api-reference.md) — signatures, option shapes, no raw Playwright where a Steps equivalent exists.
4. **Test-data feasibility** per [`../../test-data-conventions/SKILL.md`](../../test-data-conventions/SKILL.md). Each spec's data strategy sits on a rung of that skill's **strategy decision ladder** — seeded-own-data or content-resilient handling; hardcoded current content is a must-fix. Check: data generated per-attempt inside the test body? per-worker isolated? cleanup hooked and idempotent? premises declared with the named-skip discipline? no reliance on current content as the oracle? And the **test data plan** (`tests/e2e/docs/test-data-plan.md`) exists and reflects the specs under review — new dependencies and gaps the specs introduce appear in it. (Creation owner: `onboarding` Phase-1 scaffold, or the first composing session creates it from the template — `test-data-conventions` §"The test data plan". A missing plan is a must-fix directed at the author, who creates it; never grounds to fail a fresh project outright.)

### Verdict + loop

- Verdict is **SATISFIED | NOT SATISFIED**, carried in the `reviewer-inloop` return shape (`schemas/subagent-returns/reviewer-inloop.schema.json`): `status: greenlight` ⇔ SATISFIED; `status: improvements-needed` + `[must-fix]` findings ⇔ NOT SATISFIED with required changes. Returns open with the §2.0 handover envelope of [`subagent-return-schema.md`](subagent-return-schema.md). No new schema — the judge reuses the existing reviewer verdict shape.
- On NOT SATISFIED: the **author** fixes the must-fix items, re-runs 4a and 4b if code changed, then re-dispatches a **fresh** judge.
- **Bound: 3 consecutive NOT SATISFIED verdicts → stop and escalate to the operator** with the accumulated must-fix lists. This mirrors `workflow-reviewer`'s 3-cycle reject cap (`../../workflow-reviewer/SKILL.md` §"3-cycle reject cap"); an author↔judge loop that cannot converge in 3 cycles has a disagreement only the operator can settle.
- Harness backstop: `hooks/composition-judge-gate.sh` records `composition-judge-` dispatches and verdicts per session and WARNs at Stop while a judge loop is open on a NOT-SATISFIED verdict below the cap. Arming the loop in the first place (dispatching the judge at all) is not mechanically detectable and stays markdown-only — tagged in `../../coverage-expansion/references/anti-rationalizations.md` §"Pattern: `markdown-only` deferral — judge-loop arming".

### Where Stage 4c applies

| Composing exit | How the judge loop lands |
|---|---|
| `achilles-protocol` Stage 4 (interactive + autonomous) | 4c after 4a/4b, before commit — see `stages-protocol.md` §"Stage 4c" |
| `test-composer` Step 6 | Step 6c after 6a/6b. Under `coverage-expansion` dual-stage, the Stage-B reviewer cycle satisfies 4c **provided its brief includes dimension 4** — the loop is not double-imposed |
| `onboarding` Phase 3 exit | Each happy-path spec's composing cycle ends with 4c (via `test-composer` Step 6c) |
| `ticket-driven-testing` §7 | Its §8/§8b adversarial machinery (five probe missions + negative control) **counts as the judge loop** — do not impose a second 4c on top; §8b's dispatch discipline is the equivalence |
| `companion-mode` Stage-3 graduation | Graduated specs pass through `achilles-protocol` Stage 4, which now includes 4c. Evidence bundles themselves are NOT composing exits — no judge on a bundle |
| `bug-discovery` Phase 6 | Reproduction specs get a 4c judge before the Phase 7 report cites them |
| `test-repair` / `self-repair` whole-rewrite heals (heal type g) | The operator-approved rewrite goes through `test-composer`, whose Step 6c applies. Incremental heals do NOT trigger 4c — their gate is the stability rule (§3.3) |

## §5 Smoke vs e2e depth doctrine

Two spec depths, chosen per test by what the test is *about*:

- **e2e spec — the journey IS the subject.** Walk the journey through the UI end-to-end; no state-injection shortcuts on the path under test. A journey's full UI walk is the subject of **exactly one** e2e test.
- **smoke / derivative spec — a surface is the subject.** Reach the target view via API / state injection (`test-optimization.md` §4's two-of-two gate; `setAuthCookie` / seed helpers), and put UI assertions ONLY on the surface under test. Everything upstream of the subject is setup, and setup goes through the fastest safe channel.
- **Auth:** session/cookie injection everywhere **except** the tests whose subject IS login/signup — those keep the UI walk. Authentication is a *precondition*, not a step of the journeys it unlocks, so injecting it does not breach the e2e no-shortcut rule (the gate-first regression/smoke/e2e architecture this section instantiates is defined in `../../../docs/agentic-shift-left.md` §"Stage 4 — Guard / Heal").
- **Organisation:** specs are organised by user journey (one spec file per journey / feature area holding its scenarios); suites split e2e vs smoke so the depth choice is visible in the tree. Derivatives shortcut; the one e2e walk does not.

Rationale: duplicated UI walks multiply run time and flake surface without multiplying signal — the walk is already locked by its one e2e test; derivatives re-walking it re-test the walk, not their own subject.

## §6 Orchestrator dispatch discipline

The specialist task families of this suite each run as **dedicated subagent dispatches** carrying a role-prefixed brief that points at the task's canonical instruction set. The orchestrator skill — whichever skill is currently routing (the top-level orchestrator, `coverage-expansion`, `onboarding`, or a caller like `ticket-driven-testing`) — **routes, gates, and integrates results; it does not carry these tasks out inline.** When an orchestrator catches itself starting one — opening a `playwright-cli` session to inspect selectors, writing a spec body, probing a boundary, judging its own composition — it stops and dispatches.

| Task family | Dispatch prefix (greppable) | Canonical instruction set |
|---|---|---|
| UI inspection / page-repository building | `stage2-<scope>:` (crawl: `phase1-*:`) | [`stages-protocol.md`](stages-protocol.md) Stage 2; [`playwright-cli-protocol.md`](playwright-cli-protocol.md) |
| Test composing | `composer-j-<slug>:` / `composer-sj-<slug>:` | `../../test-composer/SKILL.md` |
| Coverage-expansion passes | (orchestrated; per-journey work via `composer-*` / `probe-*` / `reviewer-*`) | `../../coverage-expansion/SKILL.md` |
| Journey mapping | `phase4-cycle-<N>:` sections; `phase4-prioritise-author` | `../../journey-mapping/SKILL.md` |
| Adversarial probing / bug discovery | `probe-j-<slug>-<pass>:` / `probe-*:` | `../../bug-discovery/SKILL.md`; `../../coverage-expansion/references/adversarial-subagent-contract.md` |
| Failure diagnosis | `fd-<scope>` sessions; `fd-ci-<run-id>:` pipeline entrypoint (subagent-only skill) | `../../failure-diagnosis/SKILL.md` |
| Repair workers | `repair-worker-<file-slug>:` | `../../self-repair/references/worker-pipeline.md` |
| Composition judging (Stage 4c) | `composition-judge-<scope>:` | §4 of this file |
| Workflow / phase review | `workflow-reviewer-*:` / `phase-validator-*:` | `../../workflow-reviewer/SKILL.md` |

This section cites existing precedent rather than inventing a new rule: `../../coverage-expansion/SKILL.md` §"Orchestrator context budget" → "Hard rules — kernel-resident" ("The orchestrator does NOT compose tests directly", "does NOT run `playwright-cli` for selector inspection", "does NOT run `npx playwright test` for stabilization"), `../../coverage-expansion/references/anti-rationalizations.md` §"Pattern: Orchestrator-direct composition" (whose scope covers this full task-family list), and `failure-diagnosis`'s subagent-only convention. Why it holds: context discipline (DOM snapshots, spec source, and stabilization transcripts live in worker contexts, never the conductor's), separation of duties (an orchestrator that composes has no independent reviewer), and parallelism (absorbed work is serial by construction — if parallel dispatch feels unsafe, fix the upstream cause per `test-optimization.md` §1.A, don't absorb).

**Enforcement:** markdown-only for the general rule (the in-flight-registry hooks that mechanically distinguished orchestrator from subagent writers were retired in 0.3.6; the registry entry above carries the reviewer-visible tag). Partial harness backing exists per family: `hooks/playwright-cli-isolation-guard.sh` (slug shape), `hooks/subagent-schema-preread-gate.sh` (brief must cite the role schema), `hooks/composition-judge-gate.sh` (judge-loop leash), and the `workflow-reviewer-pass<N>:` checklists (spec files cross-checked against recorded composer dispatches).

## §7 Kernel-resident invariants (for citing skills to mirror)

Citing skills may mirror these lines in their own `### Hard rules — kernel-resident` blocks (dual-update obligation per §1.3):

- **Composing rules are single-homed.** Shared rules live at their canon-index home (`test-composition-standards.md` §2); cite, never fork, no one-extra-clause extensions.
- **Stage 4c is mandatory at every composing exit.** After 4a + 4b: independent `composition-judge-` subagent, four dimensions (intent coverage, oracle strength, API compliance, test-data feasibility), fresh judge per cycle, 3 consecutive NOT SATISFIED → operator.
- **Stability is 3×/5×.** 3 consecutive green for new/edited tests; 5 for a heal of a previously-flaky test.
- **`test.fail()` only as a ticketed defect sentinel** (`ticket-driven-testing` §7); never in coverage/adversarial passes.
- **One e2e walk per journey; derivatives shortcut** via API/state injection and assert only their own surface (§5).
- **Data feasibility is a composing gate** — a scenario whose data cannot be generated, isolated, and cleaned up is blocked/flagged per `test-data-conventions`, never written against whatever is live.
- **Specialist task families dispatch; orchestrators never absorb** (§6) — UI inspection, composing, probing, diagnosis, repair, and judging each run as role-prefixed subagent dispatches; an orchestrator catching itself starting one inline stops and dispatches.
