// The project root and rule file the factory tools share with hooks/lib/project-root.sh:
// $CLAUDE_PROJECT_DIR, else the current directory; $FACTORY_RULES (absolute, or relative to the root),
// else achilles-factory-rules.json.
import path from 'node:path';

export const DEFAULT_RULES_FILE = 'achilles-factory-rules.json';

export const projectRoot = () => path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());

export function rulesPath(root = projectRoot()) {
  const p = process.env.FACTORY_RULES || DEFAULT_RULES_FILE;
  return path.isAbsolute(p) ? p : path.join(root, p);
}
