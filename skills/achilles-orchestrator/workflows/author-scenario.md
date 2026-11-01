# Workflow: author-scenario

One durable test (or a small set the user named) from a scenario, a URL, a bundle, or a fix request. Also answers API questions. Entry conditions and deliverables: [SKILL.md](../SKILL.md) §2.

## Entry points

| Entry | Starts at | Source of the scenario |
|---|---|---|
| User described a scenario or gave a URL | Stage 1 | the brief; discovery fills gaps |
| `happyPathDescription` from the onboard workflow (Phase 3) | Stage 1, no questions | one sentence per primary journey; the author also writes the discovery draft |
| `bundlePath` from an evidence-capture graduation | Stage 3 | `summary.md` carries task, pass criterion and URL; `spec.ts` carries the selectors; the bundle is read-only |
| Fix / edit an existing test | Stage 3 (fix mode) | the spec path; new selectors go through a mini Stage 2 |
| API question | none | answer from [`api-reference.md`](../references/api-reference.md); no dispatch |

## Stage 1: scenario

1. If the brief carries a complete scenario or acceptance criteria, reformat into Given/When/Then and continue. Ask nothing you can read.
2. Otherwise dispatch an **inspector** (`stage2-<slug>` session) to explore the pages the ask names and return: candidate scenarios in Given/When/Then, preconditions (auth, data), the success criterion, and an `app-context.md` append. The inspector saves what it saw per [`stages-protocol.md`](../references/stages-protocol.md) §"App context".
3. Anything the inspector could not settle (which of two flows, which account, what counts as success) is one `NEEDS_CONTEXT` hand-back with the drafted scenario attached. Do not advance on a guess.

## Stage 2: elements

Dispatch an **inspector** with the approved scenario and the `page-repository.json` slice. It follows [`stages-protocol.md`](../references/stages-protocol.md) §"Stage 2" and returns proposed entries with the raw inspection facts behind each (URL path, state reached, tag, role, accessible name, test attribute, match count, snapshot excerpt or screenshot path), reusing existing entries where they exist. It inserts nothing and runs no evidence tool.

- The author writes the entries in Stage 3: insert `"provisional": true`, run `npx achilles-selector-evidence`, drop the flag in the same change ([`selector-evidence.md`](../references/selector-evidence.md)). Live-verified entries with a note land under the standing authorisation; entries the tool could not verify live (source-only, interaction-gated, user-supplied) ride along flagged `provisional` and are listed in the `DONE_WITH_CONCERNS` hand-back; they do not stop the run.
- No stable selector and the frontend source is in the workspace: the author's brief includes a `selector-development` JIT step for that element. Frontend absent: record the fragile selector as test debt in the return.
- The live app unreachable: `NEEDS_CONTEXT` asking for selectors or a screenshot per element; never invent one.

## Stage 3: write and stabilise

Dispatch an **author** loading [`stages-protocol.md`](../references/stages-protocol.md) §"Stage 3", [`api-reference.md`](../references/api-reference.md) and [`../../test-data-conventions/SKILL.md`](../../test-data-conventions/SKILL.md), with the scenario, the proposed entries and their inspection facts, the fixture path, `tests/e2e/docs/test-data-plan.md` (the author creates it from the `test-data-conventions` template when it is missing and updates it for the data this scenario needs), and the session slug `stage2-<slug>` for mini-inspections. The author inserts the entries and runs the evidence sequence, writes the spec, runs it to 3 consecutive greens, runs Stage 4a (optimisation) and 4b (compliance) on what it wrote, stages the files, and returns with the spec path, the entries added (which stayed provisional and why), the plan path, and the stability evidence. A failing test inside the author's loop goes through `failure-diagnosis` inside that author; an app bug comes back as `app-bug` with evidence and the test unchanged.

For the onboard entry the author also writes `tests/e2e/docs/.discovery-draft.json` ([state-files.md](../references/state-files.md) §"Discovery draft") at the end of Stage 3.

## Stage 4c: judge

Dispatch a fresh **reviewer** loading [`../../review/SKILL.md`](../../review/SKILL.md) in judge mode with the spec paths, the scenario, the repository slice and `tests/e2e/docs/test-data-plan.md`. `greenlight` → you commit the staged work (`test(<area>): <scenario>`, [commit-conventions.md](../references/commit-conventions.md)). `improvements-needed` → re-dispatch the author with the must-fix list, then a new reviewer. Third consecutive `improvements-needed` → hand back `DONE_WITH_CONCERNS` with the three lists.

## Fix mode

Skip Stages 1–2. The author reads the spec and the API reference, diagnoses with `failure-diagnosis` (evidence floor first), heals or reports, meets the stability bar, runs the 4b sweep, and returns. New selectors go through the inspector step. Commit `fix(<area>): <cause> — <heal>`.

## After the last scenario

Readiness check (all committed tests green on a clean run; `page-repository.json` valid; `app-context.md` updated), then hand back `DONE` with the scenarios committed, the pages covered, the entries added, and one line naming the next step the cascade suggests (map-journeys at level C, expand-coverage at None). Do not start it. Any entry still flagged `provisional` makes it `DONE_WITH_CONCERNS`, one entry per concern with its selector and where it is referenced.
