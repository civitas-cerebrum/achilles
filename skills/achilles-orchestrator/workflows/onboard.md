# Workflow: onboard

Zero to a maintained e2e suite in eight phases. Every phase ends with a fresh reviewer ([`../../review/SKILL.md`](../../review/SKILL.md), phase-gate mode) before the next starts, and the ledger `tests/e2e/docs/onboarding-status.json` records each transition ([state-files.md](../references/state-files.md) §"Pipeline ledgers").

## Front-load

1. **Mode.** `runMode: standard` (first pass and first discovery cycle strict per unit; later ones may group) unless the brief says `depth` (strict per unit everywhere, up to ~20× the dispatches). The P3 adversarial opt-out candidates are proposed here too, so no mid-run question is needed; both land in the ledger with the authorising quote. A brief with neither mode nor an authorisation for the full pipeline is a `NEEDS_CONTEXT` hand-back that names the two modes, the cost ("tens of minutes to several hours"), and the opt-out candidates.
2. **Preconditions.** The dev server is reachable; the cascade level ([cascade.md](../references/cascade.md)) is A, B or C; no committed e2e suite is already in conflict (a committed `tests/e2e/*.spec.ts` set means this is a resume of a later phase, not onboarding). A project with substantial Playwright coverage is not onboarded; route to expand-coverage.
3. Write the ledger with all eight rows `pending`, Phase 1 `in-progress`, and `runMode` with its authoriser.

## Phase map

| # | Phase | Produces | Expert |
|---|---|---|---|
| 1 | Scaffold | `playwright.config.ts`, `tests/e2e/{fixtures,docs}/`, `tests/e2e/playwright.setup.ts`, `.gitignore` entries, `test:repair` script | author (scaffold brief) |
| 2 | Groundwork | `app-context.md`, `page-repository.json`, `tests/e2e/fixtures/auth.ts` | inspector (walk) + author (files) |
| 3 | Happy path | one spec per primary journey, `.discovery-draft.json` | author per journey via [author-scenario](author-scenario.md) |
| 4 | Journey mapping | sentinel-bearing `journey-map.md`, `journey-map-coverage.md` | [map-journeys](map-journeys.md) |
| 5 | Coverage expansion | specs per journey per pass, adversarial ledger | [expand-coverage](expand-coverage.md) |
| 6 | Bug discovery | findings + regression specs | [hunt-bugs](hunt-bugs.md) |
| 7 | Secrets sweep | `.env`, `.env.example`, env-driven suite | author ×2 |
| 8 | Report | `qa-summary-deck.{html,pdf}` | doc-writer loading `qa-reporting` |

Cascade: level B skips the files Phase 1 already finds; level C makes Phases 1–2 verify-only.

## Phase 1: scaffold

Author brief (scaffold scope: config, `package.json` scripts, `.gitignore`, `tests/e2e/**`): `playwright.config.ts` with the dev-server URL, `retries`, `use.video`/`use.trace: 'retain-on-failure'`, the `html` + `json` + `@civitas-cerebrum/achilles/reporter` reporters, a `webServer` block when the suite should start the app; `tests/e2e/fixtures/base.ts` with the `HELPER SLOT` markers ([`test-optimization.md`](../references/test-optimization.md) §"Placeholder convention"); `tests/e2e/docs/test-data-plan.md` from the template in `test-data-conventions`; `tests/e2e/.gitignore` (`playwright-report/`, `test-results/`, `.last-run.json`, `bug-evidence/`) and `.achilles/`, `.playwright-cli/` in the root `.gitignore`; `"test:repair": "achilles-self-repair"`.

Exit: `npx playwright test --list` lists zero specs without error (you run it); the files exist; you read the config diff for `webServer.command` before the first run. Commit `chore: scaffold e2e suite`.

## Phase 2: groundwork

Inspector walks the running app (`phase1-<entry>` sessions, one per entry point, in parallel) and returns a page list with purpose and primary elements, the auth model, roles, URL surface, and the test-infrastructure probe tags (`../../journey-mapping/references/test-infrastructure-probe.md`). Author turns the returns into `app-context.md` (with a `## Test Infrastructure` section carrying the tags verbatim), `page-repository.json` (one entry set per discoverable page, evidence notes where live-verified), and `tests/e2e/fixtures/auth.ts` that mints users at runtime.

