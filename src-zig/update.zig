//! In-app self-update, mirroring the flow Spork and Quad use (modeled on
//! milim, github.com/oshtz/milim), reshaped for this codebase: the bridge
//! dispatches synchronously on the UI thread, so the release check and the
//! download both run as poll-based jobs (main.zig's JobRegistry, same as the
//! import commands) and this module holds the blocking work plus the pure
//! helpers those workers call.
//!
//! Flow: `checkLatest` fetches the newest GitHub release and picks this
//! platform's asset + its `.sha256` sidecar; `downloadAndStage` streams the
//! asset down (progress via `Progress` atomics), verifies the checksum, and
//! stages it under `<storage_root>/updates` (macOS additionally extracts the
//! .app from the release zip via `ditto`); `applyStaged` spawns a detached
//! swap script that waits for this process to exit, swaps the portable exe
//! (Windows) or .app bundle (macOS) with a backup, and relaunches. A failed
//! swap restores the backup and leaves an error marker `takeRecoveryError`
//! surfaces once on the next launch.

const std = @import("std");
const builtin = @import("builtin");

const app_manifest = @import("app_manifest_zon");

/// The running app's version, straight from app.zon (the same manifest field
/// CI's "Verify tag matches manifest version" step checks against the tag).
pub const current_version: []const u8 = app_manifest.version;

const github_repo = "lzitser23/maat";
const user_agent = "Maat/" ++ current_version;

pub const max_package_bytes: usize = 512 * 1024 * 1024;
const max_checksum_bytes: usize = 1024 * 1024;
const max_release_json_bytes: usize = 4 * 1024 * 1024;
const recovery_error_name = "install-error.txt";

/// Byte counters the download worker publishes and `update_progress` reads
/// from the bridge thread. One download runs at a time (`update_download_start`
/// enforces it), so a single shared instance is enough.
pub const Progress = struct {
    downloaded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn reset(self: *Progress) void {
        self.downloaded.store(0, .monotonic);
        self.total.store(0, .monotonic);
    }
};

pub const UpdateInfo = struct {
    version: []const u8,
    assetName: []const u8,
    downloadUrl: []const u8,
    checksumUrl: []const u8,

    pub fn toJson(self: UpdateInfo, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

/// Numeric-segment version compare, tolerant of a leading "v" — the same
/// rule Spork/Quad's updateCheck.ts applies.
pub fn isNewer(candidate: []const u8, current: []const u8) bool {
    var a = std.mem.splitScalar(u8, std.mem.trimStart(u8, std.mem.trim(u8, candidate, " \t"), "vV"), '.');
    var b = std.mem.splitScalar(u8, std.mem.trimStart(u8, std.mem.trim(u8, current, " \t"), "vV"), '.');
    while (true) {
        const as = a.next();
        const bs = b.next();
        if (as == null and bs == null) return false;
        const av = if (as) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        const bv = if (bs) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        if (av != bv) return av > bv;
    }
}

/// Whether `name` is this platform's update package (CI's release asset
/// naming: "Maat-portable-vX.Y.Z.exe" / "Maat-macos-vX.Y.Z.zip").
pub fn isPlatformAsset(name: []const u8) bool {
    if (builtin.os.tag == .windows) {
        return std.mem.startsWith(u8, name, "Maat-portable-") and std.mem.endsWith(u8, name, ".exe");
    }
    if (builtin.os.tag == .macos) {
        return std.mem.startsWith(u8, name, "Maat-macos-") and std.mem.endsWith(u8, name, ".zip");
    }
    return false;
}

/// Release-asset basenames only; anything path-like is hostile.
pub fn validateAssetName(name: []const u8) error{InvalidUpdateAsset}!void {
    if (name.len == 0 or name[0] == '.') return error.InvalidUpdateAsset;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidUpdateAsset;
    if (!(std.mem.endsWith(u8, name, ".exe") or std.mem.endsWith(u8, name, ".zip")))
        return error.InvalidUpdateAsset;
}

/// Only GitHub release URLs over https — these round-trip through the
/// webview between the check and the download.
pub fn validateDownloadUrl(url: []const u8) error{InvalidUpdateUrl}!void {
    const uri = std.Uri.parse(url) catch return error.InvalidUpdateUrl;
    if (!std.mem.eql(u8, uri.scheme, "https")) return error.InvalidUpdateUrl;
    const host_component = uri.host orelse return error.InvalidUpdateUrl;
    var host_buf: [256]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return error.InvalidUpdateUrl;
    if (!(std.mem.eql(u8, host, "github.com") or std.mem.eql(u8, host, "api.github.com")))
        return error.InvalidUpdateUrl;
}

/// First 64-hex-digit token in a checksum file line — matches "<hash>  <name>",
/// "<name>: <hash>", and bare-hash layouts.
fn firstSha256Hex(line: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        const is_hex = i < line.len and std.ascii.isHex(line[i]);
        if (is_hex) {
            if (start == null) start = i;
        } else if (start) |s| {
            if (i - s == 64) return line[s..i];
            start = null;
        }
    }
    return null;
}

pub fn expectedSha256(checksum_text: []const u8, asset_name: []const u8) ?[]const u8 {
    var single_line: ?[]const u8 = null;
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, checksum_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        line_count += 1;
        single_line = line;
        if (std.mem.indexOf(u8, line, asset_name) != null) {
            if (firstSha256Hex(line)) |hex| return hex;
        }
    }
    if (line_count == 1) return firstSha256Hex(single_line.?);
    return null;
}

