// spec-lint fixture: getBy* on a frame taken from the page, inside a hook
// rules: TB-A1
import { test, expect } from './fixtures/base';

test.beforeEach(async ({ page }) => {
  const frame = page.mainFrame();
  await frame.getByRole('button').click(); // EXPECT TB-A1
});
