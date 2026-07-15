const std = @import("std");
const testing = std.testing;
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;
const Asset = storage_mod.Asset;

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

/// Writes `contents` into `<board_path>/assets/<hash[0..2]>/<hash>.png`, mirroring
/// where ingest would place a managed copy, and returns the absolute path (caller
/// frees). Storage itself never writes asset content - this stands in for the
/// ingest step so purge/delete tests can assert the file is actually removed.
fn writeManagedAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    board_path: []const u8,
    hash: []const u8,
    contents: []const u8,
) ![]u8 {
    const managed_path = try std.fmt.allocPrint(allocator, "{s}/assets/{s}/{s}.png", .{ board_path, hash[0..2], hash });
    try writeAbsoluteFile(io, managed_path, contents);
    return managed_path;
}

fn blankAsset(board_id: []const u8, source_id: []const u8, hash: []const u8, managed_path: []const u8, original_path: []const u8) Asset {
    return Asset{
        .id = hash, // fine for tests: caller picks a unique-enough hash/id already
        .boardId = board_id,
        .sourceId = source_id,
        .name = "pic.png",
        .originalPath = original_path,
        .managedPath = managed_path,
        .mime = "image/png",
        .extension = "png",
        .size = 6,
        .hash = hash,
        .width = null,
        .height = null,
        .kind = "image",
        .previewStatus = "ready",
        .thumbnailPath = null,
        .tags = &.{},
        .folders = &.{},
        .note = null,
        .sourceUrl = null,
        .trashedAt = null,
        .createdAt = "2024-01-01T00:00:00.000+00:00",
        .metadataJson = null,
    };
}

// ---------------------------------------------------------------------------
// ported from src-tauri/src/storage.rs `mod tests`
// ---------------------------------------------------------------------------

test "purge removes rows and managed file but spares an outside-root original" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    const original_path = try std.fmt.allocPrint(allocator, "{s}/originals/pic.png", .{tmp_root});
    defer allocator.free(original_path);
    try writeAbsoluteFile(io, original_path, "pixels");

    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    try testing.expectEqual(@as(usize, 1), boards.len);
    const board = boards[0];

    const source = try store.insertSource(allocator, board.id, "folder", original_path, "managed");
    defer source.deinit(allocator);

    const hash = "aabbccddeeff00112233445566778899";
    const managed_path = try writeManagedAsset(allocator, io, board.path, hash, "pixels");
    defer allocator.free(managed_path);

    const asset = blankAsset(board.id, source.id, hash, managed_path, original_path);
    const inserted = try store.insertAsset(allocator, asset);
    try testing.expect(inserted);
    try store.bumpSourceCount(source.id, 1);

    {
        const view = try store.loadBoard(allocator, board.id);
        defer view.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), view.assets.len);
        try testing.expectEqual(@as(usize, 1), view.nodes.len);
        try testing.expectEqual(@as(i64, 1), view.sources[0].itemCount);
    }
    try testing.expect(fileExists(io, managed_path));

    try store.purgeAssets(allocator, board.id, &.{hash});

    const after = try store.loadBoard(allocator, board.id);
    defer after.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), after.assets.len);
    try testing.expectEqual(@as(usize, 0), after.nodes.len);
    try testing.expectEqual(@as(i64, 0), after.sources[0].itemCount);
    try testing.expect(!fileExists(io, managed_path));
    try testing.expect(fileExists(io, original_path));
}

test "deleting a source removes it with its assets but spares originals" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try absPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const root_path = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(root_path);
    const original_path = try std.fmt.allocPrint(allocator, "{s}/originals/pic.png", .{tmp_root});
    defer allocator.free(original_path);
    try writeAbsoluteFile(io, original_path, "pixels");

    var store = try Storage.open(allocator, root_path);
    defer store.close();

    const boards = try store.listBoards(allocator);
    defer {
        for (boards) |b| b.deinit(allocator);
        allocator.free(boards);
    }
    const board = boards[0];

    const source = try store.insertSource(allocator, board.id, "folder", original_path, "managed");
    defer source.deinit(allocator);

    const hash = "0123456789abcdef0123456789abcdef";
    const managed_path = try writeManagedAsset(allocator, io, board.path, hash, "pixels");
    defer allocator.free(managed_path);

    const asset = blankAsset(board.id, source.id, hash, managed_path, original_path);
    try testing.expect(try store.insertAsset(allocator, asset));
    try store.bumpSourceCount(source.id, 1);

    {
        const view = try store.loadBoard(allocator, board.id);
        defer view.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), view.sources.len);
        try testing.expectEqual(@as(usize, 1), view.assets.len);
    }
    try testing.expect(fileExists(io, managed_path));

    const after = try store.deleteSource(allocator, board.id, source.id);
    defer after.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), after.sources.len);
    try testing.expectEqual(@as(usize, 0), after.assets.len);
    try testing.expectEqual(@as(usize, 0), after.nodes.len);
    try testing.expect(!fileExists(io, managed_path));
    try testing.expect(fileExists(io, original_path));
}

