const std = @import("std");

const PlatformOption = enum {
    auto,
    @"null",
    macos,
    linux,
    windows,
};

const TraceOption = enum {
    off,
    events,
    runtime,
    all,
};

const WebEngineOption = enum {
    system,
    chromium,
};

const PackageTarget = enum {
    macos,
    windows,
    linux,
};

const app_exe_name = "maat-native";

pub fn build(b: *std.Build) void {
    const target = nativeSdkTarget(b);
    const optimize = b.standardOptimizeOption(.{});
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
    const automation_enabled = b.option(bool, "automation", "Enable Native SDK automation artifacts") orelse false;
    const js_bridge_enabled = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
    const package_target = b.option(PackageTarget, "package-target", "Package target: macos, windows, linux") orelse .windows;
    const native_sdk_path = b.option([]const u8, "native-sdk-path", "Path to the Native SDK framework checkout") orelse discoverNativeSdkPath(b);
    const optimize_name = @tagName(optimize);
    const selected_platform: PlatformOption = switch (platform_option) {
        .auto => if (target.result.os.tag == .macos) .macos else if (target.result.os.tag == .linux) .linux else if (target.result.os.tag == .windows) .windows else .@"null",
        else => platform_option,
    };
    if (selected_platform == .macos and target.result.os.tag != .macos) {
        @panic("-Dplatform=macos requires a macOS target");
    }
    if (selected_platform == .linux and target.result.os.tag != .linux) {
        @panic("-Dplatform=linux requires a Linux target");
    }
    if (selected_platform == .windows and target.result.os.tag != .windows) {
        @panic("-Dplatform=windows requires a Windows target");
    }
    const app_web_engine = appWebEngineConfig();
    const web_engine = web_engine_override orelse app_web_engine.web_engine;
    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, app_web_engine.cef_dir);
    const cef_auto_install = cef_auto_install_override orelse app_web_engine.cef_auto_install;
    if (web_engine == .chromium and selected_platform != .macos) {
        @panic("-Dweb-engine=chromium currently requires -Dplatform=macos");
    }

    const native_sdk_mod = nativeSdkModule(b, target, optimize, native_sdk_path);
    const options = b.addOptions();
    options.addOption([]const u8, "platform", switch (selected_platform) {
        .auto => unreachable,
        .@"null" => "null",
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
    });
    options.addOption([]const u8, "trace", @tagName(trace_option));
    options.addOption([]const u8, "web_engine", @tagName(web_engine));
    options.addOption(bool, "debug_overlay", debug_overlay);
    options.addOption(bool, "automation", automation_enabled);
    options.addOption(bool, "js_bridge", js_bridge_enabled);
    const options_mod = options.createModule();

    const runner_mod = localModule(b, target, optimize, "src-zig/runner.zig");
    runner_mod.addImport("native_sdk", native_sdk_mod);
    runner_mod.addImport("build_options", options_mod);
    runner_mod.addImport("app_manifest_zon", b.createModule(.{ .root_source_file = b.path("app.zon") }));

    const app_mod = localModule(b, target, optimize, "src-zig/main.zig");
    app_mod.addImport("native_sdk", native_sdk_mod);
    app_mod.addImport("runner", runner_mod);

    // Vendored C dependencies (see src-zig/vendor/): sqlite3 for the
    // catalog database, stb_image/stb_image_write/stb_image_resize2 for
    // the ingest pipeline's thumbnailing. Wired here rather than via
    // build.zig.zon dependencies because these are vendored source
    // amalgamations, not Zig packages -- the same pattern the SDK itself
    // uses for its own platform-host C/ObjC/C++ sources below.
    app_mod.addCSourceFile(.{
        .file = b.path("src-zig/vendor/sqlite3.c"),
        .flags = &.{"-DSQLITE_THREADSAFE=1"},
    });
    app_mod.addCSourceFile(.{
        .file = b.path("src-zig/vendor/stb_impl.c"),
        .flags = &.{},
    });
    app_mod.addIncludePath(b.path("src-zig/vendor"));

    const exe = b.addExecutable(.{
        .name = app_exe_name,
        .root_module = app_mod,
    });
    linkPlatform(b, target, app_mod, exe, selected_platform, web_engine, native_sdk_path, cef_dir, cef_auto_install);
    b.installArtifact(exe);

    // Windows/system web_engine loads WebView2 via LoadLibraryW("WebView2Loader.dll")
    // with no explicit search path (src/platform/windows/webview2_host.cpp), so the
    // DLL must sit next to the exe -- it is not provided by the WebView2 Runtime
    // install, only by the Microsoft.Web.WebView2 NuGet redistributable. Vendored
    // here (src-zig/vendor/windows/) the same way sqlite3.c/stb_impl.c are vendored
    // above, and installed into zig-out/bin as part of the default step so it's
    // present for `native dev`/`native build` alike (neither goes through the `run`
    // step). Without it, WebView2 never spawns and the window is a blank white shell.
    if (selected_platform == .windows and web_engine == .system) {
        const webview2_loader = b.addInstallFileWithDir(
            b.path("src-zig/vendor/windows/WebView2Loader.dll"),
            .bin,
            "WebView2Loader.dll",
        );
        b.getInstallStep().dependOn(&webview2_loader.step);
    }

    // Frontend lives at the repo root (src/, index.html, vite.config.ts,
    // package.json) -- not in a frontend/ subdir -- so these steps run
    // plain `pnpm` with no --prefix, unlike the `native init --frontend`
    // scaffold this build.zig was adapted from.
    const frontend_install = b.addSystemCommand(&.{ "pnpm", "install" });
    const frontend_install_step = b.step("frontend-install", "Install frontend dependencies");
    frontend_install_step.dependOn(&frontend_install.step);

    const frontend_build = b.addSystemCommand(&.{ "pnpm", "build" });
    const frontend_step = b.step("frontend-build", "Build the frontend");
    frontend_step.dependOn(&frontend_build.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&frontend_build.step);
    addCefRuntimeRunFiles(b, target, run, exe, web_engine, cef_dir);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);

    const dev = b.addSystemCommand(&.{ "native", "dev", "--manifest", "app.zon", "--binary" });
    dev.addFileArg(exe.getEmittedBin());
    dev.step.dependOn(&exe.step);
    const dev_step = b.step("dev", "Run the frontend dev server and native shell");
    dev_step.dependOn(&dev.step);

    const package = b.addSystemCommand(&.{
        "native",
        "package",
        "--target",
        @tagName(package_target),
        "--manifest",
        "app.zon",
        "--assets",
        "dist",
        "--optimize",
        optimize_name,
        "--output",
        b.fmt("zig-out/package/{s}-0.1.0-{s}-{s}{s}", .{ app_exe_name, @tagName(package_target), optimize_name, packageSuffix(package_target) }),
        "--binary",
    });
    package.addFileArg(exe.getEmittedBin());
    package.addArgs(&.{ "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
    if (cef_auto_install) package.addArg("--cef-auto-install");
    package.step.dependOn(&exe.step);
    package.step.dependOn(&frontend_build.step);
    const package_step = b.step("package", "Create a local package artifact");
    package_step.dependOn(&package.step);

    const tests = b.addTest(.{ .root_module = app_mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // src-zig/server.zig has no native_sdk/runner imports and is tested
    // standalone so its root-guard/URL-decoding tests always run under
    // `zig build test` -- app_mod's own test run only reaches code paths
    // actually referenced from main.zig's test blocks (Zig's lazy
    // analysis otherwise skips server.zig entirely, since nothing in
    // main.zig's tests calls into it).
    const server_test_mod = localModule(b, target, optimize, "src-zig/server.zig");
    if (target.result.os.tag == .windows) {
        server_test_mod.linkSystemLibrary("ws2_32", .{});
    } else {
        // macOS (and any other POSIX target): server.zig's socket layer
        // calls std.c's libc socket bindings directly (see server.zig's
        // sock* helpers), which need libc linked to resolve.
        server_test_mod.linkSystemLibrary("c", .{});
    }
    const server_tests = b.addTest(.{ .root_module = server_test_mod });
    test_step.dependOn(&b.addRunArtifact(server_tests).step);
}

fn nativeSdkTarget(b: *std.Build) std.Build.ResolvedTarget {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .macos) return target;

    if (b.sysroot == null) {
        b.sysroot = macosSdkPath(b) orelse b.sysroot;
    }

    var query = target.query;
    query.os_tag = .macos;
    query.os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } };
    return b.resolveTargetQuery(query);
}