pub fn verifyChecksum(bytes: []const u8, checksum_text: []const u8, asset_name: []const u8) error{ ChecksumMissing, ChecksumMismatch }!void {
    const expected = expectedSha256(checksum_text, asset_name) orelse return error.ChecksumMissing;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var actual_buf: [64]u8 = undefined;
    const actual = std.fmt.bufPrint(&actual_buf, "{x}", .{&digest}) catch unreachable;
    var expected_lower_buf: [64]u8 = undefined;
    for (expected, 0..) |ch, i| expected_lower_buf[i] = std.ascii.toLower(ch);
    if (!std.mem.eql(u8, actual, expected_lower_buf[0..expected.len])) return error.ChecksumMismatch;
}

/// The platform asset + sidecar out of a GitHub release JSON document, or
/// null when the release is not newer / carries no self-update package
/// (older releases, or a platform without one). All strings are duped onto
/// `allocator`.
pub fn pickUpdate(allocator: std.mem.Allocator, release_json: []const u8) !?UpdateInfo {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, release_json, .{}) catch return error.BadReleaseJson;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadReleaseJson,
    };
    const tag = switch (root.get("tag_name") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!isNewer(tag, current_version)) return null;
    const assets = switch (root.get("assets") orelse return null) {
        .array => |a| a,
        else => return null,
    };

    var asset_name: ?[]const u8 = null;
    var asset_url: ?[]const u8 = null;
    var checksum_url: ?[]const u8 = null;
    for (assets.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const url = switch (obj.get("browser_download_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (isPlatformAsset(name)) {
            asset_name = name;
            asset_url = url;
        }
    }
    const found_name = asset_name orelse return null;
    for (assets.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (name.len == found_name.len + ".sha256".len and
            std.mem.startsWith(u8, name, found_name) and
            std.mem.endsWith(u8, name, ".sha256"))
        {
            checksum_url = switch (obj.get("browser_download_url") orelse continue) {
                .string => |s| s,
                else => continue,
            };
        }
    }
    const found_checksum_url = checksum_url orelse return null;

    return .{
        .version = try allocator.dupe(u8, tag),
        .assetName = try allocator.dupe(u8, found_name),
        .downloadUrl = try allocator.dupe(u8, asset_url.?),
        .checksumUrl = try allocator.dupe(u8, found_checksum_url),
    };
}

fn fetchBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    max_bytes: usize,
    progress: ?*Progress,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = user_agent },
            .{ .name = "Accept", .value = "application/octet-stream, application/vnd.github+json" },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success) return error.UpdateHttpFailure;

    if (progress) |p| {
        if (response.head.content_length) |len| p.total.store(len, .monotonic);
    }

    var transfer_buffer: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = body_reader.readSliceShort(&chunk) catch return error.UpdateHttpFailure;
        if (n == 0) break;
        if (bytes.items.len + n > max_bytes) return error.UpdateTooLarge;
        try bytes.appendSlice(allocator, chunk[0..n]);
        if (progress) |p| p.downloaded.store(bytes.items.len, .monotonic);
    }
    if (bytes.items.len == 0) return error.UpdateHttpFailure;
    return bytes.toOwnedSlice(allocator);
}