test "purge never deletes a managed path outside the storage root" {
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

    const source = try store.insertSource(allocator, board.id, "file", "irrelevant", "managed");
    defer source.deinit(allocator);

    // Deliberately outside the storage root - a real ingest would never construct an
    // asset like this, but this is exactly the situation `remove_managed_file`'s
    // root-guard exists to protect against.
    const outside_path = try std.fmt.allocPrint(allocator, "{s}/precious.txt", .{tmp_root});
    defer allocator.free(outside_path);
    try writeAbsoluteFile(io, outside_path, "keep me");

    const hash = "deadbeefdeadbeefdeadbeefdeadbeef";
    const asset = blankAsset(board.id, source.id, hash, outside_path, outside_path);
    try testing.expect(try store.insertAsset(allocator, asset));

    try store.purgeAssets(allocator, board.id, &.{hash});

    // The DB row is gone (purge always removes the row)...
    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), view.assets.len);

    // ...but the file outside the root must never be touched.
    try testing.expect(fileExists(io, outside_path));
}

// ---------------------------------------------------------------------------
// additional coverage requested for the port
// ---------------------------------------------------------------------------

test "delete_board removes child rows instead of leaking orphans" {
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

    const first_boards = try store.listBoards(allocator);
    defer {
        for (first_boards) |b| b.deinit(allocator);
        allocator.free(first_boards);
    }
    const board_a_id = try allocator.dupe(u8, first_boards[0].id);
    defer allocator.free(board_a_id);

    const board_b = try store.createBoard(allocator, "Second board");
    defer board_b.deinit(allocator);
    const board_b_path = try allocator.dupe(u8, board_b.path);
    defer allocator.free(board_b_path);
    const board_b_id = try allocator.dupe(u8, board_b.id);
    defer allocator.free(board_b_id);

    const source = try store.insertSource(allocator, board_b_id, "file", "irrelevant", "managed");
    defer source.deinit(allocator);

    const hash = "cafebabecafebabecafebabecafebabe";
    const asset = blankAsset(board_b_id, source.id, hash, "irrelevant-managed-path", "irrelevant-original-path");
    try testing.expect(try store.insertAsset(allocator, asset));

    const frame = try store.createFrame(allocator, board_b_id, 0, 0, 100, 100, "note");
    defer frame.deinit(allocator);

    // Sanity: board B really does have the rows we just made.
    {
        const view = try store.loadBoard(allocator, board_b_id);
        defer view.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), view.sources.len);
        try testing.expectEqual(@as(usize, 1), view.assets.len);
        try testing.expectEqual(@as(usize, 1), view.nodes.len);
        try testing.expectEqual(@as(usize, 1), view.frames.len);
    }

    const after = try store.deleteBoard(allocator, board_b_id);
    defer after.deinit(allocator);
    try testing.expectEqualStrings(board_a_id, after.board.id);

    // The `libraries` row itself is gone.
    try testing.expectError(error.NotFound, store.getBoard(allocator, board_b_id));

    // And - the fix this port makes over the Rust original - the child rows are
    // gone too, not orphaned with a dangling library_id.
    {
        const sources = try store.listSources(allocator, board_b_id);
        defer {
            for (sources) |s| s.deinit(allocator);
            allocator.free(sources);
        }
        try testing.expectEqual(@as(usize, 0), sources.len);

        const assets = try store.listAssets(allocator, board_b_id);
        defer {
            for (assets) |a| a.deinit(allocator);
            allocator.free(assets);
        }
        try testing.expectEqual(@as(usize, 0), assets.len);

        const nodes = try store.listNodes(allocator, board_b_id);
        defer {
            for (nodes) |n| n.deinit(allocator);
            allocator.free(nodes);
        }
        try testing.expectEqual(@as(usize, 0), nodes.len);

        const frames = try store.listFrames(allocator, board_b_id);
        defer {
            for (frames) |f| f.deinit(allocator);
            allocator.free(frames);
        }
        try testing.expectEqual(@as(usize, 0), frames.len);
    }

    // Best-effort folder removal also ran.
    try testing.expect(!fileExists(io, board_b_path));
}

