# bypass-artifacts

Verbatim, byte-for-byte copies of the artifacts produced by the prior incident
Run-2 onboarding bypass session. Originally used by the exploit-replication
test cases to lock the hardening hooks against the EXACT inputs the bypass
produced — not paraphrased equivalents. Those case files were retired with the
hooks they exercised; the artifacts are kept as the canonical record of the
bypass shapes (and as inputs for any future exploit-replication coverage).

The artifacts are read-only fixtures. Do not edit them; if the upstream
shape changes, copy the new artifacts in and bump anything that depends on
the old shape.

| File | Source path in downstream-e2e |
|---|---|
| `BENCHMARK-pre-bypass.md` | `BENCHMARK.md` lines 1–308 — the pre-bypass state (Run 0 + Run 1, no Run 2) |
| `BENCHMARK-run-2-bypass-section.md` | `BENCHMARK.md` lines 310–481 — the verbatim Run-2 section the bypass committed |
| `onboarding-report-bypass.md` | `tests/e2e/docs/onboarding-report.md` — the verbatim 103-line report the bypass committed |
| `coverage-expansion-state-bypass.json` | `tests/e2e/docs/coverage-expansion-state.json` — the verbatim Pass-1-only state file with 6 `blocked-dispatch-failure` dispatches |
| `onboarding-phase-ledger-bypass.json` | `tests/e2e/docs/onboarding-phase-ledger.json` — the verbatim ledger with phases 1–4 greenlit, phases 5–7 absent |

## Cross-reference: downstream-e2e bypass commit

```
c23fbdd docs(partial): onboarding-report + coverage-expansion-state + BENCHMARK Run 2
```

The commit message itself uses the framing token "partial" — see the PR body
for the open gap on a `commit-msg` hook (no such hook exists yet; recorded as
follow-up).
