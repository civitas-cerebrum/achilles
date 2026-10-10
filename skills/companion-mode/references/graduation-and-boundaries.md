# Directory boundaries, graduation, cross-skill summary

# Directory boundaries

Permissions split into **Phases 1–5** (the evidence run itself) and **Phase 6 graduation** (writes that flow through a handoff). Companion mode never writes outside the evidence directory during Phases 1–5; during Phase 6, writes outside the evidence directory are owned by the receiving skill (`achilles-protocol` Stage 3 or `onboarding`), not by companion mode itself.

| Path | Owner | Phases 1–5 | Phase-6 graduation |
|---|---|---|---|
| `tests/e2e/evidence/` | companion-mode | Read + write | Read-only (bundle is frozen as audit trail) |
| `tests/e2e/docs/journey-map.md` | `journey-mapping` | Read-only | Read-only (only `onboarding` may regenerate it) |
| `tests/e2e/docs/app-context.md` | `achilles-protocol` Stage 1/2/5 | Read-only | Written by the receiving skill, not by companion mode |
| `tests/e2e/docs/adversarial-findings.md` | `bug-discovery` / `coverage-expansion` | Read-only | Read-only |
| `tests/<spec>.spec.ts` | Stage 3 / `test-composer` | Read-only | Written by Stage 3 after handoff — companion mode does NOT copy the bundle spec into `tests/` |
| `page-repository.json` | Stage 2 | Read; write only with approval (or `autonomousMode: true`) | Written by Stage 3 after handoff |
| `playwright.config.ts` | project | Read-only | Written by `onboarding` (Level A/B) or by Stage 3 (Level C) — NOT by companion mode |
| `package.json` | project | Read-only | Written by `onboarding` Level-A install OR by the Level-A "(a) just this task" remediation step before invoking Stage 3 — see the matrix below |
| `tests/fixtures/base.ts` | `onboarding` scaffold | Read-only | Written by `onboarding` (Level B full) or by the Level-B "(a) just this task" minimum scaffold step before invoking Stage 3 |

## Phase-6 minimum-scaffold writes (Level A / B / "(a) just this task")

When the user picks "(a) just this task" at the Phase-6 offer **and** the cascade detector reported Level A or B, companion mode performs the minimum scaffold writes itself before handing off to Stage 3 — because Stage 3 expects the framework already installed and the fixture already wired. This is the only Phase-6 case where companion mode itself writes outside the evidence directory; in every other case, the writes are performed by the receiving skill.

| Level | What companion mode writes (Phase 6, option (a) only) |
|---|---|
| **A** | Run `npm install @civitas-cerebrum/element-interactions @civitas-cerebrum/element-repository @playwright/test` (writes `package.json`, `package-lock.json`, `node_modules/`). Then write a minimal `playwright.config.ts`, `tests/fixtures/base.ts`, and `page-repository.json` (the same scaffold `onboarding` would write at Level B). |
| **B** | Write only the missing scaffold files among `playwright.config.ts`, `tests/fixtures/base.ts`, `page-repository.json`. |
| **C** | No scaffold writes — Stage 3 can land a durable test without `journey-map.md`. |

After the Level-appropriate writes complete, companion mode invokes `achilles-protocol` Stage 3 with the bundle's task description, pass criterion, and selectors as inputs. From that point on, all further writes (the durable spec, page-repository updates, app-context updates, commits) are owned by Stage 3 — companion mode does not supervise.

