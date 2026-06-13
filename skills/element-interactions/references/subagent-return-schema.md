# Subagent Return + Ledger Schema — Reference

**Subagent returns** are validated against per-role JSON Schemas under [`schemas/subagent-returns/`](../../../schemas/subagent-returns/README.md). That directory is the source of truth — see its README for the role-to-schema table and authoring conventions.

**Adversarial-findings ledger** (markdown) is documented in §3 below (finding-block format in §1). The ledger format is prose because the ledger file (`tests/e2e/docs/adversarial-findings.md`) is markdown, not YAML — there is no machine-readable schema for it. §3 is therefore the source of truth for ledger entries.

---

## 1. Canonical finding-return schema (mandatory, prose, for the ledger)

Every subagent dispatched by `coverage-expansion`, `test-composer`, `bug-discovery`, or `agents-vs-agents` that reports a finding MUST format each finding exactly as:

```
- **<FINDING-ID>** [<severity>] — <one-line title>
  - scope: <what was probed>
  - expected: <what should happen>
  - observed: <what happened>
  - coverage: <existing test or none>
```

### Field rules

| Field | Rule |
|---|---|
| `FINDING-ID` | `<journey-slug>-<pass>-<nn>` (inside a numbered pass, Stage A findings) or `<journey-slug>-<nn>` (outside pass numbering). `<nn>` is a two-digit integer, zero-padded. Reviewer findings (Stage B) use the extended subformat `<journey-slug>-<pass>-<cycle>-R-<nn>` — see §2.4. Phase-validator findings use `pv-<phase>-<nn>` (phase 1–8, §2.5); `agents-vs-agents` findings use `ai-<category-slug>-<nn>`. No other alternative ID schemes (`AF-XX-NN`, `P4-XX-BUG-NN`, `REG-XX-NN`, `BUG-NNN`) are accepted. IDs are never renumbered or reused across runs — triage state keys on the FINDING-ID. |
| `severity` | One of `critical`, `high`, `medium`, `low`, `info`. No other values. Do not invent new severities (no `no-impact`, `blocker`, `p0`). Map DOM-only / no-impact items to `info`. **Applies to Stage A finding blocks only.** Stage B (reviewer) findings use a fixed `[must-fix]` priority bracket, not a severity bracket — per §2.4. The "no other values" rule is scoped to Stage A; §1's bracket position is not meaningful for reviewer returns. |
| `title` | One line. No trailing period. Describes the finding, not the test. |
| `scope` | One sentence naming the probe surface — page, endpoint, element, flow step. |
| `expected` | One sentence describing correct behaviour. |
| `observed` | One sentence describing the actual behaviour. |
| `coverage` | One of three forms: (a) `none` — no covering test/pattern; (b) a spec-file path plus test name that locks the finding (e.g. `tests/e2e/j-<slug>-regression.spec.ts › <test name>`); (c) `app-wide:<pattern-id>` where `<pattern-id>` is a stable kebab-case identifier from `tests/e2e/docs/app-wide-patterns.md` (per `coverage-expansion/references/app-wide-scan.md`). Form (c) cites an app-wide pattern documented by the one-shot Pass-4 prelude scan; per-journey probes use it to avoid re-deriving recurring patterns. |

### Severity rubric

This table is the single severity authority. No other file may restate the enum inline — point here. The `critical` row's criteria are the **security-class** criteria referenced by the evidence rule below.

| Severity | Definition |
|---|---|
| `critical` | Monetary loss, data exfiltration, privilege escalation, auth bypass, credential/key exposure, or legal-or-compliance risk. |
| `high` | A state the app must prevent, or material user impact — a blocked journey, a core feature broken. |
| `medium` | Degraded UX or data correctness issue. User notices, but can still use the app. |
| `low` | Minor inconsistency, cosmetic defect, UX nit. |
| `info` | DOM-only / no user impact. Code hygiene. |

Report-facing label mappings are documented in the skills that present findings — `bug-discovery`'s "No impact (DOM-only)" is the report-facing label for canonical `info`; `bug-report`'s Jira labels are the title-cased canonical values (`info` is never ticketed); `agents-vs-agents` judge severities map verbatim, lowercased. No skill invents a new scale.

### Evidence rule

