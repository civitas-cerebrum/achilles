// Corpus spec: one driver-binding hole per test. EXPECT lines must be hit; CLEAN lines must not.
import type { Page, BrowserContext } from '@playwright/test';
import { WebElement } from '@civitas-cerebrum/element-interactions';
import { test, expect } from './fixtures/base';
import { clickCss } from './utils/wrappers';

let shared: Page;
let untyped;

test.describe('holes', () => {
  test.beforeAll(async ({ browser }) => {
    shared = await browser.newPage();
  });
  test.beforeEach(async ({ context }) => {
    untyped = await context.newPage();
  });

  test('TC-0001 · module-level typed page assigned in a hook', async () => {
    await shared.locator('#a').click(); // EXPECT TB-A1
  });

  test('TC-0002 · module-level untyped page assigned in a hook', async () => {
    await untyped.goto('/x'); // EXPECT TB-A2
  });

  test('TC-0003 · fixtures object not destructured', async (fx) => {
    await fx.page.locator('#b').click(); // EXPECT TB-A1
  });

  test('TC-0004 · destructured page member', async ({ page }) => {
    const { keyboard } = page;
    await keyboard.press('Enter'); // EXPECT TB-A2
  });

  test('TC-0005 · untyped extend fixture', async ({ adminPage }) => {
    await adminPage.goto('/admin'); // EXPECT TB-A2
  });

  test('TC-0006 · raw locator behind a repository element', async ({ repo }) => {
    const el = await repo.get('payButton', 'CheckoutPage');
    await el.locator.click(); // EXPECT TB-A2
    await (el as WebElement).locator.evaluate((n) => n.remove()); // EXPECT TB-A4
  });

  test('TC-0007 · computed member', async ({ page }) => {
    const m = 'click';
    await page[m](); // EXPECT TB-A2
  });

  test('TC-0008 · unlisted raw methods', async ({ page }) => {
    const btn = page.getByTestId('x'); // EXPECT TB-A1
    expect(await btn.isHidden()).toBe(false); // EXPECT TB-A2
    await btn.setChecked(true); // EXPECT TB-A2
    await btn.tap(); // EXPECT TB-A2
    await page.waitForRequest('**/api'); // EXPECT TB-A2
  });

  test('TC-0009 · no-equivalent members stay A2b', async ({ page, context }) => {
    await page.waitForEvent('download'); // EXPECT TB-A2b
    await context.clearCookies(); // EXPECT TB-A2b
  });

  test('TC-0010 · wrapper leaves the spec', async ({ page, steps }) => {
    await clickCss(page, '#pay'); // EXPECT TB-A11
    await steps.click('payButton', 'CheckoutPage'); // CLEAN
  });

  test('TC-0011 · controls', async ({ steps, repo }) => {
    const el = await repo.get('payButton', 'CheckoutPage'); // CLEAN
    const book = { title: 'x' };
    const { title } = book; // CLEAN
    await steps.verifyText('heading', 'CheckoutPage', title); // CLEAN
    expect(el).toBeTruthy(); // CLEAN
  });
});

const local = test.extend<{ ctx2: BrowserContext }>({
  ctx2: async ({ browser }, use) => {
    const c = await browser.newContext();
    const p = await c.newPage();
    await p.locator('#warm').click(); // EXPECT TB-A1
    await use(c);
  },
});
local('TC-0012 · spec-local extend body is blocking', async ({ ctx2 }) => {
  await ctx2.clearCookies(); // EXPECT TB-A2b
});
