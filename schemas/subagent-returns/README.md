# Subagent return schemas

Canonical machine-readable form. Every skill-loading subagent must return a
shape that validates against the JSON Schema for its role.

| Role | Schema | Status enum |
|---|---|---|
| composer | `composer.schema.json` | new-tests-landed, covered-exhaustively, blocked, skipped |
| reviewer-inloop | `reviewer-inloop.schema.json` | greenlight, improvements-needed |
| probe | `probe.schema.json` | clean, findings-emitted, blocked |
| phase-validator | `phase-validator.schema.json` | greenlight, improvements-needed |
| section-agent | `section-agent.schema.json` | section-complete, section-deferred, blocked |
| phase4-prioritise-author | `phase4-prioritise-author.schema.json` | journey-map-authored, blocked |
| workflow-reviewer | `workflow-reviewer.schema.json` | (verdict: approve, reject, escalate) |

All schemas reference the shared `handover.schema.json` envelope via `$ref`.

### Handover envelope optional fields

The handover envelope defines two optional fields that describe how the dispatch was structured:

| Field | Type | Description |
|---|---|---|
| `dispatch-mode` | enum (`per-journey`, `per-section`, `grouped`, `single-agent-collapsed`) | How the dispatch was structured. **Required** on cycle-1 (journey-mapping) and Pass-1 (coverage-expansion) returns. Cycle-1 / Pass-1 returns carrying `dispatch-mode == grouped` or `single-agent-collapsed` violate the strict-per-X contract (see `coverage-expansion/SKILL.md` §"Stage A per-journey dispatch is non-negotiable" and `journey-mapping/SKILL.md` §"Iterative discovery cycles"). |
| `parallel-wave-size` | integer ≥ 1 | Size of the parallel wave this dispatch was part of. On cycle-1 / Pass-1, `parallel-wave-size == 1` violates the contract UNLESS the roster genuinely contains only one item (in which case `dispatch-mode: per-journey` with wave-size 1 is the correct shape). |

**Enforcement split — read carefully.** These return-text rules are **reviewer-enforced, not harness-enforced**: the `workflow-reviewer-pass<N>:` / `workflow-reviewer-cycle<N>:` briefs cite the rule and the reviewer rejects non-compliant returns (see `skills/workflow-reviewer/SKILL.md` per-unit checklists). No hook inspects `dispatch-mode` / `parallel-wave-size` in return text. What IS harness-enforced is the dispatch-side half of the same contract: `hooks/standard-mode-first-pass-guard.sh` (`PreToolUse:Agent`, DENY) blocks `[group]` / `[P3-batch]` dispatches and single-agent section walkthroughs before they run — on the first pass/cycle under `runMode: standard` / `cycleStrictness: standard`, and on EVERY pass/cycle under `depth`.

Cycle-2+ returns (journey-mapping) and Pass-2-onward returns (coverage-expansion) may omit both fields or carry any enum value under `runMode: standard` / `cycleStrictness: standard` — the strict contract relaxes after the first cycle/pass. Under `runMode: depth` / `cycleStrictness: depth` (selected via `onboarding`'s front-load gate) the contract applies to every pass / cycle, not just the first.

The schema itself does not encode the mode-aware rule (the field enum is unchanged — `grouped` and `single-agent-collapsed` remain valid values for non-depth runs); the reviewer reads the relevant state file's mode field (`coverage-expansion-state.json` / `.phase4-cycle-state.json` / the onboarding ledger) and applies the per-mode scope.

## Format

- JSON Schema draft 2020-12.
- Each schema has a sibling `fixtures/<role>-valid.yaml` and `fixtures/<role>-invalid.yaml`.
- The script `scripts/validate-schema-fixtures.mjs` exercises every fixture against every schema.
- The hook `hooks/subagent-return-schema-guard.sh` validates live subagent returns against the same schemas at runtime via the self-contained `hooks/lib/validator.bundle.mjs` (built by `scripts/build-validator.mjs`, all schemas inlined — no repo root or node_modules needed at hook runtime).

## Adding a new role

1. Author `<role>.schema.json` with `$schema` set to draft 2020-12 and `$ref` to `handover.schema.json` for the envelope.
2. Add valid + invalid fixtures.
3. Run `node scripts/validate-schema-fixtures.mjs` and confirm both fixtures behave as expected.
4. Wire the role's description-prefix mapping into `hooks/lib/schema-role-map.sh` (`resolve_schema_role`) — roles are NOT picked up automatically by filename. The mapping is the single source of truth shared by `subagent-schema-preread-gate.sh` (PreToolUse DENY) and `subagent-return-schema-guard.sh` (PostToolUse WARN).
5. Rebuild the validator bundle (`npm run build:validator`) so the new schema is inlined into `hooks/lib/validator.bundle.mjs`.

## Ajv strict-mode notes

When writing schemas:
- Every `if` and `then` subschema must include `"type": "object"` (Ajv strictTypes).
- Every `then` block that adds a `required` field must include a `properties` stub mirroring that field's type (Ajv strictRequired).

See the existing schemas for examples.

## Consumers

External consumers (automated CLI drivers and other orchestrators) read these files directly. Treat them as a versioned public API — additions are minor bumps, removals are breaking.
