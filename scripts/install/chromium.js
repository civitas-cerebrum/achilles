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

function probePlaywrightCli() {
  const probe = spawnSync('npx', ['--no-install', 'playwright-cli', '--version'], {
    cwd: projectRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  return { ok: probe.status === 0, version: (probe.stdout || '').trim() };
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

function installChromium() {
  const cliProbe = probePlaywrightCli();
  if (!cliProbe.ok) {
    // Fail loudly — npm 7+ swallows postinstall stdout on success, but a
    // non-zero exit code surfaces the warning so the consumer learns
    // chromium was NOT fetched.
    console.warn('[@civitas-cerebrum/achilles] @playwright/cli not reachable via `npx`. The CLI is shipped as a dependency — re-run `npm install` if this is unexpected. Chromium was NOT fetched; subsequent skill activations may need to run `npx playwright-cli install-browser chromium` manually.');
    process.exitCode = 1;
    return;
  }
  if (process.env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD === '1') {
    console.log(`[@civitas-cerebrum/achilles] @playwright/cli ${cliProbe.version} reachable. Browser fetch skipped (PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1).`);
    return;
  }
  if (chromiumAlreadyCached()) {
    console.log(`[@civitas-cerebrum/achilles] @playwright/cli ${cliProbe.version} reachable. Chromium already cached — skipping download.`);
    return;
  }
  console.log(`[@civitas-cerebrum/achilles] @playwright/cli ${cliProbe.version} reachable. Ensuring chromium is installed…`);
  const browserInstall = spawnSync('npx', ['--no-install', 'playwright-cli', 'install-browser', 'chromium'], {
    cwd: projectRoot,
    stdio: 'inherit',
  });
  if (browserInstall.status === 0) {
    console.log('[@civitas-cerebrum/achilles] ✔ chromium ready (cached or freshly installed).');
  } else {
    console.warn(`[@civitas-cerebrum/achilles] chromium install exited with status ${browserInstall.status}. You may need to run \`npx playwright-cli install-browser chromium\` manually before driving a browser.`);
    process.exitCode = 1;
  }
}

module.exports = { installChromium };
