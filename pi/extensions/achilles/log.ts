import fs from 'node:fs';
/** Append one JSON line to $ACHILLES_PI_LOG when set. Used by live tests and for support. */
export function log(kind: string, data: Record<string, unknown>): void {
  const file = process.env.ACHILLES_PI_LOG;
  if (!file) return;
  try { fs.appendFileSync(file, JSON.stringify({ t: Date.now(), kind, ...data }) + '\n'); } catch { /* never throw from logging */ }
}
