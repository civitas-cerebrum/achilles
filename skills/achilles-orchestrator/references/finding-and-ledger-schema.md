# Finding and ledger schema

The one format for findings, the return envelope every expert opens with, the Markdown ledger at `tests/e2e/docs/adversarial-findings.md`, and the grep checks the orchestrator runs on every return. Per-role JSON schemas live under `schemas/subagent-returns/`; that directory is the source of truth for return shapes, this file for the finding block and the ledger.

## 1. Finding block

Every finding, in a return, a spill file or the ledger:

```
- **<FINDING-ID>** [<severity>] — <one-line title>
  - scope: <what was probed>
  - expected: <what should happen>
  - observed: <what happened>
  - coverage: <existing test, app-wide:<pattern-id>, or none>
```

| Field | Rule |
|---|---|
| `FINDING-ID` | `<journey-slug>-<pass>-<nn>` inside a numbered pass; `<journey-slug>-<nn>` outside one; reviewer findings `<journey-slug>-<pass>-<cycle>-R-<nn>`; phase-gate findings `pv-<phase>-<nn>`; AI-adversarial findings `ai-<category-slug>-<nn>`. `<nn>` is two digits, zero-padded. Never renumbered or reused; triage keys on the id. No other scheme (`AF-`, `P4-`, `REG-`, `BUG-NNN`). |
| `severity` | `critical`, `high`, `medium`, `low`, `info`. Nothing else (`no-impact`, `blocker`, `p0` are not severities). Reviewer findings carry the fixed bracket `[must-fix]` instead. |
| `title` | One line, no trailing period, describes the finding not the test. |
| `scope` | One sentence naming the surface: page, endpoint, element, flow step. |
| `expected` / `observed` | One sentence each. |
| `coverage` | `none`; a spec path plus test name (`tests/e2e/j-<slug>-regression.spec.ts › <test name>`); or `app-wide:<pattern-id>` citing `tests/e2e/docs/app-wide-patterns.md`. |

### Severity rubric (the single authority)

Severity says how bad the worst realistic outcome is for the person the feature serves. That person is whoever relies on the result: the user on the screen, an administrator, or the business that reads the data the feature produces. Ask the questions in order; the first yes is the severity.

| Severity | The question | Typical cases |
|---|---|---|
| `critical` | Does someone lose money, data or access they should have, gain access they should not have, or does the product break a legal promise? | a wrong charge or payout; records lost or exposed; another account's data shown; auth bypass; a leaked credential |
| `high` | Is the person stopped: they cannot finish what the feature exists for, and a typical user would not find a way round? Or is the result wrong at its core, so that whoever relies on it is misled without knowing? | a save that silently fails; a step that cannot be passed; a report or an event whose main value is always wrong |
| `medium` | Does the feature finish, but with a result that is wrong in part, or only after a workaround a typical user does find? | one field of a saved record wrong; a value missing in some cases; a retry needed |
| `low` | Is the result right, and something is still off that costs seconds or that most people would not notice? | a cosmetic or copy defect; a duplicate request on a double click; a misaligned control |
| `info` | Is there no effect on anyone? | DOM-only leftovers, code hygiene |

How to apply it:

- **Rate the outcome, not the cause.** A one-line fix and a redesign get the same severity when the user loses the same thing.
- **Rate the worst realistic case**, not the sample that was reproduced. A defect seen on one record that would hit every record is rated on every record.
- **Frequency and visibility are priority, not severity.** A rare crash is still `high`; a typo on the home page is still `low`. Priority is the reader's call, proposed from severity and journey tier.
- **A workaround lowers the severity one step only when a typical user would find it unaided.**
- **Data nobody sees is still data.** A wrong value sent to another system, stored for later or reported to the business is rated by what its reader loses, on the same questions.
- **Blocking is the `high` question.** A defect blocks the journey when the person is stopped; `medium` and below never block, however wrong they look.
- **One value from the list, then the reason in a sentence**: what is lost, by whom, and whether there is a way round. No ranges ("low to medium"), no conditions ("low if …"), no private scales (S1, P2). A verdict that is not `bug` states the severity the defect would have if it were ruled one.

Report-facing labels map onto these (bug-discovery's "No impact (DOM-only)" is `info`; bug-report's Jira labels are the title-cased values, `info` never ticketed; agents-vs-agents judge severities map verbatim).

### Evidence rule

Every finding above `info` cites captured evidence appropriate to its oracle: a screenshot for visual or UX findings; a saved response body, header dump, console capture, DOM excerpt or a static-inference rationale (`inferred: true`) for API, security or privacy findings. A finding without evidence caps at `info`. Security-class findings (the `critical` row) are rated on impact regardless of screenshot visibility.

## 2. Return envelope

Every expert return opens with:

```json
{ "handover": { "role": "<role or role-scope slug>", "cycle": 1, "status": "<status word>", "next-action": "<one line for the orchestrator>" } }
```

Exactly those four fields inside `handover`; everything else (`summary`, `journey`, `pass`, `section`, `findings`, `spill`, `paths`, `questions`, `concerns`, `exit-criteria-checked`, …) at top level. `status` is one of the four hand-back words or the workflow result word the brief named ([controller-contract.md](controller-contract.md) §"Worker statuses"). JSON over YAML.

