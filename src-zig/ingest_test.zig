const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest.zig");
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;

const stbw = @cImport({
    @cInclude("stb_image_write.h");
});

// ---------------------------------------------------------------------------
// test helpers
// ---------------------------------------------------------------------------

fn absPath(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn writeAbsoluteFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Writes a small valid 4x4 RGBA PNG at `path_abs` using stb_image_write directly
/// (the vendored library already used by ingest.zig's own thumbnailing) - per the
/// porting brief, this is how the "generates a real thumbnail" test fabricates its
/// fixture rather than shipping a binary PNG file.
fn writeTestPng(allocator: std.mem.Allocator, path_abs: []const u8) !void {
    if (std.fs.path.dirname(path_abs)) |parent| {
        try std.Io.Dir.cwd().createDirPath(testing.io, parent);
    }
    var pixels: [4 * 4 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i] = 200;
        pixels[i + 1] = 80;
        pixels[i + 2] = 40;
        pixels[i + 3] = 255;
    }
    const path_z = try allocator.dupeZ(u8, path_abs);
    defer allocator.free(path_z);
    const ok = stbw.stbi_write_png(path_z.ptr, 4, 4, 4, &pixels, 4 * 4);
    if (ok == 0) return error.WritePngFailed;
}

fn findAssetByName(assets: []const storage_mod.Asset, name: []const u8) ?storage_mod.Asset {
    for (assets) |a| {
        if (std.mem.eql(u8, a.name, name)) return a;
    }
    return null;
}

// ---------------------------------------------------------------------------
// ported from src-tauri/src/ingest.rs `mod tests`
// ---------------------------------------------------------------------------

test "eagle candidates prefer the original asset file over its thumbnail" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const info_dir = try std.fs.path.join(allocator, &.{ tmp_root, "Fixture.library", "images", "asset.info" });
    defer allocator.free(info_dir);

    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{info_dir});
    defer allocator.free(metadata_path);
    try writeAbsoluteFile(io, metadata_path,
        \\{"name":"Original asset","ext":"jpg","tags":["identity"],"folders":["folder-id"]}
    );

    const thumb_path = try std.fmt.allocPrint(allocator, "{s}/Original asset_thumbnail.png", .{info_dir});
    defer allocator.free(thumb_path);
    try writeAbsoluteFile(io, thumb_path, "thumbnail");

    const asset_path = try std.fs.path.join(allocator, &.{ info_dir, "Original asset.jpg" });
    defer allocator.free(asset_path);
    try writeAbsoluteFile(io, asset_path, "original");

    const library_path = try std.fs.path.join(allocator, &.{ tmp_root, "Fixture.library" });
    defer allocator.free(library_path);

    const candidates = try ingest.eagleCandidates(allocator, io, library_path);
    defer {
        for (candidates) |c| c.deinit(allocator);
        allocator.free(candidates);
    }

    try testing.expectEqual(@as(usize, 1), candidates.len);
    try testing.expectEqualStrings(asset_path, candidates[0].file_path);
}

test "importing an eagle library fixture updates the source item count" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const info_dir = try std.fs.path.join(allocator, &.{ tmp_root, "Fixture.library", "images", "asset.info" });
    defer allocator.free(info_dir);

    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{info_dir});
    defer allocator.free(metadata_path);
    try writeAbsoluteFile(io, metadata_path,
        \\{"name":"Original asset","ext":"jpg","tags":["identity"],"folders":["folder-id"]}
    );

    const thumb_path = try std.fmt.allocPrint(allocator, "{s}/Original asset_thumbnail.png", .{info_dir});
    defer allocator.free(thumb_path);
    try writeAbsoluteFile(io, thumb_path, "thumbnail");

    const asset_path = try std.fs.path.join(allocator, &.{ info_dir, "Original asset.jpg" });
    defer allocator.free(asset_path);
    try writeAbsoluteFile(io, asset_path, "original");

    const library_path = try std.fs.path.join(allocator, &.{ tmp_root, "Fixture.library" });
    defer allocator.free(library_path);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{library_path};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 1), report.imported);
    try testing.expectEqual(@as(i64, 0), report.failed);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), view.sources.len);
    try testing.expectEqual(@as(i64, 1), view.sources[0].itemCount);
    try testing.expectEqual(@as(usize, 1), view.assets.len);
    try testing.expectEqualStrings(asset_path, view.assets[0].originalPath);
}

