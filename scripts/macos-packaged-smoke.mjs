// Packaged-.app smoke test for CI (see .github/workflows/build.yml's macos
// job, which runs this right after `native:package:macos` so only a
// proven-good bundle gets signed/uploaded).
//
// Why this exists (issue #31): the macOS job previously proved compile (`zig
// build test`) plus bundle *structural* completeness (package-fixup.mjs's
// verifyMacos) but never actually launched the app -- it never bound the
// loopback file server or round-tripped a native bridge command, so a macOS
// binary that compiled and packaged yet crashed on boot would ship green. The
// windows job's smoke:packaged catches that on Windows via WebView2's CDP
// endpoint; WKWebView (the macOS system web engine) doesn't speak CDP and
// @native-sdk/cli 0.5.4 ships no equivalent automation hook, so this instead
// asserts the same bar through the app's own diagnostic log -- exactly the
// fallback path packaged-smoke.mjs already uses on newer WebView2 runtimes
// (verifyViaDiagnosticLog): app.start + bridge.dispatch + runtime.frame can
// only be emitted after the webview attached, the embedded assets served, JS
// ran, and src/App.tsx's getAppState() boot round-trip hit a native command.
// A blank shell or a boot-time page error produces zero bridge dispatches.
//
// Isolation: computeStorageRoot (src-zig/main.zig) and the Native SDK's own
// app dirs both derive from $HOME on macOS (~/Library/Application Support/...),
// so overriding HOME for the child fully redirects everything it reads or
// writes into a throwaway temp dir. The real ~/Library is never touched. The
// exact log subpath is SDK-internal, so this searches the isolated HOME for
// native-sdk.jsonl rather than hard-coding a path.
//
// macOS-only, and requires a GUI (windowserver) session so WKWebView can
// attach -- GitHub-hosted macos-latest runners provide one. If a future
// runner image stops doing so, this should be moved to a runner that does
// rather than downgraded to a no-op: a smoke that cannot fail proves nothing.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const packageDir = path.join(repoRoot, "zig-out", "package");

const READY_TIMEOUT_MS = 40000;
const POLL_INTERVAL_MS = 500;

function log(msg) {
  console.log(`[macos-smoke] ${msg}`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// The packager writes the bundle as the one directory under zig-out/package
// with a Contents/Info.plist (same discovery the build.yml sign step uses).
async function findAppBundle() {
  const entries = await readdir(packageDir, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const plist = path.join(packageDir, entry.name, "Contents", "Info.plist");
    if (existsSync(plist)) return path.join(packageDir, entry.name);
  }
  return null;
}

// The single Mach-O under Contents/MacOS is the app executable; launching it
// directly (rather than via `open`) lets us hand the child an overridden HOME.
async function findExecutable(appDir) {
  const macosDir = path.join(appDir, "Contents", "MacOS");
  const names = await readdir(macosDir).catch(() => []);
  for (const name of names) {
    const full = path.join(macosDir, name);
    const info = await stat(full).catch(() => null);
    if (info?.isFile()) return full;
  }
  return null;
}

// Recursively collect any native-sdk.jsonl under the isolated HOME.
async function findLogFiles(dir) {
  const out = [];
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...(await findLogFiles(full)));
    } else if (entry.name === "native-sdk.jsonl") {
      out.push(full);
    }
  }
  return out;
}

// Same bar the Windows CDP-fallback proves (packaged-smoke.mjs): the app
// started, completed at least one native bridge round-trip, and published at
// least one frame.
async function verifyViaDiagnosticLog(home) {
  const logPaths = await findLogFiles(home);
  const counts = { "app.start": 0, "bridge.dispatch": 0, "runtime.frame": 0 };
  for (const logPath of logPaths) {
    const text = await readFile(logPath, "utf8").catch(() => "");
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line);
        if (event.name in counts) counts[event.name] += 1;
      } catch {
        // partial trailing line from the just-killed writer -- ignore
      }
    }
  }
  return {
    ok: counts["app.start"] >= 1 && counts["bridge.dispatch"] >= 1 && counts["runtime.frame"] >= 1,
    counts,
    logPaths,
  };
}

async function main() {
  let child = null;
  let pass = false;
  let failReason = "";
  const home = await mkdtemp(path.join(os.tmpdir(), "maat-macos-smoke-"));

  try {
    const appDir = await findAppBundle();
    if (!appDir) {
      failReason = `no .app bundle found under ${packageDir} -- run "pnpm native:package:macos" first`;
    }

    let exePath = null;
    if (!failReason) {
      exePath = await findExecutable(appDir);
      if (!exePath) failReason = `no executable under ${path.join(appDir, "Contents", "MacOS")}`;
    }

    if (!failReason) {
      log(`launching ${exePath} with HOME=${home}`);
      child = spawn(exePath, [], {
        env: { ...process.env, HOME: home },
        stdio: "ignore",
      });
      let exitCode = null;
      child.on("exit", (code) => {
        exitCode = code;
        if (code !== 0 && code !== null) log(`app process exited early with code ${code}`);
      });

      const deadline = Date.now() + READY_TIMEOUT_MS;
      while (Date.now() < deadline) {
        const verdict = await verifyViaDiagnosticLog(home);
        if (verdict.ok) {
          pass = true;
          log(
            `verified via the app's diagnostic log: app started, ` +
              `${verdict.counts["bridge.dispatch"]} bridge round-trip(s), ` +
              `${verdict.counts["runtime.frame"]} frame(s) published.`,
          );
          break;
        }
        if (exitCode !== null && exitCode !== 0) {
          failReason = `app process exited with code ${exitCode} before completing a bridge round-trip`;
          break;
        }
        await sleep(POLL_INTERVAL_MS);
      }
      if (!pass && !failReason) {
        failReason = `app never completed a bridge round-trip within ${READY_TIMEOUT_MS}ms (blank-webview / boot-failure symptom)`;
      }
    }
  } catch (err) {
    failReason = failReason || `harness error: ${err}`;
  } finally {
    if (child?.pid) {
      try {
        process.kill(child.pid, "SIGKILL");
      } catch {
        // already gone
      }
    }
    // On failure, surface whatever the app did manage to log before deleting
    // the isolated HOME, so a boot failure on CI isn't just a bare timeout.
    if (!pass) {
      const logPaths = await findLogFiles(home);
      if (logPaths.length === 0) {
        log(`no native-sdk.jsonl under ${home} -- the app died before the Native SDK logger initialized`);
      }
      for (const logPath of logPaths) {
        const text = await readFile(logPath, "utf8").catch(() => "");
        if (!text.trim()) continue;
        log(`--- diagnostic log: ${logPath} ---`);
        console.log(text.trimEnd());
        log(`--- end ---`);
      }
    }
    await rm(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(() => {});
  }

  if (pass) {
    log("PASS: the packaged .app launched, booted the WebView UI, and completed a native bridge round-trip.");
    process.exit(0);
  } else {
    log(`FAIL: ${failReason}`);
    process.exit(1);
  }
}

main();