fn macosSdkPath(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
        if (sdkroot.len > 0) return sdkroot;
    }

    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer b.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        b.allocator.free(result.stdout);
        return null;
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

// Resolves the @native-sdk/cli checkout this build graph reads its Zig
// modules and platform host sources from (see nativeSdkModule/linkPlatform
// below). Never hardcode this to one machine's absolute npm path -- CI
// runners and every other developer's machine install the package under a
// different prefix. Resolution order, matching `native`'s own generated
// build graphs (which locate the SDK the same way rather than embedding an
// absolute path):
//   1. NATIVE_SDK_HOME, if set -- an explicit override, e.g. for a local
//      SDK checkout that isn't installed through npm at all.
//   2. `npm root -g` + "@native-sdk/cli" -- where `npm install -g
//      @native-sdk/cli` (this repo's documented prerequisite, and what
//      .github/workflows/build.yml's Windows job runs) actually puts it.
//   3. A clear @panic with fix-it instructions -- silently falling back to
//      a guessed path would just trade one hardcoded-path bug for another.
// `-Dnative-sdk-path=...` (see the b.option() call above) always wins over
// all of this when passed explicitly.
fn discoverNativeSdkPath(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("NATIVE_SDK_HOME")) |env_path| {
        if (env_path.len > 0) return env_path;
    }
    if (npmGlobalNativeSdkPath(b)) |path| return path;
    @panic(
        \\Could not locate the @native-sdk/cli package.
        \\
        \\Fix by one of:
        \\  1. Installing it globally so `npm root -g` can find it:
        \\       npm install -g @native-sdk/cli
        \\  2. Setting NATIVE_SDK_HOME to an existing checkout, e.g. (PowerShell):
        \\       $env:NATIVE_SDK_HOME = "C:\path\to\node_modules\@native-sdk\cli"
        \\  3. Passing the path directly for this build only:
        \\       zig build -Dnative-sdk-path=C:\path\to\node_modules\@native-sdk\cli
    );
}

