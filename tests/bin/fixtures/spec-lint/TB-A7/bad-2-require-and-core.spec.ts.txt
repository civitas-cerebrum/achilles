// spec-lint fixture: a require of playwright and a value import from playwright-core
// rules: TB-A7
import { devices } from 'playwright-core'; // EXPECT TB-A7
import { test } from './fixtures/base';
const { chromium } = require('playwright'); // EXPECT TB-A7

test('TC-0071 · runs', async ({ steps }) => {
  await steps.navigateTo(devices ? '/a' : '/b');
  expect(chromium).toBeTruthy();
});
