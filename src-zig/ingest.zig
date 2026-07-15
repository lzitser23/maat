//! Zig port of Maat's import/ingest pipeline (originally src-tauri/src/ingest.rs +
//! the import-adjacent helpers in src-tauri/src/lib.rs). See
//! scratchpad/COMMAND-CONTRACT.md sections 1 (commands 6-8) and 3 (behavioral
//! invariants: walkdir semantics, Eagle detection, dedupe, thumbnail rules, MIME/kind
//! table, URL/clipboard import specifics) for the exact behavior this mirrors.
//!
//! Design notes / deltas from the Rust original:
//!   * Dedupe check (`Storage.findAssetByHash`) runs right after hashing, BEFORE the
//!     managed-copy + thumbnail work, so a re-import of an already-known file skips all
//!     of that work entirely. The Rust original always redid the thumbnail decode/encode
//!     work (content-addressed thumb *files* were skipped via `if !thumb_path.exists()`,
//!     but the `image::open` + resize CPU work still ran) before its own DB dedupe check
//!     short-circuited the insert. This is a deliberate, requested optimization, not a
//!     preserved quirk.
//!   * Rust's `catch_unwind` per-file panic isolation has no Zig equivalent; instead,
//!     each candidate's import runs through a normal Zig error union and any error is
//!     turned into a `failed`+message entry in the report without aborting the batch.
//!     stb returning null on an undecodable image is NOT a Zig error - it is handled as
//!     the contract's `fallback` path, so a corrupt image is still counted as imported
//!     (matching Rust: image::open failing does not fail an import).
//!   * mime_guess's extension table is approximated by a small static table (`guessMime`)
//!     covering common image/video/audio/pdf extensions actually needed by `classify`
//!     (which only checks the mime *prefix* for those three kinds, plus an exact
//!     `application/pdf` check) - exact parity with the mime_guess crate's full table is
//!     not attempted.
//!   * `Storage.root` and `Storage.newUuidV4`/`nowRfc3339`-equivalents are not `pub` on
//!     Storage; per the porting brief this module does not edit storage.zig. Local
//!     equivalents (`nowRfc3339`, `newUuidV4`) are duplicated here, and `storage.root` is
//!     read directly (Zig has no field-level privacy - only top-level pub/non-pub - so
//!     this is a plain field read, not a workaround of an actual access restriction).
//!   * `import_external_urls` uses Zig 0.16's `std.http.Client`, which is newer/less
//!     battle-tested than Rust's `ureq`. This path is not exercised by the test suite
//!     (no test opens a real socket); only a parse-failure short-circuit is tested, to
//!     prove the function at least type-checks and behaves for the trivial failure case.
//!   * Import paths are assumed absolute (as the OS file picker/drag-drop always
//!     supplies), matching the managed-copy path construction; unlike Rust's PathBuf
//!     (which tolerates cwd-relative paths transparently), a handful of calls here
//!     (`copyFileAbsolute`) assert absoluteness.

const std = @import("std");
const builtin = @import("builtin");
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;
const Asset = storage_mod.Asset;

const stb = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
    @cInclude("stb_image_resize2.h");
});

const MAX_EXTERNAL_IMPORT_BYTES: u64 = 100 * 1024 * 1024;
const THUMBNAIL_BOUND: f64 = 720.0;

// ---------------------------------------------------------------------------
// Public DTOs
// ---------------------------------------------------------------------------

pub const ImportReport = struct {
    imported: i64,
    skippedDuplicates: i64,
    failed: i64,
    sourceId: []const u8,
    messages: []const []const u8,

    pub fn deinit(self: ImportReport, allocator: std.mem.Allocator) void {
        allocator.free(self.sourceId);
        for (self.messages) |m| allocator.free(m);
        allocator.free(self.messages);
    }

    pub fn toJson(self: ImportReport, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

/// Input DTO for `importClipboardItems`. Two mutually exclusive payload
/// shapes (issue #2 -- clipboard images beyond the bridge's ~1 MiB message
/// cap):
///   * `bytes` set, `uploadPath` null -- the original inline-bytes shape
///     (`{ name, mime?, bytes: number[] }` over the wire), still used for
///     small payloads where JSON-encoding every byte as an integer is cheap
///     enough not to bother with a second transport.
///   * `uploadPath` set, `bytes` null -- a temp file already written to
///     `<storage_root>/.uploads/<id>` by `server.zig`'s `POST /upload`
///     handler (streamed there in bounded chunks, never buffered whole in
///     the bridge message). `importClipboardItems` below moves (not
///     copies) this file into its own `clipboard-<uuid>` temp dir rather
///     than re-reading/re-writing the bytes.
/// Both borrowed - caller retains ownership of whichever is set.
pub const ClipboardItem = struct {
    name: []const u8,
    mime: ?[]const u8,
    bytes: ?[]const u8 = null,
    uploadPath: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// importPaths
// ---------------------------------------------------------------------------

pub fn importPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: *Storage,
    board_id: []const u8,
    paths: []const []const u8,
) !ImportReport {
    var builder = try ReportBuilder.init(allocator);
    errdefer builder.deinitOnError(allocator);

    for (paths) |raw| {
        if (!existsAbs(io, raw)) {
            builder.failed += 1;
            try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "Missing path: {s}", .{raw}));
            continue;
        }

        const kind: []const u8 = if (isEagleLibrary(io, raw))
            "eagle"
        else if (isDirAbs(io, raw))
            "folder"
        else
            "file";

        const source = try storage.insertSource(allocator, board_id, kind, raw, "managed");
        defer source.deinit(allocator);
        try builder.setSourceId(allocator, source.id);

        const candidates = if (std.mem.eql(u8, kind, "eagle"))
            try eagleCandidates(allocator, io, raw)
        else if (std.mem.eql(u8, kind, "folder"))
            try folderCandidates(allocator, io, raw)
        else
            try singleFileCandidate(allocator, raw);
        defer {
            for (candidates) |c| c.deinit(allocator);
            allocator.free(candidates);
        }

        var source_imported: i64 = 0;
        for (candidates) |candidate| {
            if (importOne(allocator, io, storage, board_id, source.id, candidate)) |imported| {
                if (imported) {
                    builder.imported += 1;
                    source_imported += 1;
                } else {
                    builder.skipped += 1;
                }
            } else |err| {
                builder.failed += 1;
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Failed to import {s}: {s}",
                    .{ candidate.file_path, @errorName(err) },
                );
                try builder.addMessage(allocator, msg);
            }
        }

        try storage.bumpSourceCount(source.id, source_imported);
    }

    return builder.finalize(allocator);
}

