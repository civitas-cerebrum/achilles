# Workflow: hunt-bugs

Adversarial probing of the whole app (or a named page set) after the suite is green. The orchestrator iterates journeys and dispatches one author per journey (or per relevance group) loading [`../../bug-discovery/SKILL.md`](../../bug-discovery/SKILL.md); each return is reviewed before the next wave. Inside expand-coverage, passes 4–5 run the same expert per journey with a negative-case matrix; this workflow is the standalone, cross-app sweep.

## Modes

- `live` (default): probes drive the running app through `playwright-cli` (`probe-<slug>` sessions).
- `static`: no app reachable; probes infer from specs, repository, `app-context.md` and source, and mark every finding `inferred: true` (`../../bug-discovery/references/static-mode.md`).
- `phase`: `full` (default), `1a-element-probing`, `1b-flow-probing` (needs 1a's findings file).

## Preflight

- Green suite (`npx playwright test`); a red suite routes to [repair-suite](repair-suite.md) first.
- `page-repository.json` populated; `app-context.md` present (phases 2 and 4 are limited without it; say so in the hand-back).
- Journey map present: iterate its journeys, elevated-risk first within a tier. Absent: iterate the site's pages from `app-context.md`, all `baseline`.
- Focus ids from a prior coverage pass (critical/high pass-5 findings) go into the matching journeys' briefs.

## Dispatch

- One author per journey by default. When more than five journeys share a section, group same-priority, same-section journeys up to seven per brief; never group an elevated-risk journey or one carrying remediation work; cross-tab or concurrent-state flows (phase 1b) stay per-journey.
- Each brief: the journey block (never the whole map; the first-time effect depends on the probe seeing the app before the context), the page-repository slice, the session slug, the probe budget from the session charter, the ledger and lockfile paths, the finding schema pointer ([finding-and-ledger-schema.md](../references/finding-and-ledger-schema.md)), and `mode`/`phase`.
- The author runs phases 1a–7 of its skill for its scope, appends findings to `tests/e2e/docs/adversarial-findings.md`, writes reproduction specs that assert the correct behaviour (red today, green when fixed), and returns `findings-emitted`, `clean` or `blocked` with the charter-versus-actuals line.
- A fresh reviewer per return (Stage B adversarial mode) attempts two or three probes the author did not, checks ledger well-formedness and that every finding above `info` cites evidence. `improvements-needed` → re-dispatch the author with the list; cap 7 cycles as in [dual-stage-retry-loop.md](../references/dual-stage-retry-loop.md).
- Quality safeguard: shallow returns across a grouped dispatch end grouping for the rest of the run.

## Report

After the last wave, one doc-writer consolidates `bug-discovery-report.md` (phase 7 of the expert skill): findings by severity and priority, reproduction spec per finding or an explicit `app-bug` flag, coverage notes (charter versus actuals, areas not probed and why). Filing tickets is a separate doc-writer dispatch loading `bug-report` per finding the user asks for.

Commit per journey `docs(bug-hunt): j-<slug> — N findings`; reproduction specs commit with their journey.

## Hand-back

`DONE` with counts by severity, the report path, the ledger path, reproduction specs committed, and the not-probed list. Findings without evidence above `info` do not exist; a run that ends with ambiguous findings lists them under concerns.