A Phase-1-through-5 run that writes outside the evidence directory (excluding the gated `page-repository.json` write inside Phase 3) is a contract violation. A Phase-6 run that writes anything beyond the Level-appropriate minimum scaffold (e.g., regenerates `journey-map.md` itself, edits the receiving skill's outputs after handoff) is also a contract violation.

# Graduation paths (summary)

The full mechanics live in §"Phase 6: Report and automation offer". This section is the at-a-glance map.

| User picks at Phase 6 | Setup state | What companion mode does | Receiving skill |
|---|---|---|---|
| `yes` | None (fully onboarded) | Invoke `achilles-protocol` with `autonomousMode: true, entry: "stage3", bundlePath: "<absolute>"` | `achilles-protocol` Stage 3 |
| `(a) just this task` | A | Install framework + write minimum scaffold, then hand off | `achilles-protocol` Stage 3 |
| `(a) just this task` | B | Write missing scaffold files, then hand off | `achilles-protocol` Stage 3 |
| `(a) just this task` | C | No scaffold writes; hand off directly | `achilles-protocol` Stage 3 |
| `(b) full onboarding` | A / B / C | Hand task + pass criterion + bundle path to onboarding as `happyPathDescription` | `onboarding` |
| `no` / no answer | Any | Leave bundle in place, end session | — |
| FAILED verdict offer accepted | Any | Hand off to failure-diagnosis; automation question deferred | `failure-diagnosis` |
| FAILED + diagnosis = app bug + "yes" (file ticket) | Any | Pass bundle evidence to `bug-report`; automation deferred until bug is fixed | `bug-report` |
| FAILED + diagnosis = test issue | Any | Defer; user fixes test issue, then re-runs companion mode | — |

Hard invariants across all paths:

- **Graduated specs pass the Stage 4c composition judge.** Every Stage-3 graduation path lands in `achilles-protocol` Stage 3→4, whose Stage 4c dispatches the independent `composition-judge-` review before commit (`../achilles-protocol/references/test-composition-standards.md` §4). Evidence bundles themselves are not composing exits — no judge runs on a bundle.
- The bundle is **never** moved, deleted, or modified after Phase 5. It stays in `tests/e2e/evidence/<slug>-<ts>/` as the audit trail and is referenced (not copied) by the receiving skill in its commit message or report.
- Companion mode does **not** chain handoffs. After invoking Stage 3, `onboarding`, or `bug-report`, companion mode is done.
- Companion mode **never** performs a Phase-6 handoff without an explicit `yes / (a) / (b)` from the user. Vague replies get a clarifying re-prompt.
- The `bug-report` offer appears **only** after `failure-diagnosis` has confirmed the root cause is an app bug — never speculatively on a FAILED verdict alone.

# Cross-skill summary

- **Reads from:** `package.json` (cascade detection), `playwright.config.ts` (runner version + cascade), `tests/fixtures/base.ts` (fixture import path + cascade), `page-repository.json` (selector reuse + cascade), `tests/e2e/docs/journey-map.md` line 1 (sentinel check for Level C).
- **Writes during Phases 1–5:** `tests/e2e/evidence/<slug>-<ts>/` (everything), and (with approval, or under `autonomousMode: true`) `page-repository.json` for new selector entries.
- **Writes during Phase 6 (only on `(a) just this task` × Level A/B):** `package.json` + `package-lock.json` + `node_modules/` (Level A install), and the minimum scaffold among `playwright.config.ts`, `tests/fixtures/base.ts`, `page-repository.json` (Level A/B). All other Phase-6 paths perform NO writes — the receiving skill (`achilles-protocol` Stage 3 or `onboarding`) owns those.
- **Returns to caller (interactive):** the printed Phase-6 report plus, if a handoff was made, control transfers to the receiving skill. Companion mode does not return a structured value to an interactive user.
- **Returns to caller (autonomousMode):** `{ status: 'passed' | 'failed' | 'inconclusive', bundlePath: '<absolute>', specPath: '<absolute>', graduated: 'none' | 'stage3' | 'onboarding' }`.
- **Skill invocations:** never invokes another skill during Phases 1–5. Phase 6 may invoke `achilles-protocol` (Stage 3), `onboarding`, `failure-diagnosis`, or `bug-report` — and only one of them per session, and only with explicit user assent. `bug-report` is only offered after `failure-diagnosis` has confirmed an app bug on a FAILED run.