Spill files: a return longer than a summary writes its body to `tests/e2e/docs/.subagent-returns/<role>-<scope>-<pass>-c<cycle>.md` with `<!-- subagent-returns:<role>:<scope>:pass-<pass>:cycle-<cycle> -->` on line 1 and returns the path under `spill`. Applies to `covered-exhaustively` (the per-expectation mapping table), `improvements-needed` (the finding lists), `findings-emitted` (the finding blocks), and section-agent flow descriptions. `new-tests-landed`, `greenlight`, `clean` and `blocked` are index-only already.

## 3. Ledger: `tests/e2e/docs/adversarial-findings.md`

Created by the first pass-4 probe (or the first standalone hunt). Validated in memory before every append, under the advisory lock `tests/e2e/docs/.adversarial-findings.lock` (`mkdir` to take, `rmdir` to release, held under 500 ms, never during probing). Appends are additive to one `### j-<slug>` section per dispatch; cross-cutting consolidation is the cleanup dispatch's job only.

### 3.1 Header (written once)

```markdown
<!-- coverage-expansion-adversarial:generated -->
# Adversarial Findings — <app name from package.json>

**Generated by:** coverage-expansion (passes 4–5)
**Pass 4 date:** YYYY-MM-DD
**Pass 5 date:** _(filled by pass 5)_
**Dedup date:** _(filled by the cleanup dispatch)_

## Cross-cutting findings

_(Populated by the post-pass-5 cleanup. Present and empty until then.)_
```

### 3.2 Per-journey section

```markdown
### j-<slug>

**Pass <N> — <kind> (YYYY-MM-DD, build <short-sha-or-unknown>)**

Scope: <one-line probe scope>

#### <FINDING-ID> [<severity>] — <title>
- expected: <one sentence>
- observed: <one sentence>
- ledger-only: <true|false>
- coverage: <spec + test name, app-wide:<pattern-id>, or none>
- classification: <boundary-verified | suspected-bug | ambiguous>
- evidence: <path or inferred: true>
- fingerprint: <probe category from §3.6>
- repro: <steps or spec>
- status: <open | locked | declined: <reason>>

**Pass <N> summary:** probes=N, boundaries=M, suspected-bugs=K (crit=x, high=y, med=z, low=w)
```

`<kind>` ∈ `probe` (pass 4), `consolidation` (pass 5), `hunt` (standalone). One `###` per journey; `####` only for findings; `ledger-only: true` means a suspected bug with no committed regression test; a pass-5 decline uses one of `no regression written — finding classified as suspected bug | ambiguous | duplicate of cross-cutting #N | value gate: <reason>`.

### 3.6 Probe-category vocabulary

The naming surface for `fingerprint:` and dedup. Non-exhaustive: use the closest label plus a one-word qualifier rather than a parallel scheme.

- Web / API: `auth-tamper`, `input-tamper`, `price-tamper`, `qty-tamper`, `balance-bypass`, `state-skip`, `replay`, `idor`, `priv-esc`, `client-server-divergence`, `race`, `boundary-values`, `compound`.
- AI safety (`agents-vs-agents`): `prompt-leak`, `guardrail-bias`, `scope-escape`, `output-injection`, `ai-data-leak`, `multi-turn-erosion`.

## 4. Caller contract

Every dispatching workflow points briefs at this file instead of re-pasting it, rejects non-conforming returns (one re-dispatch quoting the violation, then `blocked-dispatch-failure`), and never extends the block with "one extra field"; extensions land here.

### 4.1 Conformance checks (grep, no parser)

- Finding blocks: lines matching `^- \*\*[a-z0-9-]+-\d+-\d+\*\* \[(?:critical|high|medium|low|info)\]` (in-pass) or the out-of-pass form, followed by the four sub-bullets `scope:` / `expected:` / `observed:` / `coverage:`.
- `covered-exhaustively` returns: the literal `status: covered-exhaustively`, a `| Expectation | Covering spec | Test name |` header in the spill, one row per `Test expectations:` entry, and on re-passes the four `trigger N` lines.
- Banned tokens: `no-new-tests-by-rationalisation`, unqualified `no-new-tests`, `AF-`, `P4-`, `REG-` prefixes (the `-R-` infix is not a prefix), `[p0]` / `[blocker]` / `[no-impact]` brackets, `nice-to-have`, `greenlight-with-notes`, a top-level `notes:`.
- Ledger append: the `**Pass <N> — <kind> (date…)**` header, the `Scope:` line and the `**Pass <N> summary:**` footer, in that order, bracketing the blocks.
- Reviewer returns: `status` ∈ `greenlight | improvements-needed`; finding blocks `^ {2}- \*\*[a-z0-9-]+-\d+-\d+-R-\d+\*\* \[must-fix\]`; `greenlight` has a `summary:` and no findings; `improvements-needed` has ≥1 must-fix and no `summary:`.
- Phase-gate returns: `verdict` ∈ `approve | reject | escalate`; `phase` an integer; `checklist` or `exit-criteria-checked` non-empty with a path-shaped `evidence` per row; on `reject` ≥1 `pv-<phase>-<nn>` finding with `checklist-item` / `what-missing` / `methodology-ref` / `fix-instruction`.
- Probe returns: `probes`, `boundaries`, `finding-ids` (or `clean` / `blocked` with a reason).
- Repair-worker returns: every briefed test in `tests[]` with an outcome from the eight; `healed` carries `fix` and `stability-runs`; `app-bug` carries `bug-report` with evidence paths under `bug-evidence/`; `stage-log[]` shows `understand` before `fix`.

## 5. Non-goals

A programmatic validator in this file (the adapter runs Ajv against the role schemas; this is the prose contract); per-skill overrides; a transport format for finding blocks beyond Markdown.
