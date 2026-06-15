# Cascade Detector — Canonical Onboarding-State Probe

**Status:** single source of truth for the onboarding-state cascade (Levels A / B / C / None) and the per-caller responses to each level. Cited by `element-interactions` (routing), `onboarding` (preconditions), and `companion-mode` (Phase 6 automation offer). Callers run the probe as documented here and consume the resulting level — they do NOT re-paste the detection table or infer levels from memory. Drift between callers is the bug this file exists to prevent.

The detector answers exactly one question: **"is this project onboarded for element-interactions test automation, and if not, how far did it get?"** It does NOT answer "is a pipeline mid-flight?" — callers that care about in-flight state (e.g. `companion-mode`'s mid-pipeline advisory) check `tests/e2e/docs/coverage-expansion-state.json` separately, on their own contract.

---

## Detection table

Run the checks top-down. The first failing check assigns the level; later checks are skipped.

| Level | Condition | Meaning |
|---|---|---|
| **A** | `@civitas-cerebrum/element-interactions` is absent from `package.json` (`dependencies` and `devDependencies`) OR `node_modules/@civitas-cerebrum/element-interactions/` does not exist | Framework not installed — nothing downstream can run. |
| **B** | Dep present, but any scaffold file is missing: `playwright.config.ts`, `tests/fixtures/base.ts`, `page-repository.json` | Installed but not scaffolded. |
| **C** | Scaffold present, but `tests/e2e/docs/journey-map.md` is missing OR its line 1 is not the literal sentinel `<!-- journey-mapping:generated -->` | Scaffolded but never journey-mapped. Individual tests (Stage 3) can land; `coverage-expansion` / `test-composer` cannot. |
| **None** | All checks pass | Fully onboarded. |

There is no Level D. A detector result outside `A | B | C | None` is a detector bug, not a new level for callers to handle.

## How to probe — Read/Glob, not shell

Use the Read and Glob tools, not `ls`/`cat` from Bash:

1. **Level A check** — Read `package.json` and look for `@civitas-cerebrum/element-interactions` under `dependencies` or `devDependencies`; then Glob `node_modules/@civitas-cerebrum/element-interactions/package.json` to confirm the install actually landed. Either miss → **A**.
2. **Level B check** — Glob `playwright.config.ts`, `tests/fixtures/base.ts`, and `**/page-repository.json`. Any miss → **B**.
3. **Level C check** — Read line 1 of `tests/e2e/docs/journey-map.md`. Missing file, or line 1 is not the literal `<!-- journey-mapping:generated -->` → **C**.
4. **None** — everything above passed.

Record the level before acting on it. Sentinel strings are case-sensitive — copy them verbatim from [`skill-registry.md`](skill-registry.md) §"Non-skill sentinel strings".

Detector use is a methodology rule — no harness hook enforces it; callers comply by running the probe before acting on onboarding state.

## Per-caller response matrix

Each caller consumes the same level but responds on its own contract. The authoritative response text lives with the caller (paths below); this matrix is the index.

### `element-interactions` (routing — vague request or no scaffold)

| Level | Response |
|---|---|
| **A / B / C** | Point the user at the `onboarding` skill (interactive eight-phase pipeline); an external automated CLI driver may drive the same pipeline non-interactively. At Level C only: individual Stage 1–4 scenarios may still proceed — the journey map is required by `coverage-expansion` / `test-composer`, not by Stage 3 — but route any Stage-5 / coverage intent through `journey-mapping` first. |
| **None** | Normal routing — Stages 1–4 inline, companion skills per the routing block in `element-interactions/SKILL.md`. |

### `onboarding` (preconditions — which phases are live)

| Level | Response |
|---|---|
| **A** | Full pipeline from Phase 1 (install + scaffold). |
| **B** | Phase 1 writes only the missing scaffold files, then the pipeline continues normally. |
| **C** | Phases 1–2 verify-only (scaffold exists); the pipeline's first producing phase is Phase 3 (happy path) / Phase 4 (journey mapping). |
| **None** | Already onboarded — do not re-run the pipeline. Route the user's intent to `coverage-expansion` (more coverage) or `bug-discovery` (adversarial probing) instead. |

### `companion-mode` (Phase 6 — automation offer after a PASSED verdict)

Offer shapes are verbatim in `skills/companion-mode/SKILL.md` §"Next-step offer matrix"; minimum-scaffold writes are in its §"Phase-6 minimum-scaffold writes" table. Summary:

| Level | Offer | If user picks "(a) just this task" |
|---|---|---|
| **None** | Stage-3 graduation: invoke `element-interactions` with `autonomousMode: true, entry: "stage3", bundlePath: "<absolute>"` | n/a — the offer is a plain yes/no |
| **A** | "(a) just this task / (b) full onboarding" | Install `@civitas-cerebrum/element-interactions` + `@civitas-cerebrum/element-repository` + `@playwright/test`, write minimal `playwright.config.ts`, `tests/fixtures/base.ts`, `page-repository.json`, then hand off to Stage 3 |
| **B** | "(a) just this task / (b) full onboarding" | Write only the missing scaffold files, then hand off to Stage 3 |
| **C** | "(a) just this task / (b) full onboarding" | No scaffold writes — Stage 3 lands a durable test without `journey-map.md` |

"(b) full onboarding" at any of A / B / C invokes `onboarding` with the bundle's task description + pass criterion as `happyPathDescription`. FAILED / INCONCLUSIVE verdicts defer the automation offer entirely — see the companion-mode matrix.

---

## Relationship to other reference docs

| Reference | Scope |
|---|---|
| [`skill-registry.md`](skill-registry.md) | Canonical skill names, invocation strings, sentinel strings (including the journey-map sentinel this detector checks). |
| [`autonomous-mode-callers.md`](autonomous-mode-callers.md) | The `entry: "stage3"` contract used by companion-mode's Level-None graduation path. |
| [`cascade-detector.md`](cascade-detector.md) (this file) | Canonical onboarding-state probe and per-caller response matrix. |