fn npmGlobalNativeSdkPath(b: *std.Build) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "npm", "root", "-g" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer b.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        b.allocator.free(result.stdout);
        return null;
    }
    const npm_root = std.mem.trimEnd(u8, result.stdout, "\r\n");
    const candidate = b.pathJoin(&.{ npm_root, "@native-sdk", "cli" });
    // Confirm the package is actually there (not just that `npm root -g`
    // ran) by checking for the module every native_sdk_mod import below
    // reads through nativeSdkPath() -- avoids handing back a plausible but
    // nonexistent path when the global root exists but the package was
    // never installed into it.
    const sentinel = b.pathJoin(&.{ candidate, "src", "root.zig" });
    std.Io.Dir.accessAbsolute(b.graph.io, sentinel, .{}) catch return null;
    return candidate;
}

fn localModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn nativeSdkPath(b: *std.Build, native_sdk_path: []const u8, sub_path: []const u8) std.Build.LazyPath {
    return .{ .cwd_relative = b.pathJoin(&.{ native_sdk_path, sub_path }) };
}

// webview2_host.cpp's entire WebView2 implementation lives behind
// `#if __has_include(<WebView2.h>)` and silently compiles to a no-op stub
// otherwise (see the comment above where this is called) -- which means it
// has likely never actually been compiled outside MSVC (whose historically
// loose nested-lambda capture rules paper over a real bug: a lambda at
// ~line 4110 uses `key` from its enclosing scope without listing it in its
// own capture list). Clang (what zig cc drives here) rejects that. This
// can't be hand-patched in node_modules -- that wouldn't survive a fresh
// `npm install` for anyone else building this repo -- so it's patched here,
// at configure time, into a generated copy that gets compiled instead of
// the original.
//
// Each patch below is tolerant of the upstream SDK having already fixed the
// bug it targets: if the known-buggy text is present, patch it; if the
// known-fixed text is already present (upstream shipped the fix itself),
// pass the source through untouched for that patch; only panic when neither
// form is found, since that means the SDK changed in some third way this
// file doesn't know how to handle yet. Verified against @native-sdk/cli
// 0.4.0 through 0.4.3.
fn patchedWebview2HostSource(b: *std.Build, native_sdk_path: []const u8) std.Build.LazyPath {
    const original_path = b.pathJoin(&.{ native_sdk_path, "src", "platform", "windows", "webview2_host.cpp" });
    const source = std.Io.Dir.cwd().readFileAlloc(b.graph.io, original_path, b.allocator, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.panic("failed to read {s} to patch the clang nested-lambda-capture gap: {t}", .{ original_path, err });
    };

    // Patch 1: nested-lambda-capture. Fixed upstream in @native-sdk/cli
    // 0.4.1 (vercel-labs/native#72's comment thread) -- 0.4.1 through 0.4.3
    // already list `key` in the capture, so this is a pass-through there.
    const lambda_needle = "[host, bridge_window_id, bridge_label, lifetime](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {";
    const lambda_fixed = "[host, key, bridge_window_id, bridge_label, lifetime](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {";
    const lambda_patched: []const u8 = if (std.mem.indexOf(u8, source, lambda_needle) != null)
        std.mem.replaceOwned(u8, b.allocator, source, lambda_needle, lambda_fixed) catch @panic("OOM")
    else if (std.mem.indexOf(u8, source, lambda_fixed) != null)
        source
    else
        @panic("webview2_host.cpp contains neither the known-buggy (0.4.0) nor the known-fixed (0.4.1-0.4.3) nested-lambda-capture text -- the SDK likely changed again; update or drop this build-time patch in build.zig");

    // createNativeWindow's CreateWindowExW call for the startup window
    // hardcodes CW_USEDEFAULT for X/Y, silently discarding window.x/y
    // (the app.zon-declared position, and whatever the runner computes
    // for e.g. manual startup centering) -- Windows picks its own
    // cascading placement instead, which is why the window always
    // spawns pinned near (0,0) regardless of app.zon. outer_width/height
    // just above already derive the OUTER size from a content-size
    // AdjustWindowRectEx(&frame, ...) call; `frame.left`/`frame.top` from
    // that same call are the matching outer-position offset, so adding
    // them to window.x/window.y lands the CONTENT rect's top-left at the
    // requested position exactly the way outer_width/outer_height land
    // its size there (for the chromeless WS_POPUP style this app uses,
    // AdjustWindowRectEx leaves frame.left/top at 0, so this reduces to
    // plain window.x/window.y). Still broken as of 0.4.3.
    const position_needle =
        \\        style,
        \\        CW_USEDEFAULT,
        \\        CW_USEDEFAULT,
        \\        outer_width,
        \\        outer_height,
    ;
    const position_replacement =
        \\        style,
        \\        (int)window.x + frame.left,
        \\        (int)window.y + frame.top,
        \\        outer_width,
        \\        outer_height,
    ;
    const position_patched: []const u8 = if (std.mem.indexOf(u8, lambda_patched, position_needle) != null)
        std.mem.replaceOwned(u8, b.allocator, lambda_patched, position_needle, position_replacement) catch @panic("OOM")
    else if (std.mem.indexOf(u8, lambda_patched, position_replacement) != null)
        lambda_patched
    else
        @panic("webview2_host.cpp contains neither the known-buggy (0.4.0-0.4.3) nor the known-fixed CreateWindowExW CW_USEDEFAULT text -- the SDK likely changed; update or drop this build-time patch in build.zig");

    // WM_GETMINMAXINFO never sets ptMaxPosition/ptMaxSize/ptMaxTrackSize,
    // only ptMinTrackSize (and only when app.zon declares a min size).
    // Windows computes sane maximize geometry on its own for a normal
    // WS_OVERLAPPEDWINDOW, but this app's chromeless window is WS_POPUP
    // with no non-client frame for that default calculation to key off
    // of: ShowWindow(SW_MAXIMIZE) (see window_toggle_maximize in
    // src-zig/main.zig) silently grows it to the wrong rect and never
    // flips the WS_MAXIMIZE style bit, so IsZoomed stays false and a
    // second toggle call "restores" a window that was never truly
    // maximized. Supplying the monitor's work-area rect explicitly here
    // is the standard fix for maximizing a caption-less popup window.
    // Still broken as of 0.4.3. This patch and the ptMinTrackSize dedup
    // patch right after it are coupled: the dedup only has anything to do
    // if this one actually ran (see maxinfo_applied below).
    const maxinfo_needle =
        \\                    Window &window = entry.second;
        \\                    if (window.hwnd != hwnd) continue;
        \\                    if (window.min_width <= 0 && window.min_height <= 0) break;
    ;
    const maxinfo_replacement =
        \\                    Window &window = entry.second;
        \\                    if (window.hwnd != hwnd) continue;
        \\                    MINMAXINFO *info = reinterpret_cast<MINMAXINFO *>(lparam);
        \\                    bool handled_max = false;
        \\                    if (windowIsChromeless(window)) {
        \\                        MONITORINFO monitor_info = {};
        \\                        monitor_info.cbSize = sizeof(monitor_info);
        \\                        HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        \\                        if (GetMonitorInfoW(monitor, &monitor_info)) {
        \\                            info->ptMaxPosition.x = monitor_info.rcWork.left - monitor_info.rcMonitor.left;
        \\                            info->ptMaxPosition.y = monitor_info.rcWork.top - monitor_info.rcMonitor.top;
        \\                            info->ptMaxSize.x = monitor_info.rcWork.right - monitor_info.rcWork.left;
        \\                            info->ptMaxSize.y = monitor_info.rcWork.bottom - monitor_info.rcWork.top;
        \\                            info->ptMaxTrackSize = info->ptMaxSize;
        \\                            handled_max = true;
        \\                        }
        \\                    }
        \\                    if (window.min_width <= 0 && window.min_height <= 0) { if (handled_max) return 0; break; }
    ;
    const maxinfo_applied = std.mem.indexOf(u8, position_patched, maxinfo_needle) != null;
    const maxinfo_patched: []const u8 = if (maxinfo_applied)
        std.mem.replaceOwned(u8, b.allocator, position_patched, maxinfo_needle, maxinfo_replacement) catch @panic("OOM")
    else if (std.mem.indexOf(u8, position_patched, maxinfo_replacement) != null)
        position_patched
    else
        @panic("webview2_host.cpp contains neither the known-buggy (0.4.0-0.4.3) nor the known-fixed WM_GETMINMAXINFO text -- the SDK likely changed; update or drop this build-time patch in build.zig");

    // The maxinfo patch above declares its own `MINMAXINFO *info` earlier
    // in the same handler; the original code re-declares it a few lines
    // later, right before the pre-existing ptMinTrackSize assignment,
    // which would fail to compile as a duplicate declaration. Only needed
    // -- and only matched against -- when the maxinfo patch actually ran;
    // if it was a pass-through (upstream already fixed maximize), there is
    // no duplicate to remove.
    const info_redecl_needle = "                    MINMAXINFO *info = reinterpret_cast<MINMAXINFO *>(lparam);\n                    if (window.min_width > 0) info->ptMinTrackSize.x = outer_width;";
    const info_redecl_replacement = "                    if (window.min_width > 0) info->ptMinTrackSize.x = outer_width;";
    const patched: []const u8 = if (!maxinfo_applied)
        maxinfo_patched
    else if (std.mem.indexOf(u8, maxinfo_patched, info_redecl_needle) != null)
        std.mem.replaceOwned(u8, b.allocator, maxinfo_patched, info_redecl_needle, info_redecl_replacement) catch @panic("OOM")
    else
        @panic("webview2_host.cpp no longer contains the expected ptMinTrackSize text right after the WM_GETMINMAXINFO patch ran -- the SDK likely changed; update or drop this build-time patch in build.zig");

    const write_files = b.addWriteFiles();
    return write_files.add("webview2_host_patched.cpp", patched);
}

