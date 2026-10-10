# Verification record

What "verified" and "stable" mean as written artefacts: the verify note, the can-fail proofs, the content-hash stamp.
The run counts live in [test-composition-standards.md](test-composition-standards.md) §7 ("Stability is 3×/5×"); the verifier role's scope is in
[roles-and-dispatch.md](roles-and-dispatch.md) §"Change loop".

## Stable

A test the suite keeps is **stable** only when both hold:

1. **N consecutive green runs for its test id** in the Achilles reporter history (`.achilles/history/tests.ndjson`:
   one entry per test per run, keyed by `id`, with `project` and `status`). N is set by the project, never below that bar. Each run is its own invocation with its own
   `--output` directory, so a failure's artefacts are never overwritten. `flaky` (green only on retry) does not count:
   pass `--retries=0` on the verification invocation. An order-placing test on the `one-confirming-run` spend policy
   (`test-data-conventions`, spend budgets) counts one audited run instead and is never re-run to reach N.
2. **One can-fail proof per family**: the negative control, or a mutation (`E2E_MUTATION=<hook>` honoured by a
   fixture, or `achilles-mutate --only <id>` after `--calibrate`) that turns the intended assertion red **with the
   intended message**. Red for another reason is not a proof.

**Citations are context-qualified.** A suite that shards by a dimension (region, tenant, browser, account) runs the
same test id once per context. Every id a verify note cites is written with its context (`region-2 CHK-03`), or the
note carries a single `Context:` line when it covers exactly one. A bare id never counts as evidence; tools that read
verify notes must match on the pair.

## The verify note

The verifier, an agent that did not write or review the change, writes `docs/evidence/<change>/verify.md`:

```markdown
# Verify — <change>

- **Change**: <change> (brief: docs/evidence/<change>/brief.md)
- **Verifier**: independent (did not write or review the code)
- **Date**: <YYYY-MM-DD>
- **Context**: <single-context note only; delete when the note covers several>
- **Verdict**: <PASS | PASS with notes | FAIL>
- **Status**: <in verification | complete>

## Gates
- <type check, unit + conventions guard, hook fixture cases, scenario lint: result and counts>
- Secrets: <evidence dirs scanned by env variable NAME; no values printed>
- Readability: <spec-shape.md check: flat, steps visible, oracle call present, no test that cannot fail>

## Runs
| Spec file | Context | Run label (`--output`) | Result | Resources (id → final state) |
|---|---|---|---|---|

## Can-fail proofs
| Mutation | Context + id | Red at (quoted assertion + message) |
|---|---|---|

## <context>
- <context> <ID> — green N× (runs above) | one-confirming-run (audited); proof: <mutation>

## Findings
<defects, flakiness, weak oracles, residual gaps; unverified, skipped or blocked ids as bare ids; they do not count>
```

| Verdict | Means |
|---|---|
| **PASS** | every gate, run and proof holds |
| **PASS with notes** | as PASS, with weak oracles or gaps listed under Findings |
| **FAIL** | anything else, naming the item |

A controller may override a FAIL only with a recorded ruling that names the evidence.

**Status** is `in verification` until every run and proof is recorded, then `complete`, and `complete` only with PASS
or PASS with notes. `complete` is approver-class: only the independent verifier writes it, never the author or the
controller that drove the change. The path gate does not read the verdict (KL-16 in
[known-limits.md](known-limits.md)).

## The stamp

The commit gate checks the verify command's receipt: format and check in
[factory-gates.md](factory-gates.md#process.evidence). The receipt carries a tree hash, never a timestamp.
