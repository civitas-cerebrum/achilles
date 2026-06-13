# Phase 1 — Make the Harness Honest (integrity fixes)

**Date:** 2026-06-12
**Status:** Approved design, pending implementation plan
**Source:** `2026-06-12-senior-qa-audit.md` (four-surface senior-QA audit)
**Repos:** `achilles` (this repo) and `element-interactions` (sibling, via its contribution methodology)

## Problem

The audit found the system claims enforcement and produces reports that are not
true today:

- Hooks installed to `~/.claude/hooks/` cannot validate anything (no schemas, no
  node_modules) — the flagship ledger write-gate silently `exit 0`s in every
  consumer install, and subagent-return validation emits only false WARNs.
- Every Write|Edit gate is bypassable through the Bash tool, and an awk
  regex-metachar bug lets most Edit calls bypass the ledger gate even in-repo.
- Six-plus skills claim "Harness-enforced" backing from hooks retired in 0.3.6.
- The benchmark self-report (`run-summary.json`) reads artifacts no skill writes
  and hardcodes a passing exit code.
- In element-interactions, `steps.waitForState` swallows timeouts (it can never
  fail a test, yet the README models it as an assertion), the
  pointer-interception auto-retry silently clicks through real overlay bugs, and
  the package cannot be published due to a `file:` dependency.

A "more senior" QA agent built on top of this inherits a false foundation.
Phase 1 repairs it. Phases 2 (senior judgment layer) and 3 (state-control and
evidence upgrades) build on the repaired base and get their own specs.

## Design — achilles repo

### A1. Self-contained validator bundle

One esbuild-bundled, dependency-free artifact: `hooks/lib/validator.bundle.mjs`.

- Embeds: all `schemas/subagent-returns/*.schema.json` (including the handover
  envelope), `schemas/onboarding-status.schema.json`, the `yaml` parser, Ajv
  2020 + ajv-formats, using the exact Ajv configuration shared by
  `compile-schemas.mjs` and the current runtime validator.