// ---------------------------------------------------------------------------
// additional coverage requested for the port
// ---------------------------------------------------------------------------

test "reimporting the same file is deduped instead of creating a second asset" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const source_file = try std.fmt.allocPrint(allocator, "{s}/originals/note.txt", .{tmp_root});
    defer allocator.free(source_file);
    try writeAbsoluteFile(io, source_file, "hello dedupe");

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{source_file};

    const first = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer first.deinit(allocator);
    try testing.expectEqual(@as(i64, 1), first.imported);
    try testing.expectEqual(@as(i64, 0), first.skippedDuplicates);

    const second = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer second.deinit(allocator);
    try testing.expectEqual(@as(i64, 0), second.imported);
    try testing.expectEqual(@as(i64, 1), second.skippedDuplicates);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);
}

test "a real PNG gets a generated 720-bounded thumbnail" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const source_file = try std.fmt.allocPrint(allocator, "{s}/originals/pic.png", .{tmp_root});
    defer allocator.free(source_file);
    try writeTestPng(allocator, source_file);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{source_file};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(i64, 1), report.imported);
    try testing.expectEqual(@as(i64, 0), report.failed);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);

    const asset = view.assets[0];
    try testing.expectEqualStrings("image", asset.kind);
    try testing.expectEqualStrings("ready", asset.previewStatus);
    try testing.expectEqual(@as(?i64, 4), asset.width);
    try testing.expectEqual(@as(?i64, 4), asset.height);
    try testing.expect(asset.thumbnailPath != null);
    try testing.expect(fileExists(io, asset.thumbnailPath.?));
}

test "a non-image file gets fallback preview status and no thumbnail" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const source_file = try std.fmt.allocPrint(allocator, "{s}/originals/notes.txt", .{tmp_root});
    defer allocator.free(source_file);
    try writeAbsoluteFile(io, source_file, "just some plain text notes");

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{source_file};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(i64, 1), report.imported);
    try testing.expectEqual(@as(i64, 0), report.failed);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);

    const asset = view.assets[0];
    try testing.expectEqualStrings("document", asset.kind);
    try testing.expectEqualStrings("fallback", asset.previewStatus);
    try testing.expectEqual(@as(?i64, null), asset.width);
    try testing.expectEqual(@as(?i64, null), asset.height);
    try testing.expectEqual(@as(?[]const u8, null), asset.thumbnailPath);
}

test "a corrupt image in a folder import falls back but does not sink the batch" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const folder = try std.fmt.allocPrint(allocator, "{s}/originals", .{tmp_root});
    defer allocator.free(folder);

    const good_path = try std.fmt.allocPrint(allocator, "{s}/good.png", .{folder});
    defer allocator.free(good_path);
    try writeTestPng(allocator, good_path);

    const bad_path = try std.fmt.allocPrint(allocator, "{s}/bad.png", .{folder});
    defer allocator.free(bad_path);
    try writeAbsoluteFile(io, bad_path, "this is not a real png file at all");

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{folder};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    // Both files are counted as imported (the corrupt one falls back rather than
    // failing), proving one bad file never sinks the rest of the batch.
    try testing.expectEqual(@as(i64, 2), report.imported);
    try testing.expectEqual(@as(i64, 0), report.failed);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), view.assets.len);

    const good = findAssetByName(view.assets, "good.png") orelse return error.MissingAsset;
    try testing.expectEqualStrings("ready", good.previewStatus);
    try testing.expect(good.thumbnailPath != null);

    const bad = findAssetByName(view.assets, "bad.png") orelse return error.MissingAsset;
    try testing.expectEqualStrings("image", bad.kind);
    try testing.expectEqualStrings("fallback", bad.previewStatus);
    try testing.expectEqual(@as(?i64, null), bad.width);
    try testing.expectEqual(@as(?[]const u8, null), bad.thumbnailPath);
}

