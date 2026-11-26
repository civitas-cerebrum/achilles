// spec-lint fixture: the driver behind the repository and behind Steps
// rules: TB-A14 TB-A1 TB-A2
import { test, expect } from './fixtures/base';

test('TC-0140 · pays', async ({ repo, steps }) => {
  await repo.driver.locator('#pay').click(); // EXPECT TB-A14 TB-A1
  await (steps as any).page.goto('/x'); // EXPECT TB-A14 TB-A14 TB-A2
});
