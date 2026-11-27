// spec-lint fixture: the fixtures module may import Playwright (it is not a spec)
// place: tests/e2e/fixtures/base.ts
// rules: TB-A7
import { test as base, expect } from '@playwright/test';
import { baseFixture } from '@civitas-cerebrum/element-interactions';

export const test = baseFixture(base, 'tests/e2e/page-repository.json');
export { expect };