fn nativeSdkModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native_sdk_path: []const u8) *std.Build.Module {
    const geometry_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/geometry/root.zig");
    const assets_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/assets/root.zig");
    const app_dirs_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/app_dirs/root.zig");
    const trace_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/trace/root.zig");
    const app_manifest_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/platform_info/root.zig");
    const json_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/json/root.zig");
    const canvas_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/canvas/root.zig");
    canvas_mod.addImport("geometry", geometry_mod);
    canvas_mod.addImport("json", json_mod);
    const debug_mod = externalModule(b, target, optimize, native_sdk_path, "src/debug/root.zig");
    debug_mod.addImport("app_dirs", app_dirs_mod);
    debug_mod.addImport("trace", trace_mod);

    const native_sdk_mod = externalModule(b, target, optimize, native_sdk_path, "src/root.zig");
    native_sdk_mod.addImport("geometry", geometry_mod);
    native_sdk_mod.addImport("assets", assets_mod);
    native_sdk_mod.addImport("app_dirs", app_dirs_mod);
    native_sdk_mod.addImport("trace", trace_mod);
    native_sdk_mod.addImport("app_manifest", app_manifest_mod);
    native_sdk_mod.addImport("diagnostics", diagnostics_mod);
    native_sdk_mod.addImport("platform_info", platform_info_mod);
    native_sdk_mod.addImport("json", json_mod);
    native_sdk_mod.addImport("canvas", canvas_mod);
    return native_sdk_mod;
}

