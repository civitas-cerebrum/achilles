// spec-lint fixture: elements by repository name through the Steps API and the repository
// rules: TB-A1
import { test, expect } from './fixtures/base';

test('TC-0003 · the schedule panel shows', async ({ steps, repo }) => {
  await steps.verifyPresence('schedulePanel', 'DashboardPage');
  const item = await repo.getByText('menuItem', 'DashboardPage', 'Reports');
  expect(item).toBeTruthy();
});
