// Packaged-artifact smoke test for CI (see .github/workflows/build.yml's
// windows job, which runs this between `pnpm run native:package` and
// uploading the artifact so only a proven-good artifact gets uploaded).
//
// Unlike scripts/native-smoke.mjs -- which drives `native dev` (the local
// dev-mode shell, not meant for CI) -- this launches the actual packaged
// bin/maat-native.exe produced by the packager, from its own bin/
// directory, the same way a user double-clicking the shipped exe would.
// It proves the shipped artifact itself boots: WebView2 attaches (not the
// "blank white shell" bug -- see build.zig's linkPlatform windows/system
// comments), the frontend assets packaged alongside the exe are found (not
// the "missing dist/" packaging gap scripts/package-fixup.mjs works around),
// the board UI renders, and the native bridge answers its startup call.
//
// Bridge round-trip: src/App.tsx's boot effect calls getAppState(), which
// invokes the "list_boards_state" native command (src/lib/bridge.ts) before
// the canvas can render real board data. A rendered board canvas with a
// non-empty #root and no page errors therefore already proves the round
// trip succeeded -- a broken bridge would surface as either a rejected
// promise (page error) or a canvas stuck without ever appearing.
//
// Windows-only, requires a real GUI session with the WebView2 Runtime
// installed (see the workflow comment for why windows-latest is expected
// to provide both, and the self-hosted-runner fallback if it ever doesn't).
import { chromium } from "@playwright/test";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const packageRoot = path.join(repoRoot, "zig-out", "package");

// Distinct from native-smoke.mjs's 9412 so the two scripts could in
// principle run back-to-back without a leftover listener on the port.
const CDP_PORT = 9413;
const CDP_URL = `http://127.0.0.1:${CDP_PORT}`;
const BOARD_TESTID = "maat-canvas";
const READY_TIMEOUT_MS = 30000;

function log(msg) {
  console.log(`[packaged-smoke] ${msg}`);
}

function runToCompletion(command, args) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, { stdio: "ignore" });
    proc.on("error", () => resolve());
    proc.on("exit", () => resolve());
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Finds the packaged Windows bin/ dir the same way scripts/package-fixup.mjs
// does: `native package --target windows`'s output directory name isn't
// fixed, so locate it by its package-manifest.zon's `.target = "windows"`.
async function findWindowsPackageBinDir() {
  const entries = await readdir(packageRoot, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const manifestPath = path.join(packageRoot, entry.name, "package-manifest.zon");
    if (!existsSync(manifestPath)) continue;
    const manifest = await readFile(manifestPath, "utf8");
    if (/\.target\s*=\s*"windows"/.test(manifest)) {
      return path.join(packageRoot, entry.name, "bin");
    }
  }
  throw new Error(`no windows package-manifest.zon found under ${packageRoot} -- run "pnpm run native:package" first`);
}

