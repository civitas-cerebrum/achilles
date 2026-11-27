// Corpus spec: reach-through to the driver behind framework objects, and the ways a binding leaves the spec.
import { test } from './fixtures/base';
import { withPage, withList, withFn, typeWith, readEl } from './utils/verbs';

test('TC-0301 · repo.driver', async ({ repo }) => {
  await repo.driver.locator('#pay').click(); // EXPECT TB-A1 TB-A14
  await repo.driver.goto('/x'); // EXPECT TB-A2 TB-A14
  await repo['driver'].goto('/z'); // EXPECT TB-A2 TB-A14
});

test('TC-0302 · steps private page', async ({ steps }) => {
  await (steps as any).page.goto('/x'); // EXPECT TB-A2 TB-A14
  await (steps as any)['page'].reload(); // EXPECT TB-A2 TB-A14
  await (steps as any)._page.goBack(); // EXPECT TB-A14
  await steps.page.goto('/y'); // EXPECT TB-A2 TB-A14
});

test('TC-0303 · interactions reach-through', async ({ interactions }) => {
  await (interactions as any).interact.page.goto('/y'); // EXPECT TB-A2 TB-A14
  await interactions.interact.page.goto('/y'); // EXPECT TB-A2 TB-A14
});

test('TC-0304 · A11 shapes', async ({ page, steps, repo }) => {
  await withPage({ page, steps }); // EXPECT TB-A11
  await withList([page]); // EXPECT TB-A11
  await withList(...[page]); // EXPECT TB-A11
  await withFn(() => page); // EXPECT TB-A11
  await typeWith(page.keyboard); // EXPECT TB-A11
  await readEl(await repo.get('payButton', 'CheckoutPage')); // EXPECT TB-A11
  await Promise.resolve(page).then(withPage); // EXPECT TB-A11
  await withPage({ steps }); // CLEAN
  await Promise.all([steps.click('payButton', 'CheckoutPage')]); // CLEAN
});

const keep: { p?: unknown } = {};
let saved;
test('TC-0305 · stored and returned', async ({ page, contextStore }) => {
  keep.p = page; // EXPECT TB-A11
  saved = page; // EXPECT TB-A11
  contextStore.put('p', page); // EXPECT TB-A11
});
function exposes(page) {
  return page; // EXPECT TB-A11
}
test('TC-0306 · uses exposes', async ({ steps }) => {
  await steps.verifyPresence('heading', 'HomePage'); // CLEAN
});

test('TC-0307 · reflection and computed access', async ({ steps, repo }) => {
  const k = 'page';
  const d = Reflect.get(repo, 'driver'); // EXPECT TB-A14
  const all = Object.values(steps); // EXPECT TB-A14
  const pairs = Object.entries(repo); // EXPECT TB-A14
  const drv = repo['dri' + 'ver']; // EXPECT TB-A14
  const p = steps[k]; // EXPECT TB-A14
  const copy = { ...steps }; // EXPECT TB-A14
  const moved = Object.assign({}, repo); // EXPECT TB-A14
  await steps.verifyPresence('heading', 'HomePage'); // CLEAN
});