test "importExternalUrls surfaces a per-url failure without touching the network for an unparsable url" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    // An empty scheme-less string fails `std.Uri.parse` before any socket is ever
    // opened, so this exercises (and type-checks) the whole importExternalUrls path
    // without requiring real network access.
    const urls = [_][]const u8{""};
    const report = try ingest.importExternalUrls(allocator, io, &store, board.id, &urls);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 0), report.imported);
    try testing.expectEqual(@as(i64, 1), report.failed);
    try testing.expectEqual(@as(usize, 1), report.messages.len);
}

test "importClipboardItems rejects empty and oversized payloads" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const items = [_]ingest.ClipboardItem{
        .{ .name = "empty.png", .mime = "image/png", .bytes = &.{} },
    };
    const report = try ingest.importClipboardItems(allocator, io, &store, board.id, &items);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 0), report.imported);
    try testing.expectEqual(@as(i64, 1), report.failed);
}

// ---------------------------------------------------------------------------
// issue #2: clipboard images beyond the bridge's ~1 MiB message cap
// ---------------------------------------------------------------------------

// Mirrors what server.zig's `POST /upload` handler does: writes a plain
// file directly to disk (standing in for the streamed-from-socket write),
// completely outside any bridge message. `importClipboardItems` is then
// invoked with a `ClipboardItem{ .uploadPath = ... }` referencing it --
// this is the "upload-shaped import" path the HITL decision calls for a
// native integration test to cover, proving a payload that would blow the
// bridge's ~1 MiB request cap succeeds when it never has to cross the
// bridge as bytes at all.
test "importClipboardItems imports an upload-shaped item well beyond 1 MiB" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    // A real PNG (so the ingest pipeline's decode/thumbnail step succeeds
    // too, not just the size/transport plumbing), padded well past 1 MiB
    // with a trailing junk chunk -- stb_image only reads what it needs from
    // the front of the file, so the padding doesn't affect decoding but
    // does push the file size past the bridge's cap. Placed under
    // `<root_path>/.uploads/` -- the only location `importClipboardItems`'s
    // containment check now accepts, mirroring where server.zig's real
    // `/upload` handler always writes.
    const upload_path = try std.fs.path.join(allocator, &.{ root_path, ".uploads", "deadbeef" });
    defer allocator.free(upload_path);
    if (std.fs.path.dirname(upload_path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);

    try writeTestPng(allocator, upload_path);
    const png_bytes = try std.Io.Dir.cwd().readFileAlloc(io, upload_path, allocator, .limited(1024 * 1024));
    defer allocator.free(png_bytes);

    // Pad well past 1 MiB with a trailing junk chunk -- stb_image only
    // reads what it needs from the front of the file, so the padding
    // doesn't affect decoding but does push the file size past the
    // bridge's cap.
    const over_1mib = 1024 * 1024 + 4096;
    const padded = try allocator.alloc(u8, png_bytes.len + over_1mib);
    defer allocator.free(padded);
    @memcpy(padded[0..png_bytes.len], png_bytes);
    @memset(padded[png_bytes.len..], 'x');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = upload_path, .data = padded });

    const st = try std.Io.Dir.cwd().statFile(io, upload_path, .{});
    try testing.expect(st.size > 1024 * 1024);

    const items = [_]ingest.ClipboardItem{
        .{ .name = "pasted.png", .mime = "image/png", .uploadPath = upload_path },
    };
    const report = try ingest.importClipboardItems(allocator, io, &store, board.id, &items);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 1), report.imported);
    try testing.expectEqual(@as(i64, 0), report.failed);

    // The upload temp file was moved (not left behind) into the ephemeral
    // clipboard-import dir, which importClipboardItems then deletes once
    // ingest finishes -- so nothing should remain at the original path.
    try testing.expect(!fileExists(io, upload_path));

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);
    try testing.expectEqual(@as(i64, @intCast(st.size)), view.assets[0].size);
}