// ---------------------------------------------------------------------------
// importExternalUrls
// ---------------------------------------------------------------------------

pub fn importExternalUrls(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: *Storage,
    board_id: []const u8,
    urls: []const []const u8,
) !ImportReport {
    const temp_dir = try tempImportDir(allocator, io, storage, "remote");
    defer allocator.free(temp_dir);

    var builder = try ReportBuilder.init(allocator);
    errdefer builder.deinitOnError(allocator);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    for (urls) |url| {
        const outcome = try downloadUrl(allocator, io, url, temp_dir);
        switch (outcome) {
            .ok => |p| try paths.append(allocator, p),
            .failed => |msg| {
                builder.failed += 1;
                try builder.addMessage(allocator, msg);
            },
        }
    }

    if (paths.items.len > 0) {
        const path_slices = try allocator.alloc([]const u8, paths.items.len);
        defer allocator.free(path_slices);
        for (paths.items, 0..) |p, i| path_slices[i] = p;

        const imported = try importPaths(allocator, io, storage, board_id, path_slices);
        try builder.mergeFrom(allocator, imported);
    }

    std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};

    return builder.finalize(allocator);
}

// ---------------------------------------------------------------------------
// importClipboardItems
// ---------------------------------------------------------------------------

pub fn importClipboardItems(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: *Storage,
    board_id: []const u8,
    items: []const ClipboardItem,
) !ImportReport {
    const temp_dir = try tempImportDir(allocator, io, storage, "clipboard");
    defer allocator.free(temp_dir);

    var builder = try ReportBuilder.init(allocator);
    errdefer builder.deinitOnError(allocator);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    for (items) |item| {
        if (item.uploadPath) |upload_path| {
            // Security boundary (renderer-supplied path): `uploadPath` is
            // plain JSON data from the bridge -- server.zig's `/upload`
            // handler only ever hands back paths under
            // `<storage_root>/.uploads/<uuid>`, but nothing stops a
            // compromised or buggy caller from sending an arbitrary
            // absolute path instead. Everything below this point renames
            // or deletes `upload_path`, so containment must be proven
            // BEFORE any of that -- and the out-of-containment path must
            // not be touched at all (not even deleted) if the check fails.
            validateUploadContainment(allocator, io, storage.root, upload_path) catch |err| {
                builder.failed += 1;
                try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "Clipboard upload rejected: {s} ({s})", .{ item.name, @errorName(err) }));
                continue;
            };

            const st = std.Io.Dir.cwd().statFile(io, upload_path, .{}) catch |err| {
                builder.failed += 1;
                try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "Clipboard upload missing: {s} ({s})", .{ item.name, @errorName(err) }));
                continue;
            };
            if (st.size == 0) {
                builder.failed += 1;
                try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "Empty clipboard item: {s}", .{item.name}));
                std.Io.Dir.deleteFileAbsolute(io, upload_path) catch {};
                continue;
            }
            if (st.size > MAX_EXTERNAL_IMPORT_BYTES) {
                builder.failed += 1;
                try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "Clipboard item too large: {s}", .{item.name}));
                std.Io.Dir.deleteFileAbsolute(io, upload_path) catch {};
                continue;
            }

            const extension = extensionFromMime(item.mime) orelse (extensionFromName(item.name) orelse "png");
            const name = try ensureExtension(allocator, item.name, extension);
            defer allocator.free(name);
            const unique = try uniqueFilename(allocator, io, name);
            defer allocator.free(unique);
            const dest_path = try std.fs.path.join(allocator, &.{ temp_dir, unique });

            // Moved, not copied: the bytes already live on disk (written
            // streaming by server.zig's /upload handler), so this just
            // relocates the file into the clipboard-import temp dir rather
            // than re-reading/re-writing potentially 100 MB of data.
            if (std.Io.Dir.renameAbsolute(upload_path, dest_path, io)) {
                try paths.append(allocator, dest_path);
            } else |err| {
                allocator.free(dest_path);
                builder.failed += 1;
                try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}));
                std.Io.Dir.deleteFileAbsolute(io, upload_path) catch {};
            }
            continue;
        }

        const bytes = item.bytes orelse &[_]u8{};
        if (bytes.len == 0) {
            builder.failed += 1;
            try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "Empty clipboard item: {s}", .{item.name}));
            continue;
        }
        if (bytes.len > MAX_EXTERNAL_IMPORT_BYTES) {
            builder.failed += 1;
            try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "Clipboard item too large: {s}", .{item.name}));
            continue;
        }

        const extension = extensionFromMime(item.mime) orelse (extensionFromName(item.name) orelse "png");
        const name = try ensureExtension(allocator, item.name, extension);
        defer allocator.free(name);
        const unique = try uniqueFilename(allocator, io, name);
        defer allocator.free(unique);
        const dest_path = try std.fs.path.join(allocator, &.{ temp_dir, unique });

        if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = bytes })) {
            try paths.append(allocator, dest_path);
        } else |err| {
            allocator.free(dest_path);
            builder.failed += 1;
            try builder.addMessage(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}));
        }
    }

    if (paths.items.len > 0) {
        const path_slices = try allocator.alloc([]const u8, paths.items.len);
        defer allocator.free(path_slices);
        for (paths.items, 0..) |p, i| path_slices[i] = p;

        const imported = try importPaths(allocator, io, storage, board_id, path_slices);
        try builder.mergeFrom(allocator, imported);
    }

    std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};

    return builder.finalize(allocator);
}

// ---------------------------------------------------------------------------
// Report builder
// ---------------------------------------------------------------------------

