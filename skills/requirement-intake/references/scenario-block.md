# Scenario block — template and field contract

Copy the block below into a scenario document listed in `specs.shape.scenarioDocs`, fill every field, then run the
lint (`npx achilles-scenario-lint`, or the `specs.shape.lint` command of the project). The lint checks the field
names, the `- **Field**: ` bullet shape and the enum word at the start of a value. Free text may follow an enum
value. The test that implements the block is titled `'<ID> — <title>'`.

```markdown
#### <ID> — <title>

- **Contexts**: <one or more context names — whatever the project shards runs by, e.g. north, south>
- **Type**: <tags from specs.shape.blockEnums.type (else specs.shape.tags) — e.g. @e2e @checkout>
- **Purpose**: <one sentence: the behaviour under test, in user terms>
- **Preconditions / test data**: <what must be true before step 1, stated as requirements (merchant purpose, item
  count, minimum basket, payment option offered, account constraints); env variable NAMES only, never values>
- **Steps**:
  1. <user-language action — "Add an item to the basket", "Choose the wallet provider">
  2. <next action; name the observable condition, never a selector and never a fixed wait ("the popup closes",
     not "wait 30 s")>
- **Expected**: <observable outcomes; UI copy in quotes where it matters; amounts as rules (total = subtotal −
  discount), not literals>
- **Oracle**: <UI-only | api | db, or the project's blockEnums.oracle> <(+ the field or status checked)>
- **Spend policy**: <none | disposable | released | one-confirming-run, or the project's blockEnums.spendPolicy>
- **Status**: <proposed | implemented | green | red-by-design | blocked | omitted-by-ruling> <(count, date, evidence, reason)>
```

## Fields

| Field | Contract | Lint check |
|---|---|---|
| Heading | `#### <ID> — <title>`; the ID matches `specs.shape.titleIdPattern` | a heading that looks like an ID but fails the grammar is an error |
| Contexts | whatever the project shards runs by (region, tenant, browser, account) | at least one name; the ID is unique per context |
| Type | the test's tags | every tag in `blockEnums.type` (else `specs.shape.tags`, else any `@tag`) |
| Purpose | why the scenario exists | present |
| Preconditions / test data | requirements, resolved at runtime (`test-data-conventions`, data engine) | present |
| Steps | numbered, indented, user language | no `data-test…`, `[`, `#id`, `getBy…`, `locator`, no durations or fixed waits |
| Expected | what the user observes when the behaviour is right | present |
| Oracle | the layer that confirms the outcome (`test-composer` oracle ladder: UI-only ≈ L0/L1, api ≈ L2, db ≈ L3) | first word from `blockEnums.oracle` (default `UI-only`, `api`, `db`) |
| Spend policy | what running it costs (see the spend budgets in `test-data-conventions`) | leading token from `blockEnums.spendPolicy` (default `none`, `disposable`, `released`, `one-confirming-run`) |
| Status | lifecycle, updated after verification | leading token from `blockEnums.status` (default: the six above) |

Tokens are hyphenated, but a block may use prose: the lint lower-cases the value, drops counts such as `3×`, and
turns spaces into hyphens before matching, so `green 3× (2026-09-12)` matches `green` and `one confirming run`
matches `one-confirming-run`.

Optional bullets the lint ignores: **Spec** (spec file, test title, tags — first bullet once implemented) and
**Corrected (<date>)** (what live behaviour contradicted, keeping the old claim visible — last bullet).

A block whose Status is `omitted-by-ruling (<date>, <reason>)` needs only Contexts, Purpose and Status: it describes
no executable test and keeps its heading so the decision stays on record. A project that sets its own
`blockEnums.status` must keep `omitted-by-ruling` in that list to keep this minimal form.

## Example (the neutral example application)

```markdown
#### CHK-03 — Cancelling the wallet popup returns to checkout without an order

- **Contexts**: south
- **Type**: @e2e @checkout @negative
- **Purpose**: A shopper who abandons the wallet provider's popup is back at checkout and the order is not placed.
- **Preconditions / test data**: merchant open now (`demo-bistro` or any merchant the resolver finds); one orderable
  item; the wallet provider offered on `/pay`; account `shopper-b` with the "Save payment method" switch off.
- **Steps**:
  1. Add one item to the basket and go to checkout.
  2. Choose the wallet provider and continue to payment.
  3. In the popup, choose "Cancel and return".
  4. The popup closes and checkout is shown again.
- **Expected**: checkout shows the basket unchanged (same items, total = subtotal + delivery fee); no confirmation
  page is reached.
- **Oracle**: api (`GET /orders/<id>` for the order started at checkout stays `pending`, never `placed`)
- **Spend policy**: none
- **Status**: green 3× (2026-09-12, verify note of the change)
```
