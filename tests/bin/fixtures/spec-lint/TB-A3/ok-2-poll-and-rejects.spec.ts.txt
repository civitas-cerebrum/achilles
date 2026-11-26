// spec-lint fixture: expect.poll, rejects and toHaveLength on data are not web-first matchers
// rules: TB-A3
import { test, expect } from './fixtures/base';

test('TC-0034 · the basket fills', async ({ steps }) => {
  await expect.poll(() => steps.getCount('basketRow', 'CartPage')).toBe(3);
  await expect(steps.getText('missing', 'CartPage', { timeout: 1 })).rejects.toBeInstanceOf(Error);
  expect(['a', 'b']).toHaveLength(2);
});
