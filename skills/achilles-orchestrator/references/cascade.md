# Cascade: the onboarding-state probe

One probe, run in preflight ([SKILL.md](../SKILL.md) §3), answers "is this project onboarded for Achilles test automation, and if not, how far did it get?". It does not answer "is a pipeline mid-flight?"; that is the resume-file check in [state-files.md](state-files.md).

## Detection table

Run the checks top-down. The first failing check assigns the level.

| Level | Condition | Meaning |
|---|---|---|
| **A** | `@civitas-cerebrum/element-interactions` absent from `package.json` (`dependencies` and `devDependencies`) OR `node_modules/@civitas-cerebrum/element-interactions/` missing | Framework not installed; nothing downstream can run |
| **B** | Dependency present, but any scaffold file missing: `playwright.config.ts`, `tests/fixtures/base.ts` (or `tests/e2e/fixtures/base.ts`), `page-repository.json` | Installed, not scaffolded |
| **C** | Scaffold present, but `tests/e2e/docs/journey-map.md` missing OR its line 1 is not the literal `<!-- journey-mapping:generated -->` | Scaffolded, never journey-mapped. Single scenarios can land; coverage expansion cannot |
| **None** | All checks pass | Onboarded |

There is no Level D. Sentinel strings are case-sensitive; copy them from the table.

Read the files to probe; do not infer the level from memory or from a directory listing alone. Record the level in the run's resume file before acting on it.

## What each level means per workflow

| Workflow | A | B | C | None |
|---|---|---|---|---|
| author-scenario | hand back `NEEDS_CONTEXT`: offer onboarding, or the one-task scaffold (install + minimal `playwright.config.ts`, `base.ts`, `page-repository.json`) | one-task scaffold of the missing files, then proceed | proceed; the journey map is not required for one scenario | proceed |
| onboard | full pipeline from Phase 1 | Phase 1 writes only the missing files | Phases 1–2 verify only; first producing phase is 3 | do not re-run; route the ask to expand-coverage or hunt-bugs |
| map-journeys, expand-coverage, hunt-bugs (live) | `BLOCKED` with the install step named | `BLOCKED` with the missing files named | map-journeys runs; the other two require it first | proceed |
| verify-change, evidence-capture | the evidence run needs a Playwright project; at A or B offer the one-task scaffold in `NEEDS_CONTEXT` | as A | proceed | proceed |
| qa-reporting | catalogue needs level None; the deck runs from any level with specs present | | | |

## Sentinel strings

| String | Where |
|---|---|
| `<!-- journey-mapping:generated -->` | line 1 of `tests/e2e/docs/journey-map.md` |
| `<!-- coverage-expansion-adversarial:generated -->` | line 1 of `tests/e2e/docs/adversarial-findings.md` |
| `<!-- app-wide-scan:generated -->` | line 1 of `tests/e2e/docs/app-wide-patterns.md` |
| `<!-- performance-testing:generated -->` | line 1 of `tests/perf/docs/perf-report.md` |
| `<!-- perf-onboarding:scenario-model -->` | line 1 of `tests/perf/docs/scenario-model.md` |
| `"discovery-draft-version": 1` | first key of `tests/e2e/docs/.discovery-draft.json` |
| `<!-- subagent-returns:<role>:<scope> -->` | line 1 of every spill file under `tests/e2e/docs/.subagent-returns/` |