const ReportBuilder = struct {
    imported: i64 = 0,
    skipped: i64 = 0,
    failed: i64 = 0,
    source_id: []const u8,
    messages: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) !ReportBuilder {
        return .{ .source_id = try allocator.alloc(u8, 0) };
    }

    fn deinitOnError(self: *ReportBuilder, allocator: std.mem.Allocator) void {
        allocator.free(self.source_id);
        for (self.messages.items) |m| allocator.free(m);
        self.messages.deinit(allocator);
    }

    fn addMessage(self: *ReportBuilder, allocator: std.mem.Allocator, msg: []const u8) !void {
        try self.messages.append(allocator, msg);
    }

    fn setSourceId(self: *ReportBuilder, allocator: std.mem.Allocator, id: []const u8) !void {
        const copy = try allocator.dupe(u8, id);
        allocator.free(self.source_id);
        self.source_id = copy;
    }

    /// Mirrors Rust's `merge_reports`: counts add, messages append, and `sourceId` is
    /// overwritten only when `other.sourceId` is non-empty (last-successful-batch wins).
    fn mergeFrom(self: *ReportBuilder, allocator: std.mem.Allocator, other: ImportReport) !void {
        self.imported += other.imported;
        self.skipped += other.skippedDuplicates;
        self.failed += other.failed;

        if (other.sourceId.len > 0) {
            allocator.free(self.source_id);
            self.source_id = other.sourceId;
        } else {
            allocator.free(other.sourceId);
        }

        try self.messages.appendSlice(allocator, other.messages);
        allocator.free(other.messages);
    }

    fn finalize(self: *ReportBuilder, allocator: std.mem.Allocator) !ImportReport {
        return .{
            .imported = self.imported,
            .skippedDuplicates = self.skipped,
            .failed = self.failed,
            .sourceId = self.source_id,
            .messages = try self.messages.toOwnedSlice(allocator),
        };
    }
};

// ---------------------------------------------------------------------------
// Candidate generation
// ---------------------------------------------------------------------------

/// Exposed (not otherwise part of the module's public surface) so
/// `ingest_test.zig` can port Rust's `eagle_candidates_prefer_original_asset_over_thumbnail`
/// unit test, which exercises Eagle candidate discovery directly without going through
/// a `Storage`/DB at all - same as the Rust original's same-module private-fn test.
pub const ImportCandidate = struct {
    file_path: []u8,
    metadata_json: ?[]u8,
    display_name: ?[]u8,
    thumbnail_path: ?[]u8,
    width: ?i64,
    height: ?i64,
    tags: []const []const u8,
    folders: []const []const u8,
    note: ?[]u8,
    source_url: ?[]u8,

    pub fn deinit(self: ImportCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        if (self.metadata_json) |m| allocator.free(m);
        if (self.display_name) |d| allocator.free(d);
        if (self.thumbnail_path) |t| allocator.free(t);
        for (self.tags) |s| allocator.free(s);
        allocator.free(self.tags);
        for (self.folders) |s| allocator.free(s);
        allocator.free(self.folders);
        if (self.note) |n| allocator.free(n);
        if (self.source_url) |s| allocator.free(s);
    }
};

fn singleFileCandidate(allocator: std.mem.Allocator, path: []const u8) ![]ImportCandidate {
    const list = try allocator.alloc(ImportCandidate, 1);
    list[0] = .{
        .file_path = try allocator.dupe(u8, path),
        .metadata_json = null,
        .display_name = try basenameOwned(allocator, path),
        .thumbnail_path = null,
        .width = null,
        .height = null,
        .tags = try allocator.alloc([]const u8, 0),
        .folders = try allocator.alloc([]const u8, 0),
        .note = null,
        .source_url = null,
    };
    return list;
}

/// Mirrors `folder_candidates`: recursive walk, `follow_links(false)` semantics (a
/// symlink's own dirent kind is never `.file` or `.directory` from the OS's point of
/// view when unresolved, so `Dir.Walker` - which only recurses into `.directory`
/// entries and which this function only keeps `.file` entries from - naturally skips
/// symlinks both as traversal targets and as import candidates), filtered to
/// dot-prefixed *file* names only (hidden directories are still walked into).
fn folderCandidates(allocator: std.mem.Allocator, io: std.Io, folder_abs: []const u8) ![]ImportCandidate {
    var dir = try std.Io.Dir.openDirAbsolute(io, folder_abs, .{ .iterate = true });
    defer dir.close(io);

    var walker = try std.Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    var list: std.ArrayList(ImportCandidate) = .empty;
    errdefer {
        for (list.items) |c| c.deinit(allocator);
        list.deinit(allocator);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isHidden(entry.basename)) continue;

        const abs_path = try std.fs.path.join(allocator, &.{ folder_abs, entry.path });
        errdefer allocator.free(abs_path);
        const display_name = try allocator.dupe(u8, entry.basename);
        errdefer allocator.free(display_name);

        try list.append(allocator, .{
            .file_path = abs_path,
            .metadata_json = null,
            .display_name = display_name,
            .thumbnail_path = null,
            .width = null,
            .height = null,
            .tags = try allocator.alloc([]const u8, 0),
            .folders = try allocator.alloc([]const u8, 0),
            .note = null,
            .source_url = null,
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Mirrors `eagle_candidates`: enumerates `<library>/images/*.info` directories, reads
/// each item's `metadata.json` (tolerating a missing/unparsable file, matching Rust's
/// `.ok()` chains), and picks the real payload file over any `_thumbnail.*` sibling.
pub fn eagleCandidates(allocator: std.mem.Allocator, io: std.Io, library_abs: []const u8) ![]ImportCandidate {
    const images_abs = try std.fs.path.join(allocator, &.{ library_abs, "images" });
    defer allocator.free(images_abs);

    var images_dir = std.Io.Dir.openDirAbsolute(io, images_abs, .{ .iterate = true }) catch {
        return try allocator.alloc(ImportCandidate, 0);
    };
    defer images_dir.close(io);

    var list: std.ArrayList(ImportCandidate) = .empty;
    errdefer {
        for (list.items) |c| c.deinit(allocator);
        list.deinit(allocator);
    }

    var it = images_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const ext = std.fs.path.extension(entry.name);
        if (ext.len <= 1 or !std.ascii.eqlIgnoreCase(ext[1..], "info")) continue;

        const info_dir_abs = try std.fs.path.join(allocator, &.{ images_abs, entry.name });
        defer allocator.free(info_dir_abs);

        const metadata_path = try std.fs.path.join(allocator, &.{ info_dir_abs, "metadata.json" });
        defer allocator.free(metadata_path);

        const metadata_json: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(1024 * 1024)) catch null;

        var parsed: ?std.json.Parsed(std.json.Value) = null;
        if (metadata_json) |mj| {
            parsed = std.json.parseFromSlice(std.json.Value, allocator, mj, .{}) catch null;
        }
        defer if (parsed) |*p| p.deinit();

        const value_opt: ?std.json.Value = if (parsed) |p| p.value else null;

        const display_name = if (value_opt) |v| try firstStringDup(allocator, v, &.{ "name", "title", "filename" }) else null;
        const thumbnail_path = try firstThumbnailFile(allocator, io, info_dir_abs);
        const width = if (value_opt) |v| getI64FromValue(v, "width") else null;
        const height = if (value_opt) |v| getI64FromValue(v, "height") else null;
        const tags = if (value_opt) |v| try stringListDup(allocator, v, "tags") else try allocator.alloc([]const u8, 0);
        const folders = if (value_opt) |v| try stringListDup(allocator, v, "folders") else try allocator.alloc([]const u8, 0);
        const note = if (value_opt) |v| try firstStringDup(allocator, v, &.{ "annotation", "note", "description" }) else null;
        const source_url = if (value_opt) |v| try firstStringDup(allocator, v, &.{ "url", "source", "sourceUrl", "website" }) else null;

        const payload = try firstPayloadFile(allocator, io, info_dir_abs, value_opt);

        if (payload) |file_path| {
            try list.append(allocator, .{
                .file_path = file_path,
                .metadata_json = metadata_json,
                .display_name = display_name,
                .thumbnail_path = thumbnail_path,
                .width = width,
                .height = height,
                .tags = tags,
                .folders = folders,
                .note = note,
                .source_url = source_url,
            });
        } else {
            if (metadata_json) |m| allocator.free(m);
            if (display_name) |d| allocator.free(d);
            if (thumbnail_path) |t| allocator.free(t);
            for (tags) |s| allocator.free(s);
            allocator.free(tags);
            for (folders) |s| allocator.free(s);
            allocator.free(folders);
            if (note) |n| allocator.free(n);
            if (source_url) |s| allocator.free(s);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn isEagleLibrary(io: std.Io, path_abs: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path_abs, .{}) catch return false;
    if (st.kind != .directory) return false;

    const ext = std.fs.path.extension(path_abs);
    if (ext.len <= 1) return false;
    if (!std.ascii.eqlIgnoreCase(ext[1..], "library")) return false;

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const images_path = std.fs.path.join(fba.allocator(), &.{ path_abs, "images" }) catch return false;
    const st2 = std.Io.Dir.cwd().statFile(io, images_path, .{}) catch return false;
    return st2.kind == .directory;
}

fn isDirAbs(io: std.Io, path_abs: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path_abs, .{}) catch return false;
    return st.kind == .directory;
}

fn isFileAbs(io: std.Io, path_abs: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path_abs, .{}) catch return false;
    return st.kind == .file;
}

fn existsAbs(io: std.Io, path_abs: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path_abs, .{}) catch return false;
    return true;
}

fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

fn isMetadataFileName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "metadata.json");
}

/// `stem` (file_stem in Rust) lowercased equals "thumbnail", or ends with "_thumbnail".
fn isEagleThumbnail(name: []const u8) bool {
    const stem = std.fs.path.stem(name);
    if (std.ascii.eqlIgnoreCase(stem, "thumbnail")) return true;
    return std.ascii.endsWithIgnoreCase(stem, "_thumbnail");
}

fn lessThanIgnoreCaseSlice(_: void, a: []u8, b: []u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

/// Non-recursive listing of file (not directory) entries in `dir_abs`, sorted by
/// lowercase name - mirrors the `files.sort_by_key(|p| lowercase name)` calls in
/// `first_payload_file`/`first_thumbnail_file`.
fn listDirFilesSorted(allocator: std.mem.Allocator, io: std.Io, dir_abs: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try list.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, list.items, {}, lessThanIgnoreCaseSlice);
    return list.toOwnedSlice(allocator);
}

fn firstThumbnailFile(allocator: std.mem.Allocator, io: std.Io, info_dir_abs: []const u8) !?[]u8 {
    const names = listDirFilesSorted(allocator, io, info_dir_abs) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |name| {
        if (isEagleThumbnail(name)) return try std.fs.path.join(allocator, &.{ info_dir_abs, name });
    }
    return null;
}

fn metadataPayloadFile(allocator: std.mem.Allocator, io: std.Io, info_dir_abs: []const u8, metadata: std.json.Value) !?[]u8 {
    if (try firstStringDup(allocator, metadata, &.{"filename"})) |filename| {
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ info_dir_abs, filename });
        if (isFileAbs(io, path) and !isMetadataFileName(std.fs.path.basename(path))) {
            return path;
        }
        allocator.free(path);
    }

    const name = (try firstStringDup(allocator, metadata, &.{ "name", "title" })) orelse return null;
    defer allocator.free(name);
    const extension = (try firstStringDup(allocator, metadata, &.{ "ext", "extension" })) orelse try allocator.dupe(u8, "");
    defer allocator.free(extension);

    const filename: []u8 = blk: {
        if (extension.len == 0) break :blk try allocator.dupe(u8, name);
        const needle = try std.fmt.allocPrint(allocator, ".{s}", .{extension});
        defer allocator.free(needle);
        if (std.ascii.endsWithIgnoreCase(name, needle)) break :blk try allocator.dupe(u8, name);
        break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ name, extension });
    };
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ info_dir_abs, filename });
    if (isFileAbs(io, path) and !isMetadataFileName(filename)) {
        return path;
    }
    allocator.free(path);
    return null;
}

fn firstPayloadFile(allocator: std.mem.Allocator, io: std.Io, info_dir_abs: []const u8, metadata_opt: ?std.json.Value) !?[]u8 {
    if (metadata_opt) |metadata| {
        if (try metadataPayloadFile(allocator, io, info_dir_abs, metadata)) |p| return p;
    }

    const names = try listDirFilesSorted(allocator, io, info_dir_abs);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var fallback_index: ?usize = null;
    for (names, 0..) |name, i| {
        if (isMetadataFileName(name)) continue;
        if (fallback_index == null) fallback_index = i;
        if (!isEagleThumbnail(name)) {
            return try std.fs.path.join(allocator, &.{ info_dir_abs, name });
        }
    }
    if (fallback_index) |i| {
        return try std.fs.path.join(allocator, &.{ info_dir_abs, names[i] });
    }
    return null;
}

fn firstStringDup(allocator: std.mem.Allocator, value: std.json.Value, keys: []const []const u8) !?[]u8 {
    if (value != .object) return null;
    for (keys) |key| {
        if (value.object.get(key)) |v| {
            if (v == .string) {
                const trimmed = std.mem.trim(u8, v.string, " \t\r\n");
                if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
            }
        }
    }
    return null;
}

