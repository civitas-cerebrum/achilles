// spec-lint fixture: the extended forms (advisory)
// rules: TB-A11
import { helper } from './utils/helpers';
import { test, expect } from './fixtures/base';

test('TC-0112 · hands the page over indirectly', async ({ page, steps, repo, contextStore }) => {
  await helper({ page, steps }); // EXPECT TB-A11/advisory
  await helper([page]); // EXPECT TB-A11/advisory
  await helper(() => page); // EXPECT TB-A11/advisory
  await helper(page.keyboard); // EXPECT TB-A11/advisory
  await helper(await repo.get('payButton', 'CheckoutPage')); // EXPECT TB-A11/advisory
  await Promise.resolve(page).then(helper); // EXPECT TB-A11/advisory TB-A11/advisory
  contextStore.put('page', page); // EXPECT TB-A11/advisory
});