- CLI contract (superset of today's `validate-against-schema.mjs`):
  `node validator.bundle.mjs validate <role|onboarding-status> <data-file>` —
  exit 0 valid, 1 invalid (errors on stderr), 2 unknown schema/usage.
  Data files may be YAML or JSON.
- Built by `scripts/build-validator.mjs` (esbuild as devDependency), wired into
  `prepack` and the hook-test runner (build-if-absent). The artifact is
  gitignored; `sync-hooks` builds it before copying.
- `postinstall.js` ships it with the hook files (it lives under `hooks/lib/`,
  already in the copy set — verify and add to the manifest checks).
- Consumers: `subagent-return-schema-guard.sh` and
  `onboarding-ledger-write-gate.sh` replace their path-walking schema lookups
  with the bundle. The "schema dir not found → exit 0" silent-allow branches are
  deleted: if the bundle is missing or node is unavailable, the write-gate still
  runs its shell-side structural checks (actor identity, phase-skip,
  mode-authorisation, deliverable existence) — those must not depend on node.
- Kills audit items: harness #2 (consumer no-op), #4 (false WARNs), part of
  hook-quality (validate-against-schema resolution).

### A2. Edit-path synthesis fix

The write-gate's Edit synthesis (`awk sub(o,n)` — old_string treated as regex)
is replaced with literal replacement via the bundle:
`node validator.bundle.mjs replace <file> <old-file> <new-file>` performing
split/join literal substitution with uniqueness check (mirrors the Edit tool's
own contract: zero or multiple matches → report, gate falls back to DENY-safe
behavior rather than silent allow).

- On synthesis failure the gate **denies** with a diagnostic, never allows.
- New test cases: old_string containing `[`, `(`, `*`, `&` (awk/sed metachars),
  multi-line old_string, no-match, multi-match.
- Kills harness #3.

### A3. Bash-bypass guard

New hook `protected-artifact-bash-guard.sh` (PreToolUse:Bash, DENY mode).

- **Protected paths** (basename/glob match anywhere in the command):
  `onboarding-status.json`, `journey-map.md`, `.phase4-cycle-state.json`,
  `coverage-expansion-state.json`, `.workflow-approvers.json`,
  `adversarial-findings.md`, `.ledger-integrity.json` (new, see A4),
  `~/.claude/hooks/`, `~/.claude/settings.json`.
- **Write-shaped constructs** that trigger DENY when combined with a protected
  path: output redirection (`>`, `>>`) targeting the path, `tee`, `cp`, `mv`,
  `rm`, `install`, `ln`, `truncate`, `dd of=`, `sed -i`, `perl -i`,
  `sponge`, in-place `jq`/`yq` idioms, and interpreter one-liners
  (`python -c`, `python3 -c`, `node -e`, `ruby -e`, `perl -e`) that mention a
  protected path at all (interpreters can write without shell redirection, so
  mention + interpreter = deny).
- Read-only access (cat/grep/jq/head without redirection into the path) allowed.
- Deny text via `lib/no-skip-messaging.sh`, naming the sanctioned route
  (Write/Edit tools, which the gates inspect) and the rule being enforced.
- Registered in HOOK_MANIFEST; full allow/deny test matrix in `hooks/tests/`.
- Known limit (documented in the hook header): Bash filtering cannot be
  airtight — the agent shares the hooks' privileges. A4 provides detection for
  whatever slips through. Together they re-back several "retired in 0.3.6"
  invariants (see A7).
- Kills harness #1 frontally, #7 and the meta-surface (hook self-modification)
  partially.

### A4. Tamper-evident ledger chain

Detection layer for out-of-band mutations that A3 cannot prevent.

- On every **sanctioned** (gate-approved) write to `onboarding-status.json`, the
  write-gate records `sha256(content)` plus timestamp into a sidecar
  `tests/e2e/docs/.ledger-integrity.json` (itself on the A3 protected list and
  gated for Write/Edit).
- `onboarding-ledger-gate.sh` (dispatch gate) and the write-gate verify, before
  honoring any ledger state, that the on-disk ledger hashes to the sidecar's
  last record. Mismatch → DENY (dispatches and further ledger writes) with
  recovery instructions: restore the ledger via the sanctioned path or have the
  operator delete the sidecar explicitly (an auditable human action).
- Missing sidecar + existing ledger → treated as legacy/bootstrap: gate writes
  the first record on the next sanctioned write but does not deny (no breakage
  for in-flight projects); the bootstrap is logged.
- The `rm onboarding-status.json` reset trick dies here: missing ledger +
  existing sidecar → DENY (the "brand-new run" silent-allow branch now requires
  both files absent).
- sha256 via `shasum -a 256` fallback when `sha256sum` is absent (macOS, also
  fixes the same bug in selector-development-pipeline-stepper).
- Kills harness #1's residual, #7, #9's fail-open-on-missing-ledger.

### A5. run-summary-writer truth pass

- Read the artifacts skills actually write: `tests/e2e/docs/onboarding-status.json`
  (phases), `tests/e2e/docs/adversarial-findings.md` (findings, parsed by the
  canonical ledger grammar), `tests/e2e/docs/journey-map.md` (journey count).
- Parse `playwright-report/results.json` across **all** suites/tests/retries;
  derive pass/fail/flaky counts and the real run status; delete the hardcoded
  `pw_exit=0` (report `null` when no report exists rather than a fake pass).
- Severity vocabulary: the canonical five (`critical/high/medium/low/info`).
- Add `timestamp`, `git_sha`, `achilles_version` fields.
- Use the bundled-jq resolution pattern like every other hook.
- Add the missing test case (fixture project with known artifacts → exact
  expected JSON).
- Run-over-run history/trends stay in Phase 3; Phase 1 only makes the single
  snapshot truthful.
- Kills harness hook-quality item; evidence #3.

### A6. Hook hygiene batch

Small fixes, each with a test where one is missing:

1. Bare `jq` → bundled-jq fallback in selector-development-activation-gate,
   -inertness-guard, -pipeline-stepper, run-summary-writer.
2. `sha256sum` → `shasum -a 256` fallback (pipeline-stepper; shared helper in
   `lib/`).
3. commit-message-gate: also extract `--message=…` and `-F <file>` message
   sources; heredoc commit messages at minimum trigger a conservative DENY-safe
   review path rather than silent pass.
4. Reviewer-prefix alignment: one canonical regex in a lib helper, used by
   ledger-gate, approver-registry, brief-gate, attestation-gate.
5. Wire `workflow-reviewer` into `lib/schema-role-map.sh` (schema exists,
   role unmapped).
6. Delete dead code: in-flight-registry leash in subagent-return-schema-guard
   (registrar retired), stale dispatch-guard reference in
   playwright-cli-isolation-guard deny text.
7. `harness-hooks.md`: index the four missing hooks (approver-registry,
   brief-gate, attestation-gate, run-summary-writer) + the new A3 guard.
8. Write-gate hook timeout 3s → 10s (node cold-start + Ajv compile headroom).
9. attestation-gate: remove vestigial empty regex group and repair the blanked
   comment.
10. pipeline-stepper: replace `echo | xargs cat` with a loop (space-safe);
    guard empty arrays for bash 3.2 `set -u`.
11. hooks/tests/fixtures/bypass-artifacts/README.md: drop references to deleted
    tests 24-30.

### A7. Stale-claims sweep

Every "Harness-enforced" claim citing a hook retired in 0.3.6 is resolved one
of two ways — no third option:

- **Re-backed:** where A3/A4 now genuinely enforce the rule (out-of-band state
  writes, ledger forgery, deliverable-signature forgery), update the claim to
  name the new hook precisely.
- **Honest:** otherwise rewrite to the established "the harness guard was
  retired in 0.3.6; the rule still applies" form.

Known sites (re-verify by grep during implementation):
`coverage-expansion/SKILL.md:46,564,569`, `test-composer/SKILL.md:357`,
`contributing-to-element-interactions/SKILL.md:321,762`. Also fix:
schemas/subagent-returns/README.md's false "picks up new roles automatically by
filename" claim and its unimplemented dispatch-mode rejection rules (either
implement in the first-pass guard — preferred if small — or rewrite as
reviewer-enforced), contributing SKILL.md:822's nonexistent `build_message`
helper reference, and the onboarding-status schema's missing `modeAuthorizer`
property that the write-gate's deny text cites.