fn getI64FromValue(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn stringListDup(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const []const u8 {
    if (value != .object) return try allocator.alloc([]const u8, 0);
    const arr = value.object.get(key) orelse return try allocator.alloc([]const u8, 0);
    if (arr != .array) return try allocator.alloc([]const u8, 0);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    for (arr.array.items) |item| {
        var chosen: ?[]u8 = null;
        if (item == .string) {
            const trimmed = std.mem.trim(u8, item.string, " \t\r\n");
            if (trimmed.len > 0) chosen = try allocator.dupe(u8, trimmed);
        } else if (item == .object) {
            chosen = try firstStringDup(allocator, item, &.{ "name", "title", "id" });
        }
        if (chosen) |c| try list.append(allocator, c);
    }
    return list.toOwnedSlice(allocator);
}

fn dupeOwnedStrList(allocator: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, src.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < src.len) : (i += 1) out[i] = try allocator.dupe(u8, src[i]);
    return out;
}

fn basenameOwned(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return allocator.dupe(u8, std.fs.path.basename(path));
}

// ---------------------------------------------------------------------------
// Per-file import
// ---------------------------------------------------------------------------

/// Test-only failure-injection seam (see `ingest_test.zig`'s orphan-cleanup
/// test): when set, `importOne` returns this error immediately before calling
/// `storage.insertAsset`, so a test can deterministically exercise the
/// errdefer cleanup below without provoking a genuine SQLite failure. Always
/// `null` outside of `zig build test`.
pub var test_force_insert_error: ?anyerror = null;

fn importOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: *Storage,
    board_id: []const u8,
    source_id: []const u8,
    candidate: ImportCandidate,
) !bool {
    const hash_hex = try hashFileHex(allocator, io, candidate.file_path);
    defer allocator.free(hash_hex);

    if (try storage.findAssetByHash(allocator, board_id, hash_hex)) |existing_id| {
        allocator.free(existing_id);
        return false;
    }

    const board = try storage.getBoard(allocator, board_id);
    defer board.deinit(allocator);

    const extension = try lowerExtensionOwned(allocator, candidate.file_path);
    defer allocator.free(extension);

    const asset_dir = try std.fs.path.join(allocator, &.{ board.path, "assets", hash_hex[0..2] });
    defer allocator.free(asset_dir);
    try std.Io.Dir.cwd().createDirPath(io, asset_dir);

    const managed_name = if (extension.len == 0)
        try allocator.dupe(u8, hash_hex)
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ hash_hex, extension });
    defer allocator.free(managed_name);

    const managed_path = try std.fs.path.join(allocator, &.{ asset_dir, managed_name });
    defer allocator.free(managed_path);

    const managed_preexisted = existsAbs(io, managed_path);
    if (!managed_preexisted) {
        try std.Io.Dir.copyFileAbsolute(candidate.file_path, managed_path, io, .{ .make_path = true });
    }
    // From here on a managed-file copy sits on disk. If we're the one who just
    // put it there and anything below fails, delete it again rather than
    // leaving an orphan behind forever (F1). Never delete a file that already
    // existed before this call (e.g. a leftover from an unrelated prior run).
    errdefer if (!managed_preexisted) {
        std.Io.Dir.cwd().deleteFile(io, managed_path) catch {};
    };

    const st = try std.Io.Dir.cwd().statFile(io, managed_path, .{});
    const size: i64 = @intCast(st.size);

    const mime = try guessMime(allocator, extension);
    defer allocator.free(mime);
    const kind_literal = classify(mime, extension);

    const thumbs_dir = try std.fs.path.join(allocator, &.{ board.path, "thumbs" });
    defer allocator.free(thumbs_dir);

    var preview = try previewMetadata(allocator, io, candidate, managed_path, kind_literal, thumbs_dir, hash_hex);
    // Until ownership moves into `asset` below, `preview` owns both the
    // `previewStatus`/`thumbnailPath` allocations and (if non-null) the actual
    // thumbnail file on disk; on error before that hand-off, clean up both.
    var preview_owns_memory = true;
    errdefer if (preview_owns_memory) {
        allocator.free(preview.previewStatus);
        if (preview.thumbnailPath) |tp| allocator.free(tp);
    };
    errdefer if (preview_owns_memory) {
        if (preview.thumbnailPath) |tp| std.Io.Dir.cwd().deleteFile(io, tp) catch {};
    };

    const name_str: []const u8 = candidate.display_name orelse std.fs.path.basename(candidate.file_path);
    const name_final: []const u8 = if (name_str.len == 0) "Untitled" else name_str;

    var asset = Asset{
        .id = try newUuidV4(io, allocator),
        .boardId = try allocator.dupe(u8, board_id),
        .sourceId = try allocator.dupe(u8, source_id),
        .name = try allocator.dupe(u8, name_final),
        .originalPath = try allocator.dupe(u8, candidate.file_path),
        .managedPath = try allocator.dupe(u8, managed_path),
        .mime = try allocator.dupe(u8, mime),
        .extension = try allocator.dupe(u8, extension),
        .size = size,
        .hash = try allocator.dupe(u8, hash_hex),
        .width = preview.width,
        .height = preview.height,
        .kind = try allocator.dupe(u8, kind_literal),
        .previewStatus = preview.previewStatus,
        .thumbnailPath = preview.thumbnailPath,
        .tags = try dupeOwnedStrList(allocator, candidate.tags),
        .folders = try dupeOwnedStrList(allocator, candidate.folders),
        .note = if (candidate.note) |n| try allocator.dupe(u8, n) else null,
        .sourceUrl = if (candidate.source_url) |s| try allocator.dupe(u8, s) else null,
        .trashedAt = null,
        .createdAt = try nowRfc3339(io, allocator),
        .metadataJson = if (candidate.metadata_json) |m| try allocator.dupe(u8, m) else null,
    };
    // Ownership of preview.previewStatus / preview.thumbnailPath transferred into
    // `asset`; the two errdefers above are now moot (asset.deinit + the
    // asset-scoped errdefers below take over both the memory and the file).
    preview = undefined;
    preview_owns_memory = false;

    // Declared in this order so that, on error, the thumbnail *file* is deleted
    // (while `asset.thumbnailPath` is still a valid pointer) before
    // `asset.deinit` frees the memory backing that same pointer - errdefers run
    // last-declared-first, so `asset.deinit` must be declared first.
    errdefer asset.deinit(allocator);
    errdefer if (asset.thumbnailPath) |tp| std.Io.Dir.cwd().deleteFile(io, tp) catch {};

    if (builtin.is_test) {
        if (test_force_insert_error) |err| return err;
    }

    const inserted = try storage.insertAsset(allocator, asset);
    asset.deinit(allocator);
    return inserted;
}

