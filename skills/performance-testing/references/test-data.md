# Test Data

## SharedArray — load once, share across VUs

Loading a data file per-VU multiplies memory by VU count. Use `SharedArray` so the data is
parsed once and shared read-only.

```js
import { SharedArray } from 'k6/data';

const users = new SharedArray('users', () => JSON.parse(open('./users.json')));

export default function () {
  const u = users[(__VU + __ITER) % users.length]; // deterministic per-VU/iter spread
  // ... use u.username / u.password
}
```

## Avoid cache-skew

Hitting the same id every iteration warms a cache and reports latency the real workload never
sees. Spread reads across the key space (`% users.length`, randomized ids within the valid
range). State the spread strategy in the report.

## Parameterize from env, not literals

Credentials and dataset paths come from `__ENV` (see `lib/config.js`), never inline literals
(Rules 2 and 7).

## Write-load data hygiene

A write-heavy load test (POST/PUT) creates real rows. Run against staging/sandbox only, and
note in the report that the run mutated data — coordinate cleanup or use a disposable dataset.
