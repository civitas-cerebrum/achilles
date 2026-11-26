// Corpus spec: one seeded violation per blocking rule that is rare in live suites.
import { test as raw } from '@playwright/test'; // EXPECT TB-A7
import { test, expect } from './fixtures/base';

async function onlyOnce(steps) { await steps.click('a', 'P'); } // EXPECT TB-S2

for (const r of ['/a', '/b']) {
  test(`TC-02${r} · generated`, async ({ steps }) => { // EXPECT TB-S1
    await steps.navigateTo(r);
  });
}

test.describe.configure({ mode: 'serial' }); // EXPECT TB-S7

test.only('TC-0201 · only', async ({ steps }) => { // EXPECT TB-F6
  await onlyOnce(steps);
});

test('TC-0202 · sleeps', async ({ page, steps }) => {
  await page.waitForTimeout(500); // EXPECT TB-F5
  await new Promise((r) => setTimeout(r, 500)); // EXPECT TB-F5
  await steps.verifyPresence('heading', 'HomePage');
});

test('TC-0203 · swallowed try', async ({ steps }) => {
  try { // EXPECT TB-F3
    await steps.verifyPresence('receipt', 'OrderPage');
  } catch {
    // tolerated
  }
});

test('TC-0204 · inline selectors and web-first', async ({ page, steps }) => {
  await steps.on('panel', 'P').findBySelector('input[name=q]').fill('x'); // EXPECT TB-A5
  await expect(page.locator('.price')).toHaveText('1'); // EXPECT TB-A3 TB-A1 TB-A5
  await expect(page).toHaveURL(/done/); // EXPECT TB-A3
  await steps.click('#submit', 'P'); // EXPECT TB-A5
  await steps.navigateTo('/orders#latest'); // CLEAN
});

test('TC-0205 · nested steps and unknown method', async ({ steps }) => {
  await test.step('outer', async () => {
    await test.step('inner', async () => { // EXPECT TB-S4
      await steps.getLocator('x', 'P'); // EXPECT TB-A10
    });
  });
});

test('TC-0206 · conditional assertion', async ({ steps }) => {
  const r = await steps.isVisible('x', 'P');
  if (r) { // EXPECT TB-F1
    await steps.verifyText('x', 'P', 'y');
  }
});

test('TC-0207 · refusal callback keeps its literal', async ({ steps }) => {
  await expect(() => steps.on('row', 'P').findBySelector('.x')).rejects.toThrow(); // CLEAN
});
