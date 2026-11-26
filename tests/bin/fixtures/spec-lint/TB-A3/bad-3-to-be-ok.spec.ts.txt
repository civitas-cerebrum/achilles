// spec-lint fixture: toBeOK is advisory (unmeasured)
// rules: TB-A3
import { test, expect } from './fixtures/base';

test('TC-0032 · the health endpoint answers', async ({ steps }) => {
  const res = await steps.requestGet('/health');
  expect(res).toBeOK(); // EXPECT TB-A3/advisory
});