Every finding above `info` MUST cite captured evidence appropriate to its oracle — a screenshot for visual/UX findings; a saved response body, header dump, console capture, DOM/source excerpt, or static-inference rationale (`inferred: true`) for API/security/privacy findings. Findings with no captured evidence cap at `info`. Security-class findings (the critical-row criteria) are severity-rated on impact regardless of screenshot visibility. The rule is operationalised by `bug-discovery` Phase 5 and inherited here.

### Worked example

```
- **j-<slug>-4-03** [high] — <one-sentence finding title>
  - scope: <single sentence — endpoint / element / flow step under probe>
  - expected: <one sentence — what correct behaviour looks like>
  - observed: <one sentence — what actually happened>
  - coverage: none
```

---

## 2. Handover envelope + per-role return shapes

### 2.0 Handover envelope (mandatory on every skill-loading subagent return)

Full schema: `schemas/subagent-returns/handover.schema.json`.

Every subagent that loads a skill via the `Skill` tool **MUST** include a `handover` object as the **first key** of its return. The envelope pairs the return with its in-flight registry entry and is the primary cleanup path for the harness leash.

The envelope has exactly **four** required fields — no others are allowed inside it:

| Field | Type | Rule |
|---|---|---|
| `role` | string | Kebab-case slug identifying the dispatched role (e.g. `composer-j-login-flow`, `reviewer-inloop`, `probe`, `phase-validator`, `section-agent`, `phase4-prioritise-author`). |
| `cycle` | integer ≥ 1 | Cycle number within the role's dispatch loop. |
| `status` | string | Role-specific terminal-or-continuation status. Constrained by the per-role schema. |
| `next-action` | string (non-empty) | One-line directive for the orchestrator — what should happen after this return. |

Fields that belong at the **top level** (never inside `handover`): `phase`, `summary`, `journey`, `pass`, `section`, `findings`, `exit-criteria-checked`, `spill`, and any other role payload field.

JSON is preferred over YAML for all handover returns. YAML's compact-mapping form (`key: value: rest`) silently corrupts values that contain `:`, causing schema validation to fail without a clear error.

### 2.5 Phase-validator return shape

Full schema: `schemas/subagent-returns/phase-validator.schema.json`.

The phase-validator is dispatched at the end of each pipeline phase to verify exit criteria before the orchestrator advances.

**Status enum:** `greenlight` | `improvements-needed`

**Required top-level fields on `greenlight`:** `handover`, `phase` (integer 1–7), `exit-criteria-checked` (array, ≥1 item), `summary`.

**Required top-level fields on `improvements-needed`:** `handover`, `phase`, `findings` (array, ≥1 item), `summary`.

Finding blocks (under `improvements-needed`) match `^ {2}- \*\*pv-[1-7]-\d{2,}\*\* \[must-fix\]` with sub-bullets `criterion:` / `issue:` / `fix:`.

Banned tokens inherited from reviewer shape: `nice-to-have`, `greenlight-with-notes`, top-level `notes:`.

**Worked example — `greenlight`:**

```json
{
  "handover": {
    "role": "phase-validator",
    "cycle": 1,
    "status": "greenlight",
    "next-action": "orchestrator to advance to phase 3"
  },
  "phase": 2,
  "exit-criteria-checked": [
    {
      "criterion": "app-context.md exists with a sentinel line",
      "satisfied": true,
      "evidence": "File present at tests/e2e/docs/app-context.md; sentinel found on line 1"
    },
    {
      "criterion": "journey-map.md exists with at least one journey entry",
      "satisfied": true,
      "evidence": "File present at tests/e2e/docs/journey-map.md; 3 journey entries identified"
    }
  ],
  "summary": "Phase 2 exit criteria fully satisfied; greenlighting advance to phase 3."
}
```

---

## 3. Strict ledger schema — `tests/e2e/docs/adversarial-findings.md`

The adversarial findings ledger is enforced, not conventional. Every subagent that appends to the ledger MUST validate its append against the schema below **before committing**. Schema violations are contract violations; the subagent corrects the append or re-emits.

The ledger lives at `tests/e2e/docs/adversarial-findings.md`. It is created on the first Pass-4 subagent invocation.