test "inserting an asset with a hash already present in the board is a no-op duplicate" {
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

    const source = try store.insertSource(allocator, board.id, "file", "irrelevant", "managed");
    defer source.deinit(allocator);

    const hash = "1111111111111111111111111111111a";
    const asset = blankAsset(board.id, source.id, hash, "managed-path-one", "original-path-one");
    try testing.expect(try store.insertAsset(allocator, asset));

    // findAssetByHash sees the row that was just inserted.
    {
        const found = try store.findAssetByHash(allocator, board.id, hash);
        defer if (found) |f| allocator.free(f);
        try testing.expect(found != null);
    }

    // A second insert with the same (boardId, hash) must be rejected without
    // touching the row count or creating a second board node.
    const duplicate = blankAsset(board.id, source.id, hash, "managed-path-two", "original-path-two");
    const inserted_again = try store.insertAsset(allocator, duplicate);
    try testing.expect(!inserted_again);

    const view = try store.loadBoard(allocator, board.id);
    defer view.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), view.assets.len);
    try testing.expectEqual(@as(usize, 1), view.nodes.len);
    try testing.expectEqualStrings("managed-path-one", view.assets[0].managedPath);
}

test "opening an empty catalog seeds a single default board named Maat Board" {
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
    try testing.expectEqual(@as(usize, 1), boards.len);
    try testing.expectEqualStrings("Maat Board", boards[0].name);
    try testing.expectEqualStrings(boards[0].createdAt, boards[0].updatedAt);
}

test "renameBoard updates the name and re-fetches the board" {
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
    const board_id = boards[0].id;

    const renamed = try store.renameBoard(allocator, board_id, "Renamed Board");
    defer renamed.deinit(allocator);
    try testing.expectEqualStrings("Renamed Board", renamed.name);
    try testing.expectEqualStrings(board_id, renamed.id);

    const fetched = try store.getBoard(allocator, board_id);
    defer fetched.deinit(allocator);
    try testing.expectEqualStrings("Renamed Board", fetched.name);

    try testing.expectError(error.NotFound, store.getBoard(allocator, "does-not-exist"));
}

test "deleteBoard refuses to delete the last remaining board" {
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
    try testing.expectError(error.CannotDeleteLastBoard, store.deleteBoard(allocator, boards[0].id));
}

// ---------------------------------------------------------------------------
// board pagination (issue #4)
// ---------------------------------------------------------------------------

test "loadBoardPage paginates a synthetic 1000-asset board with zero missing or duplicated ids" {
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

    const source = try store.insertSource(allocator, board.id, "folder", "irrelevant", "managed");
    defer source.deinit(allocator);

    const total_assets: usize = 1000;
    var i: usize = 0;
    while (i < total_assets) : (i += 1) {
        var hash_buf: [64]u8 = undefined;
        const hash = std.fmt.bufPrint(&hash_buf, "synthetic-hash-{d:0>8}", .{i}) catch unreachable;
        const managed_path = try std.fmt.allocPrint(allocator, "{s}/assets/{s}.png", .{ board.path, hash });
        defer allocator.free(managed_path);
        const asset = blankAsset(board.id, source.id, hash, managed_path, managed_path);
        try testing.expect(try store.insertAsset(allocator, asset));
    }
    try store.bumpSourceCount(source.id, @intCast(total_assets));

    var seen_asset_ids: std.StringHashMap(void) = .init(allocator);
    defer seen_asset_ids.deinit();
    var seen_node_ids: std.StringHashMap(void) = .init(allocator);
    defer seen_node_ids.deinit();

    var cursor: ?[]const u8 = null;
    var owned_cursor: ?[]u8 = null;
    defer if (owned_cursor) |c| allocator.free(c);

    var pages: usize = 0;
    var saw_board_on_first_page = false;
    while (true) {
        pages += 1;
        const page = try store.loadBoardPage(allocator, board.id, cursor);
        defer page.deinit(allocator);

        if (cursor == null) {
            try testing.expect(page.board != null);
            try testing.expect(page.sources != null);
            try testing.expect(page.frames != null);
            try testing.expectEqualStrings(board.id, page.board.?.id);
            saw_board_on_first_page = true;
        } else {
            try testing.expect(page.board == null);
            try testing.expect(page.sources == null);
            try testing.expect(page.frames == null);
        }

        // Every page (except possibly the very last) should be exactly the
        // page-size constant -- proves N=300 is actually what's used, not
        // some other bound.
        if (page.nextCursor != null) {
            try testing.expectEqual(Storage.board_page_size, page.assets.len);
        }
        try testing.expectEqual(page.assets.len, page.nodes.len);

        for (page.assets) |asset| {
            const gop = try seen_asset_ids.getOrPut(try allocator.dupe(u8, asset.id));
            try testing.expect(!gop.found_existing);
        }
        for (page.nodes) |node| {
            const gop = try seen_node_ids.getOrPut(try allocator.dupe(u8, node.assetId));
            try testing.expect(!gop.found_existing);
        }

        if (owned_cursor) |c| allocator.free(c);
        owned_cursor = null;
        if (page.nextCursor) |nc| {
            owned_cursor = try allocator.dupe(u8, nc);
            cursor = owned_cursor;
        } else {
            break;
        }
    }

    try testing.expect(saw_board_on_first_page);
    try testing.expectEqual(total_assets, seen_asset_ids.count());
    try testing.expectEqual(total_assets, seen_node_ids.count());
    try testing.expect(pages > 1); // proves pagination actually happened (1000 / 300 = 4 pages)

    {
        var it = seen_asset_ids.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
    }
    {
        var it = seen_node_ids.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
    }
}