### A8. Tests + install simulation

- New hook-test cases for every behavior changed above (target: every DENY and
  every fail-open branch exercised).
- **Install simulation** (new test script, runs in `test:hooks` CI path):
  `npm pack` → unpack into a temp dir mimicking a consumer project → run
  postinstall with `HOME` pointed at a temp home → assert (a) the validator
  bundle and hooks land in `<temp-home>/.claude/hooks/`, (b) the write-gate
  **denies** a forged ledger write when invoked from that location, (c) the
  return-schema guard produces a real validation verdict (not a
  module-not-found WARN). This is the test that would have caught A1's bug
  class; it pins the consumer-install contract permanently.

## Design — element-interactions repo

Implemented through the package's own contribution methodology: the
orchestrator dispatches `contribution-handover-` subagents which load
`contributing-to-element-interactions` (subagent-only skill). Returns conform
to `contribution-handover.schema.json`.

### B1. waitForState honesty (breaking, 0.4.0)

- `Utils.waitForState` and `Steps.waitForState` **throw on timeout** by
  default. New option `{ optional: true }` restores the soft-probe behavior
  (returns boolean, logs).
- Strict-mode-violation narrowing to `.first()` becomes a loud, single-line
  warn at default log level (not debug-channel), naming page/element and count.
- All internal pre-action waits keep their current semantics **except** the
  swallowed-timeout path now carries the failure context into the eventual
  action error (no behavioral break for passing tests; failing tests fail
  earlier and clearer).
- README: the `waitForState` assertion-style example is corrected; CHANGELOG
  entry marks the breaking change; version 0.4.0.

### B2. Interception-retry signal + opt-out

- The dispatchEvent fallback stays default-on (compat) but: pushes a
  `testInfo.annotations` entry (`type: 'interception-fallback'`, description
  naming page/element) so it is visible in every report, and logs at warn
  level.
- New config option (fixture/use-level) `interceptionRetry: false` disables the
  fallback so genuine overlay bugs fail the click.
- `force`/`withoutScrolling` get honest doc descriptions (they dispatch a DOM
  click event; they are not Playwright's `force: true`). Renaming is deferred
  to a later major.

### B3. Publish blocker — sql-client dependency

Decide by inspecting runtime behavior when sql-client is absent:
- If SQL steps already throw a helpful "configure X" error lazily → move
  `@civitas-cerebrum/sql-client` to `optionalDependencies`/peer with a
  documented install step.
- Otherwise → publish sql-client to the registry and pin a semver range.
Either way: `npm pack` must produce an installable tarball; add a CI check
(`npm pack --dry-run` + a no-`file:`-deps assertion).

### B4. Docs drift + typecheck

- Delete/rewrite README §"Advanced: Raw Interactions API" to the WebElement-only
  reality; fix `getText` (returns `null`, not `''`); document the
  `greaterThanOrEqual`/`lessThanOrEqual` verifyCount variants; add
  `html`/`outerHtml` to the matcher list.
- Add `typecheck:tests` script (`tsc --noEmit` including `tests/`) to the test
  pipeline; fix fallout — primarily negative.spec.ts's raw-Locator usages,
  rewritten to WebElement so the rejection tests fail for the right reason.
- Relabel `test-coverage-report.txt` claims as "API (method-invocation)
  coverage".

## Acceptance criteria

1. `npm run test:hooks` green, including all new cases; every previously
   fail-open branch has a test proving its new behavior.
2. Install simulation (A8) green: gates demonstrably fire from a consumer-style
   install.
3. `rg '"Harness-enforced'` over `skills/` returns only claims naming hooks
   that exist in HOOK_MANIFEST.
4. `run-summary.json` produced from a fixture project matches expected output
   exactly (real counts, real status, canonical severities).
5. element-interactions: full suite green; `npm pack` succeeds with no `file:`
   deps; `typecheck:tests` green; a new spec proves `waitForState` rejects on
   timeout and `{ optional: true }` does not.
6. No skill, README, or schema doc makes a claim contradicted by the code
   (spot-checked against the audit's drift list).

## Out of scope (deferred)

- **Phase 2:** likelihood-aware risk model, risk-based plan generation /
  stopping criteria, equivalence partitioning & BVA methodology, oracle-strength
  ladder + UI deliberate-failure check, visibility-rule security carve-out,
  maintenance economics (value gates, runtime budget), perf-baseline protocol,
  accessibility pass, severity/priority propagation, count-over-quality
  incentive fixes.
- **Phase 3:** state-control plane (network mocking, clock, storage/cookies,
  auth state), `test.step()` wrapping + failure-artifact enrichment, ledger
  schema extensions (evidence/repro/build fields, fingerprints), trend
  reporting + flake ledger, soft assertions, dialog/download/waitForURL
  facades, puppet-reviewer hardening beyond Phase 1's prefix alignment.
- Legacy `singularity` skill removal/merge (coordinate separately — it ships in
  installed environments).
