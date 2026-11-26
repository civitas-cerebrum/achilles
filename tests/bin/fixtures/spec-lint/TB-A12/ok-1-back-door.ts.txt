// spec-lint fixture: an API back-door helper that drives no UI
// place: tests/e2e/helpers/api.ts
// rules: TB-A12
import type { APIRequestContext } from '@playwright/test';

export async function seedUser(request: APIRequestContext, name: string) {
  const res = await request.post('/api/users', { data: { name } });
  return res.json();
}
