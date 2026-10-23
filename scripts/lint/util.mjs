import { readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

export const SKILLS_DIR = 'skills';

// Check modules take this `report` and call it once per finding group.
export function makeReport() {
  const state = { failed: false };
  function report(title, ok, details) {
    console.log(`[${ok ? 'PASS' : 'FAIL'}] ${title}`);
    if (ok) return;
    state.failed = true;
    for (const line of details) console.log(`        ${line}`);
  }
  return { report, state };
}

// Recursively collect files under `root` matching a predicate.
export function walk(root, pred, acc = []) {
  for (const name of readdirSync(root)) {
    const full = join(root, name);
    if (statSync(full).isDirectory()) walk(full, pred, acc);
    else if (pred(full)) acc.push(full);
  }
  return acc;
}
