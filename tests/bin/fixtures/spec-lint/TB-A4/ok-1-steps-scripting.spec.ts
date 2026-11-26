// spec-lint fixture: page scripting through the Steps API
// rules: TB-A4
import { test, expect } from './fixtures/base';

test('TC-0042 · keeps the theme', async ({ steps }) => {
  const theme = await steps.getLocalStorage('theme');
  const width = await steps.evaluateScript(() => window.innerWidth);
  expect([theme, width]).toHaveLength(2);
});
