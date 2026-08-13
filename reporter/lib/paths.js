'use strict';
// paths.js — project root and artifact-path resolution.
//
// The reporter receives the RESOLVED config, so `outputDir` and the reporter
// output paths are read rather than guessed. `config.rootDir` is the common
// root of the test directories, NOT the project root, so it is deliberately
// not used as an anchor: the anchor is the config file's directory, then the
// nearest enclosing git work tree.

const fs = require('node:fs');
const path = require('node:path');

/** Project root: nearest git work tree above the config, else the config dir. */
function projectRoot(config, cwd) {
  const start = (config && config.configFile) ? path.dirname(config.configFile) : (cwd || process.cwd());
  let dir = path.resolve(start);
  for (;;) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
    const up = path.dirname(dir);
    if (up === dir) return path.resolve(start);
    dir = up;
  }
}

/** Relative POSIX path under `root`, or null when the path escapes the root. */
function relToRoot(root, target) {
  const rel = path.relative(root, path.resolve(root, target));
  if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return rel.split(path.sep).join('/');
}

function reporterEntries(config) {
  const list = (config && config.reporter) || [];
  return Array.isArray(list) ? list : [];
}

function reporterOptions(config, name) {
  for (const entry of reporterEntries(config)) {
    const id = Array.isArray(entry) ? entry[0] : entry;
    const opts = Array.isArray(entry) ? entry[1] : undefined;
    if (typeof id === 'string' && (id === name || id.endsWith(`/${name}`))) return opts || {};
  }
  return null;
}

/**
 * The set of paths a run writes, in the same shape the archiver hook derives by
 * grepping the config — but resolved rather than grepped, so a computed
 * `outputDir` lands here too. Non-existent paths, paths outside the project
 * root, and paths nested inside another candidate are dropped, mirroring the
 * hook's candidate rules so the two agree on what "this run's artifacts" means.
 */
function resolveCandidates(config, root, env) {
  const e = env || process.env;
  const anchor = (config && config.configFile) ? path.dirname(config.configFile) : root;
  const out = [];

  const add = (abs, kind, resolvedFrom) => {
    if (!abs) return;
    const rel = relToRoot(root, abs);
    if (!rel) return;
    if (!fs.existsSync(path.join(root, rel))) return;
    for (const existing of out) {
      if (existing.path === rel) return;
      if (rel.startsWith(`${existing.path}/`)) return;
    }
    out.push({ path: rel, kind, resolvedFrom });
  };

  for (const project of (config && config.projects) || []) {
    if (project && project.outputDir) {
      add(project.outputDir, 'outputDir', `config:projects[${project.name || ''}].outputDir`);
    }
  }

  const html = reporterOptions(config, 'html');
  if (html) {
    const folder = html.outputFolder || e.PLAYWRIGHT_HTML_REPORT || 'playwright-report';
    add(path.resolve(anchor, folder), 'htmlReport', html.outputFolder ? 'config:reporter.html.outputFolder' : 'default');
  }

  const json = reporterOptions(config, 'json');
  if (json) {
    const file = json.outputFile || e.PLAYWRIGHT_JSON_OUTPUT_NAME;
    if (file) add(path.resolve(anchor, file), 'jsonReport', json.outputFile ? 'config:reporter.json.outputFile' : 'env:PLAYWRIGHT_JSON_OUTPUT_NAME');
  }

  const junit = reporterOptions(config, 'junit');
  if (junit) {
    const file = junit.outputFile || e.PLAYWRIGHT_JUNIT_OUTPUT_NAME;
    if (file) add(path.resolve(anchor, file), 'junitReport', junit.outputFile ? 'config:reporter.junit.outputFile' : 'env:PLAYWRIGHT_JUNIT_OUTPUT_NAME');
  }

  return out;
}

/** Size/count/newest-mtime for one path (mtime in whole seconds, like stat(1)). */
function statPath(root, rel) {
  let files = 0;
  let bytes = 0;
  let newest = 0;
  const visit = (abs) => {
    let st;
    try { st = fs.lstatSync(abs); } catch { return; }
    if (st.isSymbolicLink()) return;
    if (st.isDirectory()) {
      let entries = [];
      try { entries = fs.readdirSync(abs); } catch { return; }
      for (const name of entries) visit(path.join(abs, name));
      return;
    }
    if (!st.isFile()) return;
    files += 1;
    bytes += st.size;
    const secs = Math.floor(st.mtimeMs / 1000);
    if (secs > newest) newest = secs;
  };
  visit(path.join(root, rel));
  return { files, bytes, newestMtime: newest };
}

/**
 * Per-path stats plus the aggregate. Per-path is what the archiver hook checks:
 * it resolves its own candidate set by grepping the config, which can be a
 * SUBSET of what the reporter resolved (a computed `outputDir` is invisible to
 * a grep). Comparing path by path lets the hook confirm that everything IT can
 * see is already covered, instead of demanding the two sets be identical.
 */
function statCandidates(root, candidates) {
  const byPath = {};
  let files = 0;
  let bytes = 0;
  let newest = 0;
  for (const c of candidates) {
    const stats = statPath(root, c.path);
    byPath[c.path] = stats;
    files += stats.files;
    bytes += stats.bytes;
    if (stats.newestMtime > newest) newest = stats.newestMtime;
  }
  return { files, bytes, newestMtime: newest, byPath };
}

module.exports = { projectRoot, relToRoot, resolveCandidates, statPath, statCandidates, reporterOptions };