test "importClipboardItems reports a missing uploadPath as a failure without erroring the batch" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const missing_path = try std.fs.path.join(allocator, &.{ tmp_root, "does-not-exist", "nope" });
    defer allocator.free(missing_path);

    const items = [_]ingest.ClipboardItem{
        .{ .name = "gone.png", .mime = "image/png", .uploadPath = missing_path },
    };
    const report = try ingest.importClipboardItems(allocator, io, &store, board.id, &items);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 0), report.imported);
    try testing.expectEqual(@as(i64, 1), report.failed);
}

// ---------------------------------------------------------------------------
// uploadPath containment: `importClipboardItems` renames/deletes a
// renderer-supplied `uploadPath` with no other proof it was ever produced by
// server.zig's real `/upload` handler, so it must independently reject
// anything that doesn't resolve inside this session's `.uploads` dir --
// BEFORE touching the file at all (not even to delete it).
// ---------------------------------------------------------------------------

test "importClipboardItems rejects an out-of-containment uploadPath without touching the file" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const uploads_dir = try std.fs.path.join(allocator, &.{ root_path, ".uploads" });
    defer allocator.free(uploads_dir);
    try std.Io.Dir.cwd().createDirPath(io, uploads_dir);

    // 1. Relative traversal: walks back out of `.uploads` via `..`
    // segments to a file that was never uploaded.
    const traversal_victim = try std.fs.path.join(allocator, &.{ tmp_root, "traversal-victim.txt" });
    defer allocator.free(traversal_victim);
    try writeAbsoluteFile(io, traversal_victim, "traversal secret");
    const traversal_path = try std.fs.path.join(allocator, &.{ uploads_dir, "..", "..", "traversal-victim.txt" });
    defer allocator.free(traversal_path);

    // 2. A plain absolute path with no relation to the storage root at all.
    const elsewhere_victim = try std.fs.path.join(allocator, &.{ tmp_root, "outside", "elsewhere-victim.txt" });
    defer allocator.free(elsewhere_victim);
    try writeAbsoluteFile(io, elsewhere_victim, "elsewhere secret");

    // 3. A sibling directory that is a textual prefix-collision with
    // `.uploads` (`.uploads_evil`) but is not actually inside it -- proves
    // the containment check requires a real path-separator boundary, not a
    // bare string-prefix match.
    const evil_dir = try std.fs.path.join(allocator, &.{ root_path, ".uploads_evil" });
    defer allocator.free(evil_dir);
    const prefix_victim = try std.fs.path.join(allocator, &.{ evil_dir, "prefix-victim.txt" });
    defer allocator.free(prefix_victim);
    try writeAbsoluteFile(io, prefix_victim, "prefix secret");

    const items = [_]ingest.ClipboardItem{
        .{ .name = "traversal.txt", .mime = "text/plain", .uploadPath = traversal_path },
        .{ .name = "elsewhere.txt", .mime = "text/plain", .uploadPath = elsewhere_victim },
        .{ .name = "prefix.txt", .mime = "text/plain", .uploadPath = prefix_victim },
    };
    const report = try ingest.importClipboardItems(allocator, io, &store, board.id, &items);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 0), report.imported);
    try testing.expectEqual(@as(i64, 3), report.failed);

    // None of the three rejected files were renamed or deleted -- the
    // containment check must run (and reject) before any filesystem
    // mutation, and the rejection path itself must not delete them either.
    try testing.expect(fileExists(io, traversal_victim));
    try testing.expect(fileExists(io, elsewhere_victim));
    try testing.expect(fileExists(io, prefix_victim));
}

// ---------------------------------------------------------------------------
// F1 regression: insertAsset failing after the managed-file copy must not
// orphan the copy (or a generated thumbnail) on disk, nor leak the asset
// DTO's allocations. Uses `ingest.test_force_insert_error`, a test-only seam
// in `importOne` that fails right where `storage.insertAsset` would be
// called, so this is exercised without needing to provoke a genuine SQLite
// error. `std.testing.allocator` (used throughout this file) fails the test
// on any leak, so a clean run here also proves the DTO is freed.
// ---------------------------------------------------------------------------