fn externalModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native_sdk_path: []const u8, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = nativeSdkPath(b, native_sdk_path, path),
        .target = target,
        .optimize = optimize,
    });
}

fn linkPlatform(b: *std.Build, target: std.Build.ResolvedTarget, app_mod: *std.Build.Module, exe: *std.Build.Step.Compile, platform: PlatformOption, web_engine: WebEngineOption, native_sdk_path: []const u8, cef_dir: []const u8, cef_auto_install: bool) void {
    if (platform == .macos) {
        switch (web_engine) {
            .system => {
                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0" };
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/macos/appkit_host.m"), .flags = flags });
                app_mod.linkFramework("WebKit", .{});
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                // The SDK's usr/include must stay a system include dir (searched after zig's
                // bundled libc++/libc headers). A plain -I shadows libc++'s <string.h>/<math.h>
                // wrappers in ObjC++ and surfaces SDK nullability gaps as a diagnostic flood.
                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-isystem{s}/usr/include", .{sysroot}) else "";
                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include, include_arg, define_arg } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", include_arg, define_arg };
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/macos/cef_host.mm"), .flags = flags });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.addFrameworkPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
                app_mod.linkFramework("Chromium Embedded Framework", .{});
                app_mod.addRPath(.{ .cwd_relative = "@executable_path/Frameworks" });
            },
        }
        if (b.sysroot) |sysroot| {
            app_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        // Rounds the chromeless main window's corners after the SDK creates
        // it (src-zig/vendor/macos/window_corners.m) -- see that file for
        // why this can't just live in appkit_host.m's own styleMask choice.
        const window_corners_flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, b.fmt("-I{s}/usr/include", .{sysroot}) } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0" };
        app_mod.addCSourceFile(.{ .file = b.path("src-zig/vendor/macos/window_corners.m"), .flags = window_corners_flags });
        app_mod.linkFramework("AppKit", .{});
        app_mod.linkFramework("AVFoundation", .{});
        app_mod.linkFramework("MediaToolbox", .{});
        app_mod.linkFramework("Accelerate", .{});
        app_mod.linkFramework("Foundation", .{});
        app_mod.linkFramework("CoreText", .{});
        app_mod.linkFramework("UniformTypeIdentifiers", .{});
        app_mod.linkFramework("Security", .{});
        app_mod.linkFramework("Metal", .{});
        app_mod.linkFramework("QuartzCore", .{});
        app_mod.linkSystemLibrary("c", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("c++", .{});
    } else if (platform == .linux) {
        switch (web_engine) {
            .system => {
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/linux/gtk_host.c"), .flags = &.{} });
                app_mod.linkSystemLibrary("gtk4", .{});
                app_mod.linkSystemLibrary("webkitgtk-6.0", .{});
                app_mod.linkSystemLibrary("dl", .{});
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/linux/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
                app_mod.linkSystemLibrary("cef", .{});
                app_mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
            },
        }
        app_mod.linkSystemLibrary("c", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("stdc++", .{});
    } else if (platform == .windows) {
        switch (web_engine) {
            .system => {
                // webview2_host.cpp gates its entire WebView2 implementation on
                // `__has_include(<WebView2.h>) && __has_include(<wrl.h>)` and
                // silently compiles a no-op stub otherwise (its own comment:
                // "WebView loads will report WebViewNotFound"). Zig's bundled
                // mingw headers ship wrl.h but not the WebView2 SDK headers --
                // those only come from the Microsoft.Web.WebView2 NuGet package,
                // which also doesn't ship on this include path by default. That
                // silent stub is why `native dev` opened a window that never
                // grew a WebView2 control: no error anywhere, just a blank host
                // window. Vendored here (src-zig/vendor/windows/include/) is
                // WebView2.h from that NuGet package, EventToken.h (a small
                // Windows SDK header WebView2.h needs that mingw doesn't
                // bundle either -- the same gap this file already works
                // around for audioclientactivationparams.h above), and a
                // minimal wrl.h shim: mingw's bundled <wrl.h> lacks the real
                // SDK's Callback<>/ComPtr<> helpers (webview2_host.cpp's two
                // `using Microsoft::WRL::...` lines), and the real ones pull
                // in the full WinRT/activation header stack mingw doesn't
                // carry. The shim reimplements just those two pieces against
                // <unknwn.h> -- see the header for why that's sufficient.
                app_mod.addIncludePath(b.path("src-zig/vendor/windows/include"));
                app_mod.addCSourceFile(.{ .file = patchedWebview2HostSource(b, native_sdk_path), .flags = &.{"-std=c++17"} });
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/windows/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib", .{cef_dir})));
                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
            },
        }
        app_mod.linkSystemLibrary("c", .{});
        app_mod.linkSystemLibrary("c++", .{});
        app_mod.linkSystemLibrary("user32", .{});
        app_mod.linkSystemLibrary("gdi32", .{});
        app_mod.linkSystemLibrary("imm32", .{});
        app_mod.linkSystemLibrary("comctl32", .{});
        app_mod.linkSystemLibrary("ole32", .{});
        app_mod.linkSystemLibrary("oleacc", .{});
        app_mod.linkSystemLibrary("shell32", .{});
        // The audio backend: Media Foundation (session + source resolver
        // + streaming audio renderer) and WinHTTP (the cache fill).
        app_mod.linkSystemLibrary("mf", .{});
        app_mod.linkSystemLibrary("mfplat", .{});
        app_mod.linkSystemLibrary("winhttp", .{});
        // The local file server (src-zig/server.zig) speaks raw
        // Winsock2 directly -- see the comment at the top of that file
        // for why it doesn't use std.Io.net.
        app_mod.linkSystemLibrary("ws2_32", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("libcef", .{});
    }
}

fn addCefRuntimeRunFiles(b: *std.Build, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, exe: *std.Build.Step.Compile, web_engine: WebEngineOption, cef_dir: []const u8) void {
    if (web_engine != .chromium) return;
    if (target.result.os.tag != .macos) return;
    const copy = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
        \\set -e
        \\exe="$0"
        \\exe_dir="$(dirname "$exe")"
        \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework" &&
        \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks" "$exe_dir" &&
        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/" &&
        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/" &&
        \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/" &&
        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libEGL.dylib" "$exe_dir/" &&
        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib" "$exe_dir/" &&
        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libvk_swiftshader.dylib" "$exe_dir/" &&
        \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/vk_swiftshader_icd.json" "$exe_dir/"
    , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }) });
    copy.addFileArg(exe.getEmittedBin());
    run.step.dependOn(&copy.step);
}

