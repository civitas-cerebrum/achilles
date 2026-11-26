// spec-lint fixture: a fixture name nothing declares (advisory)
// rules: TB-A10
import { test, expect } from './fixtures/base';

test('TC-0102 · uses a ghost fixture', async ({ steps, ghostSession }) => { // EXPECT TB-A10/advisory
  await steps.navigateTo('/');
  expect(ghostSession).toBeTruthy();
});
