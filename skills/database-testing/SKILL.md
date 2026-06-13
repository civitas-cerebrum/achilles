---
name: database-testing
description: >
  Use whenever a test reads from or asserts against a SQL database — write, run, review, or just
  call. Owns the structured shape every database interaction should produce: row-count expectations,
  cell-value assertions, column-order assertions, transaction (commit/rollback) verification, and
  using the DB as the oracle for a UI/API mutation. Auto-activates on the explicit-intent triggers
  (database test, SQL test, query the db in a test, verify db state, assert the database, check the
  table, data-layer test, persistence test) AND on any test or planned test that calls
  `steps.sqlQuery`, `steps.sqlExecute`, `steps.sqlTransaction`, `steps.sqlSelect`, `steps.sqlInsert`,
  `steps.sqlUpdate`, `steps.sqlDelete`, or any `steps.verifySql*` matcher — even inside a UI- or
  API-flow spec. The rationale: every persisted mutation deserves at minimum a state assertion;
  without one the test silently passes when the write regresses. Also activates on phrases that
  signal a DB interaction is about to land: "check the row was inserted", "verify it saved to the
  database", "assert the order was created", "query the table after the action". Extends
  contract-testing (API surface) and test-composer (UI flows) by adding the persistence layer as a
  verifiable oracle. Not for: ORM/migration/DDL testing, schema-drift detection, load/perf testing,
  or pure UI assertions — those route elsewhere.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared. Subagents (which return structured data) are exempt.

# Database Testing — Persistence-Layer Verification

> **⚠ Not-yet-shipped surface.** The `steps.sql*` methods and `verifySql*` matchers this skill governs are NOT exposed by the current framework dependency (`@civitas-cerebrum/element-interactions` `^0.3.6`). No spec may be written against them until the Phase-0 preflight below confirms the installed framework exposes them. When the framework ships the surface, pin the exact minimum version here (replacing this banner) — until then this document is the contract the surface will satisfy, not a description of something currently callable. Do NOT fall back to raw `pg`/`mysql` clients in specs to work around the gap.

A structured protocol for writing **database-backed** tests using the Steps API
(`steps.sqlQuery/sqlExecute/sqlTransaction` + `sqlSelect/Insert/Update/Delete` + `verifySql*`).
These tests verify what actually persisted — the oracle that closes the loop on UI and API actions.

## Scope & Boundaries — Read Before Starting

**What this skill IS for:**
- Asserting a query returns the expected rows/shape/order for known inputs (read contracts).
- Asserting a write (INSERT/UPDATE/DELETE) changed exactly the expected rows.
- Asserting a transaction commits atomically and rolls back cleanly on failure.
- Using the DB as the **oracle** after a UI or API action ("the order row exists with status COMPLETED").
- Locking data-layer invariants (FK integrity, aggregate correctness) against regressions.

**What this skill is NOT for:**
- **Schema migrations / DDL / drift detection** → belongs in the app's own migration tooling.
- **ORM unit testing** → the service's own suite.
- **Load / performance / connection-pool tuning** → wrong tool.
- **Production databases** → never. Staging/sandbox/local only, with explicit ack.

## Prerequisites

Verify ALL before starting; if any is missing, stop and ask.

- A reachable non-production SQL database (local/staging) with a known connection string in an env var.
- `baseFixture` is wired with `dbUrl` (and any `dbProviders`) in the test fixture.
- `@civitas-cerebrum/element-interactions` is the test framework (check `package.json`) AND the Phase-0 preflight confirms it exposes `steps.sql*` — the current `^0.3.6` dep does not (see banner).
- A source of truth for expected data — a deterministic seed, a fixture, or known reference values.
- **Local `file:`/`npm link` of the framework** can load `@playwright/test` twice → `No tests found`.
  Fix: remove the framework's nested `node_modules/@playwright*`, or set `NODE_OPTIONS=--preserve-symlinks`.

## API Reference (the surface this skill governs)

| Method | Use |
|---|---|
| `steps.sqlQuery<T>(sql, params?)` / `(provider, sql, params?)` | parametrised SELECT → `SqlResult<T>` |
| `steps.sqlExecute(sql, params?)` / `(provider, sql, params?)` | INSERT/UPDATE/DELETE → `rowCount` |
| `steps.sqlTransaction(fn)` / `(provider, fn)` | atomic BEGIN/COMMIT, auto-ROLLBACK on throw |
| `steps.sqlSelect/sqlInsert/sqlUpdate/sqlDelete(table)` | fluent builder → `.run()` |
| `steps.verifySqlRowCount(res, n \| {min,max})` | row-count assertion |
| `steps.verifySqlValue(res, rowIndex, column, expected)` | single-cell assertion |
| `steps.verifySqlContains(res, partialRow)` | ≥1 row matches a column subset |
| `steps.verifySqlColumn(res, column, expectedOrdered[])` | ordered column values |
| `steps.verifySqlEmpty / verifySqlNotEmpty(res)` | empty / non-empty |