fn hashFileHex(allocator: std.mem.Allocator, io: std.Io, path_abs: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path_abs, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositional(io, &.{&buf}, offset);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn lowerExtensionOwned(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len <= 1) return allocator.alloc(u8, 0);
    const raw = ext[1..];
    const out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

const MimeEntry = struct { ext: []const u8, mime: []const u8 };
const mime_table = [_]MimeEntry{
    .{ .ext = "jpg", .mime = "image/jpeg" },
    .{ .ext = "jpeg", .mime = "image/jpeg" },
    .{ .ext = "png", .mime = "image/png" },
    .{ .ext = "gif", .mime = "image/gif" },
    .{ .ext = "bmp", .mime = "image/bmp" },
    .{ .ext = "webp", .mime = "image/webp" },
    .{ .ext = "tif", .mime = "image/tiff" },
    .{ .ext = "tiff", .mime = "image/tiff" },
    .{ .ext = "ico", .mime = "image/vnd.microsoft.icon" },
    .{ .ext = "svg", .mime = "image/svg+xml" },
    .{ .ext = "avif", .mime = "image/avif" },
    .{ .ext = "heic", .mime = "image/heic" },
    .{ .ext = "heif", .mime = "image/heif" },
    .{ .ext = "mp4", .mime = "video/mp4" },
    .{ .ext = "mov", .mime = "video/quicktime" },
    .{ .ext = "webm", .mime = "video/webm" },
    .{ .ext = "mkv", .mime = "video/x-matroska" },
    .{ .ext = "avi", .mime = "video/x-msvideo" },
    .{ .ext = "m4v", .mime = "video/x-m4v" },
    .{ .ext = "mp3", .mime = "audio/mpeg" },
    .{ .ext = "wav", .mime = "audio/wav" },
    .{ .ext = "flac", .mime = "audio/flac" },
    .{ .ext = "ogg", .mime = "audio/ogg" },
    .{ .ext = "m4a", .mime = "audio/mp4" },
    .{ .ext = "aac", .mime = "audio/aac" },
    .{ .ext = "pdf", .mime = "application/pdf" },
};

/// Approximates `mime_guess::from_path(...).first_or_octet_stream()` for the
/// extensions actually relevant to `classify`'s mime-prefix checks.
fn guessMime(allocator: std.mem.Allocator, extension: []const u8) ![]u8 {
    for (mime_table) |entry| {
        if (std.mem.eql(u8, extension, entry.ext)) return allocator.dupe(u8, entry.mime);
    }
    return allocator.dupe(u8, "application/octet-stream");
}

/// Exact port of `classify(mime, extension)` - order of checks matters (first match
/// wins), per COMMAND-CONTRACT.md's MIME/kind table.
fn classify(mime: []const u8, extension: []const u8) []const u8 {
    if (std.mem.startsWith(u8, mime, "image/")) return "image";
    if (std.mem.startsWith(u8, mime, "video/")) return "video";
    if (std.mem.startsWith(u8, mime, "audio/")) return "audio";
    if (std.mem.eql(u8, mime, "application/pdf") or std.mem.eql(u8, extension, "pdf")) return "pdf";
    for ([_][]const u8{ "ttf", "otf", "woff", "woff2" }) |e| if (std.mem.eql(u8, extension, e)) return "font";
    for ([_][]const u8{ "fig", "sketch", "psd", "ai", "xd", "afdesign" }) |e| if (std.mem.eql(u8, extension, e)) return "design";
    for ([_][]const u8{ "zip", "rar", "7z", "tar", "gz" }) |e| if (std.mem.eql(u8, extension, e)) return "archive";
    for ([_][]const u8{ "doc", "docx", "ppt", "pptx", "xls", "xlsx", "md", "txt", "rtf" }) |e| if (std.mem.eql(u8, extension, e)) return "document";
    return "unknown";
}

// ---------------------------------------------------------------------------
// Thumbnails
// ---------------------------------------------------------------------------

const PreviewResult = struct {
    width: ?i64,
    height: ?i64,
    previewStatus: []u8,
    thumbnailPath: ?[]u8,
};

/// Mirrors `preview_metadata`: non-image kinds always fall back; an Eagle-provided
/// thumbnail (byte-for-byte copy) takes priority over decoding+resizing the managed
/// file; Eagle metadata width/height (if present) takes priority over freshly-decoded
/// dimensions either way.
fn previewMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate: ImportCandidate,
    managed_path: []const u8,
    kind: []const u8,
    thumbs_dir: []const u8,
    hash: []const u8,
) !PreviewResult {
    if (!std.mem.eql(u8, kind, "image")) {
        return .{ .width = null, .height = null, .previewStatus = try allocator.dupe(u8, "fallback"), .thumbnailPath = null };
    }

    if (candidate.thumbnail_path) |thumb_src| {
        if (copyThumbnail(allocator, io, thumb_src, thumbs_dir, hash)) |thumb_path| {
            return .{ .width = candidate.width, .height = candidate.height, .previewStatus = try allocator.dupe(u8, "ready"), .thumbnailPath = thumb_path };
        } else |_| {
            // Fall through to the decode-based probe, matching Rust's `if let Ok(...)`.
        }
    }

    const probed = try imageProbe(allocator, io, managed_path, thumbs_dir, hash);
    return .{
        .width = candidate.width orelse probed.width,
        .height = candidate.height orelse probed.height,
        .previewStatus = probed.previewStatus,
        .thumbnailPath = probed.thumbnailPath,
    };
}

fn copyThumbnail(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, thumbs_dir: []const u8, hash: []const u8) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, thumbs_dir);

    const raw_ext = try lowerExtensionOwned(allocator, source_path);
    defer allocator.free(raw_ext);
    const ext_final: []const u8 = if (raw_ext.len == 0) "png" else raw_ext;

    const filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ hash, ext_final });
    defer allocator.free(filename);
    const thumb_path = try std.fs.path.join(allocator, &.{ thumbs_dir, filename });
    errdefer allocator.free(thumb_path);

    if (!existsAbs(io, thumb_path)) {
        try std.Io.Dir.copyFileAbsolute(source_path, thumb_path, io, .{ .make_path = true });
    }
    return thumb_path;
}

const FitSize = struct { w: i32, h: i32 };

/// Fit-within, aspect-preserving scale to a 720x720 bounding box (may upscale a small
/// source image to fill more of the bound, matching the `image` crate's documented
/// "scaled to the maximum possible size that fits within bounds" semantics for
/// `.thumbnail()` - COMMAND-CONTRACT.md flags this exact behavior as ambiguous from the
/// Rust docs alone; this is the conscious reading taken for the port).
fn thumbnailFit(w: i32, h: i32) FitSize {
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    const scale = @min(THUMBNAIL_BOUND / wf, THUMBNAIL_BOUND / hf);
    const out_w: i32 = @intFromFloat(@round(wf * scale));
    const out_h: i32 = @intFromFloat(@round(hf * scale));
    return .{ .w = @max(out_w, 1), .h = @max(out_h, 1) };
}

