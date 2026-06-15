# Input-Domain Analysis — Partitions & Boundaries

**Status:** the discipline behind `test-composer` Step 3's edge-case variants (item 3 of the implementation order). Cited from Step 7's coverage matrix ("partitions covered" column) and from `database-testing` Phase 2's Edge bullet. The boundary-values probe category (`../../element-interactions/references/subagent-return-schema.md` §3.6) shares this discipline on the adversarial side.
**Scope:** how to turn "boundary inputs, empty or overflow data" from a vibe into a derived, auditable set. The output is a partition table; the edge-case variant set is read off the table, not improvised. This is a convention (model-compliance) — no hook checks the table; the Stage B reviewer does.

---

## Rules

1. **Partition every input into equivalence classes.** For each input the journey's forms and parameters accept, enumerate its valid and invalid classes from the spec — or, when no spec exists, from validation behaviour observed during Step 2 discovery (error messages, `maxlength` attributes, rejected submissions). An equivalence class is a set of values the app treats identically: any one member tests the whole class.
2. **One test per class — a second test in the same class must displace, not add.** If a class already has a covering test, a new candidate either replaces it (because it is a strictly better representative) or is dropped. Two tests in one class is count padding, not coverage.
3. **Boundary pairs at every partition edge.** Each edge between classes gets the pair of values that straddle it: `min-1`/`min`, `max`/`max+1`, empty/1-char, off-by-one dates (yesterday/today, expiry day/day after). Boundaries are where implementations break; interior values are where they don't.
4. **Record the partition table as a comment block atop the spec file.** The reviewer audits the table against the tests beneath it — a test with no class, or a class with no test, is a finding. Step 7's coverage matrix carries the same mapping in its "partitions covered" column.

---

## Worked example — registration form

Inputs: `email` (required), `password` (8–64 chars per the spec), `age` (optional, 18–120).

```ts
/*
 * Partition table — j-register
 * | Input    | Class                          | Representative        | Valid? | Test                                |
 * |----------|--------------------------------|-----------------------|--------|-------------------------------------|
 * | email    | well-formed                    | a@example.com         | yes    | happy path                          |
 * | email    | malformed (no @)               | a.example.com         | no     | rejects malformed email             |
 * | email    | empty                          | ""                    | no     | requires email                      |
 * | password | in range (8–64)                | 8 chars               | yes    | accepts minimum password (boundary) |
 * | password | too short (boundary: 7/8)      | 7 chars               | no     | rejects 7-char password             |
 * | password | too long (boundary: 64/65)     | 65 chars              | no     | rejects 65-char password            |
 * | password | at max (boundary: 64)          | 64 chars              | yes    | accepts 64-char password            |
 * | age      | omitted (optional)             | —                     | yes    | happy path                          |
 * | age      | in range                       | 35                    | yes    | covered by happy-path variant       |
 * | age      | under min (boundary: 17/18)    | 17                    | no     | rejects under-18                    |
 * | age      | at min (boundary: 18)          | 18                    | yes    | accepts age 18                      |
 * | age      | over max (boundary: 120/121)   | 121                   | no     | rejects over-120                    |
 * | age      | non-numeric                    | "abc"                 | no     | rejects non-numeric age             |
 */
```

Read the variant set off the table: every `no` row is an error-state or edge-case test; every boundary `yes` row is an edge-case test; interior `yes` rows fold into the happy path. Twelve classes, ten tests — not "as many as feel thorough".

---

## Anti-patterns

| Anti-pattern | Reality |
|---|---|
| Five "weird email" tests | One malformed class, one test. Pick the best representative; displace the rest. |
| Testing `min+5` but not `min-1`/`min` | Interior values catch nothing the happy path didn't. Edges or it didn't happen. |
| Partition table written after the tests | The table derives the tests, not the other way round. A post-hoc table rationalises gaps instead of exposing them. |
| Classes from imagination instead of spec/observation | If neither spec nor observed validation defines an edge, you are inventing contract — note it as a discovery question, don't assert it. |