This section is the single structural authority for the ledger (header layout, per-journey block, finding block shape, pass summary line). The probe-category vocabulary that subagents pick from lives in §3.6 below; the severity rubric is §1's table. The former legacy schema (`skills/coverage-expansion/references/adversarial-findings-schema.md`) has been deleted — its vocabulary moved here (§3.6) and its 3-value severity rubric superseded by §1's five-value enum. Every citation repoints to §1 / §3 / §3.6 of this file.

### 3.1 File header (written once, by the first Pass-4 subagent)

```markdown
<!-- coverage-expansion-adversarial:generated -->
# Adversarial Findings — <app name from package.json>

**Generated by:** coverage-expansion (depth mode, passes 4–5)
**Pass 4 date:** YYYY-MM-DD
**Pass 5 date:** _(filled by pass 5)_
**Dedup date:** _(filled by cleanup subagent)_

## Cross-cutting findings

_(Populated by the post-pass-5 cleanup subagent. Until then, leave the section present but empty — the header must exist so per-journey sections can backref it.)_
```

### 3.2 Per-journey section (one per journey, written by the first subagent to probe it)

```markdown
### j-<slug>

**Pass <N> — <kind> (YYYY-MM-DD)**

Scope: <one-line probe scope>

#### <FINDING-ID> [<severity>] — <title>
- expected: <one sentence>
- observed: <one sentence>
- ledger-only: <true|false>
- coverage: <spec file + test name, or "none">

#### <FINDING-ID> [<severity>] — <title>
- expected: ...
- observed: ...
- ledger-only: ...
- coverage: ...

(repeat per finding)

**Pass <N> summary:** probes=N, boundaries=M, suspected-bugs=K (crit=x, high=y, med=z, low=w)
```

Every Pass block MUST open with a `**Pass <N> — <kind> (YYYY-MM-DD)**` line, include a `Scope:` line, and close with a `**Pass <N> summary:**` footer. `<kind>` is one of `probe` (Pass 4) or `consolidation` (Pass 5). Mis-ordered or missing headers are schema violations.

### 3.3 Ledger field rules

| Field | Rule |
|---|---|
| `### j-<slug>` | Exactly one `###` header per journey. No nested `####` that aren't findings. |
| `**Pass <N> — <kind> (YYYY-MM-DD)**` | Bolded line. ISO date. `<kind>` ∈ {`probe`, `consolidation`}. |
| `Scope:` | Single-line prose, no bullets. |
| `#### <FINDING-ID> [<severity>] — <title>` | `<FINDING-ID>` follows §1's rules. `<severity>` is one of the five values. |
| `expected:` / `observed:` | One sentence each, on their own line, as list items. |
| `ledger-only:` | `true` when the finding is a suspected bug with no committed regression test; `false` when a passing regression test was added. |
| `coverage:` | Spec-file path + test name, OR `none`, OR `app-wide:<pattern-id>`. Matches §1 exactly. |
| `**Pass <N> summary:**` | One line. `probes=N, boundaries=M, suspected-bugs=K (crit=x, high=y, med=z, low=w)`. Integers only. |

### 3.4 Worked example

```markdown
### j-<slug>

**Pass 4 — probe (YYYY-MM-DD)**

Scope: <one-sentence probe surface — endpoints, elements, flows under test>.

#### j-<slug>-4-01 [high] — <one-sentence finding title>
- expected: <one sentence — correct behaviour>
- observed: <one sentence — actual behaviour>
- ledger-only: true
- coverage: none

#### j-<slug>-4-02 [medium] — <one-sentence finding title>
- expected: <one sentence>
- observed: <one sentence>
- ledger-only: true
- coverage: none

**Pass 4 summary:** probes=12, boundaries=8, suspected-bugs=2 (crit=0, high=1, med=1, low=0)

**Pass 5 — consolidation (YYYY-MM-DD)**

Scope: compound probes, ambiguous-resolution, regression authoring for pass-4 boundaries.

#### j-<slug>-5-01 [low] — <one-sentence finding title>
- expected: <one sentence>
- observed: <one sentence>
- ledger-only: false
- coverage: tests/e2e/j-<slug>-regression.spec.ts › <test name>

**Pass 5 summary:** probes=6, boundaries=5, suspected-bugs=0 (crit=0, high=0, med=0, low=0)
```

### 3.5 Append discipline

