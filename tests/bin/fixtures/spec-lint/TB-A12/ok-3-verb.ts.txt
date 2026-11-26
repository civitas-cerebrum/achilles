// spec-lint fixture: a verb over steps
// place: tests/e2e/flows/login-flow.ts
// rules: TB-A12
import type { Steps } from '@civitas-cerebrum/element-interactions';

export async function signIn(steps: Steps, email: string, password: string) {
  await steps.fill('emailInput', 'LoginPage', email);
  await steps.fill('passwordInput', 'LoginPage', password);
  await steps.click('submitButton', 'LoginPage');
}