/// The newest release's update package for this platform, or null when
/// up-to-date / nothing shippable. Runs on a job worker thread.
pub fn checkLatest(allocator: std.mem.Allocator, io: std.Io) !?UpdateInfo {
    const url = "https://api.github.com/repos/" ++ github_repo ++ "/releases/latest";
    const body = try fetchBytes(allocator, io, url, max_release_json_bytes, null);
    defer allocator.free(body);
    return pickUpdate(allocator, body);
}

fn updatesDir(allocator: std.mem.Allocator, storage_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ storage_root, "updates" });
}

/// Download the package + sidecar, verify, and stage under
/// `<storage_root>/updates`. On macOS the release zip is then extracted via
/// `ditto` and the inner `.app` path is returned; on Windows the staged exe
/// path is returned. Runs on a job worker thread.
pub fn downloadAndStage(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage_root: []const u8,
    asset_name: []const u8,
    download_url: []const u8,
    checksum_url: []const u8,
    progress: *Progress,
) ![]u8 {
    try validateAssetName(asset_name);
    try validateDownloadUrl(download_url);
    try validateDownloadUrl(checksum_url);
    progress.reset();

    const package = try fetchBytes(allocator, io, download_url, max_package_bytes, progress);
    defer allocator.free(package);
    const checksum = try fetchBytes(allocator, io, checksum_url, max_checksum_bytes, null);
    defer allocator.free(checksum);
    try verifyChecksum(package, checksum, asset_name);

    const update_root = try updatesDir(allocator, storage_root);
    defer allocator.free(update_root);
    try std.Io.Dir.cwd().createDirPath(io, update_root);
    const staged = try std.fs.path.join(allocator, &.{ update_root, asset_name });
    errdefer allocator.free(staged);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staged, .data = package });

    if (builtin.os.tag != .macos) return staged;

    // macOS: the release asset is a ditto-zip of the signed .app; unpack it
    // next to itself and hand back the bundle. The zip never carried a
    // quarantine attribute (this process downloaded it), so the extracted
    // app launches without a Gatekeeper block.
    defer allocator.free(staged);
    const extract_dir = try std.fs.path.join(allocator, &.{ update_root, "extracted" });
    defer allocator.free(extract_dir);
    std.Io.Dir.cwd().deleteTree(io, extract_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, extract_dir);

    var ditto = try std.process.spawn(io, .{
        .argv = &.{ "ditto", "-xk", staged, extract_dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try ditto.wait(io);
    if (term != .exited or term.exited != 0) return error.UpdateExtractFailed;
    std.Io.Dir.cwd().deleteFile(io, staged) catch {};

    var dir = try std.Io.Dir.cwd().openDir(io, extract_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".app")) {
            return std.fs.path.join(allocator, &.{ extract_dir, entry.name });
        }
    }
    return error.UpdateExtractFailed;
}

/// The error marker a failed swap script left behind, consumed on read so the
/// next launch reports it exactly once.
pub fn takeRecoveryError(allocator: std.mem.Allocator, io: std.Io, storage_root: []const u8) !?[]u8 {
    const update_root = try updatesDir(allocator, storage_root);
    defer allocator.free(update_root);
    const marker = try std.fs.path.join(allocator, &.{ update_root, recovery_error_name });
    defer allocator.free(marker);
    const contents = std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(io, marker) catch {};
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(contents);
        return null;
    }
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(contents);
    return owned;
}

