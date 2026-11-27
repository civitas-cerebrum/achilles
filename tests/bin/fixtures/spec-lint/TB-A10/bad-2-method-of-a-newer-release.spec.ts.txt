// spec-lint fixture: getUrl does not exist in the pinned 0.3.5
// pin: 0.3.5
// rules: TB-A10
import { test, expect } from './fixtures/base';

test('TC-0101 · stays on the page', async ({ steps }) => {
  expect(steps.getUrl()).toContain('/orders'); // EXPECT TB-A10
});
