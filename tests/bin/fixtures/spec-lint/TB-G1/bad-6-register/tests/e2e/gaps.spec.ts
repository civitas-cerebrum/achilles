import { test } from './fixtures/base';

test('TC-0417 · listens to the console', async ({ page, steps }) => {
  // EXPECT-NEXT TB-G1
  // framework-gap: FG-3
  page.on('console', () => undefined);
  await steps.navigateTo('/');
});

test('TC-0418 · waives with the hatch', async ({ page }) => {
  // achilles-allow TB-A2 -- the bring-to-front call has no Steps form [gap: FG-2]
  await page.bringToFront();
});

test('TC-0419 · waives with the hatch again', async ({ page }) => {
  // EXPECT-NEXT TB-G1
  // achilles-allow TB-A2 -- the bring-to-front call has no Steps form [gap: FG-2]
  await page.bringToFront();
});

test('TC-0420 · cites a row that is not in the register', async ({ page }) => {
  // EXPECT-NEXT TB-G1
  // achilles-allow TB-A2 -- the bring-to-front call has no Steps form [gap: FG-9]
  await page.bringToFront();
});
