// Regression smoke test for the "native:dev opens a blank white WebView2
// shell" bug (see build.zig's linkPlatform windows/system comments for the
// root cause: WebView2.h/WebView2Loader.dll/wrl.h weren't wired into the
// build, so the whole embedded-WebView layer silently compiled to a no-op
// stub -- the window opened, but no WebView2 control ever attached, and
// nothing was logged).
//
// This launches `native dev --yes` for real (the exact command
// `pnpm run native:dev` runs), attaches to the app's WebView2 instance over
// the Chrome DevTools Protocol, and asserts the actual Maat board UI
// rendered -- not just that the process started or the Zig bridge
// responds (native automate bridge already covers that, and would have
// stayed green throughout this bug).
//
// Windows-only, requires a real GUI session (WebView2 needs a desktop) --
// not meant for CI, run it locally: `pnpm run smoke:native`.
import { chromium } from "@playwright/test";
import { spawn } from "node:child_process";
import { access, copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

function runToCompletion(command, args) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, { stdio: "ignore" });
    proc.on("error", () => resolve());
    proc.on("exit", () => resolve());
  });
}

// Runs a PowerShell one-liner and returns its trimmed stdout. Used for the
// window-behavior assertions below: Playwright/CDP only sees the WebView2
// content, not the native window frame, so reading/moving the actual HWND
// goes through plain Win32 calls via a child powershell.exe process.
function runPowerShellCapture(script) {
  return new Promise((resolve, reject) => {
    const proc = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk) => (stdout += chunk));
    proc.stderr.on("data", (chunk) => (stderr += chunk));
    proc.on("error", reject);
    proc.on("exit", (code) => {
      if (code !== 0) return reject(new Error(`powershell exited ${code}: ${stderr}`));
      resolve(stdout.trim());
    });
  });
}

// Finds the app's own top-level window by process id + Win32 class name
// ("NativeSdkWindowsHost", the class webview2_host.cpp registers for
// every window it creates) and prints its screen rect as
// "left,top,width,height". Title matching alone is NOT reliable here:
// Windows can leave a same-titled "ghost window" placeholder behind
// briefly after a process exits (classic symptom: rect pinned at
// (-32000,-32000)), and this script itself launches/kills the app
// repeatedly across runs. Errors (window not found) print "NOTFOUND"
// instead of throwing, so the caller can report a clean reason.
function findWindowRectPs(pid) {
  return `
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class NativeSmokeWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
$target = $null
$cb = {
  param($h, $l)
  $procId = 0
  [NativeSmokeWin32]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
  if ($procId -ne ${pid} -or -not [NativeSmokeWin32]::IsWindowVisible($h)) { return $true }
  $sb = New-Object System.Text.StringBuilder 256
  [NativeSmokeWin32]::GetClassName($h, $sb, 256) | Out-Null
  if ($sb.ToString() -eq "NativeSdkWindowsHost") { $script:target = $h; return $false }
  return $true
}
[NativeSmokeWin32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if (-not $target) { Write-Output "NOTFOUND"; exit 0 }
`;
}

function findWindowRectScript(pid) {
  return (
    findWindowRectPs(pid) +
    `
$rect = New-Object NativeSmokeWin32+RECT
[NativeSmokeWin32]::GetWindowRect($target, [ref]$rect) | Out-Null
Write-Output "$($rect.Left),$($rect.Top),$($rect.Right-$rect.Left),$($rect.Bottom-$rect.Top)"
`
  );
}

function moveWindowScript(pid, x, y, width, height) {
  return (
    findWindowRectPs(pid) +
    `
[NativeSmokeWin32]::SetWindowPos($target, [IntPtr]::Zero, ${x}, ${y}, ${width}, ${height}, 0x0004 -bor 0x0010) | Out-Null
$rect = New-Object NativeSmokeWin32+RECT
[NativeSmokeWin32]::GetWindowRect($target, [ref]$rect) | Out-Null
Write-Output "$($rect.Left),$($rect.Top),$($rect.Right-$rect.Left),$($rect.Bottom-$rect.Top)"
`
  );
}

// Resolves the maat-native.exe process id, polling briefly since the
// binary is spawned by `native dev`'s own child process tree and may not
// exist for the first instant after the CDP endpoint comes up.
async function findAppPid(deadline) {
  while (Date.now() < deadline) {
    const output = await runPowerShellCapture(
      "(Get-Process -Name maat-native -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id)",
    ).catch(() => "");
    const pid = Number.parseInt(output, 10);
    if (!Number.isNaN(pid)) return pid;
    await sleep(300);
  }
  return null;
}

