// spec-lint fixture: literals inside callbacks that only a refusal assertion consumes
// rules: TB-A5
import { test, expect } from './fixtures/base';

test('TC-0053 · inline selectors are refused by the framework', async ({ steps }) => {
  expect(() => steps.on('row', 'CartPage').findBySelector('.remove')).toThrow();
  const call = () => steps.click('#raw', 'CartPage');
  await expect(call).rejects.toThrow(/selector/);
});