**Rules:** always parametrise (`$1`/`?`), never interpolate values; one assertion per persisted fact;
prefer `verifySqlContains` over brittle full-row equality; clean up mutations so specs are rerunnable.

## Methodology — Autonomously Discover & Compose DB Tests

This extends the discovery loops of `contract-testing` (API surface) and `test-composer` (UI flows).

### Phase 0 — Preflight (is the surface shipped?)

Before any other phase, verify the installed framework actually exposes `steps.sqlQuery`:

- grep the package's type declarations: `grep -r "sqlQuery" node_modules/@civitas-cerebrum/element-interactions/**/*.d.ts`, or
- check at runtime in a scratch spec: `typeof steps.sqlQuery === 'function'`.

If absent, return `status: blocked` with a `blocked-reason` naming the version gap (the installed version vs. the framework version that ships `steps.sql*`). Do NOT fall back to raw `pg`/`mysql` clients in specs — that bypasses the Steps API's provider routing, logging, and assertion surface, and produces specs the framework can never validate.

### Phase 1 — Discover the schema (introspection)

Query `information_schema` to map the database without prior knowledge:

```sql
-- tables
SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';
-- columns + types
SELECT table_name, column_name, data_type, is_nullable
  FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, ordinal_position;
-- foreign keys (relationship graph)
SELECT tc.table_name, kcu.column_name, ccu.table_name AS references_table, ccu.column_name AS references_column
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
  JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
  WHERE tc.constraint_type = 'FOREIGN KEY';
```

Run these with `steps.sqlQuery` (or a throwaway script) to build a table/column/FK inventory.

### Phase 2 — Derive scenarios from the inventory

For each discovered structure, emit the canonical scenario set:

- **Per table** → CRUD round-trip: INSERT a row, SELECT it back (`verifySqlContains`), UPDATE it
  (`verifySqlValue`), DELETE it (`verifySqlEmpty`). Clean up.
- **Per foreign key** → JOIN test across the relationship; assert referential rows line up.
- **Per numeric column** → aggregate test (SUM/COUNT/AVG + GROUP BY + HAVING) with a known expected value.
- **Per multi-write flow** (a business action touching ≥2 tables) → a `sqlTransaction` test with both a
  COMMIT path and a ROLLBACK-on-error path.
- **Ordering** → an ORDER BY query verified with `verifySqlColumn`.
- **Edge** → empty result (`verifySqlEmpty`), boundary values, and an invalid query (expect throw).
  Derive boundary values from the partition discipline in
  `../test-composer/references/input-domain-analysis.md` — one test per equivalence class, pairs at
  each partition edge, not ad-hoc "weird values".

### Phase 3 — DB-as-oracle for UI/API actions (the cross-skill bridge)

When `test-composer` writes a UI flow or `contract-testing` writes an API call that *mutates* state,
add a DB assertion that the mutation persisted:

```ts
// after a UI checkout or an apiPost that creates an order:
const order = await steps.sqlQuery(
  'SELECT status FROM orders WHERE user_id = $1 ORDER BY purchased_at DESC LIMIT 1', [userId]);
await steps.verifySqlValue(order, 0, 'status', 'COMPLETED');
```

This is the link contract-testing and UI testing were missing: the API said 201 and the UI showed a
toast, but only the DB proves the write landed. Invoke this skill from those flows whenever an action
writes data.

### Phase 4 — Coverage & honesty

- Track which tables/FKs/flows have scenarios; report what's uncovered (no silent truncation).
- Keep the seed deterministic; if expected values depend on seed state, say so.
- Never assert against production; never leave test mutations behind.

## Return Shape

When invoked as a subagent, returns conform to `schemas/subagent-returns/composer.schema.json`.
Status enum: `new-tests-landed | covered-exhaustively | blocked | skipped`. Every return MUST open
with a `handover` envelope whose required fields are `role`, `status`, and `next-action` (plus
`cycle`, an integer ≥ 1) — see `schemas/subagent-returns/handover.schema.json`. The body names the
specs created, scenarios covered, tables/relationships exercised, and any gaps (no silent truncation).

```json
{
  "handover": { "role": "composer-db-orders", "cycle": 1, "status": "new-tests-landed", "next-action": "orchestrator to record DB coverage for orders" },
  "tests-added": 6,
  "summary": "Created tests/e2e/db/orders.spec.ts — CRUD round-trip on orders, transaction commit/rollback across orders+order_items, FK join orders→users; uncovered: audit_log (no deterministic seed)."
}
```

A Phase-0 preflight failure returns `status: blocked` with `blocked-reason` naming the version gap, per the banner.
