// spec-lint fixture: the callees a binding may be passed to
// rules: TB-A11
import { signIn } from './flows/login-flow';
import { test, expect } from './fixtures/base';

test('TC-0113 · a second tab shows the receipt', async ({ page, steps }) => {
  await signIn(steps, 'user-1');
  const [popup] = await Promise.all([page.waitForEvent('popup'), steps.click('receiptLink', 'OrderPage')]);
  const other = steps.forPage(popup);
  await test.step('check the receipt', async () => { await other.verifyPresence('receipt', 'ReceiptPage'); });
});
