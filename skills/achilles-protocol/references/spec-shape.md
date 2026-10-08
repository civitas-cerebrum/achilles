# Spec shape — the flat test architecture

A spec is read far more often than it is written: by the reviewer, by the verifier, by whoever triages it red at
night, and by the person who wrote the scenario and wants to know whether the test does what the block says. This
reference fixes one shape for every UI spec so that a reader can put the scenario block next to the test and check
them line by line. It is linked from `test-composer` (Step 3) and `achilles-protocol` (the reference index and rule 17); the
scenario block it implements is defined by `requirement-intake`.

## The rules

1. **One scenario per `test()`.** Title `'<ID> — <title>'`, the ID and title of its scenario block, tags from the
   block's Type: `test('CHK-03 — …', { tag: ['@e2e', '@checkout'] }, async ({ … }) => { … })`. No loops that
   generate tests from a table, no `test.step` wrappers that hide several scenarios in one test.
2. **Steps inline, in reading order.** The block's Steps appear in the spec in the same order, one or a few calls
   each, by repository name (`steps.click('walletOption', 'PayPage')`). A reader finds step 3 of the block by
   reading down to the third step of the test.
3. **Verbs only for shared chores.** A repeated chore (arrive at checkout with a planned basket, fill delivery
   details, pay by card) becomes a fixture verb only when **two or more** scenarios share it. A step unique to one
   scenario stays inline, even when it is long. A verb does its chore and verifies its own effect with a state wait;
   it never asserts the scenario's outcome.
4. **No page-object layers.** No per-page classes, no `CheckoutPage.fillAndSubmit()` wrappers over the Steps API,
   no base-page inheritance. The element repository is the page model; fixture verbs are the only abstraction above
   the Steps API.
5. **The oracle is visible.** The test ends with the call named by the block's Oracle (`orders.expectStatus(order,
   'placed')`) or, for `UI-only`, an assertion on the effect. An order-placing test attaches its evidence (the order
   id annotation, a confirmation screenshot) in the spec, where a reader sees it.
6. **Branching, retries and mutations live in fixtures.** No `if` on environment or context in a spec, no retry
   loop, no `try/catch` that turns a failure into a pass. A permitted retry (the application may refuse and the
   scenario document says so) lives in a verb with a bounded count and a structural change per attempt. Can-fail
   hooks are honoured by fixtures only (`test-data-conventions`, data engine).
7. **One family per file.** A spec file holds the scenarios of one family (checkout negatives, wallet payments,
   discount codes); the file name says which. Contexts are projects in the config, not branches in the file.
8. **About 60 lines per test at most.** A longer test is usually two scenarios, or a chore that two tests already
   share and that should be a verb.

## Before / after — the neutral example application

Scenario block `CHK-03 — Cancelling the payment modal returns to checkout without an order` (see
`../../requirement-intake/references/scenario-block.md`).

**Before** — layered, generated, oracle hidden:

```ts
// tests/e2e/payments.spec.ts
for (const region of ['region-1', 'region-2']) {
  test.describe(`wallet ${region}`, () => {
    test('wallet cancel', async ({ page }) => {
      const shop = new ShopFlow(page);                  // page-object layer over the Steps API
      await shop.buyFirstItemAndPayWithWallet(region);   // five scenario steps hidden in one call
      if (region === 'region-2') {                       // branching on context in the spec
        await shop.modal().cancel();
      } else {
        await shop.cancelRedirect();
      }
      for (let i = 0; i < 3; i++) {                      // retry loop in the spec
        if (await shop.isOnCheckout()) break;
      }
      await shop.assertNoOrder();                        // which layer confirms? the reader cannot tell
    });
  });
}
```

**After** — flat, one scenario, oracle and evidence visible:

```ts
// tests/e2e/wallet-payments.spec.ts — family: wallet payments
test('CHK-03 — Cancelling the payment modal returns to checkout without an order',
  { tag: ['@e2e', '@checkout', '@negative'] }, async ({ steps, checkout, orders }) => {
  const req: Requirements = { payment: 'wallet', items: { count: 1 } };
  const { order } = await checkout.arriveWithPlannedBasket(req);          // step 1: chore shared by 6 scenarios → verb

  await steps.click('continueToPayment', 'CheckoutPage');                  // step 2
  await steps.click('walletOption', 'PayPage');
  const modal = await checkout.paymentModal();                             // Steps bound to the modal (fixture)
  await modal.click('cancelAndReturn', 'PaymentModal');                    // step 3
  await steps.verifyUrlContains('/checkout');                              // step 4: checkout shown again
  await steps.verifyOrder('basketItems', 'CheckoutPage', order.plannedItemNames);

  await orders.expectStatus(order, 'pending');                             // oracle: api — never `placed`
  await checkout.attachEvidence(order, 'after-cancel');                    // evidence in the report
});
```

The `region-2` modal and the `region-1` same-tab redirect are two blocks (or one block with two contexts and a verb that
knows the difference); either way the spec does not branch.

## The readability check (verifier)

The verifier performs this check on every spec in the change and records it in the verify note:

- [ ] One `test()` per block; the title is `'<ID> — <title>'`; the tags are the block's Type.
- [ ] Reading the test top to bottom follows the block's Steps in order.
- [ ] Every verb is shared by ≥ 2 scenarios; nothing scenario-specific hides in a verb.
- [ ] No page-object class, no inline selector, no sleep, no `.only`, no retry or branch in the spec.
- [ ] The last meaningful statement is the block's oracle; order-placing tests attach evidence.
- [ ] One family per file; no test longer than about 60 lines.
- [ ] No test that cannot fail: a can-fail proof exists for the family, or the assertion visibly depends on the action.

A spec that fails the check is a finding under "Readability" in the verify note, not a style comment.
