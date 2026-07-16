// Post-processes `native package --target macos` output. macOS-only now:
//
// Windows no longer goes through `native package` at all -- the shipping
// artifact is the single portable zig-out/bin/maat-native.exe that a plain
// `zig build -Doptimize=ReleaseFast` produces (the frontend build is
// embedded into the binary by build.zig's embeddedFrontendModule and the
// WebView2 loader is embedded + staged at runtime by runner.zig's
// stageWebView2Loader). That made both Windows fixups this script used to
// carry dead:
//
//   - relocating resources/dist to bin/dist (the upstream packager wrote
//     frontend files where the runtime's CWD-relative `frontend.dist`
//     resolution -- assetFilePath() in @native-sdk/cli's webview2_host.cpp,
//     still CWD-relative as of 0.4.3 -- never looked): the packaged exe no
//     longer reads dist/ from disk at all;
//   - copying WebView2Loader.dll beside the exe (fixed upstream in 0.4.1
//     anyway): the exe now stages its own embedded copy.
//
// See scripts/packaged-smoke.mjs for the check that the portable exe really
// is self-sufficient.
//
// macos: needs NO layout fixup, only verification. `createMacosApp`
// (@native-sdk/cli's tooling/package.zig) already writes frontend assets to
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
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const packageRoot = path.join(repoRoot, "zig-out", "package");

const target = process.argv[2] ?? "macos";
if (target !== "macos") {
  throw new Error(
    `unsupported package target "${target}" -- only macos goes through native package now; ` +
      `the Windows artifact is the portable exe from "zig build -Doptimize=ReleaseFast" (see this script's header)`,
  );
}

async function findPackageDir(forTarget) {
  // Where the SDK's packager (tooling/package.zig) writes the report:
  // createMacosApp puts it inside the bundle at Contents/Resources/.
  const manifestSubpath = path.join("Contents", "Resources", "package-manifest.zon");
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
  // The packager ships whatever repo-root dist/ holds (empty dir if the
  // frontend was never built -- true on a fresh checkout/CI, where only
  // the web-check job runs `pnpm build`). Build the frontend first.
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
  // even when zig-out has no binary at all -- on a fresh checkout/CI that
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

  await verifyMacos();
}

main().catch((err) => {
  console.error(`[package-fixup] ${err.stack ?? err}`);
  process.exit(1);
});
