// spec-lint fixture: untyped parameters used as framework objects in a verb (advisory)
// place: tests/e2e/flows/raw-flow.ts
// rules: TB-A14
export async function go(s: any) { await s.page.goto('/x'); } // EXPECT TB-A14/advisory
export async function goLoose(s) { return s._driver; } // EXPECT TB-A14/advisory
