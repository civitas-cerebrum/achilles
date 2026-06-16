# k6 Reference — Script Anatomy & Canonical Helpers

> Read this before writing any k6. Do not invent k6 API or threshold syntax from memory.

## Script anatomy

A k6 script exports `options` (config), a default function (the VU loop), and optionally
`handleSummary`. k6 reads env vars from the global `__ENV` (populated from the OS env and
`-e KEY=value` flags). k6 is **not Node** — no `process`, no `require`, ESM `import` only,
and remote imports (`https://jslib.k6.io/...`) are fetched at compile time.

```js
import http from 'k6/http';
import { sleep } from 'k6';

export const options = { vus: 1, duration: '30s' };

export default function () {
  http.get(`${__ENV.PERF_BASE_URL}/health`);
  sleep(1);
}
```

## Thresholds (the machine oracle)

`options.thresholds` maps a metric to pass/fail expressions. A breached threshold makes
`k6 run` exit non-zero. Common metrics: `http_req_duration` (latency; use `p(95)`, `p(99)`),
`http_req_failed` (error rate; `rate<0.01`), `iterations` / `http_reqs` (throughput).

```js
export const options = {
  thresholds: {
    http_req_duration: ['p(95)<800', 'p(99)<1500'],
    http_req_failed: ['rate<0.01'],
  },
};
```

## Executors

`constant-vus` (fixed VUs for a duration), `ramping-vus` (staged VU ramp),
`ramping-arrival-rate` (target requests/sec, k6 allocates VUs — use for breakpoint/throughput).

## Canonical helper modules

The skill scaffolds these into `tests/perf/lib/`. Copy verbatim, then adjust the numeric
templates in `profiles.js` to the workload the SLOs call for (see `workload-design.md`).

### `tests/perf/lib/config.js`

```js
// Single source of origin + auth resolution. Scenarios NEVER write an origin literal.
export function baseUrl() {
  const url = __ENV.PERF_BASE_URL;
  if (!url) {
    throw new Error('PERF_BASE_URL is not set. Export it before running k6 — never hardcode an origin.');
  }
  return url.replace(/\/$/, '');
}

export function authHeaders() {
  const token = __ENV.PERF_AUTH_TOKEN;
  return token ? { Authorization: `Bearer ${token}` } : {};
}
```

### `tests/perf/lib/profiles.js`

```js
// House-canonical workload profiles. Each export is a k6 scenario fragment.
// Numbers are STARTING TEMPLATES — derive real targets from SLOs (workload-design.md).
export const smoke = { executor: 'constant-vus', vus: 1, duration: '30s' };

export const load = {
  executor: 'ramping-vus', startVUs: 0,
  stages: [
    { duration: '1m', target: 20 },
    { duration: '3m', target: 20 },
    { duration: '1m', target: 0 },
  ],
};

export const stress = {
  executor: 'ramping-vus', startVUs: 0,
  stages: [
    { duration: '2m', target: 50 },
    { duration: '5m', target: 100 },
    { duration: '2m', target: 0 },
  ],
};

export const spike = {
  executor: 'ramping-vus', startVUs: 0,
  stages: [
    { duration: '10s', target: 100 },
    { duration: '1m', target: 100 },
    { duration: '10s', target: 0 },
  ],
};

export const soak = { executor: 'constant-vus', vus: 20, duration: '2h' };

export const breakpoint = {
  executor: 'ramping-arrival-rate', startRate: 10, timeUnit: '1s',
  preAllocatedVUs: 50, maxVUs: 500,
  stages: [{ duration: '10m', target: 500 }],
};
```

### `tests/perf/lib/thresholds.js`

```js
// SLO presets → k6 thresholds. The MACHINE ORACLE: a breach makes `k6 run` exit non-zero.
// Numbers must trace to an SLA / journey priority / user — never invent them.
export function slo({ p95Ms, p99Ms, errorRate = 0.01 } = {}) {
  const t = {};
  const dur = [];
  if (p95Ms != null) dur.push(`p(95)<${p95Ms}`);
  if (p99Ms != null) dur.push(`p(99)<${p99Ms}`);
  if (dur.length) t['http_req_duration'] = dur;
  t['http_req_failed'] = [`rate<${errorRate}`];
  return t;
}
```

### `tests/perf/lib/correlation.js`

```js
// Extract-then-inject helpers for dynamic values. A missing correlation value is a
// SCRIPT BUG — fail loudly rather than inject '' / undefined downstream.
import { check } from 'k6';

export function extractJson(res, path) {
  const value = res.json(path);
  const ok = value !== undefined && value !== null;
  check(res, { [`correlated ${path}`]: () => ok });
  if (!ok) throw new Error(`correlation failed: ${path} not present in response`);
  return value;
}

export function extractRegex(res, pattern) {
  const m = res.body.match(pattern);
  if (!m || m[1] === undefined) {
    throw new Error(`correlation failed: pattern ${pattern} did not match`);
  }
  return m[1];
}
```

### `tests/perf/lib/summary.js`

```js
// handleSummary() writes a machine-readable JSON summary the report + ledger feed consume.
// Do NOT parse k6 stdout — read tests/perf/results/<slug>.json instead.
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

export function writeSummary(slug) {
  return (data) => ({
    [`tests/perf/results/${slug}.json`]: JSON.stringify(data, null, 2),
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
  });
}
```

## Canonical scenario shape

```js
// tests/perf/scenarios/checkout.js — one scenario per file.
import http from 'k6/http';
import { sleep } from 'k6';
import { baseUrl, authHeaders } from '../lib/config.js';
import { load } from '../lib/profiles.js';
import { slo } from '../lib/thresholds.js';
import { writeSummary } from '../lib/summary.js';

export const options = {
  scenarios: { checkout: load },
  thresholds: slo({ p95Ms: 800, errorRate: 0.01 }),
};

export default function () {
  const res = http.get(`${baseUrl()}/api/products`, { headers: authHeaders() });
  sleep(1);
}

export const handleSummary = writeSummary('checkout');
```

## Running

- Smoke first: `k6 run -e PERF_BASE_URL=https://staging.example.com tests/perf/scenarios/checkout.js`
  (temporarily swap the profile to `smoke` for the 1-VU pass).
- Then the real profile. Exit code 0 = all thresholds held; non-zero = a breach (a finding).

## Future extensions (NOT v1)

k6 supports WebSocket (`k6/ws`), gRPC (`k6/net/grpc`), GraphQL (over `http`), and a browser
module (`k6/browser`). These are out of scope for v1 (HTTP/REST only) — noted here so the
boundary is explicit.