fn addCefCheck(b: *std.Build, target: std.Build.ResolvedTarget, cef_dir: []const u8) *std.Build.Step.Run {
    const script = switch (target.result.os.tag) {
        .macos => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -d "{s}/Release/Chromium Embedded Framework.framework" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Expected:" >&2
            \\  echo "  {s}/include/cef_app.h" >&2
            \\  echo "  {s}/Release/Chromium Embedded Framework.framework" >&2
            \\  echo "  {s}/libcef_dll_wrapper/libcef_dll_wrapper.a" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  echo "Or rerun with: -Dcef-auto-install=true" >&2
            \\  echo "Pass -Dcef-dir=/path/to/cef if your bundle lives elsewhere." >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
        .linux => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -f "{s}/Release/libcef.so" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        .windows => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -f "{s}/Release/libcef.dll" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        else => "echo unsupported CEF target >&2; exit 1",
    };
    return b.addSystemCommand(&.{ "sh", "-c", script });
}

fn packageSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".app",
        .windows, .linux => "",
    };
}

const AppWebEngineConfig = struct {
    web_engine: WebEngineOption = .system,
    cef_dir: []const u8 = "third_party/cef/macos",
    cef_auto_install: bool = false,
};

fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
    if (!std.mem.eql(u8, configured, "third_party/cef/macos")) return configured;
    return switch (platform) {
        .linux => "third_party/cef/linux",
        .windows => "third_party/cef/windows",
        else => configured,
    };
}

