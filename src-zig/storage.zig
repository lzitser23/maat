//! Zig port of Maat's SQLite storage layer (originally src-tauri/src/storage.rs).
//!
//! Design deltas from the Rust original (see scratchpad/INTERFACE.md + COMMAND-CONTRACT.md):
//!   * ONE long-lived connection owned by `Storage` (the Rust original opened a fresh
//!     `Connection` per command, which is why `PRAGMA foreign_keys = ON` never actually
//!     took effect there). Here the pragma is set once at `open()` and stays in effect
//!     for the process lifetime.
//!   * `deleteBoard` explicitly deletes child rows (frames, board_nodes, assets, sources)
//!     in one transaction before deleting the `libraries` row. The Rust original relied
//!     solely on `ON DELETE CASCADE`, which never fired (see above), leaking orphan rows.
//!     This port fixes that bug on purpose (INTERFACE.md item 1).
//!   * Thread-safety: `Storage` is intended to be used from multiple threads (import jobs
//!     run on a worker thread while the UI thread may load/update boards concurrently), so
//!     every public method takes `self.mutex` for the duration of its body. All shared
//!     state (the sqlite3 connection, the root Dir handle) is only ever touched while the
//!     mutex is held.
//!
//! Self-contained: imports only `std` and the vendored `sqlite3.h` (via `@cImport`).

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Domain-specific errors this module returns explicitly (in addition to the usual
/// `error.OutOfMemory` / filesystem / sqlite plumbing errors, which are left in each
/// function's inferred error set rather than enumerated here).
pub const DomainError = error{
    /// A sqlite API call failed. There is no structured error code from sqlite carried
    /// alongside this - callers that need the sqlite message should use `sqlite3_errmsg`
    /// themselves during development; in production this maps to a generic message.
    SqliteError,
    /// `getBoard` / `renameBoard` / etc. was asked for a board id that doesn't exist.
    /// (The Rust original surfaced rusqlite's `"Query returned no rows"` here, which
    /// COMMAND-CONTRACT.md §3 explicitly recommends NOT reproducing verbatim - this is
    /// a deliberately clearer replacement.)
    NotFound,
    /// `deleteBoard` refused because it was asked to delete the only remaining board.
    CannotDeleteLastBoard,
    /// Only reachable if the last-board guard were somehow bypassed.
    NoBoardAvailable,
};

/// Best-effort mapping from a `DomainError` to the exact human-readable string the
/// command-contract specifies (only `CannotDeleteLastBoard`'s string is contractually
/// exact; the others are this port's own clear replacements for sqlite-driver-specific
/// text - see `DomainError.NotFound` doc comment).
pub fn errorMessage(err: DomainError) []const u8 {
    return switch (err) {
        error.SqliteError => "Database error",
        error.NotFound => "Board not found",
        error.CannotDeleteLastBoard => "Cannot delete the last board",
        error.NoBoardAvailable => "No board available",
    };
}

// ---------------------------------------------------------------------------
// DTOs - field names are the exact camelCase JSON keys from COMMAND-CONTRACT.md §2.
// Zig's `std.json.Stringify` renders a plain struct as an object using its field names
// verbatim and in declaration order, so these types double as both the in-memory model
// and the JSON wire shape: no separate serde-style mapping layer is needed.
// ---------------------------------------------------------------------------

pub const Board = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    drawingJson: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,

    pub fn deinit(self: Board, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.drawingJson);
        allocator.free(self.createdAt);
        allocator.free(self.updatedAt);
    }

    pub fn toJson(self: Board, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

pub const Source = struct {
    id: []const u8,
    boardId: []const u8,
    kind: []const u8,
    path: []const u8,
    mode: []const u8,
    importedAt: []const u8,
    itemCount: i64,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.boardId);
        allocator.free(self.kind);
        allocator.free(self.path);
        allocator.free(self.mode);
        allocator.free(self.importedAt);
    }

    pub fn toJson(self: Source, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

pub const Asset = struct {
    id: []const u8,
    boardId: []const u8,
    sourceId: ?[]const u8,
    name: []const u8,
    originalPath: []const u8,
    managedPath: []const u8,
    mime: []const u8,
    extension: []const u8,
    size: i64,
    hash: []const u8,
    width: ?i64,
    height: ?i64,
    kind: []const u8,
    previewStatus: []const u8,
    thumbnailPath: ?[]const u8,
    tags: []const []const u8,
    folders: []const []const u8,
    note: ?[]const u8,
    sourceUrl: ?[]const u8,
    trashedAt: ?[]const u8,
    createdAt: []const u8,
    metadataJson: ?[]const u8,

    pub fn deinit(self: Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.boardId);
        if (self.sourceId) |v| allocator.free(v);
        allocator.free(self.name);
        allocator.free(self.originalPath);
        allocator.free(self.managedPath);
        allocator.free(self.mime);
        allocator.free(self.extension);
        allocator.free(self.hash);
        allocator.free(self.kind);
        allocator.free(self.previewStatus);
        if (self.thumbnailPath) |v| allocator.free(v);
        freeStringSlice(allocator, self.tags);
        freeStringSlice(allocator, self.folders);
        if (self.note) |v| allocator.free(v);
        if (self.sourceUrl) |v| allocator.free(v);
        if (self.trashedAt) |v| allocator.free(v);
        allocator.free(self.createdAt);
        if (self.metadataJson) |v| allocator.free(v);
    }

    pub fn toJson(self: Asset, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

pub const BoardNode = struct {
    id: []const u8,
    boardId: []const u8,
    assetId: []const u8,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    z: i64,
    locked: bool,
    arrangeGroup: ?[]const u8,

    pub fn deinit(self: BoardNode, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.boardId);
        allocator.free(self.assetId);
        if (self.arrangeGroup) |v| allocator.free(v);
    }

    pub fn toJson(self: BoardNode, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

pub const Frame = struct {
    id: []const u8,
    boardId: []const u8,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    label: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.boardId);
        allocator.free(self.label);
        allocator.free(self.createdAt);
        allocator.free(self.updatedAt);
    }

    pub fn toJson(self: Frame, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

pub const BoardView = struct {
    board: Board,
    sources: []Source,
    assets: []Asset,
    nodes: []BoardNode,
    frames: []Frame,

    pub fn deinit(self: BoardView, allocator: std.mem.Allocator) void {
        self.board.deinit(allocator);
        freeList(Source, allocator, self.sources);
        freeList(Asset, allocator, self.assets);
        freeList(BoardNode, allocator, self.nodes);
        freeList(Frame, allocator, self.frames);
    }

    pub fn toJson(self: BoardView, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

pub const AppStateDto = struct {
    boards: []Board,
    activeBoardId: []const u8,
    view: BoardView,

    pub fn deinit(self: AppStateDto, allocator: std.mem.Allocator) void {
        freeList(Board, allocator, self.boards);
        allocator.free(self.activeBoardId);
        self.view.deinit(allocator);
    }

    pub fn toJson(self: AppStateDto, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

/// Input DTO for `updateNodes` - borrowed slices, caller retains ownership.
pub const NodeUpdate = struct {
    id: []const u8,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    z: i64,
    locked: bool,
    arrangeGroup: ?[]const u8,
};

/// Input DTO for `updateFrames` - borrowed slices, caller retains ownership.
pub const FrameUpdate = struct {
    id: []const u8,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    label: []const u8,
};

fn freeList(comptime T: type, allocator: std.mem.Allocator, items: []T) void {
    for (items) |item| item.deinit(allocator);
    allocator.free(items);
}

fn freeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

pub const Storage = struct {
    allocator: std.mem.Allocator,
    /// Absolute path to the storage root (e.g. `%APPDATA%\MaatNative`), owned, no
    /// trailing separator.
    root: []u8,
    /// Handle to `root`, used for all relative filesystem operations below it
    /// (per-board directory creation, managed-file/board-folder deletion).
    root_dir: std.Io.Dir,
    db: *c.sqlite3,
    /// Blocking, single-threaded `Io` backend used for the handful of filesystem
    /// operations this module needs (directory creation/deletion, file deletion).
    /// Never cache the result of `.io()` across a move of `Storage` - always
    /// recompute it fresh via `ioHandle()` at the point of use.
    io_threaded: std.Io.Threaded = std.Io.Threaded.init_single_threaded,
    /// Guards every public method's body. `Storage` is expected to be called from
    /// multiple threads (e.g. an import worker thread alongside the UI thread), and
    /// sqlite3 connections plus the root `Dir` handle are not safe for unsynchronized
    /// concurrent use from this wrapper's perspective, so every public entry point
    /// takes this lock for its full duration. Internal helper methods that are called
    /// while a lock is already held do NOT lock again (that would deadlock - Zig's
    /// `Thread.Mutex` is not reentrant); such helpers are named with an `Impl` suffix
    /// and are never `pub`.
    mutex: std.Io.Mutex = .init,

    fn ioHandle(self: *Storage) std.Io {
        return self.io_threaded.io();
    }

    /// Opens (creating if necessary) the catalog database at
    /// `<root_dir_absolute_path>/catalog.sqlite3`, creates `<root>/boards`, runs the
    /// schema/migration bring-up, and seeds a default "Maat Board" if the catalog is
    /// empty. Mirrors Rust's `Storage::new_at` + `init()`.
    pub fn open(allocator: std.mem.Allocator, root_dir_absolute_path: []const u8) !Storage {
        var io_threaded: std.Io.Threaded = .init_single_threaded;
        const io = io_threaded.io();

        const root = try allocator.dupe(u8, root_dir_absolute_path);
        errdefer allocator.free(root);

        var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
        errdefer root_dir.close(io);

        try root_dir.createDirPath(io, "boards");

        const db_path = try std.fs.path.joinZ(allocator, &.{ root, "catalog.sqlite3" });
        defer allocator.free(db_path);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            db_path.ptr,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteError;
        }
        errdefer _ = c.sqlite3_close(db.?);

        var storage = Storage{
            .allocator = allocator,
            .root = root,
            .root_dir = root_dir,
            .db = db.?,
            .io_threaded = io_threaded,
        };
        try storage.runInit();
        return storage;
    }

    pub fn close(self: *Storage) void {
        _ = c.sqlite3_close(self.db);
        self.root_dir.close(self.ioHandle());
        self.allocator.free(self.root);
        self.* = undefined;
    }

    // -- schema / migrations --------------------------------------------------

    fn runInit(self: *Storage) !void {
        try self.execSql(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA foreign_keys = ON;
            \\
            \\CREATE TABLE IF NOT EXISTS libraries (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    path TEXT NOT NULL,
            \\    drawing_json TEXT NOT NULL DEFAULT '[]',
            \\    created_at TEXT NOT NULL,
            \\    updated_at TEXT NOT NULL
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS sources (
            \\    id TEXT PRIMARY KEY,
            \\    library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            \\    kind TEXT NOT NULL,
            \\    path TEXT NOT NULL,
            \\    mode TEXT NOT NULL,
            \\    imported_at TEXT NOT NULL,
            \\    item_count INTEGER NOT NULL DEFAULT 0
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS assets (
            \\    id TEXT PRIMARY KEY,
            \\    library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            \\    source_id TEXT REFERENCES sources(id) ON DELETE SET NULL,
            \\    name TEXT NOT NULL,
            \\    original_path TEXT NOT NULL,
            \\    managed_path TEXT NOT NULL,
            \\    mime TEXT NOT NULL,
            \\    extension TEXT NOT NULL,
            \\    size INTEGER NOT NULL,
            \\    hash TEXT NOT NULL,
            \\    width INTEGER,
            \\    height INTEGER,
            \\    kind TEXT NOT NULL,
            \\    preview_status TEXT NOT NULL,
            \\    thumbnail_path TEXT,
            \\    tags_json TEXT NOT NULL DEFAULT '[]',
            \\    folders_json TEXT NOT NULL DEFAULT '[]',
            \\    note TEXT,
            \\    source_url TEXT,
            \\    trashed_at TEXT,
            \\    created_at TEXT NOT NULL,
            \\    metadata_json TEXT,
            \\    UNIQUE(library_id, hash)
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS board_nodes (
            \\    id TEXT PRIMARY KEY,
            \\    library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            \\    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            \\    x REAL NOT NULL,
            \\    y REAL NOT NULL,
            \\    width REAL NOT NULL,
            \\    height REAL NOT NULL,
            \\    z INTEGER NOT NULL,
            \\    locked INTEGER NOT NULL DEFAULT 0,
            \\    arrange_group TEXT,
            \\    created_at TEXT NOT NULL,
            \\    updated_at TEXT NOT NULL
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS frames (
            \\    id TEXT PRIMARY KEY,
            \\    library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
            \\    x REAL NOT NULL,
            \\    y REAL NOT NULL,
            \\    width REAL NOT NULL,
            \\    height REAL NOT NULL,
            \\    label TEXT NOT NULL DEFAULT '',
            \\    created_at TEXT NOT NULL,
            \\    updated_at TEXT NOT NULL
            \\);
        );

        try self.migrateBoards();
        try self.migrateAssets();
        try self.repairSourceCountsImpl();

        const boards = try self.listBoardsImpl(self.allocator);
        defer freeList(Board, self.allocator, boards);
        if (boards.len == 0) {
            const board = try self.createBoardImpl(self.allocator, "Maat Board");
            board.deinit(self.allocator);
        }
    }

    fn migrateBoards(self: *Storage) !void {
        const columns = try self.tableColumns(self.allocator, "libraries");
        defer freeStringSlice(self.allocator, columns);
        if (!containsString(columns, "drawing_json")) {
            try self.execSql("ALTER TABLE libraries ADD COLUMN drawing_json TEXT NOT NULL DEFAULT '[]'");
        }
    }

    fn migrateAssets(self: *Storage) !void {
        const columns = try self.tableColumns(self.allocator, "assets");
        defer freeStringSlice(self.allocator, columns);

        const Migration = struct { col: []const u8, sql: [:0]const u8 };
        const migrations = [_]Migration{
            .{ .col = "tags_json", .sql = "ALTER TABLE assets ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]'" },
            .{ .col = "folders_json", .sql = "ALTER TABLE assets ADD COLUMN folders_json TEXT NOT NULL DEFAULT '[]'" },
            .{ .col = "note", .sql = "ALTER TABLE assets ADD COLUMN note TEXT" },
            .{ .col = "source_url", .sql = "ALTER TABLE assets ADD COLUMN source_url TEXT" },
            .{ .col = "trashed_at", .sql = "ALTER TABLE assets ADD COLUMN trashed_at TEXT" },
        };
        for (migrations) |m| {
            if (!containsString(columns, m.col)) {
                try self.execSql(m.sql);
            }
        }
    }

    // `table` is string-built into the PRAGMA statement (sqlite doesn't allow
    // binding identifiers as parameters). This is safe only because both call
    // sites pass a fixed string literal ("libraries", "assets") -- `table`
    // must never be derived from user/external input.
    fn tableColumns(self: *Storage, allocator: std.mem.Allocator, table: []const u8) ![][]const u8 {
        var buf: [64]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&buf, "PRAGMA table_info({s})", .{table});
        const stmt = try self.prepareStmt(sql);
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try columnText(allocator, stmt, 1));
        }
        return try list.toOwnedSlice(allocator);
    }

    fn repairSourceCountsImpl(self: *Storage) !void {
        try self.execSql(
            \\UPDATE sources
            \\SET item_count = (
            \\    SELECT COUNT(*)
            \\    FROM assets
            \\    WHERE assets.source_id = sources.id
            \\)
        );
    }

    pub fn repairSourceCounts(self: *Storage) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        try self.repairSourceCountsImpl();
    }

    // -- boards -----------------------------------------------------------------

    fn boardFromRow(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Board {
        const id = try columnText(allocator, stmt, 0);
        errdefer allocator.free(id);
        const name = try columnText(allocator, stmt, 1);
        errdefer allocator.free(name);
        const path = try columnText(allocator, stmt, 2);
        errdefer allocator.free(path);
        const drawing_json = try columnText(allocator, stmt, 3);
        errdefer allocator.free(drawing_json);
        const created_at = try columnText(allocator, stmt, 4);
        errdefer allocator.free(created_at);
        const updated_at = try columnText(allocator, stmt, 5);
        errdefer allocator.free(updated_at);
        return Board{
            .id = id,
            .name = name,
            .path = path,
            .drawingJson = drawing_json,
            .createdAt = created_at,
            .updatedAt = updated_at,
        };
    }

    fn listBoardsImpl(self: *Storage, allocator: std.mem.Allocator) ![]Board {
        const stmt = try self.prepareStmt(
            "SELECT id, name, path, drawing_json, created_at, updated_at FROM libraries ORDER BY created_at ASC",
        );
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayList(Board) = .empty;
        errdefer {
            for (list.items) |b| b.deinit(allocator);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try boardFromRow(allocator, stmt));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn listBoards(self: *Storage, allocator: std.mem.Allocator) ![]Board {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.listBoardsImpl(allocator);
    }

    fn getBoardImpl(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) !Board {
        const stmt = try self.prepareStmt(
            "SELECT id, name, path, drawing_json, created_at, updated_at FROM libraries WHERE id = ?1",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);
        if (!try stepRow(stmt)) return error.NotFound;
        return boardFromRow(allocator, stmt);
    }

    pub fn getBoard(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) !Board {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.getBoardImpl(allocator, board_id);
    }

    fn createBoardImpl(self: *Storage, allocator: std.mem.Allocator, name: []const u8) !Board {
        const now = try self.nowRfc3339(allocator);
        errdefer allocator.free(now);
        const id = try self.newUuidV4(allocator);
        errdefer allocator.free(id);

        const board_path = try std.fs.path.join(allocator, &.{ self.root, "boards", id });
        errdefer allocator.free(board_path);

        {
            const rel_assets = try std.fmt.allocPrint(allocator, "boards/{s}/assets", .{id});
            defer allocator.free(rel_assets);
            try self.root_dir.createDirPath(self.ioHandle(), rel_assets);
        }
        {
            const rel_thumbs = try std.fmt.allocPrint(allocator, "boards/{s}/thumbs", .{id});
            defer allocator.free(rel_thumbs);
            try self.root_dir.createDirPath(self.ioHandle(), rel_thumbs);
        }

        const drawing_json = try allocator.dupe(u8, "[]");
        errdefer allocator.free(drawing_json);
        const updated_at = try allocator.dupe(u8, now);
        errdefer allocator.free(updated_at);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const stmt = try self.prepareStmt(
            "INSERT INTO libraries (id, name, path, drawing_json, created_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6)",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, id);
        try bindText(stmt, 2, name);
        try bindText(stmt, 3, board_path);
        try bindText(stmt, 4, drawing_json);
        try bindText(stmt, 5, now);
        try bindText(stmt, 6, now);
        _ = try stepDone(stmt);

        return Board{
            .id = id,
            .name = name_copy,
            .path = board_path,
            .drawingJson = drawing_json,
            .createdAt = now,
            .updatedAt = updated_at,
        };
    }

    pub fn createBoard(self: *Storage, allocator: std.mem.Allocator, name: []const u8) !Board {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.createBoardImpl(allocator, name);
    }

    pub fn renameBoard(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8, name: []const u8) !Board {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const now = try self.nowRfc3339(self.allocator);
        defer self.allocator.free(now);

        {
            const stmt = try self.prepareStmt("UPDATE libraries SET name = ?1, updated_at = ?2 WHERE id = ?3");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, name);
            try bindText(stmt, 2, now);
            try bindText(stmt, 3, board_id);
            _ = try stepDone(stmt);
        }
        // Matches Rust: the UPDATE itself doesn't check rows-affected; a missing
        // board id only surfaces as NotFound from this re-fetch.
        return self.getBoardImpl(allocator, board_id);
    }

    fn loadBoardImpl(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) !BoardView {
        const board = try self.getBoardImpl(allocator, board_id);
        errdefer board.deinit(allocator);
        const sources = try self.listSourcesImpl(allocator, board_id);
        errdefer freeList(Source, allocator, sources);
        const assets = try self.listAssetsImpl(allocator, board_id);
        errdefer freeList(Asset, allocator, assets);
        const nodes = try self.listNodesImpl(allocator, board_id);
        errdefer freeList(BoardNode, allocator, nodes);
        const frames = try self.listFramesImpl(allocator, board_id);
        errdefer freeList(Frame, allocator, frames);
        return BoardView{
            .board = board,
            .sources = sources,
            .assets = assets,
            .nodes = nodes,
            .frames = frames,
        };
    }

    pub fn loadBoard(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) !BoardView {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.loadBoardImpl(allocator, board_id);
    }

    // -- board pagination (issue #4) ---------------------------------------------
    //
    // `load_board_page` streams a board's assets+nodes in bounded pages instead
    // of one unbounded `loadBoard` response (measured to reach ~374 KiB at 300
    // assets, breaking around 750-800 against the bridge's ~1 MiB cap). `board`,
    // `sources`, and `frames` are small and unbounded-count-unlikely, so they're
    // only sent on the first page (`cursor == null`); later pages carry `null`
    // for those three and just more `assets`/`nodes`.
    //
    // Cursor = the SQLite `rowid` of the last asset returned (assets keeps its
    // own TEXT `id` primary key, so `rowid` is a separate, always-present,
    // strictly-increasing-on-insert column - stable and free to sort by,
    // unlike `created_at`, which can collide at millisecond resolution across
    // a fast bulk import). Consistency stance: each page is read under
    // `self.mutex` independently (not one held lock across the whole
    // pagination sequence, since pages are separate bridge calls from the
    // frontend) - an insert that lands between two page fetches may or may not
    // appear in the pages already fetched or about to be fetched, but because
    // pagination is strictly `rowid > cursor` in ascending order, no already-
    // delivered asset is ever re-delivered and no page is ever missing an
    // asset that existed at the time of ITS OWN fetch. A concurrent purge of an
    // already-delivered asset likewise just means the frontend briefly holds a
    // now-stale row until its next full reload - the same staleness window
    // `loadBoard`'s single unbounded snapshot always had relative to whatever
    // happens after it returns.
    pub const board_page_size: usize = 300;

    // Byte budget (issue #4 follow-up): a fixed 300-row page does not
    // guarantee the serialized response fits the bridge's ~1 MiB buffer --
    // `note`, `metadataJson`, `tags`/`folders`, and `thumbnailPath` are all
    // user/import-influenced and effectively unbounded per asset. This is a
    // conservative ceiling (well under the ~1 MiB cap, leaving headroom for
    // the bridge envelope) that pagination now also respects: a page is cut
    // short of `board_page_size` once admitting the next row would cross
    // it. The exception (matching the review's explicit guidance) is a
    // single indivisible oversized row: the FIRST row admitted onto a page
    // always goes through even if it alone exceeds the budget, since there
    // is no smaller unit to split it into.
    pub const board_page_byte_budget: usize = 512 * 1024;

    /// Conservative flat reserve for one `board_nodes` row's serialized
    /// JSON size, added on top of each admitted asset's own measured size
    /// when deciding whether a row still fits the budget. Unlike `Asset`
    /// (whose `note`/`metadataJson`/`tags`/`folders` are user-unbounded), a
    /// node is fixed-shape (a handful of uuids, four `f64` coordinates, a
    /// z-index, a bool, and a short optional `arrangeGroup` id) -- a flat
    /// reserve is accurate enough without re-serializing every node just to
    /// measure it (nodes for a page are only looked up in bulk AFTER the
    /// page's asset set is decided, so their real bytes aren't known yet at
    /// the point this reserve is needed).
    const board_page_node_byte_reserve: usize = 512;

    pub const BoardPage = struct {
        board: ?Board,
        sources: ?[]Source,
        frames: ?[]Frame,
        assets: []Asset,
        nodes: []BoardNode,
        nextCursor: ?[]const u8,

        pub fn deinit(self: BoardPage, allocator: std.mem.Allocator) void {
            if (self.board) |b| b.deinit(allocator);
            if (self.sources) |s| freeList(Source, allocator, s);
            if (self.frames) |f| freeList(Frame, allocator, f);
            freeList(Asset, allocator, self.assets);
            freeList(BoardNode, allocator, self.nodes);
            if (self.nextCursor) |cursor| allocator.free(cursor);
        }

        pub fn toJson(self: BoardPage, allocator: std.mem.Allocator) ![]u8 {
            return std.json.Stringify.valueAlloc(allocator, self, .{});
        }
    };

    const AssetsPage = struct { assets: []Asset, next_rowid: ?i64 };

    /// Fetches up to `max_rows` assets with `rowid > after_rowid`
    /// (ascending), stopping early -- before `max_rows` -- if admitting the
    /// next row would push the page's estimated serialized size past
    /// `byte_budget` (see `board_page_byte_budget`'s doc comment). The
    /// FIRST row admitted onto the page is always kept even if it alone
    /// exceeds the budget (an indivisible oversized single row must still
    /// go through). Returns the assets and the rowid to resume from, or
    /// `null` if this was the last page.
    fn listAssetsPageImpl(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        after_rowid: i64,
        max_rows: usize,
        byte_budget: usize,
    ) !AssetsPage {
        const stmt = try self.prepareStmt(
            \\SELECT rowid, id, library_id, source_id, name, original_path, managed_path, mime, extension, size,
            \\       hash, width, height, kind, preview_status, thumbnail_path, tags_json, folders_json,
            \\       note, source_url, trashed_at, created_at, metadata_json
            \\FROM assets WHERE library_id = ?1 AND rowid > ?2 ORDER BY rowid ASC LIMIT ?3
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);
        try bindInt64(stmt, 2, after_rowid);
        // +1: one extra probe row, only ever reached when the byte budget
        // never triggers an earlier stop, to determine whether another
        // page follows once `max_rows` is hit without a wasted round trip.
        try bindInt64(stmt, 3, @intCast(max_rows + 1));

        var assets: std.ArrayList(Asset) = .empty;
        errdefer {
            for (assets.items) |a| a.deinit(allocator);
            assets.deinit(allocator);
        }
        var rowids: std.ArrayList(i64) = .empty;
        defer rowids.deinit(allocator);

        var used_bytes: usize = 0;
        var next_rowid: ?i64 = null;

        while (try stepRow(stmt)) {
            const rowid = columnInt64(stmt, 0);
            const asset = try assetFromRow(allocator, stmt, 1);

            if (assets.items.len >= max_rows) {
                // Row-count ceiling reached; this row's mere existence
                // proves a next page follows.
                asset.deinit(allocator);
                next_rowid = rowids.items[rowids.items.len - 1];
                break;
            }

            const asset_json = try asset.toJson(allocator);
            const row_cost = asset_json.len + board_page_node_byte_reserve;
            allocator.free(asset_json);

            if (assets.items.len > 0 and used_bytes + row_cost > byte_budget) {
                // Byte budget reached; this row starts the next page. Never
                // triggered for the first row of a page -- see the doc
                // comment above.
                asset.deinit(allocator);
                next_rowid = rowids.items[rowids.items.len - 1];
                break;
            }

            used_bytes += row_cost;
            try rowids.append(allocator, rowid);
            try assets.append(allocator, asset);
        }

        return .{ .assets = try assets.toOwnedSlice(allocator), .next_rowid = next_rowid };
    }

    /// Fetches the `board_nodes` rows for exactly `asset_ids` (a node is
    /// created 1:1 with its asset by `insertBoardNodeImpl` and only ever
    /// removed alongside it, so this is the full node set for the page).
    /// Builds a dynamic `IN (...)` clause since sqlite has no array-bind
    /// parameter type; `asset_ids.len` is bounded by `board_page_size`
    /// (300), so the generated SQL text stays small.
    fn listNodesForAssetIdsImpl(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        asset_ids: []const []const u8,
    ) ![]BoardNode {
        if (asset_ids.len == 0) return allocator.alloc(BoardNode, 0);

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.appendSlice(
            allocator,
            "SELECT id, library_id, asset_id, x, y, width, height, z, locked, arrange_group FROM board_nodes WHERE library_id = ? AND asset_id IN (",
        );
        for (asset_ids, 0..) |_, i| {
            if (i > 0) try sql_buf.appendSlice(allocator, ",");
            try sql_buf.appendSlice(allocator, "?");
        }
        try sql_buf.appendSlice(allocator, ") ORDER BY z ASC");

        const sql_owned = try allocator.dupeZ(u8, sql_buf.items);
        defer allocator.free(sql_owned);
        const stmt = try self.prepareStmt(sql_owned);
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, board_id);
        for (asset_ids, 0..) |asset_id, i| try bindText(stmt, @intCast(i + 2), asset_id);

        var list: std.ArrayList(BoardNode) = .empty;
        errdefer {
            for (list.items) |n| n.deinit(allocator);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try nodeFromRow(allocator, stmt));
        }
        return try list.toOwnedSlice(allocator);
    }

    /// Public paginated entry point behind the `load_board_page` bridge
    /// command. `cursor` is `null` for the first page (which also carries
    /// `board`/`sources`/`frames`) or a previous page's `nextCursor` string
    /// for a later page.
    pub fn loadBoardPage(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8, cursor: ?[]const u8) !BoardPage {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const after_rowid: i64 = if (cursor) |cur|
            std.fmt.parseInt(i64, cur, 10) catch return error.InvalidCursor
        else
            0;

        var board: ?Board = null;
        errdefer if (board) |b| b.deinit(allocator);
        var sources: ?[]Source = null;
        errdefer if (sources) |s| freeList(Source, allocator, s);
        var frames: ?[]Frame = null;
        errdefer if (frames) |f| freeList(Frame, allocator, f);

        var metadata_bytes: usize = 0;

        if (cursor == null) {
            board = try self.getBoardImpl(allocator, board_id);
            sources = try self.listSourcesImpl(allocator, board_id);
            frames = try self.listFramesImpl(allocator, board_id);

            // `board`'s `drawingJson` (and, in principle, a very large
            // number of sources/frames) is user-influenced and effectively
            // unbounded, so the first page's own metadata can already
            // approach or exceed the byte budget on its own -- measured
            // here so the assets query below is given whatever budget
            // remains, rather than blindly adding assets on top of an
            // already-large metadata payload.
            const board_json = try board.?.toJson(allocator);
            allocator.free(board_json);
            const sources_json = try std.json.Stringify.valueAlloc(allocator, sources.?, .{});
            allocator.free(sources_json);
            const frames_json = try std.json.Stringify.valueAlloc(allocator, frames.?, .{});
            allocator.free(frames_json);
            metadata_bytes = board_json.len + sources_json.len + frames_json.len;
        } else {
            // Later pages don't need the board row for anything, but still
            // confirm the board exists so a bogus/deleted boardId surfaces
            // `error.NotFound` instead of silently returning an empty page.
            const existing = try self.getBoardImpl(allocator, board_id);
            existing.deinit(allocator);
        }

        // If the board's own metadata already meets/exceeds the budget,
        // ship it alone with zero assets on this page (the same
        // "indivisible oversized item still goes through" exception
        // `listAssetsPageImpl` applies per-row, just applied to the whole
        // metadata block here) -- `nextCursor` stays at `after_rowid`
        // (unconsumed) so the very next call fetches assets from the
        // beginning with the full budget to itself, and can legitimately
        // resolve to "no more pages" if the board genuinely has none.
        const page = if (metadata_bytes >= board_page_byte_budget)
            AssetsPage{ .assets = try allocator.alloc(Asset, 0), .next_rowid = after_rowid }
        else
            try self.listAssetsPageImpl(allocator, board_id, after_rowid, board_page_size, board_page_byte_budget - metadata_bytes);
        errdefer {
            for (page.assets) |a| a.deinit(allocator);
            allocator.free(page.assets);
        }

        const asset_ids = try allocator.alloc([]const u8, page.assets.len);
        defer allocator.free(asset_ids);
        for (page.assets, 0..) |a, i| asset_ids[i] = a.id;

        const nodes = try self.listNodesForAssetIdsImpl(allocator, board_id, asset_ids);
        errdefer freeList(BoardNode, allocator, nodes);

        const next_cursor: ?[]u8 = if (page.next_rowid) |r| try std.fmt.allocPrint(allocator, "{d}", .{r}) else null;

        return BoardPage{
            .board = board,
            .sources = sources,
            .frames = frames,
            .assets = page.assets,
            .nodes = nodes,
            .nextCursor = next_cursor,
        };
    }

    /// Composes `AppStateDto` the way `get_app_state` does: oldest-created board
    /// (`listBoards` is already `ORDER BY created_at ASC`) is the active board.
    pub fn getAppState(self: *Storage, allocator: std.mem.Allocator) !AppStateDto {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const boards = try self.listBoardsImpl(allocator);
        errdefer freeList(Board, allocator, boards);
        if (boards.len == 0) return error.NoBoardAvailable;

        const active_board_id = try allocator.dupe(u8, boards[0].id);
        errdefer allocator.free(active_board_id);
        const view = try self.loadBoardImpl(allocator, boards[0].id);

        return AppStateDto{
            .boards = boards,
            .activeBoardId = active_board_id,
            .view = view,
        };
    }

    /// Deletes a board. Unlike the Rust original (which relied on a `FOREIGN KEY
    /// ... ON DELETE CASCADE` that never actually fired, since every Rust command
    /// opened a fresh connection with `foreign_keys` back off - see
    /// COMMAND-CONTRACT.md §3), this explicitly deletes frames/board_nodes/assets/
    /// sources for the board in the same transaction before deleting the `libraries`
    /// row (INTERFACE.md item 1 - a deliberate bug fix, not a preserved quirk).
    /// Returns the reloaded `BoardView` of the next-oldest remaining board.
    pub fn deleteBoard(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) !BoardView {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const boards = try self.listBoardsImpl(allocator);
        defer freeList(Board, allocator, boards);
        if (boards.len <= 1) return error.CannotDeleteLastBoard;

        // Mirrors Rust's `get_board(board_id)` call before deleting: surfaces
        // `error.NotFound` for a bogus id before any row is touched. The folder
        // cleanup below reconstructs the path from `board_id` directly rather than
        // keeping this fetched value around.
        const existing = try self.getBoardImpl(allocator, board_id);
        existing.deinit(allocator);

        try self.execSql("BEGIN");
        errdefer self.execSql("ROLLBACK") catch {};

        try self.execOneText("DELETE FROM frames WHERE library_id = ?1", board_id);
        try self.execOneText("DELETE FROM board_nodes WHERE library_id = ?1", board_id);
        try self.execOneText("DELETE FROM assets WHERE library_id = ?1", board_id);
        try self.execOneText("DELETE FROM sources WHERE library_id = ?1", board_id);
        try self.execOneText("DELETE FROM libraries WHERE id = ?1", board_id);

        try self.execSql("COMMIT");

        // Best-effort: remove the whole board folder (assets + thumbs), like Rust's
        // `let _ = fs::remove_dir_all(board.path);`.
        {
            const rel = try std.fmt.allocPrint(allocator, "boards/{s}", .{board_id});
            defer allocator.free(rel);
            self.root_dir.deleteTree(self.ioHandle(), rel) catch {};
        }

        const remaining = try self.listBoardsImpl(allocator);
        defer freeList(Board, allocator, remaining);
        if (remaining.len == 0) return error.NoBoardAvailable;
        return self.loadBoardImpl(allocator, remaining[0].id);
    }

    pub fn updateBoardDrawing(self: *Storage, board_id: []const u8, drawing_json: []const u8) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const now = try self.nowRfc3339(self.allocator);
        defer self.allocator.free(now);

        const stmt = try self.prepareStmt("UPDATE libraries SET drawing_json = ?1, updated_at = ?2 WHERE id = ?3");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, drawing_json);
        try bindText(stmt, 2, now);
        try bindText(stmt, 3, board_id);
        _ = try stepDone(stmt);
    }

    // -- sources ------------------------------------------------------------------

    fn sourceFromRow(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Source {
        const id = try columnText(allocator, stmt, 0);
        errdefer allocator.free(id);
        const board_id = try columnText(allocator, stmt, 1);
        errdefer allocator.free(board_id);
        const kind = try columnText(allocator, stmt, 2);
        errdefer allocator.free(kind);
        const path = try columnText(allocator, stmt, 3);
        errdefer allocator.free(path);
        const mode = try columnText(allocator, stmt, 4);
        errdefer allocator.free(mode);
        const imported_at = try columnText(allocator, stmt, 5);
        errdefer allocator.free(imported_at);
        const item_count = columnInt64(stmt, 6);
        return Source{
            .id = id,
            .boardId = board_id,
            .kind = kind,
            .path = path,
            .mode = mode,
            .importedAt = imported_at,
            .itemCount = item_count,
        };
    }

    fn listSourcesImpl(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]Source {
        const stmt = try self.prepareStmt(
            "SELECT id, library_id, kind, path, mode, imported_at, item_count FROM sources WHERE library_id = ?1 ORDER BY imported_at DESC",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);

        var list: std.ArrayList(Source) = .empty;
        errdefer {
            for (list.items) |s| s.deinit(allocator);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try sourceFromRow(allocator, stmt));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn listSources(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]Source {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.listSourcesImpl(allocator, board_id);
    }

    /// Ingest-facing: creates a `sources` row (mirrors Rust's `create_source`).
    pub fn insertSource(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        kind: []const u8,
        path: []const u8,
        mode: []const u8,
    ) !Source {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const now = try self.nowRfc3339(allocator);
        errdefer allocator.free(now);
        const id = try self.newUuidV4(allocator);
        errdefer allocator.free(id);
        const board_id_copy = try allocator.dupe(u8, board_id);
        errdefer allocator.free(board_id_copy);
        const kind_copy = try allocator.dupe(u8, kind);
        errdefer allocator.free(kind_copy);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        const mode_copy = try allocator.dupe(u8, mode);
        errdefer allocator.free(mode_copy);

        const stmt = try self.prepareStmt(
            "INSERT INTO sources (id, library_id, kind, path, mode, imported_at, item_count) VALUES (?1,?2,?3,?4,?5,?6,0)",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, id);
        try bindText(stmt, 2, board_id);
        try bindText(stmt, 3, kind);
        try bindText(stmt, 4, path);
        try bindText(stmt, 5, mode);
        try bindText(stmt, 6, now);
        _ = try stepDone(stmt);

        return Source{
            .id = id,
            .boardId = board_id_copy,
            .kind = kind_copy,
            .path = path_copy,
            .mode = mode_copy,
            .importedAt = now,
            .itemCount = 0,
        };
    }

    /// Ingest-facing: additive item-count bump (mirrors Rust's `increment_source`).
    /// Called once per source after all of its candidates have been processed.
    pub fn bumpSourceCount(self: *Storage, source_id: []const u8, amount: i64) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const stmt = try self.prepareStmt("UPDATE sources SET item_count = item_count + ?1 WHERE id = ?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, amount);
        try bindText(stmt, 2, source_id);
        _ = try stepDone(stmt);
    }

    fn deleteSourceRow(self: *Storage, board_id: []const u8, source_id: []const u8) !void {
        const stmt = try self.prepareStmt("DELETE FROM sources WHERE id = ?1 AND library_id = ?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source_id);
        try bindText(stmt, 2, board_id);
        _ = try stepDone(stmt);
    }

    /// Deletes a source, its assets, and their placed board nodes in one transaction
    /// (same `purgeAssetRows` helper `purgeAssets` uses), then removes the managed
    /// files from disk only after the transaction commits. Returns the reloaded
    /// `BoardView`. Matches Rust: does NOT call `repairSourceCounts` (moot - the
    /// source row itself is being deleted).
    pub fn deleteSource(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8, source_id: []const u8) !BoardView {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        try self.execSql("BEGIN");
        errdefer self.execSql("ROLLBACK") catch {};

        const asset_ids = try self.assetIdsForSource(allocator, board_id, source_id);
        defer {
            for (asset_ids) |a| allocator.free(a);
            allocator.free(asset_ids);
        }

        const files = try self.purgeAssetRowsImpl(allocator, board_id, asset_ids);
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }

        try self.deleteSourceRow(board_id, source_id);
        try self.execSql("COMMIT");

        for (files) |f| self.removeManagedFile(f);

        return self.loadBoardImpl(allocator, board_id);
    }

    fn assetIdsForSource(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8, source_id: []const u8) ![][]const u8 {
        const stmt = try self.prepareStmt("SELECT id FROM assets WHERE source_id = ?1 AND library_id = ?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source_id);
        try bindText(stmt, 2, board_id);

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |a| allocator.free(a);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try columnText(allocator, stmt, 0));
        }
        return try list.toOwnedSlice(allocator);
    }

    // -- assets -------------------------------------------------------------------

    /// `col` is the base column index of the first selected asset column
    /// (`id`) within `stmt`'s result row; callers that prepend extra
    /// leading columns (e.g. `listAssetsPageImpl` selects `rowid` first, for
    /// cursor pagination -- see storage's module-level pagination section)
    /// pass a nonzero offset so this parsing logic is shared rather than
    /// duplicated.
    fn assetFromRow(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) !Asset {
        const id = try columnText(allocator, stmt, col + 0);
        errdefer allocator.free(id);
        const board_id = try columnText(allocator, stmt, col + 1);
        errdefer allocator.free(board_id);
        const source_id = try columnTextOpt(allocator, stmt, col + 2);
        errdefer if (source_id) |v| allocator.free(v);
        const name = try columnText(allocator, stmt, col + 3);
        errdefer allocator.free(name);
        const original_path = try columnText(allocator, stmt, col + 4);
        errdefer allocator.free(original_path);
        const managed_path = try columnText(allocator, stmt, col + 5);
        errdefer allocator.free(managed_path);
        const mime = try columnText(allocator, stmt, col + 6);
        errdefer allocator.free(mime);
        const extension = try columnText(allocator, stmt, col + 7);
        errdefer allocator.free(extension);
        const size = columnInt64(stmt, col + 8);
        const hash = try columnText(allocator, stmt, col + 9);
        errdefer allocator.free(hash);
        const width = columnInt64Opt(stmt, col + 10);
        const height = columnInt64Opt(stmt, col + 11);
        const kind = try columnText(allocator, stmt, col + 12);
        errdefer allocator.free(kind);
        const preview_status = try columnText(allocator, stmt, col + 13);
        errdefer allocator.free(preview_status);
        const thumbnail_path = try columnTextOpt(allocator, stmt, col + 14);
        errdefer if (thumbnail_path) |v| allocator.free(v);
        const tags_raw = try columnText(allocator, stmt, col + 15);
        defer allocator.free(tags_raw);
        const tags = try parseStringArray(allocator, tags_raw);
        errdefer freeStringSlice(allocator, tags);
        const folders_raw = try columnText(allocator, stmt, col + 16);
        defer allocator.free(folders_raw);
        const folders = try parseStringArray(allocator, folders_raw);
        errdefer freeStringSlice(allocator, folders);
        const note = try columnTextOpt(allocator, stmt, col + 17);
        errdefer if (note) |v| allocator.free(v);
        const source_url = try columnTextOpt(allocator, stmt, col + 18);
        errdefer if (source_url) |v| allocator.free(v);
        const trashed_at = try columnTextOpt(allocator, stmt, col + 19);
        errdefer if (trashed_at) |v| allocator.free(v);
        const created_at = try columnText(allocator, stmt, col + 20);
        errdefer allocator.free(created_at);
        const metadata_json = try columnTextOpt(allocator, stmt, col + 21);
        errdefer if (metadata_json) |v| allocator.free(v);

        return Asset{
            .id = id,
            .boardId = board_id,
            .sourceId = source_id,
            .name = name,
            .originalPath = original_path,
            .managedPath = managed_path,
            .mime = mime,
            .extension = extension,
            .size = size,
            .hash = hash,
            .width = width,
            .height = height,
            .kind = kind,
            .previewStatus = preview_status,
            .thumbnailPath = thumbnail_path,
            .tags = tags,
            .folders = folders,
            .note = note,
            .sourceUrl = source_url,
            .trashedAt = trashed_at,
            .createdAt = created_at,
            .metadataJson = metadata_json,
        };
    }

    fn listAssetsImpl(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]Asset {
        const stmt = try self.prepareStmt(
            \\SELECT id, library_id, source_id, name, original_path, managed_path, mime, extension, size,
            \\       hash, width, height, kind, preview_status, thumbnail_path, tags_json, folders_json,
            \\       note, source_url, trashed_at, created_at, metadata_json
            \\FROM assets WHERE library_id = ?1 ORDER BY created_at DESC
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);

        var list: std.ArrayList(Asset) = .empty;
        errdefer {
            for (list.items) |a| a.deinit(allocator);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try assetFromRow(allocator, stmt, 0));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn listAssets(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]Asset {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.listAssetsImpl(allocator, board_id);
    }

    /// Ingest-facing: pre-insert dedupe lookup (mirrors the `SELECT id FROM assets
    /// WHERE library_id = ? AND hash = ?` that Rust's `insert_asset` runs before
    /// every insert). `insertAsset` already performs this same check internally, so
    /// callers don't strictly need to call this first - it's exposed for ingest code
    /// that wants to decide whether to bother hashing/copying/thumbnailing a
    /// candidate before calling `insertAsset` at all.
    pub fn findAssetByHash(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8, hash: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const stmt = try self.prepareStmt("SELECT id FROM assets WHERE library_id = ?1 AND hash = ?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);
        try bindText(stmt, 2, hash);
        if (!try stepRow(stmt)) return null;
        return try columnText(allocator, stmt, 0);
    }

    /// Ingest-facing: inserts one asset row, mirroring Rust's `insert_asset` exactly:
    ///   1. dedupe check on `(library_id, hash)` - if a row already exists, returns
    ///      `false` WITHOUT inserting (the `UNIQUE(library_id, hash)` constraint is
    ///      only a defense-in-depth backstop, never actually hit in the normal path).
    ///   2. otherwise inserts the row and creates its placement `board_nodes` row
    ///      (via `insertBoardNodeImpl`, the same grid-layout logic as
    ///      `create_node_for_asset`), then returns `true`.
    /// `asset.trashedAt` is ignored (a newly-inserted asset is never trashed, same as
    /// the Rust INSERT statement which doesn't even list that column).
    pub fn insertAsset(self: *Storage, allocator: std.mem.Allocator, asset: Asset) !bool {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        {
            const stmt = try self.prepareStmt("SELECT id FROM assets WHERE library_id = ?1 AND hash = ?2");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, asset.boardId);
            try bindText(stmt, 2, asset.hash);
            if (try stepRow(stmt)) return false;
        }

        const tags_json = try std.json.Stringify.valueAlloc(allocator, asset.tags, .{});
        defer allocator.free(tags_json);
        const folders_json = try std.json.Stringify.valueAlloc(allocator, asset.folders, .{});
        defer allocator.free(folders_json);

        {
            const stmt = try self.prepareStmt(
                \\INSERT INTO assets (
                \\  id, library_id, source_id, name, original_path, managed_path, mime, extension, size,
                \\  hash, width, height, kind, preview_status, thumbnail_path, tags_json, folders_json,
                \\  note, source_url, created_at, metadata_json
                \\) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)
            );
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, asset.id);
            try bindText(stmt, 2, asset.boardId);
            try bindTextOpt(stmt, 3, asset.sourceId);
            try bindText(stmt, 4, asset.name);
            try bindText(stmt, 5, asset.originalPath);
            try bindText(stmt, 6, asset.managedPath);
            try bindText(stmt, 7, asset.mime);
            try bindText(stmt, 8, asset.extension);
            try bindInt64(stmt, 9, asset.size);
            try bindText(stmt, 10, asset.hash);
            try bindInt64Opt(stmt, 11, asset.width);
            try bindInt64Opt(stmt, 12, asset.height);
            try bindText(stmt, 13, asset.kind);
            try bindText(stmt, 14, asset.previewStatus);
            try bindTextOpt(stmt, 15, asset.thumbnailPath);
            try bindText(stmt, 16, tags_json);
            try bindText(stmt, 17, folders_json);
            try bindTextOpt(stmt, 18, asset.note);
            try bindTextOpt(stmt, 19, asset.sourceUrl);
            try bindText(stmt, 20, asset.createdAt);
            try bindTextOpt(stmt, 21, asset.metadataJson);
            _ = try stepDone(stmt);
        }

        try self.insertBoardNodeImpl(asset.boardId, asset.id, asset.kind, asset.width, asset.height);
        return true;
    }

    fn assetCountImpl(self: *Storage, board_id: []const u8) !i64 {
        const stmt = try self.prepareStmt("SELECT COUNT(*) FROM assets WHERE library_id = ?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);
        _ = try stepRow(stmt);
        return columnInt64(stmt, 0);
    }

    /// Ingest-facing: places a new asset on the board's canvas, mirroring Rust's
    /// `create_node_for_asset` grid-layout math exactly (6-column wrap grid; width
    /// 224 for image/video else 204; height = width*ratio clamped to [132, 322];
    /// `z` = the board's asset count at call time — which, when called after the
    /// asset row is inserted (as `insertAsset` and Rust's `insert_asset` both do),
    /// INCLUDES the new asset, so the first asset lands at grid slot 1, not 0.
    /// That matches the Rust original exactly; `arrangeGroup` = `"import"`).
    /// `insertAsset` calls this automatically for the asset it just inserted - this
    /// is exposed separately for any ingest code path that wants to place a node
    /// without going through `insertAsset` again.
    pub fn insertBoardNode(
        self: *Storage,
        board_id: []const u8,
        asset_id: []const u8,
        kind: []const u8,
        width_hint: ?i64,
        height_hint: ?i64,
    ) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        try self.insertBoardNodeImpl(board_id, asset_id, kind, width_hint, height_hint);
    }

    fn insertBoardNodeImpl(
        self: *Storage,
        board_id: []const u8,
        asset_id: []const u8,
        kind: []const u8,
        width_hint: ?i64,
        height_hint: ?i64,
    ) !void {
        const count = try self.assetCountImpl(board_id);
        const column = @mod(count, 6);
        const row = @divTrunc(count, 6);
        const ratio: f64 = blk: {
            if (width_hint) |w| {
                if (height_hint) |h| {
                    if (w > 0) break :blk @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(w));
                }
            }
            break :blk 0.72;
        };
        const node_width: f64 = if (std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "video"))
            224.0
        else
            204.0;
        const node_height = std.math.clamp(node_width * ratio, 132.0, 322.0);

        const now = try self.nowRfc3339(self.allocator);
        defer self.allocator.free(now);
        const id = try self.newUuidV4(self.allocator);
        defer self.allocator.free(id);

        const stmt = try self.prepareStmt(
            \\INSERT INTO board_nodes (id, library_id, asset_id, x, y, width, height, z, locked, arrange_group, created_at, updated_at)
            \\VALUES (?1,?2,?3,?4,?5,?6,?7,?8,0,'import',?9,?9)
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, id);
        try bindText(stmt, 2, board_id);
        try bindText(stmt, 3, asset_id);
        try bindDouble(stmt, 4, @as(f64, @floatFromInt(column)) * 256.0);
        try bindDouble(stmt, 5, @as(f64, @floatFromInt(row)) * 238.0);
        try bindDouble(stmt, 6, node_width);
        try bindDouble(stmt, 7, node_height);
        try bindInt64(stmt, 8, count);
        try bindText(stmt, 9, now);
        _ = try stepDone(stmt);
    }

    pub fn trashAssets(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        asset_ids: []const []const u8,
    ) ![]u8 {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const trashed_at = try self.nowRfc3339(allocator);
        errdefer allocator.free(trashed_at);

        for (asset_ids) |asset_id| {
            const stmt = try self.prepareStmt("UPDATE assets SET trashed_at = ?1 WHERE id = ?2 AND library_id = ?3");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, trashed_at);
            try bindText(stmt, 2, asset_id);
            try bindText(stmt, 3, board_id);
            _ = try stepDone(stmt);
        }
        return trashed_at;
    }

    pub fn restoreAssets(self: *Storage, board_id: []const u8, asset_ids: []const []const u8) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        for (asset_ids) |asset_id| {
            const stmt = try self.prepareStmt("UPDATE assets SET trashed_at = NULL WHERE id = ?1 AND library_id = ?2");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, asset_id);
            try bindText(stmt, 2, board_id);
            _ = try stepDone(stmt);
        }
    }

    /// Adopts a client-rendered preview image (already written to disk; the caller
    /// must have proven `upload_path`'s containment BEFORE calling, since this moves
    /// the file) as this asset's thumbnail: the file is moved into the board's
    /// `thumbs/` dir as `<hash>.png`, the row flips to preview_status='ready', and
    /// the updated row is returned. Exists for kinds the engine cannot decode itself
    /// (3D models are rendered by the webview's WebGL context, not by Zig).
    pub fn setAssetThumbnail(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        asset_id: []const u8,
        upload_path: []const u8,
    ) !Asset {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        const io = self.ioHandle();

        const board_path = blk: {
            const stmt = try self.prepareStmt("SELECT path FROM libraries WHERE id = ?1");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, board_id);
            if (!try stepRow(stmt)) return error.NotFound;
            break :blk try columnText(allocator, stmt, 0);
        };
        defer allocator.free(board_path);

        const hash = blk: {
            const stmt = try self.prepareStmt("SELECT hash FROM assets WHERE id = ?1 AND library_id = ?2");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, asset_id);
            try bindText(stmt, 2, board_id);
            if (!try stepRow(stmt)) return error.NotFound;
            break :blk try columnText(allocator, stmt, 0);
        };
        defer allocator.free(hash);

        const thumbs_dir = try std.fs.path.join(allocator, &.{ board_path, "thumbs" });
        defer allocator.free(thumbs_dir);
        try std.Io.Dir.cwd().createDirPath(io, thumbs_dir);

        const filename = try std.fmt.allocPrint(allocator, "{s}.png", .{hash});
        defer allocator.free(filename);
        const thumb_path = try std.fs.path.join(allocator, &.{ thumbs_dir, filename });
        defer allocator.free(thumb_path);

        // Windows rename fails on an existing destination, and a stale thumb with
        // this content-addressed name can survive a purge+reimport cycle.
        std.Io.Dir.deleteFileAbsolute(io, thumb_path) catch {};
        try std.Io.Dir.renameAbsolute(upload_path, thumb_path, io);

        {
            const stmt = try self.prepareStmt(
                "UPDATE assets SET thumbnail_path = ?1, preview_status = 'ready' WHERE id = ?2 AND library_id = ?3",
            );
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, thumb_path);
            try bindText(stmt, 2, asset_id);
            try bindText(stmt, 3, board_id);
            _ = try stepDone(stmt);
        }

        const stmt = try self.prepareStmt(
            \\SELECT id, library_id, source_id, name, original_path, managed_path, mime, extension, size,
            \\       hash, width, height, kind, preview_status, thumbnail_path, tags_json, folders_json,
            \\       note, source_url, trashed_at, created_at, metadata_json
            \\FROM assets WHERE id = ?1 AND library_id = ?2
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, asset_id);
        try bindText(stmt, 2, board_id);
        if (!try stepRow(stmt)) return error.NotFound;
        return try assetFromRow(allocator, stmt, 0);
    }

    /// Deletes `board_nodes` + `assets` rows for `asset_ids` on the CURRENT (already
    /// open) transaction, returning the managed + thumbnail file paths to remove
    /// from disk after the caller commits. Shared by `purgeAssets` and `deleteSource`,
    /// mirroring Rust's `purge_asset_rows`.
    fn purgeAssetRowsImpl(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        asset_ids: []const []const u8,
    ) ![][]u8 {
        var files: std.ArrayList([]u8) = .empty;
        errdefer {
            for (files.items) |f| allocator.free(f);
            files.deinit(allocator);
        }

        for (asset_ids) |asset_id| {
            {
                const stmt = try self.prepareStmt(
                    "SELECT managed_path, thumbnail_path FROM assets WHERE id = ?1 AND library_id = ?2",
                );
                defer _ = c.sqlite3_finalize(stmt);
                try bindText(stmt, 1, asset_id);
                try bindText(stmt, 2, board_id);
                if (try stepRow(stmt)) {
                    const managed = try columnText(allocator, stmt, 0);
                    try files.append(allocator, managed);
                    if (try columnTextOpt(allocator, stmt, 1)) |thumb| {
                        try files.append(allocator, thumb);
                    }
                }
            }
            // board_nodes only cascades when foreign_keys is ON for the connection
            // doing the delete; this Storage always has it on (see runInit), but we
            // still delete explicitly here to mirror the Rust source 1:1 and to stay
            // correct regardless of that pragma.
            {
                const stmt = try self.prepareStmt("DELETE FROM board_nodes WHERE asset_id = ?1 AND library_id = ?2");
                defer _ = c.sqlite3_finalize(stmt);
                try bindText(stmt, 1, asset_id);
                try bindText(stmt, 2, board_id);
                _ = try stepDone(stmt);
            }
            {
                const stmt = try self.prepareStmt("DELETE FROM assets WHERE id = ?1 AND library_id = ?2");
                defer _ = c.sqlite3_finalize(stmt);
                try bindText(stmt, 1, asset_id);
                try bindText(stmt, 2, board_id);
                _ = try stepDone(stmt);
            }
        }

        return try files.toOwnedSlice(allocator);
    }

    /// Irreversible hard delete. Row deletions (`board_nodes`, `assets`) plus the
    /// `sources.item_count` recompute happen in one transaction; only after it
    /// commits are the collected managed/thumbnail files removed from disk (a failed
    /// commit leaves the filesystem untouched; a failed file removal after commit is
    /// silently ignored, same as Rust).
    pub fn purgeAssets(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        asset_ids: []const []const u8,
    ) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        try self.execSql("BEGIN");
        errdefer self.execSql("ROLLBACK") catch {};

        const files = try self.purgeAssetRowsImpl(allocator, board_id, asset_ids);
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }

        try self.repairSourceCountsImpl();
        try self.execSql("COMMIT");

        for (files) |f| self.removeManagedFile(f);
    }

    // -- frames -------------------------------------------------------------------

    fn frameFromRow(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Frame {
        const id = try columnText(allocator, stmt, 0);
        errdefer allocator.free(id);
        const board_id = try columnText(allocator, stmt, 1);
        errdefer allocator.free(board_id);
        const x = columnDouble(stmt, 2);
        const y = columnDouble(stmt, 3);
        const width = columnDouble(stmt, 4);
        const height = columnDouble(stmt, 5);
        const label = try columnText(allocator, stmt, 6);
        errdefer allocator.free(label);
        const created_at = try columnText(allocator, stmt, 7);
        errdefer allocator.free(created_at);
        const updated_at = try columnText(allocator, stmt, 8);
        errdefer allocator.free(updated_at);
        return Frame{
            .id = id,
            .boardId = board_id,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .label = label,
            .createdAt = created_at,
            .updatedAt = updated_at,
        };
    }

    fn listFramesImpl(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]Frame {
        const stmt = try self.prepareStmt(
            "SELECT id, library_id, x, y, width, height, label, created_at, updated_at FROM frames WHERE library_id = ?1 ORDER BY created_at ASC",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);

        var list: std.ArrayList(Frame) = .empty;
        errdefer {
            for (list.items) |f| f.deinit(allocator);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try frameFromRow(allocator, stmt));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn listFrames(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]Frame {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.listFramesImpl(allocator, board_id);
    }

    pub fn createFrame(
        self: *Storage,
        allocator: std.mem.Allocator,
        board_id: []const u8,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        label: []const u8,
    ) !Frame {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const now = try self.nowRfc3339(allocator);
        errdefer allocator.free(now);
        const id = try self.newUuidV4(allocator);
        errdefer allocator.free(id);
        const board_id_copy = try allocator.dupe(u8, board_id);
        errdefer allocator.free(board_id_copy);
        const label_copy = try allocator.dupe(u8, label);
        errdefer allocator.free(label_copy);
        const updated_at = try allocator.dupe(u8, now);
        errdefer allocator.free(updated_at);

        const stmt = try self.prepareStmt(
            "INSERT INTO frames (id, library_id, x, y, width, height, label, created_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?8)",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, id);
        try bindText(stmt, 2, board_id);
        try bindDouble(stmt, 3, x);
        try bindDouble(stmt, 4, y);
        try bindDouble(stmt, 5, width);
        try bindDouble(stmt, 6, height);
        try bindText(stmt, 7, label);
        try bindText(stmt, 8, now);
        _ = try stepDone(stmt);

        return Frame{
            .id = id,
            .boardId = board_id_copy,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .label = label_copy,
            .createdAt = now,
            .updatedAt = updated_at,
        };
    }

    pub fn updateFrames(self: *Storage, board_id: []const u8, frames: []const FrameUpdate) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const now = try self.nowRfc3339(self.allocator);
        defer self.allocator.free(now);

        for (frames) |frame| {
            const stmt = try self.prepareStmt(
                "UPDATE frames SET x=?1,y=?2,width=?3,height=?4,label=?5,updated_at=?6 WHERE id=?7 AND library_id=?8",
            );
            defer _ = c.sqlite3_finalize(stmt);
            try bindDouble(stmt, 1, frame.x);
            try bindDouble(stmt, 2, frame.y);
            try bindDouble(stmt, 3, frame.width);
            try bindDouble(stmt, 4, frame.height);
            try bindText(stmt, 5, frame.label);
            try bindText(stmt, 6, now);
            try bindText(stmt, 7, frame.id);
            try bindText(stmt, 8, board_id);
            _ = try stepDone(stmt);
        }
    }

    pub fn deleteFrame(self: *Storage, board_id: []const u8, frame_id: []const u8) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const stmt = try self.prepareStmt("DELETE FROM frames WHERE id = ?1 AND library_id = ?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, frame_id);
        try bindText(stmt, 2, board_id);
        _ = try stepDone(stmt);
    }

    // -- board nodes ----------------------------------------------------------------

    fn nodeFromRow(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !BoardNode {
        const id = try columnText(allocator, stmt, 0);
        errdefer allocator.free(id);
        const board_id = try columnText(allocator, stmt, 1);
        errdefer allocator.free(board_id);
        const asset_id = try columnText(allocator, stmt, 2);
        errdefer allocator.free(asset_id);
        const x = columnDouble(stmt, 3);
        const y = columnDouble(stmt, 4);
        const width = columnDouble(stmt, 5);
        const height = columnDouble(stmt, 6);
        const z = columnInt64(stmt, 7);
        const locked = columnBool(stmt, 8);
        const arrange_group = try columnTextOpt(allocator, stmt, 9);
        errdefer if (arrange_group) |v| allocator.free(v);
        return BoardNode{
            .id = id,
            .boardId = board_id,
            .assetId = asset_id,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .z = z,
            .locked = locked,
            .arrangeGroup = arrange_group,
        };
    }

    fn listNodesImpl(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]BoardNode {
        const stmt = try self.prepareStmt(
            "SELECT id, library_id, asset_id, x, y, width, height, z, locked, arrange_group FROM board_nodes WHERE library_id = ?1 ORDER BY z ASC",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, board_id);

        var list: std.ArrayList(BoardNode) = .empty;
        errdefer {
            for (list.items) |n| n.deinit(allocator);
            list.deinit(allocator);
        }
        while (try stepRow(stmt)) {
            try list.append(allocator, try nodeFromRow(allocator, stmt));
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn listNodes(self: *Storage, allocator: std.mem.Allocator, board_id: []const u8) ![]BoardNode {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());
        return self.listNodesImpl(allocator, board_id);
    }

    pub fn updateNodes(self: *Storage, board_id: []const u8, nodes: []const NodeUpdate) !void {
        self.mutex.lockUncancelable(self.ioHandle());
        defer self.mutex.unlock(self.ioHandle());

        const now = try self.nowRfc3339(self.allocator);
        defer self.allocator.free(now);

        for (nodes) |node| {
            const stmt = try self.prepareStmt(
                \\UPDATE board_nodes
                \\SET x = ?1, y = ?2, width = ?3, height = ?4, z = ?5, locked = ?6, arrange_group = ?7, updated_at = ?8
                \\WHERE id = ?9 AND library_id = ?10
            );
            defer _ = c.sqlite3_finalize(stmt);
            try bindDouble(stmt, 1, node.x);
            try bindDouble(stmt, 2, node.y);
            try bindDouble(stmt, 3, node.width);
            try bindDouble(stmt, 4, node.height);
            try bindInt64(stmt, 5, node.z);
            try bindBool(stmt, 6, node.locked);
            try bindTextOpt(stmt, 7, node.arrangeGroup);
            try bindText(stmt, 8, now);
            try bindText(stmt, 9, node.id);
            try bindText(stmt, 10, board_id);
            _ = try stepDone(stmt);
        }
    }

    // -- filesystem helpers -----------------------------------------------------

    /// Returns the path relative to `self.root` (no leading separator), or `null`
    /// if `path` is not actually under the storage root. Component-wise (checks for
    /// a separator right after the root prefix), not a bare string-prefix check, so
    /// e.g. root=`/a/b` does not falsely match `/a/bc/file`.
    fn relativeToRoot(self: *const Storage, path: []const u8) ?[]const u8 {
        if (path.len < self.root.len) return null;
        if (!std.mem.eql(u8, path[0..self.root.len], self.root)) return null;
        if (path.len == self.root.len) return path[self.root.len..];
        const sep = path[self.root.len];
        if (sep != '/' and sep != '\\') return null;
        return path[self.root.len + 1 ..];
    }

    /// Mirrors Rust's `remove_managed_file`: silently does nothing if `path` isn't
    /// under `self.root` (the safety guard that keeps a purge/delete from ever
    /// touching a file outside Maat's own storage), and ignores OS-level delete
    /// failures (already-gone file, permissions, etc.) the same way `let _ =
    /// fs::remove_file(...)` does.
    fn removeManagedFile(self: *Storage, path: []const u8) void {
        const rel = self.relativeToRoot(path) orelse return;
        if (rel.len == 0) return;
        self.root_dir.deleteFile(self.ioHandle(), rel) catch {};
    }

    // -- small sqlite plumbing ----------------------------------------------------

    fn execSql(self: *Storage, sql: [:0]const u8) !void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, &errmsg);
        if (errmsg != null) c.sqlite3_free(errmsg);
        if (rc != c.SQLITE_OK) return error.SqliteError;
    }

    /// Runs a `DELETE`/`UPDATE` style statement with exactly one text bind param at
    /// index 1. Used by `deleteBoard`'s explicit child-row cleanup.
    fn execOneText(self: *Storage, sql: [:0]const u8, param: []const u8) !void {
        const stmt = try self.prepareStmt(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, param);
        _ = try stepDone(stmt);
    }

    fn prepareStmt(self: *Storage, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return error.SqliteError;
        return stmt.?;
    }

    fn nowRfc3339(self: *Storage, allocator: std.mem.Allocator) ![]u8 {
        const ts = std.Io.Clock.real.now(self.ioHandle());
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

    fn newUuidV4(self: *Storage, allocator: std.mem.Allocator) ![]u8 {
        var bytes: [16]u8 = undefined;
        self.ioHandle().random(&bytes);
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
};

fn containsString(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn parseStringArray(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            if (item == .string) {
                try list.append(allocator, try allocator.dupe(u8, item.string));
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// sqlite bind/column helpers
// ---------------------------------------------------------------------------

/// Equivalent of the `SQLITE_TRANSIENT` macro (`(sqlite3_destructor_type)-1`), which
/// `@cImport`/translate-c cannot represent directly since it's a function-pointer
/// cast of an integer literal. Tells sqlite to make its own private copy of the
/// bound bytes immediately, so we can free our buffer right after binding.
///
/// Typed `?*anyopaque` (align 1), NOT the destructor's real function-pointer
/// type: Zig refuses to materialize the all-ones sentinel address as a
/// function pointer on targets whose function pointers carry an alignment
/// requirement ("pointer type ... requires aligned address" on
/// aarch64-macos; x86_64-windows never tripped it). The extern
/// redeclaration of `sqlite3_bind_text` below exists for the same reason:
/// it takes the destructor as `?*anyopaque`, which is ABI-identical to the
/// C signature's `void(*)(void*)` (both are one pointer-sized argument) and
/// resolves by symbol name against the same vendored sqlite3.c the `c`
/// import compiles.
const SQLITE_TRANSIENT: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
extern fn sqlite3_bind_text(stmt: ?*c.sqlite3_stmt, idx: c_int, text: [*c]const u8, n: c_int, destructor: ?*anyopaque) c_int;

fn stepRow(stmt: *c.sqlite3_stmt) !bool {
    const rc = c.sqlite3_step(stmt);
    return switch (rc) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.SqliteError,
    };
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.SqliteError;
}

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) !void {
    // The local extern above, not c.sqlite3_bind_text -- see
    // SQLITE_TRANSIENT's doc comment.
    const rc = sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), SQLITE_TRANSIENT);
    if (rc != c.SQLITE_OK) return error.SqliteError;
}

fn bindTextOpt(stmt: *c.sqlite3_stmt, idx: c_int, text: ?[]const u8) !void {
    if (text) |t| return bindText(stmt, idx, t);
    const rc = c.sqlite3_bind_null(stmt, idx);
    if (rc != c.SQLITE_OK) return error.SqliteError;
}

fn bindInt64(stmt: *c.sqlite3_stmt, idx: c_int, value: i64) !void {
    const rc = c.sqlite3_bind_int64(stmt, idx, value);
    if (rc != c.SQLITE_OK) return error.SqliteError;
}

fn bindInt64Opt(stmt: *c.sqlite3_stmt, idx: c_int, value: ?i64) !void {
    if (value) |v| return bindInt64(stmt, idx, v);
    const rc = c.sqlite3_bind_null(stmt, idx);
    if (rc != c.SQLITE_OK) return error.SqliteError;
}

fn bindDouble(stmt: *c.sqlite3_stmt, idx: c_int, value: f64) !void {
    const rc = c.sqlite3_bind_double(stmt, idx, value);
    if (rc != c.SQLITE_OK) return error.SqliteError;
}

fn bindBool(stmt: *c.sqlite3_stmt, idx: c_int, value: bool) !void {
    return bindInt64(stmt, idx, if (value) 1 else 0);
}

fn columnText(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, idx: c_int) ![]u8 {
    const ptr = c.sqlite3_column_text(stmt, idx);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    if (ptr == null) return allocator.dupe(u8, "");
    const slice = ptr[0..len];
    return allocator.dupe(u8, slice);
}

fn columnTextOpt(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, idx: c_int) !?[]u8 {
    if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) return null;
    return try columnText(allocator, stmt, idx);
}

fn columnInt64(stmt: *c.sqlite3_stmt, idx: c_int) i64 {
    return c.sqlite3_column_int64(stmt, idx);
}

fn columnInt64Opt(stmt: *c.sqlite3_stmt, idx: c_int) ?i64 {
    if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) return null;
    return columnInt64(stmt, idx);
}

fn columnDouble(stmt: *c.sqlite3_stmt, idx: c_int) f64 {
    return c.sqlite3_column_double(stmt, idx);
}

fn columnBool(stmt: *c.sqlite3_stmt, idx: c_int) bool {
    return columnInt64(stmt, idx) == 1;
}

test {
    _ = @import("storage_test.zig");
}
