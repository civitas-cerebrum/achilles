import { test } from './fixtures/base';

test('TC-0054 · filters the orders', async ({ steps }) => {
  await steps.fill('filterInput', 'OrdersPage', 'data-qa=status'); // EXPECT TB-A5/advisory
  await steps.click('applyButton', 'OrdersPage');
});
