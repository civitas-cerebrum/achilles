/** Subagent nesting depth from ACHILLES_PI_DEPTH. Anything unparseable or negative counts as 0 (the orchestrator). */
export function piDepth(): number {
  const n = Number(process.env.ACHILLES_PI_DEPTH ?? '0');
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}
