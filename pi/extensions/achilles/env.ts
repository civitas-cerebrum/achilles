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

/** ACHILLES_PI_SKILL_CHILD_FULL_BELOW (chars, default 24000): the same threshold for a subagent.
 * A child's window holds only its own skill, so it can afford a more generous whole-body budget than
 * the orchestrator and a mid-size skill still arrives entire; above this it gets the same map. */
export const skillChildFullBelow = (): number => positiveInt('ACHILLES_PI_SKILL_CHILD_FULL_BELOW', 24000);

/** The whole-body threshold in force at the current depth: the orchestrator's, or a child's. */
export const fullBelow = (): number => (piDepth() === 0 ? skillFullBelow() : skillChildFullBelow());

/** ACHILLES_PI_SKILL_HEAD_MAX (chars, default 6000): the target size of a sectioned skill's map. */
export const skillHeadMax = (): number => positiveInt('ACHILLES_PI_SKILL_HEAD_MAX', 6000);

/** ACHILLES_PI_SECTION_MAX (chars, default 12000): a fetched section over this comes back as its own
 * prose plus a table of contents of its subsections, so no single fetch is enormous. A section with
 * no subsections, and an always-required rule block, are returned whole however big they are. */
export const sectionMax = (): number => positiveInt('ACHILLES_PI_SECTION_MAX', 12000);

/** ACHILLES_PI_REF_MAX (bytes, default 8000): a skill reference whose on-disk size exceeds this earns
 * a steer note. It is compared against a stat size, so the unit is bytes, not chars. */
export const refMax = (): number => positiveInt('ACHILLES_PI_REF_MAX', 8000);

/** True when ACHILLES_PI_VERBOSE=1 turns every context compaction off. */
export const piVerbose = (): boolean => process.env.ACHILLES_PI_VERBOSE === '1';