Exit: the three files exist; `--list` still works. Commit `docs: initial app-context and site map`.

## Phase 3: happy path

From `app-context.md` pick the primary journeys (2–5). For each, run [author-scenario](author-scenario.md) from the `happyPathDescription` entry, in parallel where the journeys are independent. Each spec passes its judge review. The last author writes `.discovery-draft.json`.

Exit: one green spec per primary journey; the draft exists with its version key. Commit per spec: `test(j-<slug>): happy path`.

## Phase 4: journey mapping

Run [map-journeys](map-journeys.md) with `phases: full` and the mode's cycle strictness. Exit: sentinel on line 1, priority groupings, a `## Section → Journey Map` table, `journey-map-coverage.md` with `<missing>` rows, the edge-probe cycle reflected in the map, `.phase4-cycle-state.json` recording cycles 1 and 2. Append the probe tags to `app-context.md` if Phase 2 did not.

## Phase 5: coverage expansion

Run [expand-coverage](expand-coverage.md) with `mode: <runMode>`. Every pass transition is reviewed; the ledger row advances only after the pass-5 cleanup review approves and `coverage-expansion-state.json` is deleted. Exit: every mapped journey not covered by a Phase-3 spec has a spec or an authorised skip (P0/P1 never skipped without the quote); `<missing>` rows for P0/P1 closed before P2/P3; per-pass dedup landed. Critical or high pass-5 findings carry into the Phase-6 brief as focus ids.

## Phase 6: bug discovery

Run [hunt-bugs](hunt-bugs.md) in live mode across the map, grouped per that workflow. Exit: every probe terminal; every `findings-emitted` has a regression spec or an explicit `app-bug` flag in `adversarial-findings.md`; blocked probes carry a ledger deferral with an authoriser or were re-dispatched.

## Phase 7: secrets sweep

You scan `tests/**` and the root `playwright*.config.ts` with the regex table in `secrets-sweep` and build `NAME=value` pairs. Two author dispatches in order: one with scaffold scope writes `.env`, `.env.example`, the `.gitignore` entries and the `dotenv` load in the config, and moves config literals; one with `tests/**` scope loads `secrets-sweep` and rewrites literals to `process.env.<NAME>` using exactly the names you gave. Evidence bundles are not swept (they were redacted at capture).

Exit: your re-scan is clean apart from the reported JSON literals; `.env`, `.env.example`, `.gitignore` in place; `npx playwright test` green (you run it). Commit `chore: extract secrets to .env`.

## Phase 8: report

Doc-writer loading `qa-reporting` (deck mode). Exit: `qa-summary-deck.html` and `.pdf` at the project root; figures match the suite (staleness gate honoured); every page inspected. Commit `docs(report): qa summary deck`.

## Cross-cutting

- Self-credentialing first: no spec hard-codes a username, password or token.
- One commit per landed deliverable so a partial run resumes.
- Generic clustering vocabulary in shared docs (browse / transact / account / mutate / errors / auth), no project tokens.
- Every expert return is schema-shaped ([controller-contract.md](../references/controller-contract.md) §"Worker statuses").
- A skipped phase or an early stop needs the reviewer's approval of the deviation plus an `approvedDeviations[]` entry with a verbatim authoriser; "session length", "budget" and "auto mode" are not authorisers. Without one, the run hands back `NEEDS_CONTEXT` at the phase boundary.

## Resume

Read the ledger: the first row that is not `completed` with `reviewerVerdict: approved` is where the run continues. Each phase is independently runnable as long as its predecessor's deliverables exist on disk; confirm them before dispatching.

## Hand-back

`DONE` with the ledger summary (eight rows, verdicts, cycles), commit list, the residual-risk block from Phase 5, and the deck path. Phases ending in escalation hand back `DONE_WITH_CONCERNS` with the three reviewer returns per escalated unit.
