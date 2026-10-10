const fs   = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { packageDir, projectRoot, homeDir } = require('./context.js');

// @playwright/cli is shipped as a hard dependency of this package, so skills
// that drive a live browser can rely on it after `npm install` with no
// further action from the consumer. Confirm reachability, then fetch the
// chromium browser binary on the consumer's behalf — install-browser is
// idempotent (no-ops when already cached at $PLAYWRIGHT_BROWSERS_PATH or
// the platform default), so the cost on subsequent installs is negligible.
//
// Opt-out: set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 (the Playwright-standard
// env var) to skip the browser fetch — useful for offline installs and
// container builds that mount a pre-warmed browser cache.

// The CLI is resolved from this package, not run through npx from projectRoot: in a
// global install projectRoot is npm's lib/, where npx finds no CLI.
function playwrightCliEntry() {
  try {
    const pkgJson = require.resolve('@playwright/cli/package.json', { paths: [packageDir, projectRoot] });
    const bin = JSON.parse(fs.readFileSync(pkgJson, 'utf8')).bin;
    return path.join(path.dirname(pkgJson), typeof bin === 'string' ? bin : bin['playwright-cli']);
  } catch (_) {
    return null;
  }
}

function runCli(entry, args, stdio) {
  return spawnSync(process.execPath, [entry, ...args], { cwd: packageDir, encoding: 'utf8', stdio });
}

// Resolve the playwright-core package directory (relative to the consumer's
// project root so we pick up the right hoisted copy) and return the parsed
// browsers.json, or null if it can't be found.
function readPlaywrightBrowsersJson() {
  try {
    // require.resolve('playwright-core') returns the main entry-point file;
    // dirname gives us the package root where browsers.json lives.
    const playwrightCoreMain = require.resolve('playwright-core', { paths: [packageDir, projectRoot] });
    const browsersJsonPath   = path.join(path.dirname(playwrightCoreMain), 'browsers.json');
    return JSON.parse(fs.readFileSync(browsersJsonPath, 'utf8'));
  } catch (_) {
    return null;
  }
}

// Return the directory where Playwright caches downloaded browser binaries.
// Respects PLAYWRIGHT_BROWSERS_PATH (same env var that playwright-core reads).
function playwrightBrowsersCacheDir() {
  const envPath = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (envPath && envPath !== '0') return envPath;

  const p = process.platform;
  if (p === 'darwin') return path.join(homeDir, 'Library', 'Caches', 'ms-playwright');
  if (p === 'linux')  return path.join(process.env.XDG_CACHE_HOME || path.join(homeDir, '.cache'), 'ms-playwright');
  // Windows
  return path.join(process.env.LOCALAPPDATA || path.join(homeDir, 'AppData', 'Local'), 'ms-playwright');
}

// Return true when the expected chromium revision is already present in the
// Playwright browser cache and the directory is non-empty (i.e. the download
// completed successfully on a previous install).
function chromiumAlreadyCached() {
  const browsersJson = readPlaywrightBrowsersJson();
  if (!browsersJson) return false;

  const chromiumEntry = (browsersJson.browsers || []).find(b => b.name === 'chromium');
  if (!chromiumEntry || !chromiumEntry.revision) return false;

  const chromiumDir = path.join(playwrightBrowsersCacheDir(), `chromium-${chromiumEntry.revision}`);
  if (!fs.existsSync(chromiumDir)) return false;

  // Confirm the directory isn't empty (guards against a partial/failed download
  // that left the folder in place without any actual browser contents).
  try {
    return fs.readdirSync(chromiumDir).length > 0;
  } catch (_) {
    return false;
  }
}

// Never fails the install: a non-zero postinstall makes npm remove the package, and
// with it achilles-uninstall, after the harness has already been written.
function installChromium() {
  const manual = 'Before driving a browser, run `npx playwright-cli install-browser chromium`.';
  const entry = playwrightCliEntry();
  const probe = entry && runCli(entry, ['--version'], ['ignore', 'pipe', 'ignore']);
  if (!probe || probe.status !== 0) {
    console.warn(`[@civitas-cerebrum/achilles] @playwright/cli not found beside this package; chromium was not fetched. ${manual}`);
    return;
  }
  const version = (probe.stdout || '').trim();
  if (process.env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD === '1') {
    console.log(`[@civitas-cerebrum/achilles] @playwright/cli ${version} reachable. Browser fetch skipped (PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1).`);
    return;
  }
  if (chromiumAlreadyCached()) {
    console.log(`[@civitas-cerebrum/achilles] @playwright/cli ${version} reachable. Chromium already cached — skipping download.`);
    return;
  }
  console.log(`[@civitas-cerebrum/achilles] @playwright/cli ${version} reachable. Ensuring chromium is installed…`);
  const browserInstall = runCli(entry, ['install-browser', 'chromium'], 'inherit');
  if (browserInstall.status === 0) {
    console.log('[@civitas-cerebrum/achilles] ✔ chromium ready (cached or freshly installed).');
  } else {
    console.warn(`[@civitas-cerebrum/achilles] chromium install exited with status ${browserInstall.status}. ${manual}`);
  }
}

module.exports = { installChromium };