/// Mirrors `image_probe`: decode via stb, resize-to-fit, write PNG. Decode failure
/// (corrupt file, unsupported format) yields `(null, null, "fallback", null)` without
/// erroring - the caller still counts the file as imported.
fn imageProbe(allocator: std.mem.Allocator, io: std.Io, path_abs: []const u8, thumbs_dir: []const u8, hash: []const u8) !struct {
    width: ?i64,
    height: ?i64,
    previewStatus: []u8,
    thumbnailPath: ?[]u8,
} {
    const path_z = try allocator.dupeZ(u8, path_abs);
    defer allocator.free(path_z);

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load(path_z.ptr, &w, &h, &channels, 4);
    if (pixels == null) {
        return .{ .width = null, .height = null, .previewStatus = try allocator.dupe(u8, "fallback"), .thumbnailPath = null };
    }
    defer stb.stbi_image_free(pixels);

    const fit = thumbnailFit(@intCast(w), @intCast(h));
    const out_buf = try allocator.alloc(u8, @as(usize, @intCast(fit.w)) * @as(usize, @intCast(fit.h)) * 4);
    defer allocator.free(out_buf);

    const layout: c_int = stb.STBIR_RGBA;
    const resized = stb.stbir_resize_uint8_linear(
        @ptrCast(pixels),
        w,
        h,
        w * 4,
        out_buf.ptr,
        fit.w,
        fit.h,
        fit.w * 4,
        @intCast(layout),
    );

    var thumbnail_path: ?[]u8 = null;
    if (resized != null) {
        try std.Io.Dir.cwd().createDirPath(io, thumbs_dir);
        const filename = try std.fmt.allocPrint(allocator, "{s}.png", .{hash});
        defer allocator.free(filename);
        const thumb_path = try std.fs.path.join(allocator, &.{ thumbs_dir, filename });
        errdefer allocator.free(thumb_path);

        if (!existsAbs(io, thumb_path)) {
            const thumb_path_z = try allocator.dupeZ(u8, thumb_path);
            defer allocator.free(thumb_path_z);
            const ok = stb.stbi_write_png(thumb_path_z.ptr, fit.w, fit.h, 4, out_buf.ptr, fit.w * 4);
            if (ok == 0) return error.ThumbnailWriteFailed;
        }
        thumbnail_path = thumb_path;
    }

    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .previewStatus = try allocator.dupe(u8, "ready"),
        .thumbnailPath = thumbnail_path,
    };
}

// ---------------------------------------------------------------------------
// URL / clipboard import support
// ---------------------------------------------------------------------------

/// Errors from `validateUploadContainment` are deliberately collapsed into
/// this one value (rather than propagating `error.FileNotFound` /
/// `error.AccessDenied` / etc. verbatim) -- the exact reason a path failed
/// to resolve or land inside `.uploads` is not useful to the caller, and
/// keeping one name avoids leaking filesystem-layout details into the
/// per-item failure message shown to the user.
const UploadContainmentError = error{UploadPathNotContained};

/// Proves `upload_path` (renderer-supplied, untrusted) resolves to a real
/// file physically inside `<storage_root>/.uploads` before any caller is
/// allowed to rename or delete it. Uses handle-based final-path
/// canonicalization (`std.Io.Dir.realPathFileAbsoluteAlloc`, which opens
/// the path and asks the OS for its canonical form via
/// `GetFinalPathNameByHandle` on Windows) rather than lexical `..`
/// stripping, so this also closes reparse-point/junction escapes: a
/// junction inside `.uploads` pointing outside it resolves to its real
/// target before the prefix check runs, and a `..`-laden path resolves to
/// wherever it actually points on disk.
///
/// The prefix check requires an exact path-separator boundary right after
/// the `.uploads` prefix (not just a string prefix match), so a sibling
/// directory that merely starts with the same characters --
/// `.uploads_evil` next to `.uploads` -- is correctly rejected rather than
/// treated as contained.
fn validateUploadContainment(allocator: std.mem.Allocator, io: std.Io, storage_root: []const u8, upload_path: []const u8) UploadContainmentError!void {
    const uploads_dir = std.fs.path.join(allocator, &.{ storage_root, ".uploads" }) catch return error.UploadPathNotContained;
    defer allocator.free(uploads_dir);

    const real_uploads_dir = std.Io.Dir.realPathFileAbsoluteAlloc(io, uploads_dir, allocator) catch return error.UploadPathNotContained;
    defer allocator.free(real_uploads_dir);

    const real_upload_path = std.Io.Dir.realPathFileAbsoluteAlloc(io, upload_path, allocator) catch return error.UploadPathNotContained;
    defer allocator.free(real_upload_path);

    if (!pathIsContainedIn(real_upload_path, real_uploads_dir)) return error.UploadPathNotContained;
}

/// True when `candidate` is `dir` itself's content -- i.e. starts with
/// `dir` followed by a path separator. Deliberately NOT a bare
/// `startsWith` check: `.uploads_evil` must not count as contained in
/// `.uploads` just because the string "`.uploads`" is a textual prefix of
/// it.
fn pathIsContainedIn(candidate: []const u8, dir: []const u8) bool {
    if (candidate.len <= dir.len) return false;
    if (!std.mem.eql(u8, candidate[0..dir.len], dir)) return false;
    const sep = candidate[dir.len];
    return sep == '\\' or sep == '/';
}

fn tempImportDir(allocator: std.mem.Allocator, io: std.Io, storage: *Storage, label: []const u8) ![]u8 {
    const id = try newUuidV4(io, allocator);
    defer allocator.free(id);
    const dirname = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ label, id });
    defer allocator.free(dirname);
    // `storage.root` is a plain (non-`pub`-annotated but field-level-unrestricted, per
    // Zig's lack of field privacy) read of Storage's own storage root - see the
    // module-level doc comment.
    const full = try std.fs.path.join(allocator, &.{ storage.root, "temp-imports", dirname });
    try std.Io.Dir.cwd().createDirPath(io, full);
    return full;
}

const DownloadOutcome = union(enum) {
    ok: []u8,
    failed: []u8,
};

