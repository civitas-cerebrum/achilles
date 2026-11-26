// spec-lint fixture: responses from the Steps API are data, not driver bindings
// rules: TB-A2 TB-A11
import { test, expect } from './fixtures/base';

test('TC-0509 · reads a response', async ({ steps }) => {
  const res = await steps.requestGet('/api/items');
  const body = await res.json();
  expect(body).toBeTruthy();
});
