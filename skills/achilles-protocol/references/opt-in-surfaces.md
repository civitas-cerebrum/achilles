# Opt-in surfaces and switches

Every switch that changes what Achilles enforces. `lint-doc-drift` check 8 fails when code reads a switch that has no row here.

| Switch | Set where | Effect | Blast radius |
|---|---|---|---|
| `ACHILLES_PROTOCOL` | operator shell | `1` forces the protocol on; `0` stops a new session from activating (an active session stays active) | every Achilles hook, including the kernel wrapper |
| `KERNEL_MANDATE` | operator shell | `0` bypasses the role kernel | kernel only; Achilles gates still run |
| `.claude/kernel-mandate.json` | project | presence makes the kernel govern this tree; postinstall stages it only when absent | kernel only |
| `CIVITAS_SKIP_HOOK_INSTALL` | install env | `1` skips hook install and mandate staging | all hooks |
| `CIVITAS_SKIP_JQ_INSTALL` | install env | `1` skips the bundled jq download | hooks then need jq on PATH |
| `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` | install env | `1` skips the Chromium download | browser-driven skills |
| `CIVITAS_DISABLE_ADVERSARIAL_GATE` | operator shell | `1` disables `adversarial-verification-gate` | that gate |
| `CIVITAS_DISABLE_COMPLIANCE_SWEEP_GATE` | operator shell | `1` disables `compliance-sweep-exit-gate`; document the authorisation | that gate |
| `CIVITAS_DISABLE_EVIDENCE_GATE` | operator shell | `1` disables `evidence-bundle-gate` | that gate |
| `CIVITAS_DISABLE_SELECTOR_DEVELOPMENT` | operator shell | `1` disables the selector-development activation gate and inertness guard | selector-development pipeline |
| `CIVITAS_DISABLE_TEST_ID_GATE` | operator shell | `1` disables `test-id-compliance-gate` | that gate |
| `CIVITAS_TEST_ID_PATTERN` | project env | regex source replacing the default test-ID shape | `test-id-compliance-gate` and its scanner |
| `DECK_INSPECTION_GATE` | operator shell | `0` disables `deck-inspection-gate` | that gate |
| `SCHEMA_RETURN_GUARD` | operator shell | `strict` turns a return-schema failure from a warning into a block (exit 2) | `subagent-return-schema-guard` |
| `WORKFLOW_REVIEWER_BRIEF_GATE` | operator shell | `off` bypasses `workflow-reviewer-brief-gate` | that gate |
| `ACHILLES_ARTIFACT_RETAIN` | operator shell | integer, default 5; runs kept by the artifact archiver; `0` disables archiving | `playwright-artifact-archiver` |
| `ACHILLES_ARTIFACT_MAX_MB` | operator shell | integer, default 512; above it traces and videos are skipped | `playwright-artifact-archiver` |
| `ACHILLES_CLIENT_TERMS_FILE` | operator shell | path of the client-term denylist, default `.achilles/client-terms.local.txt` | `client-term-guard` |
| `ACHILLES_EVIDENCE_DIR` | operator shell | extra directory searched for evidence bundles | `evidence-bundle-gate` |
| `ACHILLES_EVIDENCE_GATE_BUDGET_S` | operator shell | integer seconds, default 30; time budget of the gate | `evidence-bundle-gate` |
| `ACHILLES_SESSION_STATE_DIR` | tests only | relocates the per-session activation markers | replaces where protocol-active state is read; never set it in a real session |
| `ACHILLES_JUDGE_STATE_DIR` | tests only | relocates `composition-judge-gate` state | replaces the judge state the gate trusts; never set it in a real session |
| `KERNEL_MANDATE_MANIFEST` | tests only | explicit manifest path, bypasses discovery | replaces the manifest the kernel enforces; never set it in a real session |
| `KERNEL_MANDATE_STATE_DIR` | tests only | relocates the kernel state dir (registry, decision log) | replaces the dispatch registry the kernel trusts; never set it in a real session |
| `FAKE_STAGED_HASH` | tests only | replaces the staged-tree hash the stepper trusts | never set it in a real session |

## Kill switches that are not environment variables

| Switch | Effect |
|---|---|
| `.claude/onboarding-stop-authorized` | authorises an early stop of the onboarding pipeline |
| deleting the project's `.claude/kernel-mandate.json` | the kernel stops governing the tree |