- Atomic append under the advisory lockfile at `tests/e2e/docs/.adversarial-findings.lock`. Hold the lock for ≤500ms.
- Validate against the schema in-memory BEFORE writing. If validation fails, fix the append and re-validate before releasing the lock.
- Never rewrite another journey's section. Appends are additive to one `### j-<slug>` block per dispatch.
- Cross-cutting consolidation is the cleanup subagent's job only (runs once after Pass 5).

### 3.6 Probe-category vocabulary

Subagents pick categories based on the journey's flow. This is the single naming surface so the ledger, the dedup `fingerprint:` field, and the cleanup-pass dedup step stay consistent. It is **non-exhaustive** — a probe that does not fit an existing label uses the closest match plus a one-word qualifier rather than inventing a parallel scheme.

**Web / API adversarial categories:**

- `auth-tamper` — missing/expired/wrong-user tokens, session fixation
- `input-tamper` — injection payloads, type confusion, extreme values
- `price-tamper` — client-side price or total manipulation
- `qty-tamper` — negative, zero, non-integer quantities
- `balance-bypass` — direct-API paths that skip client-side balance checks
- `state-skip` — submitting later-step actions without earlier steps
- `replay` — re-sending idempotency-sensitive requests
- `idor` — access another user's resources by ID guess
- `priv-esc` — regular user performing admin-scoped actions
- `client-server-divergence` — diverge client state from server state
- `race` — concurrent requests on shared state
- `boundary-values` — limits: max quantity, max string length, expiry edges
- `compound` — two or more probes combined (used heavily in Pass 5 / consolidation)

