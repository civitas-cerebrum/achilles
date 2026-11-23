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
| `<!-- platform-testing:generated -->` | line 1 of `tests/platform/docs/platform-report.md` |
| `"discovery-draft-version": 1` | first key of `tests/e2e/docs/.discovery-draft.json` |
| `<!-- subagent-returns:<role>:<scope> -->` | line 1 of every spill file under `tests/e2e/docs/.subagent-returns/` |

## Platform projects

A native app target (iOS, Android) runs the same probe with the platform files in place of the web ones. The level is recorded per modality: a project can be onboarded for web and at level B for platform, or the reverse.

| Level | Condition (platform) | Meaning |
|---|---|---|
| **A** | `@civitas-cerebrum/element-interactions` below 0.4.0 or absent, OR `@wdio/cli` not pinned at `10.2.0` in `devDependencies`, OR `webdriverio` absent | Framework or inspection tool not installed |
| **B** | Any of: `playwright.platform.config.ts`, `tests/platform/fixtures/base.ts`, at least one `tests/capabilities/*.json` with `platformName`, `tests/capabilities/README.md`, the page repository (below) | Installed, not scaffolded |
| **C** | Scaffold present, but `tests/platform/docs/app-context.md` has no screen entries | Scaffolded, never inspected. Single scenarios can land once their screens are inspected; a suite cannot |
| **None** | All checks pass | Onboarded for platform |

Rules that differ from the web cascade:

- **One page repository per project.** If `tests/e2e/page-repository.json` exists, platform pages go into it (one page name per platform) and the B check looks there. A platform-only project uses `tests/platform/page-repository.json`. Two repositories in one project is a drift to fix, not a layout.
- **No Chromium requirement.** A platform-only project is never sent to `playwright-cli install-browser` or `npx playwright install`; neither is a level condition. The Appium server, its drivers and the devices are environment, checked in preflight, not in the cascade.
- **The scaffold is the platform scaffold** ([`../../platform-testing/SKILL.md`](../../platform-testing/SKILL.md) §"Scaffolding"): config with `workers: 1`, capabilities files and README, the fixture, the pinned `@wdio/cli`, the app build and install step. It never writes a capability into the fixture or config.
- **Pipeline state** is `tests/platform/docs/platform-onboarding-status.json`, a resume file like the other ledgers ([state-files.md](state-files.md)).

| Workflow on a platform target | A | B | C | None |
|---|---|---|---|---|
| one platform scenario | `NEEDS_CONTEXT`: offer the platform pipeline or the one-task platform scaffold | one-task platform scaffold of the missing files, then proceed | inspect the scenario's screens, then proceed | proceed |
| platform pipeline ("platform-onboard" / "onboard the iOS / Android app") | from `preflight` | `scaffold` writes only the missing files | `preflight` and `scaffold` verify only; first producing phase is `inspect` | do not re-run; route to the ask's own work |
