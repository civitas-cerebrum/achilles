// spec-lint fixture: a method present in the pinned 0.3.5
// pin: 0.3.5
// rules: TB-A10
import { test, expect } from './fixtures/base';

test('TC-0104 · keeps the theme', async ({ steps }) => {
  expect(await steps.getLocalStorage('theme')).toBe('dark');
});
