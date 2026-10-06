# Known limits

One row per limit that ships. `Detector` is the case or lint that pins the behaviour. A change that closes a limit deletes its row. IDs are never reused; a gap means the row was retired or is pending a task in this release.

| ID | Limit | Detector | Owner |
|---|---|---|---|
| KL-01 | The kernel does not inspect the text of a dispatch brief; a dispatcher can pass anything it can read to a child. | kernel design (vendored) | kernel-mandate upstream |
| KL-02 | Roles that author and run code are contained by a static import/capability screen, not a sandbox. | `cases/kernel-mandate/07-write-then-execute.sh` | kernel-mandate upstream |
| KL-04 | The scaffolder is the only role that reads or writes `.env`; its return reaches the orchestrator's context, and the scaffolder's `dotenv` config import is unscreened because it declares no import list. The composer return schema has no free-text field for values. | `cases/85-qa-mandate-scopes.sh` §secrets-sweep | methodology |
| KL-08 | `pr-attribution-gate`, `perf-load-safety-gate`, the MCP branches of `adversarial-verification-gate` and `evidence-bundle-gate`, and parts of `playwright-cli-isolation-guard` only act when the kernel is dormant: while it binds, the kernel refuses those commands first. | none yet | Achilles hooks |
| KL-09 | `sync-kernel-mandate --check` without `$KERNEL_MANDATE_SRC` proves the vendored bytes match the lock, not that the lock matches upstream. | `cases/84-sync-kernel-mandate-check.sh` | Achilles maintainers |
| KL-10 | Kernel deny messages suggest `kernel-mandate explain`/`derive`; that CLI is not shipped by Achilles. | vendored text | kernel-mandate upstream |
| KL-11 | An existing project `.claude/kernel-mandate.json` is never overwritten; Achilles dispatches then bind to that manifest's roles. | `cases/71-achilles-kernel-activation-gate.sh` §postinstall | Achilles install |
| KL-12 | Several roles hold write scope on `onboarding-status.json`; who may record which transition is enforced by `onboarding-ledger-write-gate.sh`, not by the mandate. | `cases/51-onboarding-ledger-write-gate.sh` | Achilles hooks |
| KL-13 | The orchestrator may write anything under `tests/**`, including specs, fixtures and the page repository; delegating those to the scaffolder and composers is methodology, not enforcement. | `cases/71-achilles-kernel-activation-gate.sh` | methodology |

## Runtime requirements

| Requirement | Why | When missing |
|---|---|---|
| jq | every hook parses JSON with it | postinstall bundles one; hooks fall back to PATH |
| Node ≥ 20 | validator bundle, postinstall, CLIs | schema-validating hooks warn and allow |
