/** Subagent nesting depth from ACHILLES_PI_DEPTH. Anything unparseable or negative counts as 0 (the orchestrator). */
export function piDepth(): number {
  const n = Number(process.env.ACHILLES_PI_DEPTH ?? '0');
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

/** A positive integer env var, or `fallback` when it is unset, unparseable or non-positive. */
function positiveInt(name: string, fallback: number): number {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

/** ACHILLES_PI_SKILL_FULL_BELOW (chars, default 12000): a skill body under this is returned whole. */
export const skillFullBelow = (): number => positiveInt('ACHILLES_PI_SKILL_FULL_BELOW', 12000);

/** ACHILLES_PI_SKILL_HEAD_MAX (chars, default 6000): the target size of a sectioned skill's map. */
export const skillHeadMax = (): number => positiveInt('ACHILLES_PI_SKILL_HEAD_MAX', 6000);

/** ACHILLES_PI_REF_MAX (chars, default 8000): a skill reference bigger than this earns a steer note. */
export const refMax = (): number => positiveInt('ACHILLES_PI_REF_MAX', 8000);

/** True when ACHILLES_PI_VERBOSE=1 turns every context compaction off. */
export const piVerbose = (): boolean => process.env.ACHILLES_PI_VERBOSE === '1';