function parseRect(output) {
  if (output === "NOTFOUND") return null;
  const parts = output.split(",").map((n) => Number.parseInt(n, 10));
  if (parts.length !== 4 || parts.some((n) => Number.isNaN(n))) return null;
  const [left, top, width, height] = parts;
  return { left, top, width, height };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Asserts the "act like a normal window" behavior: the window must not
// spawn pinned at the screen origin (see app.zon's restore_policy), and an
// external resize/move (a window tiler, Win32 SetWindowPos, the user
// dragging it) must stick -- nothing in the app should reassert the old
// frame afterwards. Takes the already-discovered maat-native.exe pid
// (main() hoists the findAppPid call so the same pid is also available to
// cleanup()) instead of re-resolving it here.
async function assertWindowBehavior(pid) {
  if (!pid) return "window-behavior: could not find the maat-native.exe process";

  const startRect = parseRect(await runPowerShellCapture(findWindowRectScript(pid)));
  if (!startRect) return "window-behavior: could not find the app's own top-level window";
  if (startRect.left === 0 && startRect.top === 0) {
    return `window-behavior: window spawned pinned at (0,0) instead of centered (rect=${JSON.stringify(startRect)})`;
  }
  log(`window-behavior: startup rect = ${JSON.stringify(startRect)} (not pinned at 0,0, good)`);

  // Pick a size/position that's clearly different from both the startup
  // frame and (0,0), so a snap-back to either is unambiguous.
  const targetRect = { x: 40, y: 40, width: 1000, height: 700 };
  const movedRect = parseRect(
    await runPowerShellCapture(moveWindowScript(pid, targetRect.x, targetRect.y, targetRect.width, targetRect.height)),
  );
  if (!movedRect) return "window-behavior: SetWindowPos test could not find the window";
  if (movedRect.left !== targetRect.x || movedRect.top !== targetRect.y || movedRect.width !== targetRect.width || movedRect.height !== targetRect.height) {
    return `window-behavior: external SetWindowPos did not even apply (got ${JSON.stringify(movedRect)}, expected ${JSON.stringify(targetRect)})`;
  }

  await sleep(1000);
  const settledRect = parseRect(await runPowerShellCapture(findWindowRectScript(pid)));
  if (!settledRect) return "window-behavior: post-resize check could not find the window";
  if (settledRect.left !== movedRect.left || settledRect.top !== movedRect.top || settledRect.width !== movedRect.width || settledRect.height !== movedRect.height) {
    return `window-behavior: external resize snapped back after 1s (was ${JSON.stringify(movedRect)}, now ${JSON.stringify(settledRect)}) -- the app is fighting external window management`;
  }
  log(`window-behavior: resize to ${JSON.stringify(movedRect)} stuck after 1s, no snap-back`);
  return null;
}

const CDP_PORT = 9412;
const CDP_URL = `http://127.0.0.1:${CDP_PORT}`;
const BOARD_TESTID = "maat-canvas";
const READY_TIMEOUT_MS = 30000;

function log(msg) {
  console.log(`[native-smoke] ${msg}`);
}

async function waitForCdp(deadline) {
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${CDP_URL}/json/version`);
      if (res.ok) return true;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  return false;
}

async function existingAppPids() {
  const output = await runPowerShellCapture(
    "Get-Process -Name maat-native -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id",
  ).catch(() => "");
  return output
    .split(/\r?\n/)
    .map((value) => Number.parseInt(value.trim(), 10))
    .filter((value) => !Number.isNaN(value));
}

// The centering assertion requires first-launch window state, but the smoke
// harness must never kill an unrelated app or permanently reset its saved
// geometry. Refuse to start over an existing process, temporarily move the
// state file aside, and return a restoration callback used in `finally`.
async function preparePriorRunState() {
  const running = await existingAppPids();
  if (running.length > 0) {
    throw new Error(`maat-native is already running (PID${running.length === 1 ? "" : "s"} ${running.join(", ")}); close it before running smoke:native`);
  }

  const stateFile = await runPowerShellCapture(
    "Join-Path $env:LOCALAPPDATA 'com.lzitser.maat-native\\State\\windows.zon'",
  ).catch(() => "");
  if (!stateFile) return async () => {};

  const backupRoot = await mkdtemp(path.join(os.tmpdir(), "maat-native-smoke-state-"));
  const backupFile = path.join(backupRoot, "windows.zon");
  const hadState = await access(stateFile).then(() => true).catch(() => false);
  if (hadState) await copyFile(stateFile, backupFile);
  await rm(stateFile, { force: true });

  return async () => {
    await rm(stateFile, { force: true }).catch(() => {});
    if (hadState) {
      await mkdir(path.dirname(stateFile), { recursive: true });
      await copyFile(backupFile, stateFile);
    }
    await rm(backupRoot, { recursive: true, force: true }).catch(() => {});
  };
}

async function main() {
  let restorePriorRunState;
  try {
    restorePriorRunState = await preparePriorRunState();
  } catch (error) {
    log(`FAIL: ${error}`);
    process.exit(1);
  }
  log("launching `native dev --yes` with WebView2 CDP debugging enabled...");
  const child = spawn("cmd.exe", ["/c", "native", "dev", "--yes"], {
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: {
      ...process.env,
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${CDP_PORT}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let exitedEarly = false;
  child.on("exit", (code) => {
    exitedEarly = true;
    if (code !== 0 && code !== null) log(`app process exited early with code ${code}`);
  });

  // Discovered once CDP comes up (see the Promise.all below) and reused by
  // both assertWindowBehavior and cleanup, so cleanup can taskkill the
  // specific maat-native.exe PID this run's own `native dev` launched
  // instead of sweeping every maat-native.exe on the machine.
  let appPid = null;

  const cleanup = async () => {
    // `native dev` deliberately puts the vite dev server and the app binary
    // in their own process groups (so an orphaned automation-enabled app
    // doesn't die with a Ctrl+C to the CLI) and only reaps them via its own
    // Zig `defer` cleanup on a normal exit -- which a forceful taskkill on
    // just the wrapper PID skips entirely. Kill the wrapper tree first, then
    // kill the specific maat-native.exe pid (`appPid`, resolved above) this
    // run itself launched -- not an image-name sweep, which would also kill
    // an unrelated real running instance of the app -- then sweep whatever
    // ended up bound to vite's fixed dev port (see vite.config.ts). Awaited
    // so cleanup actually finishes before the script's own process exits.
    if (child.pid) {
      await runToCompletion("taskkill", ["/PID", String(child.pid), "/T", "/F"]);
    }
    if (appPid) {
      await runToCompletion("taskkill", ["/PID", String(appPid), "/T", "/F"]);
    }
    await runToCompletion("cmd.exe", [
      "/c",
      'for /f "tokens=5" %p in (\'netstat -ano ^| findstr :1421 ^| findstr LISTENING\') do taskkill /F /PID %p',
    ]);
  };

  let pass = false;
  let failReason = "";
  try {
    const deadline = Date.now() + READY_TIMEOUT_MS;
    const [cdpUp, foundPid] = await Promise.all([waitForCdp(deadline), findAppPid(deadline)]);
    appPid = foundPid;
    if (!cdpUp) {
      failReason = `CDP endpoint never came up at ${CDP_URL} within ${READY_TIMEOUT_MS}ms`;
    } else if (exitedEarly) {
      failReason = "app process exited before CDP came up";
    } else {
      const browser = await chromium.connectOverCDP(CDP_URL);
      const page = browser.contexts()[0]?.pages()[0];
      if (!page) {
        failReason = "connected over CDP but found no page";
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
            failReason = `page errors during load: ${pageErrors.join(" | ")}`;
          } else {
            const windowFailReason = await assertWindowBehavior(appPid);
            if (windowFailReason) {
              failReason = windowFailReason;
            } else {
              pass = true;
            }
          }
        } catch (err) {
          failReason = `board canvas [data-testid="${BOARD_TESTID}"] never appeared (blank/white-screen symptom): ${err}`;
        }
      }
      await browser.close().catch(() => {});
    }
  } catch (err) {
    failReason = `harness error: ${err}`;
  } finally {
    await cleanup();
    await restorePriorRunState();
  }

  if (pass) {
    log("PASS: native:dev rendered the Maat board UI inside the WebView2 shell.");
    process.exit(0);
  } else {
    log(`FAIL: ${failReason}`);
    process.exit(1);
  }
}

main();
