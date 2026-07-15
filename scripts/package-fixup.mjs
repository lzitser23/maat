// Post-processes `native package --target <target>` output. Target-aware:
// windows and macos each get their own fixup/verification (see below);
// linux isn't packaged by this repo yet.
//
// windows: works around a remaining upstream gap in @native-sdk/cli's
// desktop packager (createDesktopArtifact in its tooling/package.zig):
//
// It writes frontend files to <package>/resources/<frontend.dist>, but the
// runtime resolves `frontend.dist` ("dist") as a plain relative path
// against the process's current working directory (see assetFilePath() in
// src/platform/windows/webview2_host.cpp -- no exe-relative resolution at
// all, still true as of @native-sdk/cli 0.4.3). For the packaged
// bin/+resources/ layout, the working directory a double-clicked exe gets
// is its own bin/ directory, so it looks for bin/dist and fails with
// "Asset not found". Moving frontend.dist can't be done at build time via
// app.zon (that value is also used for local dev/debug runs, where the
// working directory is the repo root and "dist" already lives there) --
// it's specific to how the packager lays out the tree.
//
// (A second gap this script used to work around -- the packager not
// shipping WebView2Loader.dll alongside the exe -- was fixed upstream in
// 0.4.1: createDesktopArtifact now calls copyWindowsWebView2Loader for
// windows/system-web-engine targets, copying its own vendored
// third_party/webview2/<arch>/WebView2Loader.dll into bin/ automatically.)
//
// Once @native-sdk/cli fixes this gap too, drop the windows fixup below and
// point package.json's `native:package` back at the bare `native package`
// command.
//
// macos: needs NO equivalent relocation. `createMacosApp` (same
// tooling/package.zig) already writes frontend assets to
// Contents/Resources/<frontend.dist>, and the macOS host resolves relative
// asset paths against `NSBundle.mainBundle.resourcePath` when running from
// a real .app bundle (@native-sdk/cli's src/platform/macos/appkit_host.m,
// around its `resourcePath`/`isAppBundle` asset-root helpers) -- i.e.
// exactly where the packager already put them. `createMacosApp` also always
// emits Contents/Info.plist and an icon (the configured one, or the SDK's
// own default), so there's nothing to fix up there either. This script
// still verifies the bundle came out complete (binary, frontend assets,
// Info.plist, icon) so a silent packager regression fails the build loudly
// instead of shipping a broken artifact.
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { cp, readdir, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const packageRoot = path.join(repoRoot, "zig-out", "package");

const validTargets = new Set(["windows", "macos"]);
const target = process.argv[2] ?? (process.platform === "darwin" ? "macos" : "windows");
if (!validTargets.has(target)) {
  throw new Error(`unsupported package target "${target}" -- expected one of: ${[...validTargets].join(", ")}`);
}

async function findPackageDir(forTarget) {
  // Where the SDK's packager (tooling/package.zig) writes the report:
  // createDesktopArtifact puts it at the artifact root for windows/linux,
  // but createMacosApp puts it inside the bundle at Contents/Resources/.
  const manifestSubpath =
    forTarget === "macos"
      ? path.join("Contents", "Resources", "package-manifest.zon")
      : "package-manifest.zon";
  const entries = await readdir(packageRoot, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const manifestPath = path.join(packageRoot, entry.name, manifestSubpath);
    if (!existsSync(manifestPath)) continue;
    const manifest = await readFile(manifestPath, "utf8");
    if (new RegExp(`\\.target\\s*=\\s*"${forTarget}"`).test(manifest)) {
      return path.join(packageRoot, entry.name);
    }
  }
  throw new Error(`no ${forTarget} package-manifest.zon found under ${packageRoot}`);
}

async function fixupWindows() {
  const pkgDir = await findPackageDir("windows");
  const binDir = path.join(pkgDir, "bin");

  // Guard against the silent-missing-binary packager behavior described
  // above: a package without its exe must fail loudly here, not at smoke.
  const exePath = path.join(binDir, "maat-native.exe");
  if (!existsSync(exePath)) {
    throw new Error(`packaged exe missing at ${exePath} -- native package produced an artifact without the app binary`);
  }

  // Fixup: the frontend dist the runtime actually resolves against
  // (CWD/dist, i.e. bin/dist for a packaged run) rather than where the
  // packager wrote it (resources/dist).
  const distSrc = path.join(pkgDir, "resources", "dist");
  const distDest = path.join(binDir, "dist");
  await cp(distSrc, distDest, { recursive: true });
  await rm(distSrc, { recursive: true, force: true });
  const resourcesDir = path.join(pkgDir, "resources");
  const remaining = await readdir(resourcesDir).catch(() => ["?"]);
  if (remaining.length === 0) await rm(resourcesDir, { recursive: true, force: true });

  if (!existsSync(path.join(distDest, "index.html"))) {
    throw new Error(`packaged frontend missing ${path.join(distDest, "index.html")} -- the packager shipped an empty or absent dist/`);
  }

  console.log(`[package-fixup] frontend dist -> ${path.relative(repoRoot, distDest)}`);
}

// No file layout fixup needed on macOS (see module doc comment) -- this
// only verifies the bundle came out complete.
async function verifyMacos() {
  const pkgDir = await findPackageDir("macos");

  const binaryPath = path.join(pkgDir, "Contents", "MacOS", "maat-native");
  if (!existsSync(binaryPath)) {
    throw new Error(`packaged binary missing at ${binaryPath} -- native package produced a bundle without the app binary`);
  }

  const infoPlistPath = path.join(pkgDir, "Contents", "Info.plist");
  if (!existsSync(infoPlistPath)) {
    throw new Error(`packaged bundle missing ${infoPlistPath}`);
  }

  const iconPath = path.join(pkgDir, "Contents", "Resources", "AppIcon.icns");
  if (!existsSync(iconPath)) {
    throw new Error(`packaged bundle missing ${iconPath}`);
  }

  const distIndexPath = path.join(pkgDir, "Contents", "Resources", "dist", "index.html");
  if (!existsSync(distIndexPath)) {
    throw new Error(`packaged frontend missing ${distIndexPath} -- the packager shipped an empty or absent dist/`);
  }

  console.log(`[package-fixup] verified macOS bundle at ${path.relative(repoRoot, pkgDir)}`);
}

async function main() {
  // The packager also ships whatever repo-root dist/ holds (empty dir if
  // the frontend was never built -- true on a fresh checkout/CI, where
  // only the web-check job runs `pnpm build`). Build the frontend first.
  const frontend = spawnSync("pnpm", ["build"], {
    cwd: repoRoot,
    stdio: "inherit",
    shell: true,
  });
  if (frontend.status !== 0) {
    process.exit(frontend.status ?? 1);
  }

  // `native package` copies whatever release binary already exists rather
  // than building one, and (upstream quirk) happily creates the artifact
  // even when zig-out/bin has no exe at all -- on a fresh checkout/CI that
  // yields a package with no binary. Build ReleaseFast first, always.
  const build = spawnSync("native", ["build", "--yes"], {
    cwd: repoRoot,
    stdio: "inherit",
    shell: true,
  });
  if (build.status !== 0) {
    process.exit(build.status ?? 1);
  }

  const result = spawnSync("native", ["package", "--target", target], {
    cwd: repoRoot,
    stdio: "inherit",
    shell: true,
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }

  if (target === "windows") {
    await fixupWindows();
  } else {
    await verifyMacos();
  }
}

main().catch((err) => {
  console.error(`[package-fixup] ${err.stack ?? err}`);
  process.exit(1);
});