/// Mirrors `download_url`. Network errors, a non-image content-type, and an
/// over-the-cap body are all *expected* failure modes (reported per-URL, not fatal to
/// the whole import), matching Rust's `Result<PathBuf, String>` -> per-item message.
fn downloadUrl(allocator: std.mem.Allocator, io: std.Io, url: []const u8, temp_dir: []const u8) !DownloadOutcome {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Could not fetch {s}: {s}", .{ url, @errorName(err) }) };
    };

    var req = client.request(.GET, uri, .{
        .extra_headers = &.{.{ .name = "User-Agent", .value = "Maat/0.1" }},
    }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Could not fetch {s}: {s}", .{ url, @errorName(err) }) };
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Could not fetch {s}: {s}", .{ url, @errorName(err) }) };
    };

    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Could not fetch {s}: {s}", .{ url, @errorName(err) }) };
    };

    if (response.head.status.class() != .success) {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Could not fetch {s}: HTTP {d}", .{ url, @intFromEnum(response.head.status) }) };
    }

    const raw_content_type = response.head.content_type orelse "";
    const semi = std.mem.indexOfScalar(u8, raw_content_type, ';');
    const base_ct = std.mem.trim(u8, if (semi) |s| raw_content_type[0..s] else raw_content_type, " \t");

    var ct_lower_buf: [256]u8 = undefined;
    const ct_len = @min(base_ct.len, ct_lower_buf.len);
    for (base_ct[0..ct_len], 0..) |ch, i| ct_lower_buf[i] = std.ascii.toLower(ch);
    const content_type_lower = ct_lower_buf[0..ct_len];

    if (!std.mem.startsWith(u8, content_type_lower, "image/")) {
        return .{ .failed = try std.fmt.allocPrint(allocator, "URL did not resolve to an image: {s} ({s})", .{ url, content_type_lower }) };
    }

    var transfer_buffer: [4096]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);
    const bytes = body_reader.allocRemaining(allocator, .limited(MAX_EXTERNAL_IMPORT_BYTES + 1)) catch |err| switch (err) {
        error.StreamTooLong => return .{ .failed = try std.fmt.allocPrint(allocator, "Remote image too large: {s}", .{url}) },
        else => return .{ .failed = try std.fmt.allocPrint(allocator, "Could not fetch {s}: {s}", .{ url, @errorName(err) }) },
    };
    defer allocator.free(bytes);

    const extension = extensionFromMime(content_type_lower) orelse (extensionFromName(url) orelse "png");

    const maybe_name = try filenameFromUrl(allocator, url);
    const name: []u8 = blk: {
        if (maybe_name) |n| {
            defer allocator.free(n);
            break :blk try ensureExtension(allocator, n, extension);
        }
        break :blk try std.fmt.allocPrint(allocator, "remote-image.{s}", .{extension});
    };
    defer allocator.free(name);

    const unique = try uniqueFilename(allocator, io, name);
    defer allocator.free(unique);
    const dest_path = try std.fs.path.join(allocator, &.{ temp_dir, unique });

    if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = bytes })) {
        return .{ .ok = dest_path };
    } else |err| {
        allocator.free(dest_path);
        return .{ .failed = try std.fmt.allocPrint(allocator, "Could not fetch {s}: {s}", .{ url, @errorName(err) }) };
    }
}

fn extensionFromMime(mime: ?[]const u8) ?[]const u8 {
    const m = mime orelse return null;
    const semi = std.mem.indexOfScalar(u8, m, ';');
    const base = if (semi) |s| m[0..s] else m;
    const table = [_]MimeEntry{
        .{ .ext = "jpg", .mime = "image/jpeg" },
        .{ .ext = "png", .mime = "image/png" },
        .{ .ext = "gif", .mime = "image/gif" },
        .{ .ext = "webp", .mime = "image/webp" },
        .{ .ext = "avif", .mime = "image/avif" },
        .{ .ext = "bmp", .mime = "image/bmp" },
        .{ .ext = "tiff", .mime = "image/tiff" },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, base, entry.mime)) return entry.ext;
    }
    return null;
}

fn extensionFromName(name: []const u8) ?[]const u8 {
    const no_query = if (std.mem.indexOfScalar(u8, name, '?')) |q| name[0..q] else name;
    const last_slash = std.mem.lastIndexOfScalar(u8, no_query, '/');
    const base = if (last_slash) |i| no_query[i + 1 ..] else no_query;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = std.mem.trim(u8, base[dot + 1 ..], " \t\r\n");
    if (ext.len == 0 or ext.len > 8) return null;
    for (ext) |ch| if (!std.ascii.isAlphanumeric(ch)) return null;
    return ext;
}

fn filenameFromUrl(allocator: std.mem.Allocator, url: []const u8) !?[]u8 {
    const no_query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url;
    const last_slash = std.mem.lastIndexOfScalar(u8, no_query, '/');
    const base = if (last_slash) |i| no_query[i + 1 ..] else no_query;
    const trimmed = std.mem.trim(u8, base, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn ensureExtension(allocator: std.mem.Allocator, name: []const u8, extension: []const u8) ![]u8 {
    if (extensionFromName(name) != null) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ name, extension });
}

fn sanitizeFilename(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, name.len);
    defer allocator.free(buf);
    for (name, 0..) |ch, i| {
        buf[i] = if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == ' ') ch else '_';
    }
    const trimmed = std.mem.trim(u8, buf, ". ");
    if (trimmed.len == 0) return try allocator.dupe(u8, "asset");
    return try allocator.dupe(u8, trimmed);
}

fn uniqueFilename(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const sanitized = try sanitizeFilename(allocator, name);
    defer allocator.free(sanitized);
    const id = try newUuidV4(io, allocator);
    defer allocator.free(id);
    return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ id, sanitized });
}

// ---------------------------------------------------------------------------
// Local timestamp / uuid helpers (duplicated from storage.zig's private helpers -
// not `pub` there, and this module must not edit storage.zig; see module doc comment).
// ---------------------------------------------------------------------------

fn nowRfc3339(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const ts = std.Io.Clock.real.now(io);
    const ns_total: i96 = ts.nanoseconds;
    const secs: i64 = @intCast(@divFloor(ns_total, 1_000_000_000));
    const nanos_rem: i64 = @intCast(@mod(ns_total, 1_000_000_000));
    const ms: u32 = @intCast(@divFloor(nanos_rem, 1_000_000));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}+00:00",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u32, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            ms,
        },
    );
}

fn newUuidV4(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx

    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0], bytes[1], bytes[2],  bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

test {
    _ = @import("ingest_test.zig");
}
