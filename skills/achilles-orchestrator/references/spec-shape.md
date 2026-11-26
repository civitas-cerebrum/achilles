# Spec shape — the flat test architecture

A spec is read far more often than it is written: by the reviewer, by whoever triages it red at night, and by the
person who wrote the scenario and wants to know whether the test does what the block says. This reference shows the
one shape every UI spec takes so that a reader can put the scenario block next to the test and check them line by
line. It is linked from `test-composer` (Step 3) and the author-scenario workflow; the scenario block it implements is
defined by [`scenario-block.md`](scenario-block.md). The rules themselves live in
[`test-baseline.md`](test-baseline.md); this file is their worked example.

## The shape, rule by rule

1. **One scenario per `test()`**, titled `'<ID> · <title>'` from its scenario block, tags from the block's Type:
   `test('CHK-03 · …', { tag: ['@e2e', '@checkout'] }, async ({ … }) => { … })`
   ([TB-S1](test-baseline.md#tb-s1), [TB-I1](test-baseline.md#tb-i1), [TB-I3](test-baseline.md#tb-i3),
   [TB-S4](test-baseline.md#tb-s4)).
2. **Steps inline, in reading order**, by repository name: a reader finds step 3 of the block by reading down to the
   third step of the test ([TB-R1](test-baseline.md#tb-r1)).
3. **Verbs only for shared chores, or for what a spec may not hold.** A verb is a function over `steps` in a flow
   module, or a project fixture; it does its chore and checks its own effect, never the scenario's outcome
   ([TB-R2](test-baseline.md#tb-r2), [TB-R3](test-baseline.md#tb-r3), [TB-X1](test-baseline.md#tb-x1)).
4. **No page-object layers**: the element repository is the page model ([TB-S3](test-baseline.md#tb-s3)).
5. **The oracle is visible**: present, tied to the action, and able to fail; guard checks may follow it. An
   order-placing test attaches its evidence in the spec ([TB-R4](test-baseline.md#tb-r4),
   [TB-R5](test-baseline.md#tb-r5), [TB-R7](test-baseline.md#tb-r7)).
6. **Branching, retries and optional actions live in verbs and fixtures**, never in the spec
   ([TB-F1](test-baseline.md#tb-f1) to [TB-F7](test-baseline.md#tb-f7), [TB-X4](test-baseline.md#tb-x4)). Can-fail
   hooks are honoured by fixtures only (`test-data-conventions`, data engine).
7. **One family per file**; contexts are projects in the config, not branches in the file
   ([TB-S6](test-baseline.md#tb-s6), [TB-P3](test-baseline.md#tb-p3)).
8. **Short tests**: past the length hint a test is usually two scenarios, or a chore two tests already share
   ([TB-S5](test-baseline.md#tb-s5)).

## Before / after: the neutral example application

Scenario block `CHK-03 — Cancelling the payment modal returns to checkout without an order` (see
[`scenario-block.md`](scenario-block.md)).

**Before**: layered, generated, oracle hidden:

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

**After**: flat, one scenario, oracle and evidence visible:

```ts
// tests/e2e/wallet-payments.spec.ts (family: wallet payments)
test('CHK-03 · Cancelling the payment modal returns to checkout without an order',
  { tag: ['@e2e', '@checkout', '@negative'] }, async ({ steps, checkout, orders }) => {
  const req: Requirements = { payment: 'wallet', items: { count: 1 } };
  const { order } = await checkout.arriveWithPlannedBasket(req);          // step 1: chore shared by 6 scenarios → verb

  await steps.click('continueToPayment', 'CheckoutPage');                  // step 2
  await steps.click('payOption', 'PayPage');
  const modal = await checkout.paymentModal();                             // Steps bound to the modal (fixture)
  await modal.click('cancelAndReturn', 'PaymentModal');                    // step 3
  await steps.verifyUrlContains('/checkout');                              // step 4: checkout shown again
  await steps.verifyOrder('basketItems', 'CheckoutPage', order.plannedItemNames);

  await orders.expectStatus(order, 'pending');                             // oracle: api, never `placed`
  await checkout.attachEvidence(order, 'after-cancel');                    // evidence in the report
});
```

The `region-2` modal and the `region-1` same-tab redirect are two blocks (or one block with two contexts and a verb that
knows the difference); either way the spec does not branch.

## Who checks the shape

The reviewer checks [TB-R1](test-baseline.md#tb-r1), [TB-R2](test-baseline.md#tb-r2), [TB-R4](test-baseline.md#tb-r4),
[TB-R5](test-baseline.md#tb-r5), [TB-R7](test-baseline.md#tb-r7) and [TB-S1](test-baseline.md#tb-s1) on every spec in
the change; the lint reports the mechanical rules ([TB-A5](test-baseline.md#tb-a5), [TB-F1](test-baseline.md#tb-f1),
[TB-F4](test-baseline.md#tb-f4), [TB-F5](test-baseline.md#tb-f5), [TB-F6](test-baseline.md#tb-f6),
[TB-S3](test-baseline.md#tb-s3), [TB-S5](test-baseline.md#tb-s5), [TB-S6](test-baseline.md#tb-s6)). A spec that breaks
a blocking rule is a must-fix finding, not a style comment.
