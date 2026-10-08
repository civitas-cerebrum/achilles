const fs    = require('fs');
const path  = require('path');
const https = require('https');
const { spawnSync } = require('child_process');
const { userClaudeDir } = require('./context.js');

// Bundle a pinned `jq` binary alongside the harness hooks. The hooks parse
// JSON event payloads via jq; without it, every hook crashes with
// `jq: command not found` — silent non-blocking failures on PostToolUse,
// accept-all on PreToolUse. Closes #165.
//
// Approach (mirrors the @playwright/cli + chromium delivery idiom):
//   - Fetch jq 1.7.1 from the official jqlang/jq GitHub release.
//   - Land it at ~/.claude/hooks/bin/jq (chmod +x).
//   - Hooks resolve via `${BASH_SOURCE[0]}/bin/jq` with system-jq fallback
//     so the in-repo test suite still works before postinstall has run.
//
// Opt-out: set CIVITAS_SKIP_JQ_INSTALL=1 — useful for enterprise managed
// installs where postinstall scripts must not download external binaries.
const JQ_VERSION = '1.7.1';
const JQ_MIN_SIZE_BYTES = 100 * 1024; // anything smaller is a truncated download

function jqAssetForPlatform() {
  const p = process.platform;
  const a = process.arch;
  if (p === 'darwin' && a === 'arm64') return 'jq-macos-arm64';
  if (p === 'darwin' && a === 'x64')   return 'jq-macos-amd64';
  if (p === 'linux'  && a === 'x64')   return 'jq-linux-amd64';
  if (p === 'linux'  && a === 'arm64') return 'jq-linux-arm64';
  if (p === 'win32'  && a === 'x64')   return 'jq-windows-amd64.exe';
  return null;
}

// GET with redirect-following. GitHub release-asset URLs respond 302 to a
// codeload / objects.githubusercontent.com CDN, so we follow up to a small
// number of hops. Resolves with an open IncomingMessage on the final 200.
function httpsGetFollow(url, hopsLeft, cb) {
  https.get(url, (res) => {
    const status = res.statusCode || 0;
    if ((status === 301 || status === 302 || status === 303 || status === 307 || status === 308) && res.headers.location) {
      res.resume();
      if (hopsLeft <= 0) return cb(new Error(`too many redirects fetching ${url}`));
      const next = new URL(res.headers.location, url).toString();
      return httpsGetFollow(next, hopsLeft - 1, cb);
    }
    if (status !== 200) {
      res.resume();
      return cb(new Error(`HTTP ${status} fetching ${url}`));
    }
    cb(null, res);
  }).on('error', cb);
}

function downloadToFile(url, destPath, done) {
  httpsGetFollow(url, 5, (err, res) => {
    if (err) return done(err);
    const tmp = destPath + '.part';
    const out = fs.createWriteStream(tmp);
    res.pipe(out);
    out.on('finish', () => out.close(() => done(null, tmp)));
    out.on('error', (e) => {
      try { fs.unlinkSync(tmp); } catch (_) { /* ignore */ }
      done(e);
    });
    res.on('error', (e) => {
      try { fs.unlinkSync(tmp); } catch (_) { /* ignore */ }
      done(e);
    });
  });
}

function jqVersionAtPath(jqPath) {
  try {
    const probe = spawnSync(jqPath, ['--version'], { encoding: 'utf8' });
    if (probe.status !== 0) return null;
    return (probe.stdout || '').trim();
  } catch (_) {
    return null;
  }
}

// claudeDir — same contract as installCivitasHooks(): the .claude/ base the
// jq binary lands under (<base>/hooks/bin/jq), defaulting to ~/.claude.
async function installBundledJq(claudeDir) {
  if (process.env.CIVITAS_SKIP_JQ_INSTALL === '1') {
    console.log('[civitas-cerebrum] CIVITAS_SKIP_JQ_INSTALL=1 — bundled jq install skipped.');
    return;
  }

  const asset = jqAssetForPlatform();
  if (!asset) {
    console.warn(`[civitas-cerebrum] No bundled jq available for ${process.platform}/${process.arch}. Hooks will fall back to system jq; install jq manually if it isn't already on PATH. See https://jqlang.github.io/jq/download/.`);
    process.exitCode = 1;
    return;
  }

  // Bundled binary is for consumer-side hooks at <claudeDir>/hooks/bin/jq
  // (hooks resolve it relative to their own location via BASH_SOURCE).
  // (postinstall.js exits before this in the package's own repo, so the
  // in-repo test suite always uses system jq via the hook fallback.)
  const userHooksDir = path.join(claudeDir || userClaudeDir, 'hooks');
  const binDir       = path.join(userHooksDir, 'bin');
  const dest         = path.join(binDir, process.platform === 'win32' ? 'jq.exe' : 'jq');

  // Idempotent: if already on the right version, skip.
  if (fs.existsSync(dest)) {
    const ver = jqVersionAtPath(dest);
    if (ver && ver === `jq-${JQ_VERSION}`) {
      console.log(`[civitas-cerebrum] Bundled jq ${ver} already present at ${dest}.`);
      return;
    }
  }

  fs.mkdirSync(binDir, { recursive: true });

  const url = `https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${asset}`;
  console.log(`[civitas-cerebrum] Fetching jq ${JQ_VERSION} (${asset}) → ${dest} …`);

  await new Promise((resolve) => {
    downloadToFile(url, dest, (err, tmpPath) => {
      if (err) {
        console.warn(`[civitas-cerebrum] Could not download jq from ${url}: ${err.message}. Hooks will fall back to system jq.`);
        process.exitCode = 1;
        return resolve();
      }
      try {
        const size = fs.statSync(tmpPath).size;
        if (size < JQ_MIN_SIZE_BYTES) {
          fs.unlinkSync(tmpPath);
          console.warn(`[civitas-cerebrum] jq download from ${url} was truncated (${size} bytes < ${JQ_MIN_SIZE_BYTES}). Aborting; hooks will fall back to system jq.`);
          process.exitCode = 1;
          return resolve();
        }
        fs.chmodSync(tmpPath, 0o755);
        fs.renameSync(tmpPath, dest); // atomic replace
        const ver = jqVersionAtPath(dest);
        if (!ver || ver !== `jq-${JQ_VERSION}`) {
          console.warn(`[civitas-cerebrum] Bundled jq landed at ${dest} but reports version '${ver || '(unknown)'}'. Hooks will still try the bundled path first.`);
          process.exitCode = 1;
        } else {
          console.log(`[civitas-cerebrum] ✔ Bundled jq ${ver} installed at ${dest}.`);
        }
      } catch (e) {
        try { fs.unlinkSync(tmpPath); } catch (_) { /* ignore */ }
        console.warn(`[civitas-cerebrum] Failed to finalize bundled jq at ${dest}: ${e.message}. Hooks will fall back to system jq.`);
        process.exitCode = 1;
      }
      resolve();
    });
  });
}

module.exports = { installBundledJq };