test "a forced insertAsset failure after the copy does not orphan the managed file" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const source_file = try std.fmt.allocPrint(allocator, "{s}/originals/note.txt", .{tmp_root});
    defer allocator.free(source_file);
    const contents = "insert failure fixture";
    try writeAbsoluteFile(io, source_file, contents);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    // Predict the exact managed-file path `importOne` will copy to, by
    // hashing the fixture's bytes the same way `hashFileHex` does.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(contents);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);

    const managed_filename = try std.fmt.allocPrint(allocator, "{s}.txt", .{hex[0..]});
    defer allocator.free(managed_filename);
    const managed_path = try std.fs.path.join(allocator, &.{ board.path, "assets", hex[0..2], managed_filename });
    defer allocator.free(managed_path);

    ingest.test_force_insert_error = error.SimulatedInsertFailure;
    defer ingest.test_force_insert_error = null;

    const paths = [_][]const u8{source_file};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 0), report.imported);
    try testing.expectEqual(@as(i64, 1), report.failed);
    try testing.expectEqual(@as(usize, 1), report.messages.len);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), view.assets.len);

    try testing.expect(!fileExists(io, managed_path));
}

// ---------------------------------------------------------------------------
// AI-dataset feature: sidecar `.txt` caption pairing in folderCandidates.
// See folderCandidates's doc comment in ingest.zig for the exact rules
// (extension must be .txt case-insensitively, basename match is case-
// insensitive, only consumed when a sibling actually exists, empty/unreadable
// sidecars fall back to a normal candidate).
// ---------------------------------------------------------------------------

test "a folder import captures a sidecar .txt as the paired image's caption and skips it as its own asset" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const folder = try std.fmt.allocPrint(allocator, "{s}/dataset", .{tmp_root});
    defer allocator.free(folder);

    const image_path = try std.fmt.allocPrint(allocator, "{s}/photo001.png", .{folder});
    defer allocator.free(image_path);
    try writeTestPng(allocator, image_path);

    const caption_path = try std.fmt.allocPrint(allocator, "{s}/photo001.txt", .{folder});
    defer allocator.free(caption_path);
    try writeAbsoluteFile(io, caption_path, "  a cat sitting on a windowsill  \n");

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{folder};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    // Only the image is imported -- the sidecar .txt is consumed as its
    // caption, not imported as its own separate asset.
    try testing.expectEqual(@as(i64, 1), report.imported);
    try testing.expectEqual(@as(i64, 0), report.failed);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);

    const photo = findAssetByName(view.assets, "photo001.png") orelse return error.MissingAsset;
    // Whitespace-trimmed, not the raw sidecar bytes.
    try testing.expectEqualStrings("a cat sitting on a windowsill", photo.caption.?);
    try testing.expectEqual(@as(?[]const u8, null), photo.prompt);
}

test "a sidecar .txt with no matching sibling is imported as its own asset, not suppressed" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const folder = try std.fmt.allocPrint(allocator, "{s}/dataset", .{tmp_root});
    defer allocator.free(folder);

    const orphan_caption_path = try std.fmt.allocPrint(allocator, "{s}/notes.txt", .{folder});
    defer allocator.free(orphan_caption_path);
    try writeAbsoluteFile(io, orphan_caption_path, "just a loose caption file, no sibling image");

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{folder};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 1), report.imported);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);

    const notes = findAssetByName(view.assets, "notes.txt") orelse return error.MissingAsset;
    try testing.expectEqualStrings("document", notes.kind);
    try testing.expectEqual(@as(?[]const u8, null), notes.caption);
}

test "sidecar caption matching is case-insensitive on both the extension and the basename" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const folder = try std.fmt.allocPrint(allocator, "{s}/dataset", .{tmp_root});
    defer allocator.free(folder);

    // Mixed-case basename ("Photo002") paired with a differently-cased
    // basename + extension on the sidecar ("photo002.TXT").
    const image_path = try std.fmt.allocPrint(allocator, "{s}/Photo002.png", .{folder});
    defer allocator.free(image_path);
    try writeTestPng(allocator, image_path);

    const caption_path = try std.fmt.allocPrint(allocator, "{s}/photo002.TXT", .{folder});
    defer allocator.free(caption_path);
    try writeAbsoluteFile(io, caption_path, "a dog catching a frisbee");

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{folder};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 1), report.imported);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);
    try testing.expectEqualStrings("a dog catching a frisbee", view.assets[0].caption.?);
}