async function waitForCdp(deadline) {
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${CDP_URL}/json/version`);
      if (res.ok) return true;
    } catch {
      // not up yet
    }
    await sleep(300);
  }
  return false;
}

// The packaged exe computes its catalog storage root (%APPDATA%\MaatNative,
// src-zig/main.zig's computeStorageRoot) and the Native SDK computes its own
// per-app State dir (%LOCALAPPDATA%\<bundle id>\State, window geometry etc.
// -- see native-smoke.mjs's resetPriorRunState for the same path) both by
// reading the APPDATA/LOCALAPPDATA env vars directly, not via
// SHGetKnownFolderPath. Overriding those two env vars for the child process
// is therefore enough to fully redirect everything this app reads or writes
// on disk, so a fresh isolated temp dir stands in for the real user profile
// -- the real %APPDATA%\MaatNative and %LOCALAPPDATA%\com.lzitser.maat-native
// are never read from or written to by this script.
async function createIsolatedAppDataDir() {
  const root = await mkdtemp(path.join(os.tmpdir(), "maat-packaged-smoke-"));
  const roaming = path.join(root, "AppData", "Roaming");
  const local = path.join(root, "AppData", "Local");
  await mkdir(roaming, { recursive: true });
  await mkdir(local, { recursive: true });
  return { root, roaming, local };
}

async function main() {
  let child = null;
  let pass = false;
  let failReason = "";
  const appDataDir = await createIsolatedAppDataDir();

  try {
    const binDir = await findWindowsPackageBinDir();
    const exePath = path.join(binDir, "maat-native.exe");
    const loaderPath = path.join(binDir, "WebView2Loader.dll");
    const distIndexPath = path.join(binDir, "dist", "index.html");

    if (!existsSync(exePath)) {
      failReason = `packaged exe not found at ${exePath} -- run "pnpm run native:package" first`;
    } else if (!existsSync(loaderPath)) {
      // The exact gap this script exists to catch: package-fixup.mjs copies
      // WebView2Loader.dll next to the exe because the upstream packager
      // doesn't (see its own header comment) -- without it, WebView2 never
      // attaches and the window is a blank shell with nothing logged.
      failReason = `missing WebView2Loader.dll next to the packaged exe (${loaderPath}) -- WebView2 cannot load`;
    } else if (!existsSync(distIndexPath)) {
      // The other gap package-fixup.mjs works around: the packager writes
      // frontend files to resources/dist, but the packaged exe resolves
      // frontend.dist relative to its own bin/ working directory.
      failReason = `missing packaged frontend assets (${distIndexPath}) -- the packager didn't ship dist/ next to the exe`;
    }

    if (!failReason) {
      log(`launching packaged artifact: ${exePath}`);
      child = spawn(exePath, [], {
        cwd: binDir,
        env: {
          ...process.env,
          APPDATA: appDataDir.roaming,
          LOCALAPPDATA: appDataDir.local,
          WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${CDP_PORT}`,
        },
        stdio: "ignore",
      });

      let exitedEarly = false;
      child.on("exit", (code) => {
        exitedEarly = true;
        if (code !== 0 && code !== null) log(`app process exited early with code ${code}`);
      });

      const deadline = Date.now() + READY_TIMEOUT_MS;
      const cdpUp = await waitForCdp(deadline);
      if (!cdpUp) {
        failReason = `CDP endpoint never came up at ${CDP_URL} within ${READY_TIMEOUT_MS}ms (blank WebView / launch-failure symptom)`;
      } else if (exitedEarly) {
        failReason = "app process exited before CDP came up";
      } else {
        const browser = await chromium.connectOverCDP(CDP_URL);
        // The CDP endpoint can come up before WebView2 creates its first
        // page (seen on slower CI runners) -- poll instead of failing on
        // the first look.
        let page = null;
        const pageDeadline = Date.now() + 30_000;
        while (Date.now() < pageDeadline) {
          page = browser.contexts()[0]?.pages()[0] ?? null;
          if (page) break;
          await new Promise((resolve) => setTimeout(resolve, 500));
        }
        if (!page) {
          failReason = "connected over CDP but found no page within 30s (blank WebView)";
        } else {
          const pageErrors = [];
          page.on("pageerror", (err) => pageErrors.push(String(err)));

          try {
            await page.waitForSelector(`[data-testid="${BOARD_TESTID}"]`, {
              state: "visible",
              timeout: Math.max(1000, deadline - Date.now()),
            });
            const rootChildren = await page.evaluate(() => document.getElementById("root")?.children.length ?? 0);
            if (rootChildren < 1) {
              failReason = "#root is empty even though the canvas selector resolved";
            } else if (pageErrors.length > 0) {
              failReason = `page errors during load (possible native bridge round-trip failure): ${pageErrors.join(" | ")}`;
            } else {
              pass = true;
            }
          } catch (err) {
            failReason = `board canvas [data-testid="${BOARD_TESTID}"] never appeared (blank/white-screen symptom): ${err}`;
          }
        }
        await browser.close().catch(() => {});
      }
    }
  } catch (err) {
    failReason = failReason || `harness error: ${err}`;
  } finally {
    // Cleanup runs on both success and failure: kill only the PID tree this
    // script itself spawned, then delete the isolated temp AppData dir.
    // There is deliberately no image-name sweep (`taskkill /F /IM
    // maat-native.exe`) here -- that would kill every maat-native.exe on the
    // machine, including an unrelated real running instance of the app, and
    // isn't needed anyway since nothing here spawns the exe inside its own
    // detached process group (contrast native-smoke.mjs's `native dev`,
    // which does). The real %APPDATA%\MaatNative and
    // %LOCALAPPDATA%\com.lzitser.maat-native are never touched by this
    // script.
    if (child?.pid) {
      await runToCompletion("taskkill", ["/PID", String(child.pid), "/T", "/F"]);
    }
    // maxRetries/retryDelay: right after `taskkill`, the just-killed exe can
    // still hold a handle open (sqlite WAL file, log file) for a brief
    // moment on Windows -- an immediate `rm` can hit EBUSY/EPERM and,
    // without a retry, silently leave the temp dir behind (`.catch(() =>
    // {})` below exists so a genuinely-stuck handle doesn't fail the whole
    // smoke run, not to paper over an ordinary race that a short retry
    // clears).
    await rm(appDataDir.root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(() => {});
  }

  if (pass) {
    log("PASS: the packaged artifact launched, rendered the Maat board UI, and completed a native bridge round-trip.");
    process.exit(0);
  } else {
    log(`FAIL: ${failReason}`);
    process.exit(1);
  }
}

main();
