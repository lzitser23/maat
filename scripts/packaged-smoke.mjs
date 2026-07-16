// Portable-exe smoke test for CI (see .github/workflows/build.yml's
// windows job, which runs this between `zig build -Doptimize=ReleaseFast`
// and uploading the artifact so only a proven-good exe gets uploaded).
//
// Unlike scripts/native-smoke.mjs -- which drives `native dev` (the local
// dev-mode shell, not meant for CI) -- this proves the portability claim
// itself: it copies JUST zig-out/bin/maat-native.exe into a fresh empty
// temp directory and launches it from there, the same way a user
// double-clicking a downloaded exe would. No WebView2Loader.dll sibling
// (the exe stages its own embedded copy -- runner.zig's
// stageWebView2Loader), no dist/ sibling (the frontend build is embedded
// and served by src-zig/embedded_frontend_server.zig), and the working
// directory is an empty dir so the SDK's old CWD-relative dist/ resolution
// couldn't accidentally find the repo checkout's dist/ and mask a
// regression. It then asserts the exe actually boots: WebView2 attaches
// (not the "blank white shell" bug -- see build.zig's linkPlatform
// windows/system comments), the embedded frontend serves, the board UI
// renders, and the native bridge answers its startup call.
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
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { copyFile, mkdir, mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const builtExePath = path.join(repoRoot, "zig-out", "bin", "maat-native.exe");

// Distinct from native-smoke.mjs's 9412 so the two scripts could in
// principle run back-to-back without a leftover listener on the port.
const CDP_PORT = 9413;
// Both loopback literals: the WebView2 Runtime on newer windows-latest
// images (first seen on win25-vs2026/20260714.173) brings the CDP listener
// up on IPv6 [::1] without a 127.0.0.1 IPv4 counterpart, while older
// runtimes bind IPv4 -- the app itself is healthy either way (its
// diagnostic log shows frames + bridge round-trips), so poll both instead
// of hard-failing on the IPv4-only assumption.
const CDP_URLS = [`http://127.0.0.1:${CDP_PORT}`, `http://[::1]:${CDP_PORT}`];
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

async function waitForCdp(deadline) {
  while (Date.now() < deadline) {
    for (const url of CDP_URLS) {
      try {
        const res = await fetch(`${url}/json/version`);
        if (res.ok) return url;
      } catch {
        // not up yet on this loopback literal
      }
    }
    await sleep(300);
  }
  return null;
}

// Failure forensics: shows whether anything is listening on the CDP port at
// all, and on which loopback literal/address family -- distinguishes "the
// runtime ignored --remote-debugging-port entirely" from "it bound the port
// somewhere this script didn't poll".
function dumpCdpListeners() {
  return new Promise((resolve) => {
    execFile("netstat", ["-ano"], { windowsHide: true, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => {
      const lines = (stdout || "").split("\n").filter((l) => l.includes(`:${CDP_PORT} `));
      if (lines.length === 0) {
        log(`no listener on :${CDP_PORT} at failure time (debug arg likely ignored by this WebView2 runtime)`);
      } else {
        log(`sockets on :${CDP_PORT} at failure time:`);
        for (const l of lines) console.log(l.trimEnd());
      }
      resolve();
    });
  });
}

// The exe computes its catalog storage root (%APPDATA%\MaatNative,
// src-zig/main.zig's computeStorageRoot) and the Native SDK computes its own
// per-app State dir (%LOCALAPPDATA%\<bundle id>\State, window geometry etc.
// -- see native-smoke.mjs's resetPriorRunState for the same path) both by
// reading the APPDATA/LOCALAPPDATA env vars directly, not via
// SHGetKnownFolderPath -- and runner.zig's stageWebView2Loader reads
// LOCALAPPDATA the same way for its staged-DLL directory. Overriding those
// two env vars for the child process is therefore enough to fully redirect
// everything this app reads or writes on disk (including the staged
// loader), so a fresh isolated temp dir stands in for the real user profile
// -- the real %APPDATA%\MaatNative and %LOCALAPPDATA%\com.lzitser.maat-native
// are never read from or written to by this script. The isolation also
// makes the DLL staging itself part of what this smoke proves: there is no
// pre-staged loader in the isolated profile for the exe to coast on.
async function createIsolatedAppDataDir() {
  const root = await mkdtemp(path.join(os.tmpdir(), "maat-packaged-smoke-"));
  const roaming = path.join(root, "AppData", "Roaming");
  const local = path.join(root, "AppData", "Local");
  await mkdir(roaming, { recursive: true });
  await mkdir(local, { recursive: true });
  return { root, roaming, local };
}

// The portability proof: a fresh empty directory holding nothing but a copy
// of the built exe. Launching from here (as both cwd and location) means
// any lingering dependence on sibling files -- dist/, WebView2Loader.dll,
// or anything else in zig-out/bin or the repo checkout -- fails the smoke
// instead of hiding behind the developer's working tree.
async function createIsolatedExeDir() {
  const dir = await mkdtemp(path.join(os.tmpdir(), "maat-portable-exe-"));
  const exePath = path.join(dir, "maat-native.exe");
  await copyFile(builtExePath, exePath);
  return { dir, exePath };
}

async function main() {
  let child = null;
  let pass = false;
  let failReason = "";
  let exeDir = null;
  const appDataDir = await createIsolatedAppDataDir();

  try {
    if (!existsSync(builtExePath)) {
      failReason = `portable exe not found at ${builtExePath} -- run "pnpm build" then "zig build -Doptimize=ReleaseFast" first`;
    }

    if (!failReason) {
      exeDir = await createIsolatedExeDir();
      log(`launching portable exe in isolation: ${exeDir.exePath}`);
      child = spawn(exeDir.exePath, [], {
        cwd: exeDir.dir,
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
      const cdpUrl = await waitForCdp(deadline);
      if (!cdpUrl) {
        failReason = `CDP endpoint never came up at ${CDP_URLS.join(" or ")} within ${READY_TIMEOUT_MS}ms (blank WebView / launch-failure symptom)`;
      } else if (exitedEarly) {
        failReason = "app process exited before CDP came up";
      } else {
        const browser = await chromium.connectOverCDP(cdpUrl);
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
    // script itself spawned, then delete the isolated temp dirs.
    // There is deliberately no image-name sweep (`taskkill /F /IM
    // maat-native.exe`) here -- that would kill every maat-native.exe on the
    // machine, including an unrelated real running instance of the app, and
    // isn't needed anyway since nothing here spawns the exe inside its own
    // detached process group (contrast native-smoke.mjs's `native dev`,
    // which does). The real %APPDATA%\MaatNative and
    // %LOCALAPPDATA%\com.lzitser.maat-native are never touched by this
    // script.
    if (!pass && child?.pid) {
      await dumpCdpListeners();
    }
    if (child?.pid) {
      await runToCompletion("taskkill", ["/PID", String(child.pid), "/T", "/F"]);
    }
    // On failure, surface the app's own diagnostic logs before the isolated
    // dir is deleted below -- without this, a launch failure on CI reduces
    // to the bare "CDP endpoint never came up" symptom with no way to see
    // why (e.g. which WebView2 environment-creation step failed).
    if (!pass) {
      const logsDir = path.join(appDataDir.local, "com.lzitser.maat-native", "Logs");
      const logNames = await readdir(logsDir).catch(() => []);
      if (logNames.length === 0) {
        log(`no diagnostic logs under ${logsDir} -- the app died before the Native SDK logger initialized`);
      }
      for (const name of logNames) {
        const text = await readFile(path.join(logsDir, name), "utf8").catch(() => "");
        if (!text.trim()) continue;
        log(`--- diagnostic log: ${name} ---`);
        console.log(text.trimEnd());
        log(`--- end: ${name} ---`);
      }
    }
    // maxRetries/retryDelay: right after `taskkill`, the just-killed exe can
    // still hold a handle open (sqlite WAL file, log file, its own image
    // file in the exe dir) for a brief moment on Windows -- an immediate
    // `rm` can hit EBUSY/EPERM and, without a retry, silently leave the
    // temp dir behind (`.catch(() => {})` below exists so a genuinely-stuck
    // handle doesn't fail the whole smoke run, not to paper over an
    // ordinary race that a short retry clears).
    await rm(appDataDir.root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(() => {});
    if (exeDir) {
      await rm(exeDir.dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(() => {});
    }
  }

  if (pass) {
    log("PASS: the portable exe launched alone from an empty directory, rendered the Maat board UI, and completed a native bridge round-trip.");
    process.exit(0);
  } else {
    log(`FAIL: ${failReason}`);
    process.exit(1);
  }
}

main();
