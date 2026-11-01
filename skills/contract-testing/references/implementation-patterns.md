# Contract-test implementation patterns

Canonical shapes for Phase 5 of [`../SKILL.md`](../SKILL.md): copy, do not improvise. Every pattern already appears in `../../achilles-orchestrator/references/api-reference.md` → "HTTP API Steps"; read that first if anything looks unfamiliar.

**5a. Status check (happy path):**

```ts
test('GET /users/:id returns 200 for a valid id', async ({ steps }) => {
  const res = await steps.apiGet<unknown>('/users/42');
  await steps.verifyApiStatus(res, 200);
});
```

**5b. Header contract:**

```ts
test('GET /users/:id returns JSON content-type', async ({ steps }) => {
  const res = await steps.apiGet<unknown>('/users/42');
  await steps.verifyApiHeader(res, 'content-type', 'application/json; charset=utf-8');
});
```

**5c. Schema shape:**

```ts
import { UserSchema } from './schemas';

test('GET /users/:id body matches User schema', async ({ steps }) => {
  const res = await steps.apiGet<Record<string, unknown>>('/users/42');
  await steps.verifyApiStatus(res, 200);
  expect(res.body).toMatchObject(UserSchema);
});
```

**5d. Error contract:**

```ts
import { ErrorSchema } from './schemas';

test('GET /users/:id returns 404 for unknown id', async ({ steps }) => {
  const res = await steps.apiGet<Record<string, unknown>>('/users/999999999');
  await steps.verifyApiStatus(res, 404);
  expect(res.body).toMatchObject(ErrorSchema);
});
```

**5e. Auth contract:**

```ts
test('GET /users/:id returns 401 when token is missing', async ({ steps }) => {
  const res = await steps.apiGet<unknown>('/users/42', { headers: { Authorization: '' } });
  await steps.verifyApiStatus(res, 401);
});
```

**5f. Write contract (POST shape):**

```ts
test('POST /users accepts valid payload and echoes it', async ({ steps }) => {
  const payload = { name: 'Ada Lovelace', email: 'ada@example.com' };
  const res = await steps.apiPost<Record<string, unknown>>('/users', payload);
  await steps.verifyApiStatus(res, 201);
  expect(res.body).toMatchObject({ id: expect.any(Number), ...payload });
});
```

**5g. Multi-backend cross-check: single test, two providers:**

```ts
test('billing invoice references a real auth user', async ({ steps }) => {
  const invoice = await steps.apiGet<{ userId: number }>('billing', '/invoices/1');
  await steps.verifyApiStatus(invoice, 200);

  const user = await steps.apiGet<unknown>('auth', `/users/${invoice.body.userId}`);
  await steps.verifyApiStatus(user, 200);
});
```

**5h. Unknown shape: discover first, then lock.** If no OpenAPI exists, run the endpoint once, log `res.body`, draft the schema, and return it under `NEEDS_CONTEXT` for confirmation before locking it. Never assert against a shape nobody has confirmed.

**5i. List shape: array of typed objects:**

```ts
// Envelope shape: content is an array of Book-like objects
test('body carries a content array of Book objects', async ({ steps }) => {
  const res = await steps.apiGet<BooksListResponse>('/books');
  expect(res.body).toMatchObject({
    content: expect.arrayContaining([expect.objectContaining(BookSchema)]),
  });
});

// Per-item shape: every item conforms. Prefer a loop — arrayContaining only
// checks that AT LEAST ONE item matches, which hides rogue elements.
test('each item in content matches the Book schema', async ({ steps }) => {
  const res = await steps.apiGet<BooksListResponse>('/books');
  for (const item of res.body.content) {
    expect(item).toMatchObject(BookSchema);
  }
});
```

Do NOT assert `expect(res.body.content).toHaveLength(50)`; that is a value assertion on seed size, not a contract. If the spec says "at least one", assert `toBeGreaterThan(0)`. If the spec gives bounds, assert bounds (`toBeGreaterThanOrEqual` / `toBeLessThanOrEqual`). Never lock exact counts.