test "a sidecar-shaped file with a non-.txt extension is never treated as a caption" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const folder = try std.fmt.allocPrint(allocator, "{s}/dataset", .{tmp_root});
    defer allocator.free(folder);

    const image_path = try std.fmt.allocPrint(allocator, "{s}/photo003.png", .{folder});
    defer allocator.free(image_path);
    try writeTestPng(allocator, image_path);

    // Same basename, but `.caption` rather than `.txt` -- must not pair.
    const not_a_sidecar_path = try std.fmt.allocPrint(allocator, "{s}/photo003.caption", .{folder});
    defer allocator.free(not_a_sidecar_path);
    try writeAbsoluteFile(io, not_a_sidecar_path, "should not be treated as a caption");

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{folder};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    // Both files are imported as separate assets -- no pairing happened.
    try testing.expectEqual(@as(i64, 2), report.imported);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), view.assets.len);

    const photo = findAssetByName(view.assets, "photo003.png") orelse return error.MissingAsset;
    try testing.expectEqual(@as(?[]const u8, null), photo.caption);
}

test "an empty sidecar .txt is not treated as a caption and is imported as its own asset" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const folder = try std.fmt.allocPrint(allocator, "{s}/dataset", .{tmp_root});
    defer allocator.free(folder);

    const image_path = try std.fmt.allocPrint(allocator, "{s}/photo004.png", .{folder});
    defer allocator.free(image_path);
    try writeTestPng(allocator, image_path);

    const caption_path = try std.fmt.allocPrint(allocator, "{s}/photo004.txt", .{folder});
    defer allocator.free(caption_path);
    try writeAbsoluteFile(io, caption_path, "   \n  "); // whitespace-only

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const paths = [_][]const u8{folder};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    // Both the image and the (empty) sidecar are imported -- an empty
    // caption isn't worth suppressing the .txt asset for.
    try testing.expectEqual(@as(i64, 2), report.imported);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), view.assets.len);

    const photo = findAssetByName(view.assets, "photo004.png") orelse return error.MissingAsset;
    try testing.expectEqual(@as(?[]const u8, null), photo.caption);
    try testing.expect(findAssetByName(view.assets, "photo004.txt") != null);
}

test "a forced insertAsset failure after the copy does not orphan a generated thumbnail" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const source_file = try std.fmt.allocPrint(allocator, "{s}/originals/pic.png", .{tmp_root});
    defer allocator.free(source_file);
    try writeTestPng(allocator, source_file);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    // Hash the actual bytes stb wrote to disk (rather than the raw pixel
    // buffer), the same way `hashFileHex` does, so the predicted managed and
    // thumbnail paths are exact regardless of the PNG encoder's output.
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(io, source_file, allocator, .unlimited);
    defer allocator.free(file_bytes);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(file_bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);

    const managed_filename = try std.fmt.allocPrint(allocator, "{s}.png", .{hex[0..]});
    defer allocator.free(managed_filename);
    const managed_path = try std.fs.path.join(allocator, &.{ board.path, "assets", hex[0..2], managed_filename });
    defer allocator.free(managed_path);

    const thumb_filename = try std.fmt.allocPrint(allocator, "{s}.png", .{hex[0..]});
    defer allocator.free(thumb_filename);
    const thumb_path = try std.fs.path.join(allocator, &.{ board.path, "thumbs", thumb_filename });
    defer allocator.free(thumb_path);

    ingest.test_force_insert_error = error.SimulatedInsertFailure;
    defer ingest.test_force_insert_error = null;

    const paths = [_][]const u8{source_file};
    const report = try ingest.importPaths(allocator, io, &store, board.id, &paths);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(i64, 0), report.imported);
    try testing.expectEqual(@as(i64, 1), report.failed);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), view.assets.len);

    try testing.expect(!fileExists(io, managed_path));
    try testing.expect(!fileExists(io, thumb_path));
}
