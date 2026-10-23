# Phase 7: Report & Triage

## Report Location

`docs/e2e/bug-discovery-report.md`

## Report Template

```markdown
# Bug Discovery Report
**Date:** YYYY-MM-DD
**App:** [baseURL from playwright config]
**Total findings:** X
**User-visible bugs:** X | **DOM-only issues:** X | **Undocumented quirks:** X

## Summary by Severity
| Severity | Count | Categories |
|----------|-------|------------|
| **User-Visible** | | |
| Critical | X     | ...        |
| High     | X     | ...        |
| Medium   | X     | ...        |
| Low      | X     | ...        |
| **DOM-Only** | | |
| No impact | X    | ...        |

## User-Visible Bugs (Confirmed)

### <FINDING-ID> [<severity>] — Title
- scope: <one sentence — page / endpoint / element / flow step under probe>
- expected: <one sentence — correct behaviour>
- observed: <one sentence — actual behaviour>
- coverage: <spec file › test name, or none>

**Severity:** critical | high | medium | low | info
**Priority:** Highest | High | Medium | Low   _(from the Priority-derivation matrix; bug-report pre-fill)_
**Triage:** new | acknowledged | fix-in-progress | fix-verified | deferred | wontfix
**Visibility:** User-visible (screenshot) | Security-class (artifact-verified)
**Category:** Boundary input | State transition | Race condition | ...
**Phase discovered:** 1a | 1b | 4
**Page:** PageName — `/route`
**Reproduction test:** `tests/bug-discovery/element-bugs.spec.ts:L42`
**Screenshot:** ![](screenshots/<FINDING-ID>.png)
**Steps:**
1. Navigate to /page
2. Do X
3. Observe Y

---

## DOM-Only Issues (Lowest Priority)
Issues found by inspecting the HTML/DOM that are not visible to users.
These are cleanup items, not user-facing bugs.

## Undocumented Quirks (User Decision Required)
Items that could not be definitively classified as bugs.
Each entry asks: "Is this intentional?"

## Previously Reported (Triage Carry-Forward)
Counts by triage status for findings carried forward from prior runs (keyed by FINDING-ID):
| Status | Count |
|---|---|
| new | X |
| acknowledged | X |
| fix-in-progress | X |
| fix-verified | X |
| deferred | X |
| wontfix | X |
_(Regressions: list any fix-verified entry whose reproduction test failed this run and flipped to `acknowledged (regressed YYYY-MM-DD)`.)_

## Coverage Notes
- Pages probed: X/Y
- Flows tested: X
- Categories covered: [list]
- Charter vs actuals: budgeted <B> probes, consumed <C>; <closed>/<total> categories closed by diminishing-returns stop rule
- Areas not probed (and why): [derived from budget-closed items in the session charter]
```

## Triage lifecycle

Findings carry a triage status across runs. This is a **methodology convention (model-compliance), not harness-enforced**: no hook gates the report or ledger. State is keyed on the canonical FINDING-ID and survives between runs.

| Status | Meaning |
|---|---|
| `new` | First reported this run; not yet acknowledged by an operator. |
| `acknowledged` | An operator has seen it; fix not yet started. |
| `fix-in-progress` | A fix is being worked. |
| `fix-verified` | The reproduction test now passes: the bug is fixed, **evidence-revocable** (see Rules). |
| `deferred` | Operator chose to defer; verbatim instruction recorded. Filtered like a known issue. |
| `wontfix` | Operator chose not to fix; verbatim instruction recorded. Filtered like a known issue. |

**Rules:**

1. **Stable identity.** Triage state is keyed by the canonical FINDING-ID (`<journey-slug>-<pass>-<nn>` / `<journey-slug>-<nn>` per the canonical schema §1). Every entry carries the ID in its heading. **IDs are never renumbered or reused** across runs: a re-found bug keeps its original ID; a new bug gets a fresh one.
2. **Operator-only deferral.** Only an operator may set `deferred` or `wontfix`, and the verbatim instruction is recorded with the entry. **Severity is frozen during triage**: triage status changes, severity does not.
3. **Evidence-revocable fix-verified.** `fix-verified` is not terminal. A `fix-verified` entry whose reproduction test **fails again** flips to `acknowledged` with a dated `regressed YYYY-MM-DD` note, severity unchanged. (Mere failure-to-reproduce of an *inferred* static finding is `live-unconfirmed`, not a regression; see static-mode epistemics.)

**Re-run reconciliation.** On every run, Phase 3 re-runs the reproduction tests of **every prior finding not at `deferred`/`wontfix`** (`fix-verified` is NOT exempt; that is what makes it revocable). A passing repro on a `new`/`reported`/`acknowledged`/`fix-in-progress` finding advances it to `fix-verified(YYYY-MM-DD)`; a failing repro on a `fix-verified` finding flips it to `acknowledged (regressed YYYY-MM-DD)`. Reconciliation carries every prior entry forward by FINDING-ID; no finding is silently dropped.

The ledger mirrors this via its §3 `status:` line (`new | reported(<issue-url>) | fix-verified(YYYY-MM-DD) | closed-wontfix | recurring`): the report's six-state `**Triage:**` field is the operator-facing lifecycle; the ledger `status:` line is its machine-facing projection.

## Post-Report

After generating the report, ask:

> "Bug discovery report written to `docs/e2e/bug-discovery-report.md`. Would you also like me to file tickets for the confirmed bugs?"

If the user agrees, **route ticket creation through the `bug-report` skill**: one ticket per confirmed bug, with the FINDING-ID, journey, build/commit, reproduction-test pointer, and the matrix-derived Priority handed over as `bug-report`'s Traceability and pre-fill fields. When a GitHub issue (or Jira ticket) is created, write its URL back into the finding's ledger `status:` line as `status: reported(<url>)` and reflect it in the report's `**Triage:**` carry-forward. Do not hand-roll the ticket body here; `bug-report` owns the ticket shape.
