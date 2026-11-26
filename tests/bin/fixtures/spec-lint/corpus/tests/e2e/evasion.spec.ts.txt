// Corpus spec: rewrites that dodge the flow-control rules. EXPECT lines must be hit; CLEAN lines must not.
import { test, expect } from './fixtures/base';

test('TC-0101 · IIFE around a branch', async ({ steps }) => {
  await (async () => { // EXPECT TB-F1
    if (await steps.isVisible('banner', 'HomePage')) { // EXPECT TB-F1
      await steps.click('dismiss', 'HomePage');
    }
  })();
});

test('TC-0102 · one-pass loop around a branch', async ({ steps }) => {
  for (const _ of [0]) { // EXPECT TB-F1
    if (await steps.isVisible('banner', 'HomePage')) await steps.click('dismiss', 'HomePage'); // EXPECT TB-F1
  }
});

test('TC-0103 · ternary and && around actions', async ({ steps }) => {
  const shown = await steps.isVisible('banner', 'HomePage');
  shown ? await steps.click('dismiss', 'HomePage') : await steps.click('open', 'HomePage'); // EXPECT TB-F1
  shown && (await steps.click('dismiss', 'HomePage')); // EXPECT TB-F1
  const label = shown ? 'a' : 'b'; // CLEAN-BLOCKING TB-F1
  await steps.verifyText('heading', 'HomePage', label);
});

test('TC-0104 · swallowed failures without try', async ({ steps }) => {
  await steps.click('pay', 'CheckoutPage').then(() => undefined, () => undefined); // EXPECT TB-F3
  await Promise.allSettled([steps.verifyPresence('receipt', 'OrderPage')]); // EXPECT TB-F3
});

test('TC-0105 · optional actions', async ({ steps }) => {
  await steps.clickIfPresent('cookieAccept', 'HomePage'); // EXPECT TB-F7
  await steps.on('promo', 'HomePage').ifVisible().click(); // EXPECT TB-F7
  await steps.waitForState('toast', 'HomePage', 'visible', { optional: true }); // EXPECT TB-F7
  await steps.verifyPresence('heading', 'HomePage'); // CLEAN
});

test.describe('hook branches', () => {
  test.beforeEach(async ({ steps }) => {
    if (await steps.isVisible('cookieWall', 'HomePage')) await steps.click('accept', 'HomePage'); // EXPECT TB-F1
  });
  test('TC-0106 · body', async ({ steps }) => {
    await steps.verifyPresence('heading', 'HomePage');
  });
});
