// spec-lint fixture: reflection and computed access on framework objects
// rules: TB-A14
import { test, expect } from './fixtures/base';

test('TC-0142 · walks the framework objects', async ({ steps, repo }) => {
  const k = 'page';
  const a = Reflect.get(repo, 'driver'); // EXPECT TB-A14
  const b = Object.values(steps); // EXPECT TB-A14
  const c = Object.entries(repo); // EXPECT TB-A14
  const d = repo['dri' + 'ver']; // EXPECT TB-A14
  const e = steps[k]; // EXPECT TB-A14
  expect([a, b, c, d, e].length).toBe(5);
});
