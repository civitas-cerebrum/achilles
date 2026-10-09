const fs    = require('fs');
const path  = require('path');
const https = require('https');
const crypto = require('crypto');
const { userClaudeDir } = require('./context.js');

// Bundle a pinned `jq` binary alongside the harness hooks. The hooks parse
// JSON event payloads via jq; without it, every hook crashes with
// `jq: command not found` — silent non-blocking failures on PostToolUse,
// accept-all on PreToolUse. Closes #165.
//
// Approach (mirrors the @playwright/cli + chromium delivery idiom):
//   - Fetch jq 1.7.1 from the official jqlang/jq GitHub release.
//   - Check its sha256 against the pinned value, then land it at
//     ~/.claude/hooks/bin/jq (chmod +x). A mismatch deletes it unrun.
//   - Hooks resolve via `${BASH_SOURCE[0]}/bin/jq` with system-jq fallback
//     so the in-repo test suite still works before postinstall has run.
//
// Opt-out: set CIVITAS_SKIP_JQ_INSTALL=1 — useful for enterprise managed
// installs where postinstall scripts must not download external binaries.
const JQ_VERSION = '1.7.1';
// sha256 of each release asset, from https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt.
// A download is checked against this before it is made executable; it is never run unverified.
const JQ_SHA256 = {
  'jq-macos-arm64':       '0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a',
  'jq-macos-amd64':       '4155822bbf5ea90f5c79cf254665975eb4274d426d0709770c21774de5407443',
  'jq-linux-amd64':       '5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5',
  'jq-linux-arm64':       '4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5',
  'jq-windows-amd64.exe': '7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab',
};

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

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

// finalizeJq — move a downloaded jq into place only when its sha256 is the pinned one. On a mismatch the
// download is deleted without being made executable or run. Returns { ok, message }.
function finalizeJq(tmpPath, dest, expectedSha) {
  const got = sha256File(tmpPath);
  if (got !== expectedSha) {
    fs.unlinkSync(tmpPath);
    return { ok: false, message: `jq download failed its checksum (sha256 ${got}, expected ${expectedSha}); it was deleted, not run. Hooks will fall back to system jq.` };
  }
  fs.chmodSync(tmpPath, 0o755);
  fs.renameSync(tmpPath, dest); // atomic replace
  return { ok: true, message: `✔ Bundled jq ${JQ_VERSION} installed at ${dest} (sha256 verified).` };
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

  // Idempotent: the pinned binary is already in place.
  if (fs.existsSync(dest) && sha256File(dest) === JQ_SHA256[asset]) {
    console.log(`[civitas-cerebrum] Bundled jq ${JQ_VERSION} already present at ${dest}.`);
    return;
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
        const r = finalizeJq(tmpPath, dest, JQ_SHA256[asset]);
        if (r.ok) console.log(`[civitas-cerebrum] ${r.message}`);
        else { console.warn(`[civitas-cerebrum] ${r.message}`); process.exitCode = 1; }
      } catch (e) {
        try { fs.unlinkSync(tmpPath); } catch (_) { /* ignore */ }
        console.warn(`[civitas-cerebrum] Failed to finalize bundled jq at ${dest}: ${e.message}. Hooks will fall back to system jq.`);
        process.exitCode = 1;
      }
      resolve();
    });
  });
}

module.exports = { installBundledJq, finalizeJq };
