// spec-lint fixture: a .tsx spec parses with jsx
// rules: TB-G0
import { test, expect } from './fixtures/base';

const Banner = () => <div>banner</div>;

test('TC-0402 · parses', async ({ steps }) => {
  expect(Banner).toBeTruthy();
  await steps.navigateTo('/');
});