fn appWebEngineConfig() AppWebEngineConfig {
    const source = @embedFile("app.zon");
    var config: AppWebEngineConfig = .{};
    if (stringField(source, ".web_engine")) |value| {
        config.web_engine = parseWebEngine(value) orelse .system;
    }
    if (objectSection(source, ".cef")) |cef| {
        if (stringField(cef, ".dir")) |value| config.cef_dir = value;
        if (boolField(cef, ".auto_install")) |value| config.cef_auto_install = value;
    }
    return config;
}

fn parseWebEngine(value: []const u8) ?WebEngineOption {
    if (std.mem.eql(u8, value, "system")) return .system;
    if (std.mem.eql(u8, value, "chromium")) return .chromium;
    return null;
}

fn stringField(source: []const u8, field: []const u8) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
    const start_quote = std.mem.indexOfScalarPos(u8, source, equals, '"') orelse return null;
    const end_quote = std.mem.indexOfScalarPos(u8, source, start_quote + 1, '"') orelse return null;
    return source[start_quote + 1 .. end_quote];
}

fn objectSection(source: []const u8, field: []const u8) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, source, field_index, '{') orelse return null;
    var depth: usize = 0;
    var index = open;
    while (index < source.len) : (index += 1) {
        switch (source[index]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return source[open + 1 .. index];
            },
            else => {},
        }
    }
    return null;
}

fn boolField(source: []const u8, field: []const u8) ?bool {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
    var index = equals + 1;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    if (std.mem.startsWith(u8, source[index..], "true")) return true;
    if (std.mem.startsWith(u8, source[index..], "false")) return false;
    return null;
}
