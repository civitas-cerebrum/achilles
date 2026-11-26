// spec-lint fixture: a fixture the project declares with extend
// rules: TB-A9 TB-A10
import type { Steps } from '@civitas-cerebrum/element-interactions';
import { test, expect } from './fixtures/base';

const it = test.extend<{ adminSession: Steps }>({
  adminSession: async ({ steps }, use) => { await use(steps); },
});

it('TC-0093 · the admin sees the audit log', async ({ adminSession }) => {
  await adminSession.verifyPresence('auditLog', 'AdminPage');
});
