// spec-lint fixture: an HTTP call on the request fixture when steps.requestPost exists
// rules: TB-A2 TB-A13
import { test, expect } from './fixtures/base';

test('TC-0012 · creates an order', async ({ request }) => {
  await request.post('/api/orders', { data: { sku: 'A-1' } }); // EXPECT TB-A2
});