test "loadBoardPage byte-budgets pages of fat rows, staying under the budget with zero missing or duplicated ids" {
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

    const source = try store.insertSource(allocator, board.id, "folder", "irrelevant", "managed");
    defer source.deinit(allocator);

    // A "fat" note per asset -- big enough that 300 of them (the row-count
    // ceiling alone, `board_page_size`) would land well past the bridge's
    // ~1 MiB response cap (350 * 4096 bytes =~ 1.4 MiB), proving the byte
    // budget -- not just the row-count ceiling -- is what actually bounds
    // each page here.
    const fat_note = try allocator.alloc(u8, 4096);
    defer allocator.free(fat_note);
    @memset(fat_note, 'n');

    const total_assets: usize = 350;
    var i: usize = 0;
    while (i < total_assets) : (i += 1) {
        var hash_buf: [64]u8 = undefined;
        const hash = std.fmt.bufPrint(&hash_buf, "fat-hash-{d:0>8}", .{i}) catch unreachable;
        const managed_path = try std.fmt.allocPrint(allocator, "{s}/assets/{s}.png", .{ board.path, hash });
        defer allocator.free(managed_path);
        const asset = Asset{
            .id = hash,
            .boardId = board.id,
            .sourceId = source.id,
            .name = "pic.png",
            .originalPath = managed_path,
            .managedPath = managed_path,
            .mime = "image/png",
            .extension = "png",
            .size = 6,
            .hash = hash,
            .width = null,
            .height = null,
            .kind = "image",
            .previewStatus = "ready",
            .thumbnailPath = null,
            .tags = &.{},
            .folders = &.{},
            .note = fat_note,
            .sourceUrl = null,
            .trashedAt = null,
            .createdAt = "2024-01-01T00:00:00.000+00:00",
            .metadataJson = null,
        };
        try testing.expect(try store.insertAsset(allocator, asset));
    }
    try store.bumpSourceCount(source.id, @intCast(total_assets));

    var seen_asset_ids: std.StringHashMap(void) = .init(allocator);
    defer seen_asset_ids.deinit();

    var cursor: ?[]const u8 = null;
    var owned_cursor: ?[]u8 = null;
    defer if (owned_cursor) |c| allocator.free(c);

    var pages: usize = 0;
    var saw_page_under_row_ceiling = false;
    while (true) {
        pages += 1;
        const page = try store.loadBoardPage(allocator, board.id, cursor);
        defer page.deinit(allocator);

        // Every page -- not just a coincidentally-small last one -- stays
        // well under the bridge's ~1 MiB cap. With 300-row-ceiling-only
        // pagination this would fail on every page but the last (a full
        // 300-row page of these fat rows would be ~1.4 MiB).
        const page_json = try page.toJson(allocator);
        defer allocator.free(page_json);
        try testing.expect(page_json.len < 1024 * 1024);

        if (page.assets.len < Storage.board_page_size) saw_page_under_row_ceiling = true;
        try testing.expectEqual(page.assets.len, page.nodes.len);

        for (page.assets) |asset| {
            const gop = try seen_asset_ids.getOrPut(try allocator.dupe(u8, asset.id));
            try testing.expect(!gop.found_existing);
        }

        if (owned_cursor) |c| allocator.free(c);
        owned_cursor = null;
        if (page.nextCursor) |nc| {
            owned_cursor = try allocator.dupe(u8, nc);
            cursor = owned_cursor;
        } else {
            break;
        }
    }

    try testing.expectEqual(total_assets, seen_asset_ids.count());
    try testing.expect(pages > 1);
    // Proves the byte budget (not the 300-row ceiling) is what's actually
    // cutting these pages short.
    try testing.expect(saw_page_under_row_ceiling);

    {
        var it = seen_asset_ids.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
    }
}

test "loadBoardPage rejects an unknown board id" {
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

    try testing.expectError(error.NotFound, store.loadBoardPage(allocator, "does-not-exist", null));
}