/// `staged_path` must live inside `<storage_root>/updates` and be the
/// platform's install shape (.exe / .app) — it round-tripped through the
/// webview between the download job and `update_apply`.
pub fn validateStagedPath(storage_root: []const u8, staged_path: []const u8) error{InvalidUpdateAsset}!void {
    // Prefix check on the un-canonicalized paths: both come from this
    // process (storage_root from boot, staged_path originally from
    // downloadAndStage), so symlink games would require the attacker to
    // already control the storage root.
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}{c}updates{c}", .{ storage_root, std.fs.path.sep, std.fs.path.sep }) catch return error.InvalidUpdateAsset;
    if (!std.mem.startsWith(u8, staged_path, prefix)) return error.InvalidUpdateAsset;
    if (std.mem.indexOf(u8, staged_path, "..") != null) return error.InvalidUpdateAsset;
    const expect_suffix = if (builtin.os.tag == .windows) ".exe" else ".app";
    if (!std.mem.endsWith(u8, staged_path, expect_suffix)) return error.InvalidUpdateAsset;
}

fn escapePowershellLiteral(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, value, "'", "''");
}

fn escapeBashLiteral(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, value, "'", "'\\''");
}

/// Spawn the platform swap script against the staged update. The caller
/// closes the window right after; the script waits for this pid to exit,
/// swaps with a backup, relaunches, and restores + leaves the recovery
/// marker if the swap never succeeds.
pub fn applyStaged(allocator: std.mem.Allocator, io: std.Io, storage_root: []const u8, staged_path: []const u8) !void {
    try validateStagedPath(storage_root, staged_path);

    const update_root = try updatesDir(allocator, storage_root);
    defer allocator.free(update_root);
    try std.Io.Dir.cwd().createDirPath(io, update_root);
    const error_marker = try std.fs.path.join(allocator, &.{ update_root, recovery_error_name });
    defer allocator.free(error_marker);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    const pid = if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        std.c.getpid();

    if (builtin.os.tag == .windows) {
        const script_path = try std.fs.path.join(allocator, &.{ update_root, "apply-update.ps1" });
        defer allocator.free(script_path);
        const log_path = try std.fs.path.join(allocator, &.{ update_root, "install.log" });
        defer allocator.free(log_path);

        const source_esc = try escapePowershellLiteral(allocator, staged_path);
        defer allocator.free(source_esc);
        const target_esc = try escapePowershellLiteral(allocator, self_exe);
        defer allocator.free(target_esc);
        const log_esc = try escapePowershellLiteral(allocator, log_path);
        defer allocator.free(log_esc);
        const marker_esc = try escapePowershellLiteral(allocator, error_marker);
        defer allocator.free(marker_esc);
        const script_esc = try escapePowershellLiteral(allocator, script_path);
        defer allocator.free(script_esc);

        const script = try std.fmt.allocPrint(allocator,
            \\param([switch]$Elevated)
            \\$ErrorActionPreference = 'Stop'
            \\$procId = {d}
            \\$source = '{s}'
            \\$target = '{s}'
            \\$backup = "$target.previous"
            \\$staged = "$target.update"
            \\$log = '{s}'
            \\$errorMarker = '{s}'
            \\$script = '{s}'
            \\
            \\function Write-UpdateLog([string]$message) {{
            \\  try {{ Add-Content -LiteralPath $log -Value "$((Get-Date).ToString('s')) $message" }} catch {{}}
            \\}}
            \\
            \\Write-UpdateLog "Waiting for process $procId to exit."
            \\while (Get-Process -Id $procId -ErrorAction SilentlyContinue) {{
            \\  Start-Sleep -Milliseconds 200
            \\}}
            \\
            \\for ($attempt = 1; $attempt -le 120; $attempt++) {{
            \\  try {{
            \\    if (Test-Path -LiteralPath $backup) {{
            \\      Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            \\    }}
            \\    if (-not (Test-Path -LiteralPath $source)) {{
            \\      throw "Downloaded update is missing: $source"
            \\    }}
            \\    Copy-Item -LiteralPath $source -Destination $staged -Force
            \\    Move-Item -LiteralPath $target -Destination $backup -Force
            \\    Move-Item -LiteralPath $staged -Destination $target -Force
            \\    Write-UpdateLog "Installed update on attempt $attempt."
            \\    Start-Process -FilePath $target
            \\    Start-Sleep -Seconds 2
            \\    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            \\    Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
            \\    exit 0
            \\  }} catch {{
            \\    Write-UpdateLog "Attempt $attempt failed: $($_.Exception.Message)"
            \\    if ((-not (Test-Path -LiteralPath $target)) -and (Test-Path -LiteralPath $backup)) {{
            \\      try {{ Move-Item -LiteralPath $backup -Destination $target -Force }} catch {{}}
            \\    }}
            \\    Start-Sleep -Milliseconds 500
            \\  }}
            \\}}
            \\
            \\if (-not $Elevated) {{
            \\  try {{
            \\    Write-UpdateLog "Retrying update with elevation."
            \\    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script, "-Elevated")
            \\    exit 0
            \\  }} catch {{
            \\    Write-UpdateLog "Elevation failed: $($_.Exception.Message)"
            \\  }}
            \\}}
            \\
            \\Write-UpdateLog "Update failed after retries."
            \\try {{
            \\  Set-Content -LiteralPath $errorMarker -Value "The last update failed after Maat closed; the previous version was restored. See $log for details."
            \\}} catch {{}}
            \\try {{
            \\  if ((-not (Test-Path -LiteralPath $target)) -and (Test-Path -LiteralPath $backup)) {{
            \\    Move-Item -LiteralPath $backup -Destination $target -Force
            \\  }}
            \\  if (Test-Path -LiteralPath $target) {{ Start-Process -FilePath $target }}
            \\}} catch {{}}
            \\exit 1
            \\
        , .{ pid, source_esc, target_esc, log_esc, marker_esc, script_esc });
        defer allocator.free(script);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });

        _ = try std.process.spawn(io, .{
            .argv = &.{
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-WindowStyle",
                "Hidden",
                "-File",
                script_path,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        });
        return;
    }

    if (builtin.os.tag == .macos) {
        // self_exe is <bundle>.app/Contents/MacOS/<binary>.
        const macos_dir = std.fs.path.dirname(self_exe) orelse return error.InvalidUpdateAsset;
        const contents_dir = std.fs.path.dirname(macos_dir) orelse return error.InvalidUpdateAsset;
        const app_bundle = std.fs.path.dirname(contents_dir) orelse return error.InvalidUpdateAsset;

        const source_esc = try escapeBashLiteral(allocator, staged_path);
        defer allocator.free(source_esc);
        const target_esc = try escapeBashLiteral(allocator, app_bundle);
        defer allocator.free(target_esc);
        const marker_esc = try escapeBashLiteral(allocator, error_marker);
        defer allocator.free(marker_esc);

        const script = try std.fmt.allocPrint(allocator,
            \\set -e
            \\pid={d}
            \\source='{s}'
            \\target='{s}'
            \\backup="$target.previous"
            \\error_marker='{s}'
            \\while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            \\trap 'echo "The last update failed after Maat closed; the previous version was restored." > "$error_marker"; if [ ! -e "$target" ] && [ -e "$backup" ]; then mv "$backup" "$target"; open "$target"; fi' ERR
            \\rm -rf "$backup"
            \\mv "$target" "$backup"
            \\mv "$source" "$target"
            \\open "$target"
            \\rm -rf "$backup"
            \\
        , .{ pid, source_esc, target_esc, marker_esc });
        defer allocator.free(script);

        _ = try std.process.spawn(io, .{
            .argv = &.{ "bash", "-c", script },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        return;
    }

    return error.UpdateUnsupportedPlatform;
}

// ---- Tests ----------------------------------------------------------------

test "isNewer compares numeric segments and tolerates a v prefix" {
    try std.testing.expect(isNewer("v0.2.0", "0.1.0"));
    try std.testing.expect(isNewer("0.1.1", "0.1.0"));
    try std.testing.expect(!isNewer("v0.1.0", "0.1.0"));
    try std.testing.expect(!isNewer("0.0.9", "0.1.0"));
    try std.testing.expect(isNewer("1.0", "0.9.9"));
}

test "asset names reject paths and unknown types" {
    try validateAssetName("Maat-portable-v0.2.0.exe");
    try validateAssetName("Maat-macos-v0.2.0.zip");
    try std.testing.expectError(error.InvalidUpdateAsset, validateAssetName("../evil.exe"));
    try std.testing.expectError(error.InvalidUpdateAsset, validateAssetName("dir\\evil.exe"));
    try std.testing.expectError(error.InvalidUpdateAsset, validateAssetName(".hidden.exe"));
    try std.testing.expectError(error.InvalidUpdateAsset, validateAssetName("notes.txt"));
    try std.testing.expectError(error.InvalidUpdateAsset, validateAssetName(""));
}

test "download URLs must be GitHub https" {
    try validateDownloadUrl("https://github.com/x/y/releases/download/v1/a.exe");
    try validateDownloadUrl("https://api.github.com/repos/x/y/releases/assets/1");
    try std.testing.expectError(error.InvalidUpdateUrl, validateDownloadUrl("http://github.com/a.exe"));
    try std.testing.expectError(error.InvalidUpdateUrl, validateDownloadUrl("https://evil.com/a.exe"));
}

test "checksum parsing handles common layouts" {
    const name = "Maat-portable-v0.2.0.exe";
    const hash = "a" ** 64;
    try std.testing.expectEqualStrings(hash, expectedSha256(hash ++ "  " ++ name ++ "\n", name).?);
    const aggregate = ("b" ** 64) ++ "  other.dmg\n" ++ hash ++ "  " ++ name ++ "\n";
    try std.testing.expectEqualStrings(hash, expectedSha256(aggregate, name).?);
    try std.testing.expectEqualStrings(hash, expectedSha256(hash ++ "\n", name).?);
    try std.testing.expect(expectedSha256("no hashes here", name) == null);
}

test "checksum verification matches sha256" {
    const name = "Maat-portable-v0.2.0.exe";
    const bytes = "maat update bytes";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex_buf: [64]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{x}", .{&digest});
    var line_buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{s}  {s}", .{ hex, name });
    try verifyChecksum(bytes, line, name);
    const wrong = ("0" ** 64) ++ "  " ++ name;
    try std.testing.expectError(error.ChecksumMismatch, verifyChecksum(bytes, wrong, name));
}

test "pickUpdate selects the platform asset with its sidecar" {
    const allocator = std.testing.allocator;
    const asset_name = if (builtin.os.tag == .windows)
        "Maat-portable-v99.0.0.exe"
    else if (builtin.os.tag == .macos)
        "Maat-macos-v99.0.0.zip"
    else
        return; // no self-update asset on this platform
    const json = try std.fmt.allocPrint(allocator,
        \\{{"tag_name":"v99.0.0","assets":[
        \\ {{"name":"Maat-v99.0.0.dmg","browser_download_url":"https://github.com/x/y/releases/download/v99.0.0/Maat-v99.0.0.dmg"}},
        \\ {{"name":"{s}","browser_download_url":"https://github.com/x/y/releases/download/v99.0.0/{s}"}},
        \\ {{"name":"{s}.sha256","browser_download_url":"https://github.com/x/y/releases/download/v99.0.0/{s}.sha256"}}
        \\]}}
    , .{ asset_name, asset_name, asset_name, asset_name });
    defer allocator.free(json);

    const info = (try pickUpdate(allocator, json)).?;
    defer {
        allocator.free(info.version);
        allocator.free(info.assetName);
        allocator.free(info.downloadUrl);
        allocator.free(info.checksumUrl);
    }
    try std.testing.expectEqualStrings("v99.0.0", info.version);
    try std.testing.expectEqualStrings(asset_name, info.assetName);
    try std.testing.expect(std.mem.endsWith(u8, info.checksumUrl, ".sha256"));
}

test "pickUpdate returns null without a checksum sidecar or when not newer" {
    const allocator = std.testing.allocator;
    const no_sidecar =
        \\{"tag_name":"v99.0.0","assets":[
        \\ {"name":"Maat-portable-v99.0.0.exe","browser_download_url":"https://github.com/x/y/a.exe"}
        \\]}
    ;
    try std.testing.expect((try pickUpdate(allocator, no_sidecar)) == null);
    const old =
        \\{"tag_name":"v0.0.1","assets":[]}
    ;
    try std.testing.expect((try pickUpdate(allocator, old)) == null);
}