**AI-safety categories** (used by `agents-vs-agents`; see that skill's category map):

- `prompt-leak` — system-prompt extraction / instruction disclosure
- `guardrail-bias` — discriminatory output along protected characteristics
- `scope-escape` — AI abandons its intended functional scope or persona
- `output-injection` — unsanitised injectable content in AI output (XSS/SQL/phishing)
- `ai-data-leak` — cross-user data, system internals, or model identity disclosure
- `multi-turn-erosion` — guardrail decay across a long social-engineering conversation

---

## 4. Caller contract

Every caller (`coverage-expansion`, `test-composer`, `bug-discovery`) MUST:

1. Link to this file in its SKILL.md, using the relative path `skills/element-interactions/references/subagent-return-schema.md`.
2. Reference this file in every subagent dispatch brief — do not re-paste the schema into the brief.
3. Reject subagent returns that do not conform. Either:
   - re-dispatch with a stricter brief that names the specific schema violation, or
   - surface the violation to the user when re-dispatch is not possible.
4. Never invent new severities, new finding-ID schemes, or new ledger block shapes. One schema, one file.
5. **No "one extra field" extensions.** A caller that adds an informational bullet, sub-line, or suffix to the finding block is forking the schema. If a new field is genuinely necessary, open a follow-up that extends this file; do not ship the extension in a caller's SKILL.md as a de-facto override.

### 4.1 Minimal conformance check (what the caller should look for)

Callers do not run a parser — they grep the return for a short, fixed list of shape signals. A minimal check that catches the common violations:

- **Finding blocks:** one or more lines matching `^- \*\*[a-z0-9-]+-\d+-\d+\*\* \[(?:critical|high|medium|low|info)\]` (for in-pass findings) or the analogous out-of-pass form, followed by the four sub-bullets `scope:` / `expected:` / `observed:` / `coverage:`.
- **`covered-exhaustively` returns:** the literal string `status: covered-exhaustively`, a table header row `| Expectation | Covering spec | Test name |`, and at least one data row per `Test expectations:` entry in the journey block.
- **Banned tokens:** the literal strings `no-new-tests-by-rationalisation`, `no-new-tests` (unqualified), `AF-`, `P4-`, `REG-` (legacy finding-ID prefixes — note: the `-R-` infix in reviewer IDs is NOT a prefix and is allowed), and any `[p0]` / `[blocker]` / `[no-impact]` severity bracket.
- **Ledger append:** the `**Pass <N> — <kind> (YYYY-MM-DD)**` header line, the `Scope:` line, and the closing `**Pass <N> summary:** probes=…, boundaries=…, suspected-bugs=…` line, in that order, bracketing the finding blocks.
- **Reviewer returns (see `coverage-expansion/references/reviewer-subagent-contract.md` § "Return shape"):** the top-level `status:` is one of `greenlight` or `improvements-needed`. Finding blocks (when present under `missing-scenarios:`, `craft-issues:`, or `verification-misses:` sub-lists) match `^ {2}- \*\*[a-z0-9-]+-\d+-\d+-R-\d+\*\* \[must-fix\]`. **A `summary:` line is REQUIRED on `greenlight` returns** — a `greenlight` status without a `summary:` is a contract violation; treat as `improvements-needed` and re-dispatch. `greenlight` carries `summary:` and no finding blocks; `improvements-needed` has at least one `must-fix` finding and no `summary:` line. Returns containing the literal tokens `nice-to-have`, `greenlight-with-notes`, or a `notes:` sub-list are contract violations from a prior schema revision; reject and re-dispatch with a brief that quotes the banned token. The Stage A regex in the previous bullet does NOT apply to reviewer returns.
- **Phase-validator returns (§2.5):** the top-level `status:` is one of `greenlight` or `improvements-needed`. `phase:` line carries an integer 1-7 (anchored on end-of-line / non-digit so `phase: 12`, `phase: 71`, `phase: 8a` fail). `exit-criteria-checked:` array has ≥1 `- criterion:` row (the array cannot be empty). **A `summary:` line is REQUIRED on both statuses.** On `improvements-needed`, finding blocks match `^ {2}- \*\*pv-[1-7]-\d{2,}\*\* \[must-fix\]` with sub-bullets `criterion:` / `issue:` / `fix:`. Banned tokens: `nice-to-have`, `greenlight-with-notes`, top-level `notes:`. The reviewer regex from the previous bullet does NOT apply to phase-validator returns.

If any of the above is missing or a banned token is present, the caller re-dispatches with a brief that quotes the specific violation. The grep-based check is sufficient — no AST, no JSON, no parser.

### 4.2 Harness validator (PostToolUse:Agent)

The same grep-based shape signals are enforced at the harness layer by a `PostToolUse:Agent` return-schema guard. The hook is a backstop, not a replacement: callers still run the orchestrator-side grep per §4.1. The harness layer catches malformed returns the orchestrator missed; the orchestrator-side check catches violations that depend on caller-specific context the hook can't see (e.g., whether a `Test expectations:` row is missing from the mapping table). See [harness-hooks.md](harness-hooks.md).

### 4.3 Harness validator — handover-envelope leash + deregistration

The same return-schema guard also enforces the §2.0 handover envelope and drives the registry leash. On every `composer-` / `reviewer-` / `probe-` / `process-validator-` / `phase-validator-` return it parses the envelope, looks up the in-flight registry entry by slug, cycle-matches, and removes the slug on a terminal status (or leaves it in place for a non-terminal redispatch). Missing envelope or cycle-mismatch emits a fix-message WARN; the registry slot stays held until the TTL failsafe expires. **Deregistration itself fires regardless of validation mode** — the registry update is mechanical bookkeeping, not validation, so the leash works correctly even when envelope-validation is in WARN mode.

Explicit deregistration via terminal-status handover is the primary cleanup path; the registry TTL is the secondary one for crashed / abandoned dispatches that never return an envelope. (Hook index: [harness-hooks.md](harness-hooks.md).)

### 4.4 Per-prefix routing table (description-prefix → validation target)

| Description prefix | Validation target |
|---|---|
| `composer-<j-slug>:` | Stage A — `status:` enum (new-tests-landed \| covered-exhaustively \| blocked \| skipped) + per-status fields (tests-added / run-time; mapping table; reason; reason+authorizer) |
| `reviewer-<j-slug>:` | Stage B (§2.4) — `status:` (greenlight \| improvements-needed) + journey/pass/cycle + summary on greenlight \| findings sub-list on improvements-needed |
| `probe-<j-slug>:` | Adversarial — `probes:` + `boundaries:` + `findings:` count or list |
| `phase-validator-<N>:` | Phase-exit checkpoint (§2.5) — `status:` + `phase:` + `exit-criteria-checked:` array + `summary:` (REQUIRED on both statuses) + `findings: []` literal on greenlight \| ≥1 `pv-<phase>-<nn>` must-fix on improvements-needed |
| `workflow-reviewer-<scope>:` | Workflow-reviewer (`workflow-reviewer.schema.json`) — `verdict:` (approve \| reject \| escalate) + cycle accounting |
| `phase4-prioritise-author*` | Phase-4 prioritise-author (`phase4-prioritise-author.schema.json`) — convergence + authored journeys |
| `phase4-cycle-<N>:` | Phase-4 section agent (`section-agent.schema.json`) |
| `process-validator-` / `phase1-` / `stage2-` / `cleanup-` / `companion-` / `fd-` | Envelope-sanity only — the §2.0 handover envelope is parsed; no per-role JSON-Schema validation |
| bare `j-` / bare `sj-` | Silent allow — free-form or unstructured returns; no validation |

### 4.5 Selector-development return shape (convention)

Selector-development is **not** validated by the return-schema guard — it has no entry in the §4.4 routing table and no per-role schema. Its discipline is enforced instead by its own dedicated hooks (activation gate, inertness guard, pipeline stepper, revert-on-stop — see [harness-hooks.md](harness-hooks.md)). The shape below is a documented convention for the calling skill to read, not a harness-validated contract.

Subagents dispatched under the `selector-development-<scope>:` description prefix return a result envelope documenting whether a stable test-attribute was added (`ok`), was already present or inapplicable (`skipped`), or could not be applied due to a missing prerequisite (`blocked`).

#### Canonical envelope

```jsonc
{
  "status": "ok" | "skipped" | "blocked",
  "mode": "jit" | "audit",
  "scope": "<element-key>" | "<page-id>",
  "attribute": { "name": "data-testid", "value": "submit-button" },
  "files_modified": ["src/components/Form.tsx"],
  "guardrails": {
    "before_snapshot": "pass",
    "patch_applied":   "pass",
    "typecheck":       "pass",
    "unit_tests":      "pass",
    "e2e":             "pass",
    "after_snapshot":  "pass",
    "visual_diff":     "pass"
  },
  "ledger_entry": "...",
  "skipped_reason": "no-inert-option" | "not-frontend-project" | "selector-already-stable" | null,
  "blocked_artifact": "<path>" | null
}
```

#### Field rules

| Field | Rule |
|---|---|
| `status` | One of `ok`, `skipped`, `blocked`. No other values. |
| `mode` | One of `jit` (just-in-time, triggered by a test-writing dispatch) or `audit` (periodic sweep). |
| `scope` | The element key or page identifier the subagent was dispatched for. |
| `attribute` | Object with `name` and `value` — the attribute added or verified. Present on `ok`; may be omitted on `skipped` / `blocked`. |
| `files_modified` | Array of repo-relative paths changed by the patch. Empty array (`[]`) on `skipped` / `blocked`. |
| `guardrails` | Seven sub-statuses (`before_snapshot`, `patch_applied`, `typecheck`, `unit_tests`, `e2e`, `after_snapshot`, `visual_diff`). Each is one of `pass`, `skip`, or `fail`. Required on `ok`; recommended on `blocked`. |
| `ledger_entry` | Human-readable one-line summary for the selector ledger. |
| `skipped_reason` | Required when `status=skipped`. One of `no-inert-option`, `not-frontend-project`, `selector-already-stable`. Null otherwise. |
| `blocked_artifact` | Required when `status=blocked`. Repo-relative path to the artifact (file, component, config) that must be resolved before the selector can be added. Null otherwise. |

#### Minimal conformance check (what the hook validates)

- `status:` followed by one of `ok | skipped | blocked`.
- `mode:` followed by `jit` or `audit`.
- `guardrails:` block present (the 7-sub-status object).
- On `status: skipped`: `skipped_reason:` present with one of the valid enum values.
- On `status: blocked`: `blocked_artifact:` present and non-null.

The hook emits a WARN (non-blocking, initial release) when any of these markers is absent.

---

## 5. Non-goals

- A programmatic schema validator. This is prose + examples. Subagents read and conform.
- Per-skill schema overrides. If a future skill needs a return shape this schema cannot express, the fix is to extend this file — not to fork it.
- Transport format for finding blocks. The §1 finding-return format is prose/Markdown. The §2.x handover-envelope returns use JSON (preferred) or YAML — per-role schemas live in `schemas/subagent-returns/`.
