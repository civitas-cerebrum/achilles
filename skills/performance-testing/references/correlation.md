# Correlation — Dynamic Values Under Load

Correlation = capturing a server-generated value from one response and injecting it into a
later request (auth tokens, CSRF tokens, session ids, generated resource ids). Skipping it is
the #1 cause of false load-test failures (every VU replays a stale/empty token → 401/403 storm
that looks like an app failure but is a script bug).

## Rules

1. **Extract from structure, not luck.** Prefer `res.json('path.to.field')` (see `extractJson`
   in `k6-reference.md`) over regex. Use `extractRegex` only for non-JSON bodies (hidden form
   inputs, HTML).
2. **Fail loudly on a missing value.** A correlation miss throws — never inject `''`/`undefined`
   downstream. The helpers already do this.
3. **Correlate per-VU, per-iteration as the flow requires.** A login token captured once in
   `setup()` may expire mid-soak; re-acquire inside the VU loop when the token TTL is shorter
   than the test duration.
4. **Never hardcode a captured token.** A session id pasted from a browser devtools session is
   dead the moment the test runs (Rule 6).

## Patterns

```js
import http from 'k6/http';
import { baseUrl } from '../lib/config.js';
import { extractJson } from '../lib/correlation.js';

export default function () {
  const login = http.post(`${baseUrl()}/api/login`,
    JSON.stringify({ user: __ENV.PERF_USER, pass: __ENV.PERF_PASS }),
    { headers: { 'Content-Type': 'application/json' } });
  const token = extractJson(login, 'token');

  http.get(`${baseUrl()}/api/orders`, { headers: { Authorization: `Bearer ${token}` } });
}
```

## Tech-stack notes (port the relevant ones from perf-skills)

- **ASP.NET ViewState / CSRF hidden inputs** → `extractRegex` against the HTML form.
- **Java JSESSIONID** → usually a cookie; k6's cookie jar handles it automatically — only
  correlate manually if the app puts the session id in the body/URL.
- **OAuth / SAML** → acquire the bearer token in a login step, refresh when TTL < test duration.
