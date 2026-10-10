# Opt-in surfaces and switches

Every switch that changes what Achilles enforces. `lint-doc-drift` check 8 fails when code reads a switch that has no row here.

| Switch | Set where | Effect | Blast radius |
|---|---|---|---|
| `ACHILLES_PROTOCOL` | operator shell | `1` forces the protocol on; `0` stops a new session from activating (an active session stays active) | every Achilles hook, including the kernel wrapper |
| `KERNEL_MANDATE` | operator shell | `0`, `false` or `off` bypasses the role kernel, including the wrapper's refusal when the kernel file is missing | kernel only; Achilles gates still run |
| `.claude/kernel-mandate.json` | project | presence makes the kernel govern this tree; postinstall stages it when absent and refreshes it only while unedited | kernel only |
| `achilles-factory-rules.json` | project root | committing it opts the project into the factory gates it has rules for; no file, or a rule id absent, makes that gate allow silently ([factory-gates.md](factory-gates.md#opting-in-the-rule-file)) | seven gates registered for every project, no-op without the file |
| `FACTORY_RULES` | operator shell | path of the rule file, absolute or relative to the project root (`$CLAUDE_PROJECT_DIR`, else the cwd) | the factory gates and the scenario lint |
| `FACTORY_JQ` | tests only | jq binary the factory gates use | never set it in a real session |
| `FACTORY_NODE` | tests only | node binary `spend-gate` and `commit-gate` use | never set it in a real session |
| `FACTORY_SCHEMA` | tests only | rule-file schema `repository-evidence-gate` reads its `evidenceDir` default from | replaces where that gate looks for evidence notes; never set it in a real session |
| `SPEND_OPT_IN` | the command line, per run | `SPEND_OPT_IN=1` in front of a run of a spend-incurring spec is the owner's opt-in (the variable is the `spend.opt-in` rule's `optInEnv`) | `spend-gate`, for that one command |
| `NODE_BIN` | hook environment | node binary the ledger write gates validate the schema with; default `node` on PATH | replaces the validator runtime of the onboarding and perf ledger gates; never set it in a real session |
| `WORKSPACE_ROOT` | hook environment | root `adversarial-verification-gate` and `evidence-bundle-gate` search; default the git top level, else the cwd | those two gates |
| `NO_SKIP_MESSAGING_SELFTEST` | maintainer shell | `1` with `bash hooks/lib/hook-emit.sh` checks and prints the shared deny texts | none: read only when the file is run directly, never by a hook that sources it |
| `CIVITAS_SKIP_HOOK_INSTALL` | install env | `1` skips hook install and mandate staging | all hooks |
| `CIVITAS_SKIP_JQ_INSTALL` | install env | `1` skips the bundled jq download | hooks then need jq on PATH; without it, PreToolUse gates deny while the protocol is active |
| `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` | install env | `1` skips the Chromium download | browser-driven skills |
| `CIVITAS_DISABLE_ADVERSARIAL_GATE` | operator shell | `1` disables `adversarial-verification-gate` | that gate |
| `CIVITAS_DISABLE_COMPLIANCE_SWEEP_GATE` | operator shell | `1` disables `compliance-sweep-exit-gate` | that gate |
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
| `JOURNEY_MAPPING_PREREAD_GATE` | operator shell | `off` bypasses `journey-mapping-skill-preread-gate` | that gate |
| `FD_EVIDENCE_FLOOR_GATE` | operator shell | `off` bypasses `failure-diagnosis-evidence-floor-gate` | that gate |
| `KERNEL_MANDATE_SRC` | maintainer shell | path of the canonical kernel-mandate checkout; `sync-kernel-mandate` copies from it, and `--check` also compares against it | vendored kernel files in this repo |
| `CONVENTION_OVERRIDE` | tests only | replaces the cached selector convention | `selector-development-inertness-guard`; never set it in a real session |
| `FAKE_STAGED_HASH` | tests only | replaces the staged-tree hash the stepper trusts | never set it in a real session |
| `NODE_BIN` | hook environment | node binary the ledger write gates validate the schema with; default `node` on PATH | replaces the validator runtime of the onboarding and perf ledger gates; never set it in a real session |
| `WORKSPACE_ROOT` | hook environment | project root the evidence, adversarial-verification, test-id and selector-development hooks work in; default the git top level, else the cwd (the selector-development stepper requires it) | those hooks |
| `NO_SKIP_MESSAGING_SELFTEST` | maintainer shell | `1` with `bash hooks/lib/hook-emit.sh` checks and prints the shared deny texts | none: read only when the file is run directly, never by a hook that sources it |

## Kill switches that are not environment variables

| Switch | Effect |
|---|---|
| `.claude/onboarding-stop-authorized` | authorises an early stop of the onboarding pipeline |
| deleting the project's `.claude/kernel-mandate.json` | the kernel stops governing the tree |
| `npx achilles-uninstall [--global] [--project <dir>] [--dry-run]` | removes the hooks, skills, agents and registrations the install record lists (files only while unedited) and an unedited staged mandate; your own settings.json entries stay |
