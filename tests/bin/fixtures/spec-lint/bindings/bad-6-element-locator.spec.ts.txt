// spec-lint fixture: the locator of a repository element is a driver binding
// rules: TB-A2 TB-A4
import { WebElement } from '@civitas-cerebrum/element-interactions';
import { test, expect } from './fixtures/base';

test('TC-0505 · reaches the element locator', async ({ repo }) => {
  const el = await repo.get('payButton', 'CheckoutPage');
  await (el as WebElement).locator.dblclick(); // EXPECT TB-A2
  await el.locator.evaluate((n) => n.remove()); // EXPECT TB-A4
});
