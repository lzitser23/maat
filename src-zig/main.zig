const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const server_mod = @import("server.zig");
const embedded_frontend_server_mod = @import("embedded_frontend_server");
const storage_mod = @import("storage.zig");
const ingest_mod = @import("ingest.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const bridge = native_sdk.bridge;
const platform = native_sdk.platform;

// Bridge origins allowed to invoke our commands: the packaged app
// ("zero://app"), the automation harness ("zero://inline", see
// MIGRATION-BRIEF.md section 9), and the two dev-server ports in play
// during this migration (the app's normal configured Vite port, 1421,
// and the isolated port used for shell-acceptance testing, 1499).
// This same array also backs the webview navigation allowlist (see the
// `.security` block handed to runWithOptions below), and both policies are
// comptime-resolved -- which is why the embedded frontend server's origins
// are appended here from its static port set (embedded_frontend_server.zig
// exports them comptime-formatted) rather than discovered at runtime: an
// OS-assigned port could never be admitted to either policy. Mirror any
// port-set change into app.zon's `.security.navigation.allowed_origins`.
const app_origins = [_][]const u8{
    "zero://app",
    "zero://inline",
    "http://127.0.0.1:1421",
    "http://127.0.0.1:1499",
} ++ embedded_frontend_server_mod.origins;

// 18 domain commands (COMMAND-CONTRACT.md's original 14, ported 1:1 with
// the deliberate delete_board cascade fix from INTERFACE.md item 1, plus
// `load_board_page` and `list_boards_state` -- issue #4's bounded-response
// board pagination, plus `set_asset_thumbnail` -- webview-rendered previews
// for kinds the engine can't decode, e.g. 3D models, plus `set_asset_prompt`
// -- the user-editable AI-generation prompt field) onto the Storage/ingest
// layers, plus 13 shell commands (window chrome, dialogs, the local file
// server, the import job registry, and `reveal_path`, a pure OS side effect
// with no storage involvement).
const domain_handler_count = 18;
const shell_handler_count = 14;
const handler_count = domain_handler_count + shell_handler_count;

// ---- Import job registry -------------------------------------------------
//
// import_paths_start / import_urls_start / import_clipboard_start spawn a
// worker thread and return a jobId immediately; import_job_status polls
// (every 150ms from the frontend) and must return instantly. Each worker
// runs the real (blocking) ingest pipeline against the app's Storage (which
// is thread-safe -- every public method takes its own mutex), then stashes
// the serialized ImportReport JSON (or an error message) on the JobSlot for
// import_job_status to hand back on the next poll. The worker only ever
// touches JobSlot/JobRegistry state under the registry mutex -- it never
// touches the bridge/runtime machinery, so there is no cross-thread
// AsyncResponder question to resolve (see MIGRATION-BRIEF.md section 3's
// open gap on that -- this design sidesteps it entirely).
//
// Shutdown (issue #3): worker threads are joinable, not detached. App.stop
// calls JobRegistry.drain before closing Storage, which stops new jobs from
// starting and blocks until every in-flight worker has actually finished --
// so a window close mid-import can never leave a worker calling into a
// closed/closing Storage. See JobRegistry.drain's doc comment.

const job_id_len = 32;
const max_jobs = 32;

/// Zig 0.16 dropped the classic blocking `std.Thread.Mutex` in favor of
/// `Io`-based synchronization primitives; a plain worker thread here
/// has no `Io` value to hand one, and the critical sections below are
/// a handful of array writes, so a tiny spinlock is simpler and
/// sufficient (job registry is never contended for more than a few
/// instructions).
const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

/// A finished job's outcome: either the serialized `ImportReport` JSON
/// object (heap-owned via the app's allocator -- freed by
/// `import_job_status` once it has copied the bytes into its response), or
/// a short, statically-owned error message (`@errorName(...)` or a string
/// literal -- never freed).
const JobResult = union(enum) {
    report: []u8,
    err: []const u8,
};

const JobSlot = struct {
    in_use: bool = false,
    done: bool = false,
    id: [job_id_len]u8 = undefined,
    result: ?JobResult = null,
    /// Set by `JobRegistry.attachThread` right after the worker is
    /// spawned (still on the single UI/bridge-dispatch thread -- see
    /// `App.stop`'s doc comment). `drain` joins this so no worker can
    /// still be inside a `Storage` call when shutdown closes it.
    thread: ?std.Thread = null,
};

/// Owns the import job slots AND their shutdown lifecycle. `reserve`
/// starts a job; `attachThread` records its worker thread once spawned;
/// `drain` (called once, from `App.stop`) is the fix for issue #3: it
/// stops any further jobs from starting, blocks until every in-flight
/// worker has actually finished (so none can touch `Storage` after the
/// caller closes it right after `drain` returns), and frees any
/// retained-but-unpolled job result so shutdown never leaks one.
///
/// Deliberately independent of `App`/bridge/runtime -- nothing here
/// touches them -- so the drain-during-import race can be exercised
/// directly in a test (see the regression tests near the bottom of this
/// file) without booting the full native_sdk runtime.
const JobRegistry = struct {
    mutex: SpinLock = .{},
    slots: [max_jobs]JobSlot = [_]JobSlot{.{}} ** max_jobs,
    /// Guarded by `mutex`. Once true, `reserve` always returns null --
    /// set by `drain` and never cleared (a registry is drained at most
    /// once, at process shutdown).
    closing: bool = false,

    fn reserve(self: *JobRegistry) ?*JobSlot {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return null;
        for (&self.slots) |*slot| {
            if (!slot.in_use) {
                slot.in_use = true;
                slot.done = false;
                slot.result = null;
                slot.thread = null;
                // Generated under the lock (F5): `import_job_status` reads
                // `slot.id` from other threads, so writing it after unlock
                // would be an unsynchronized data race with those readers.
                generateJobId(&slot.id);
                return slot;
            }
        }
        return null;
    }

    fn attachThread(self: *JobRegistry, slot: *JobSlot, thread: std.Thread) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        slot.thread = thread;
    }

    /// Called by `import_job_status` exactly once per job, right after it
    /// has read a done slot's `result` for the first (and only) time --
    /// the point at which the slot is about to become reusable. Extracts
    /// the worker's thread handle and joins it (reclaiming the OS thread
    /// resources, matching what `drain` already does at shutdown) BEFORE
    /// marking the slot reusable, so `reserve` can never hand out a slot
    /// whose previous worker thread was never joined.
    ///
    /// Joining happens outside the lock, same reasoning as `drain`: a
    /// worker finishing calls `finishJobReport`/`finishJobError`, which
    /// takes this same lock, so joining while holding it would deadlock
    /// (moot here since the worker in question has already set `done`,
    /// but keeping the same discipline as `drain` avoids relying on that).
    /// `in_use` stays `true` for the whole join, so `reserve` cannot hand
    /// this slot to a new job until the old worker has fully exited.
    fn recycle(self: *JobRegistry, slot: *JobSlot) void {
        self.mutex.lock();
        const thread = slot.thread;
        slot.thread = null;
        self.mutex.unlock();

        if (thread) |t| t.join();

        self.mutex.lock();
        slot.in_use = false;
        self.mutex.unlock();
    }

    /// Shutdown drain (issue #3). Marks the registry closing so
    /// `reserve` rejects anything further, joins every slot's worker
    /// thread (outside the lock -- a worker finishing calls
    /// `finishJobReport`/`finishJobError`, which takes the same lock, so
    /// joining while holding it would deadlock), then frees any result a
    /// finished-but-never-polled job left behind and resets every slot.
    ///
    /// No timeout: a worker mid-`Storage` call is exactly the case this
    /// exists to protect, so `drain` always waits for real completion
    /// rather than abandoning it.
    fn drain(self: *JobRegistry, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        self.closing = true;
        self.mutex.unlock();

        for (&self.slots) |*slot| {
            self.mutex.lock();
            const maybe_thread = if (slot.in_use) slot.thread else null;
            self.mutex.unlock();
            if (maybe_thread) |thread| thread.join();
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.slots) |*slot| {
            if (slot.result) |result| {
                switch (result) {
                    // `.err` is always a static string (see `JobResult`'s
                    // doc comment) -- never freed, same as
                    // `import_job_status`'s normal poll path.
                    .report => |r| allocator.free(r),
                    .err => {},
                }
                slot.result = null;
            }
            slot.in_use = false;
            slot.thread = null;
        }
    }
};

// A plain incrementing counter is all uniqueness the job registry
// needs (ids are only ever looked up within one running process's
// lifetime, across at most `max_jobs` concurrently in-flight jobs).
var next_job_id = std.atomic.Value(u64).init(1);

fn generateJobId(out: *[job_id_len]u8) void {
    const n = next_job_id.fetchAdd(1, .monotonic);
    var raw: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u64, raw[0..8], n, .little);
    out.* = std.fmt.bytesToHex(raw, .lower);
}

fn finishJobReport(jobs: *JobRegistry, slot: *JobSlot, report_json: []u8) void {
    jobs.mutex.lock();
    slot.result = .{ .report = report_json };
    slot.done = true;
    jobs.mutex.unlock();
}

fn finishJobError(jobs: *JobRegistry, slot: *JobSlot, message: []const u8) void {
    jobs.mutex.lock();
    slot.result = .{ .err = message };
    slot.done = true;
    jobs.mutex.unlock();
}

// ---------------------------------------------------------------------------

const App = struct {
    env_map: *std.process.Environ.Map,
    allocator: std.mem.Allocator,
    storage_root: []const u8 = "",
    /// Opened once at boot (`start`, after the storage root directory
    /// exists) and closed on shutdown (`stop`). Owned by App; every domain
    /// command handler and every import job worker reaches it through
    /// `storagePtr()`. `Storage`'s own methods are mutex-guarded, so it's
    /// safe to share this single instance between the UI thread and any
    /// number of import worker threads.
    storage: ?storage_mod.Storage = null,
    runtime: ?*native_sdk.Runtime = null,
    file_server: ?*server_mod.Server = null,
    /// Windows-only (null on every other platform, and null in the one
    /// degraded Windows case `start` tolerates -- see there): serves the
    /// dist/ build embedded in the exe, so the shipped binary needs no
    /// frontend files beside it. See embedded_frontend_server.zig.
    embedded_frontend_server: ?*embedded_frontend_server_mod.Server = null,
    /// Backing storage for the URL slice `source()` hands the runtime --
    /// WebViewSource.url() just wraps the slice (the runtime copies it
    /// later, in flow.zig's copyLoadedSource), so formatting into a stack
    /// local inside source() would return a dangling pointer. This App
    /// instance is process-lifetime, so a field is always safe.
    embedded_frontend_url_buf: [64]u8 = undefined,
    jobs: JobRegistry = .{},
    handlers: [handler_count]bridge.Handler = undefined,
    policies: [handler_count]bridge.CommandPolicy = undefined,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "maat-native",
            .source = native_sdk.frontend.productionSource(.{ .dist = "dist" }),
            .source_fn = source,
            .start_fn = start,
            .stop_fn = stop,
        };
    }

    /// The managed dev-server URL, when `native dev` is driving this run.
    /// Same env var and same empty-means-unset rule as the SDK's own
    /// frontend.sourceFromEnv (frontend.Config.dev_url_env's default).
    fn devFrontendUrl(self: *@This()) ?[]const u8 {
        const url = self.env_map.get("NATIVE_SDK_FRONTEND_URL") orelse return null;
        return if (url.len > 0) url else null;
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        // Dev mode first, on every platform: `native dev` exports the Vite
        // URL and hot-reload etc. all hang off navigating there -- exactly
        // what frontend.sourceFromEnv did for every run before the
        // embedded-frontend path below existed.
        if (self.devFrontendUrl()) |url| return native_sdk.WebViewSource.url(url);
        // Windows production: the exe's own embedded dist/, served by the
        // loopback server `start` brought up (the runtime always calls the
        // start hook before it loads the startup window's webview -- see
        // flow.zig's .app_start handling), so the shipped binary needs no
        // dist/ directory beside it.
        if (builtin.os.tag == .windows) {
            const frontend_server = self.embedded_frontend_server orelse return error.EmbeddedFrontendUnavailable;
            const url = std.fmt.bufPrint(&self.embedded_frontend_url_buf, "http://127.0.0.1:{d}/", .{frontend_server.port}) catch unreachable;
            return native_sdk.WebViewSource.url(url);
        }
        // macOS (and anything else): unchanged -- the SDK's on-disk asset
        // origin, resolved against the .app bundle's Resources/dist by the
        // packaged app (see scripts/package-fixup.mjs's macOS notes).
        return native_sdk.frontend.productionSource(.{
            .dist = "dist",
            .entry = "index.html",
        });
    }

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.runtime = runtime;
        // Must come up before `source` runs (see the ordering note there).
        // Failure to bind any port of the static set is fatal only when
        // the webview will actually be sourced from this server: a dev run
        // navigates to the Vite URL instead, so hitting the concurrent-
        // instance ceiling during development must not take `native dev`
        // down with it.
        if (builtin.os.tag == .windows) {
            self.embedded_frontend_server = embedded_frontend_server_mod.Server.start() catch |err| blk: {
                if (self.devFrontendUrl() == null) return err;
                break :blk null;
            };
        }
        self.file_server = try server_mod.Server.start(self.allocator, self.storage_root);
        self.storage = try storage_mod.Storage.open(self.allocator, self.storage_root);
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        // Issue #3: drain the import job registry BEFORE closing storage.
        // `dispatch()` and this stop hook both run on the single
        // UI/bridge thread (see `runtime/flow.zig`'s `run()`: the app's
        // stop hook is delivered synchronously while handling the
        // `.app_shutdown` platform event), so no new import can start
        // once this call begins -- but any import already running is on
        // its own detached-turned-joinable worker thread and may still be
        // deep inside a `Storage` call. `drain` blocks until every such
        // worker has actually finished, so `storage.close()` below can
        // never race a worker's sqlite/root_dir access.
        self.jobs.drain(self.allocator);
        if (self.storage) |*storage| {
            storage.close();
            self.storage = null;
        }
    }

    fn storagePtr(self: *@This()) !*storage_mod.Storage {
        if (self.storage) |*s| return s;
        return error.StorageUnavailable;
    }

    fn bridge_(self: *@This()) native_sdk.BridgeDispatcher {
        var i: usize = 0;
        self.handlers[i] = .{ .name = "get_app_state", .context = self, .invoke_fn = getAppState };
        i += 1;
        self.handlers[i] = .{ .name = "create_board", .context = self, .invoke_fn = createBoard };
        i += 1;
        self.handlers[i] = .{ .name = "rename_board", .context = self, .invoke_fn = renameBoard };
        i += 1;
        self.handlers[i] = .{ .name = "load_board", .context = self, .invoke_fn = loadBoard };
        i += 1;
        self.handlers[i] = .{ .name = "load_board_page", .context = self, .invoke_fn = loadBoardPage };
        i += 1;
        self.handlers[i] = .{ .name = "list_boards_state", .context = self, .invoke_fn = listBoardsState };
        i += 1;
        self.handlers[i] = .{ .name = "delete_board", .context = self, .invoke_fn = deleteBoard };
        i += 1;
        self.handlers[i] = .{ .name = "update_nodes", .context = self, .invoke_fn = updateNodes };
        i += 1;
        self.handlers[i] = .{ .name = "trash_assets", .context = self, .invoke_fn = trashAssets };
        i += 1;
        self.handlers[i] = .{ .name = "restore_assets", .context = self, .invoke_fn = restoreAssets };
        i += 1;
        self.handlers[i] = .{ .name = "purge_assets", .context = self, .invoke_fn = purgeAssets };
        i += 1;
        self.handlers[i] = .{ .name = "delete_source", .context = self, .invoke_fn = deleteSource };
        i += 1;
        self.handlers[i] = .{ .name = "create_frame", .context = self, .invoke_fn = createFrame };
        i += 1;
        self.handlers[i] = .{ .name = "update_frames", .context = self, .invoke_fn = updateFrames };
        i += 1;
        self.handlers[i] = .{ .name = "delete_frame", .context = self, .invoke_fn = deleteFrame };
        i += 1;
        self.handlers[i] = .{ .name = "update_board_drawing", .context = self, .invoke_fn = updateBoardDrawing };
        i += 1;
        self.handlers[i] = .{ .name = "set_asset_thumbnail", .context = self, .invoke_fn = setAssetThumbnail };
        i += 1;
        self.handlers[i] = .{ .name = "set_asset_prompt", .context = self, .invoke_fn = setAssetPrompt };
        i += 1;
        self.handlers[i] = .{ .name = "reveal_path", .context = self, .invoke_fn = revealPath };
        i += 1;
        self.handlers[i] = .{ .name = "window_minimize", .context = self, .invoke_fn = windowMinimize };
        i += 1;
        self.handlers[i] = .{ .name = "window_toggle_maximize", .context = self, .invoke_fn = windowToggleMaximize };
        i += 1;
        self.handlers[i] = .{ .name = "window_close", .context = self, .invoke_fn = windowClose };
        i += 1;
        self.handlers[i] = .{ .name = "window_start_drag", .context = self, .invoke_fn = windowStartDrag };
        i += 1;
        self.handlers[i] = .{ .name = "window_start_resize", .context = self, .invoke_fn = windowStartResize };
        i += 1;
        self.handlers[i] = .{ .name = "dialog_open_files", .context = self, .invoke_fn = dialogOpenFiles };
        i += 1;
        self.handlers[i] = .{ .name = "dialog_open_folder", .context = self, .invoke_fn = dialogOpenFolder };
        i += 1;
        self.handlers[i] = .{ .name = "server_info", .context = self, .invoke_fn = serverInfo };
        i += 1;
        self.handlers[i] = .{ .name = "echo", .context = self, .invoke_fn = echo };
        i += 1;
        self.handlers[i] = .{ .name = "import_paths_start", .context = self, .invoke_fn = importPathsStart };
        i += 1;
        self.handlers[i] = .{ .name = "import_urls_start", .context = self, .invoke_fn = importUrlsStart };
        i += 1;
        self.handlers[i] = .{ .name = "import_clipboard_start", .context = self, .invoke_fn = importClipboardStart };
        i += 1;
        self.handlers[i] = .{ .name = "import_job_status", .context = self, .invoke_fn = importJobStatus };
        i += 1;
        std.debug.assert(i == handler_count);

        for (self.handlers, 0..) |handler, idx| {
            self.policies[idx] = .{ .name = handler.name, .origins = &app_origins };
        }

        return .{
            .policy = .{ .enabled = true, .commands = &self.policies },
            .registry = .{ .handlers = &self.handlers },
        };
    }
};

// ---- Domain command helpers -------------------------------------------------

/// Maps a storage `DomainError` (storage.zig) to the exact bridge error
/// whose `@errorName` is the human-readable message COMMAND-CONTRACT.md
/// specifies verbatim (e.g. "Cannot delete the last board"). The bridge
/// dispatcher (`@native-sdk/cli`'s `bridge/root.zig`) always surfaces a
/// handler's returned error via `@errorName(err)` as the JSON `error.message`
/// field, so synthesizing an error value whose *name* IS the desired
/// message (via `@field(anyerror, ...)`, same trick the stub handlers used)
/// is how a human-readable message reaches the frontend without any
/// separate error-message channel. Every branch's string literal is
/// comptime-known, so `@field` is valid here.
fn mapStorageError(err: anyerror) anyerror {
    return switch (err) {
        error.CannotDeleteLastBoard => @field(anyerror, "Cannot delete the last board"),
        error.NotFound => @field(anyerror, "Board not found"),
        error.NoBoardAvailable => @field(anyerror, "No board available"),
        error.SqliteError => @field(anyerror, "Database error"),
        else => err,
    };
}

fn copyJson(output: []u8, json: []const u8) anyerror![]const u8 {
    if (json.len > output.len) return error.PayloadTooLarge;
    @memcpy(output[0..json.len], json);
    return output[0..json.len];
}

/// Native SDK caps command results at a fixed buffer. Keep the normal fast
/// path for responses that fit; spill larger lossless JSON to the local asset
/// server and return a small marker that bridge.ts transparently resolves.
fn copyJsonOrSpillAtRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    output: []u8,
    json: []const u8,
) anyerror![]const u8 {
    if (json.len <= output.len) return copyJson(output, json);

    const spill_path = try server_mod.writeBridgeSpill(allocator, io, root_dir, json);
    defer allocator.free(spill_path);
    const SpillMarker = struct { __maatSpillPath: []const u8 };
    const marker = try std.json.Stringify.valueAlloc(allocator, SpillMarker{ .__maatSpillPath = spill_path }, .{});
    defer allocator.free(marker);
    return copyJson(output, marker);
}

fn copyJsonOrSpill(self: *App, output: []u8, json: []const u8) anyerror![]const u8 {
    const file_server = self.file_server orelse return error.ServerUnavailable;
    return copyJsonOrSpillAtRoot(self.allocator, file_server.io, self.storage_root, output, json);
}

const json_parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Parses a bridge invocation's JSON payload into `T` (a per-command arg
/// struct whose field names are the exact camelCase JSON keys bridge.ts
/// sends -- see COMMAND-CONTRACT.md). `allocator` should be an
/// arena/scratch allocator: parsed strings/slices borrow directly from
/// `payload`'s bytes where possible (see `ParseOptions.allocate`'s
/// `alloc_if_needed` default) or are allocated fresh, and the caller is
/// expected to reclaim everything at once (arena deinit) rather than
/// tracking individual frees.
fn parsePayload(comptime T: type, allocator: std.mem.Allocator, payload: []const u8) anyerror!T {
    return std.json.parseFromSliceLeaky(T, allocator, payload, json_parse_options) catch return error.InvalidRequest;
}

// ---- Domain command handlers -------------------------------------------------

fn getAppState(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const state = storage.getAppState(a) catch |err| return mapStorageError(err);
    return copyJsonOrSpill(self, output, try state.toJson(a));
}

fn createBoard(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { name: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const board = storage.createBoard(a, args.name) catch |err| return mapStorageError(err);
    return copyJsonOrSpill(self, output, try board.toJson(a));
}

fn renameBoard(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, name: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const board = storage.renameBoard(a, args.boardId, args.name) catch |err| return mapStorageError(err);
    return copyJsonOrSpill(self, output, try board.toJson(a));
}

fn loadBoard(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const view = storage.loadBoard(a, args.boardId) catch |err| return mapStorageError(err);
    return copyJsonOrSpill(self, output, try view.toJson(a));
}

/// Issue #4: bounded-response board pagination. `cursor` is `null` for the
/// first page (which also carries `board`/`sources`/`frames`) or a previous
/// page's `nextCursor` for a later page -- see storage.zig's
/// `loadBoardPage`/`BoardPage` doc comments for the pagination/consistency
/// design. bridge.ts's `loadBoard()` loops this until `nextCursor` is
/// `null` and merges the pages back into the existing `BoardView` shape, so
/// callers of `loadBoard()` are unaffected. The old unbounded `load_board`
/// command above is kept as-is (still useful for small boards / anything
/// that wants one call), not removed.
fn loadBoardPage(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, cursor: ?[]const u8 = null };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const page = storage.loadBoardPage(a, args.boardId, args.cursor) catch |err| return mapStorageError(err);
    return copyJsonOrSpill(self, output, try page.toJson(a));
}

/// Issue #4: the bounded counterpart to `get_app_state`'s embedded full
/// `BoardView` (which re-introduces the same unbounded-response problem
/// `load_board_page` fixes). Returns just the board list + active board id;
/// bridge.ts's `getAppState()` composes the full `AppStateDto` by calling
/// this then paging the active board's view through `load_board_page`.
fn listBoardsState(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const boards = storage.listBoards(a) catch |err| return mapStorageError(err);
    if (boards.len == 0) return mapStorageError(error.NoBoardAvailable);

    const Dto = struct { boards: []storage_mod.Board, activeBoardId: []const u8 };
    const dto = Dto{ .boards = boards, .activeBoardId = boards[0].id };
    return copyJsonOrSpill(self, output, try std.json.Stringify.valueAlloc(a, dto, .{}));
}

fn deleteBoard(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    // storage.deleteBoard returns the reloaded BoardView of the new active
    // (next-oldest remaining) board. Bounded response (issue #4 follow-up):
    // this used to send that whole BoardView (assets, notes, drawingJson
    // and all) back over the bridge unpaginated -- reintroducing exactly
    // the unbounded-response problem `load_board_page` fixes for reads.
    // Only the new active board id is sent; bridge.ts's `deleteBoard()`
    // re-fetches the bounded state through the existing
    // `list_boards_state` + `load_board_page` composition (same one
    // `getAppState()` already uses).
    const view = storage.deleteBoard(a, args.boardId) catch |err| return mapStorageError(err);
    const Dto = struct { activeBoardId: []const u8 };
    return copyJsonOrSpill(self, output, try std.json.Stringify.valueAlloc(a, Dto{ .activeBoardId = view.board.id }, .{}));
}

fn updateNodes(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `arrangeGroup` needs a default (missing entirely from the JSON, not
    // just null, is a valid encoding of "no arrange group" per
    // COMMAND-CONTRACT.md) which storage_mod.NodeUpdate itself doesn't
    // declare, so parse into this local twin and convert.
    const NodeArg = struct {
        id: []const u8,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        z: i64,
        locked: bool,
        arrangeGroup: ?[]const u8 = null,
    };
    const Args = struct { boardId: []const u8, nodes: []NodeArg };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const nodes = try a.alloc(storage_mod.NodeUpdate, args.nodes.len);
    for (args.nodes, 0..) |n, i| {
        nodes[i] = .{
            .id = n.id,
            .x = n.x,
            .y = n.y,
            .width = n.width,
            .height = n.height,
            .z = n.z,
            .locked = n.locked,
            .arrangeGroup = n.arrangeGroup,
        };
    }

    storage.updateNodes(args.boardId, nodes) catch |err| return mapStorageError(err);
    return "null";
}

fn trashAssets(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, assetIds: []const []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    // trash_assets is the one domain command that returns a plain string
    // (the shared trashedAt timestamp), not void/a DTO.
    const trashed_at = storage.trashAssets(a, args.boardId, args.assetIds) catch |err| return mapStorageError(err);
    const json = try std.json.Stringify.valueAlloc(a, trashed_at, .{});
    return copyJsonOrSpill(self, output, json);
}

fn restoreAssets(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, assetIds: []const []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    storage.restoreAssets(args.boardId, args.assetIds) catch |err| return mapStorageError(err);
    return "null";
}

fn setAssetThumbnail(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();
    const file_server = self.file_server orelse return error.ServerUnavailable;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, assetId: []const u8, uploadPath: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    // Same security boundary as clipboard imports: `uploadPath` is
    // renderer-supplied JSON, so prove it resolves inside
    // `<storage_root>/.uploads` before storage renames/deletes anything at
    // that path.
    try ingest_mod.validateUploadContainment(a, file_server.io, self.storage_root, args.uploadPath);

    const asset = storage.setAssetThumbnail(a, args.boardId, args.assetId, args.uploadPath) catch |err| return mapStorageError(err);
    const json = try asset.toJson(a);
    return copyJsonOrSpill(self, output, json);
}

fn setAssetPrompt(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, assetId: []const u8, prompt: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const asset = storage.setAssetPrompt(a, args.boardId, args.assetId, args.prompt) catch |err| return mapStorageError(err);
    return copyJsonOrSpill(self, output, try asset.toJson(a));
}

fn purgeAssets(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, assetIds: []const []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    storage.purgeAssets(a, args.boardId, args.assetIds) catch |err| return mapStorageError(err);
    return "null";
}

fn deleteSource(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, sourceId: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    // Bounded response (issue #4 follow-up): this used to send the whole
    // (unpaginated) BoardView back over the bridge. Only success/failure is
    // signaled here; bridge.ts's `deleteSource()` re-fetches the bounded
    // view through the existing `load_board_page`-backed `loadBoard()`.
    _ = storage.deleteSource(a, args.boardId, args.sourceId) catch |err| return mapStorageError(err);
    return "null";
}

fn createFrame(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, x: f64, y: f64, width: f64, height: f64, label: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const frame = storage.createFrame(a, args.boardId, args.x, args.y, args.width, args.height, args.label) catch |err| return mapStorageError(err);
    return copyJsonOrSpill(self, output, try frame.toJson(a));
}

fn updateFrames(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Frames have no optional fields (no z/locked/arrangeGroup), so the
    // wire shape matches storage_mod.FrameUpdate exactly -- parse directly
    // into it, no local twin needed.
    const Args = struct { boardId: []const u8, frames: []storage_mod.FrameUpdate };
    const args = try parsePayload(Args, a, invocation.request.payload);

    storage.updateFrames(args.boardId, args.frames) catch |err| return mapStorageError(err);
    return "null";
}

fn deleteFrame(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, frameId: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    storage.deleteFrame(args.boardId, args.frameId) catch |err| return mapStorageError(err);
    return "null";
}

fn updateBoardDrawing(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, drawingJson: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    storage.updateBoardDrawing(args.boardId, args.drawingJson) catch |err| return mapStorageError(err);
    return "null";
}

// ---- Shell command handlers -----------------------------------------------

fn echo(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = context;
    const payload = invocation.request.payload;
    if (payload.len > output.len) return error.PayloadTooLarge;
    @memcpy(output[0..payload.len], payload);
    return output[0..payload.len];
}

fn windowMinimize(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const runtime = self.runtime orelse return error.RuntimeUnavailable;
    try runtime.minimizeWindow(invocation.source.window_id);
    return std.fmt.bufPrint(output, "{{}}", .{});
}

fn windowClose(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const runtime = self.runtime orelse return error.RuntimeUnavailable;
    try runtime.closeWindow(invocation.source.window_id);
    return std.fmt.bufPrint(output, "{{}}", .{});
}

fn windowStartDrag(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    if (builtin.os.tag == .windows) {
        // The SDK seam below is a silent no-op on Windows for webview
        // apps: native_sdk_windows_start_window_drag (webview2_host.cpp)
        // only posts its caption-drag when a CANVAS gpu-surface view of
        // this window holds a live pointer press (view.gpu_pointer_down),
        // and a webview-shell app has no gpu-surface views at all -- so
        // `pressed` is never found and the call "succeeds" without doing
        // anything. Verified live against the built app: the mousedown
        // reaches the page, the bridge dispatch lands and returns {}, and
        // the window never moves. So on Windows the drag is started here
        // directly, the standard frameless-WebView2 pattern (and exactly
        // what the SDK's own code posts when its canvas gate passes):
        // hand the still-held physical press to the system move loop via
        // WM_NCLBUTTONDOWN/HTCAPTION. Posted, not sent -- the move loop
        // is modal and must not run inside this bridge dispatch. The
        // ReleaseCapture first is the same courtesy the SDK's path does:
        // whoever captured the mouse for the press (here WebView2's
        // renderer) must lose it before the move loop can take over.
        try startWindowsNcGesture(HTCAPTION);
        return std.fmt.bufPrint(output, "{{}}", .{});
    }
    const self: *App = @ptrCast(@alignCast(context));
    const runtime = self.runtime orelse return error.RuntimeUnavailable;
    // No JS-visible verb or Runtime method exists for starting a window
    // drag (see MIGRATION-BRIEF.md section 4) -- this reaches into the
    // platform services seam the framework's own canvas-widget code uses.
    try runtime.options.platform.services.startWindowDrag(invocation.source.window_id);
    return std.fmt.bufPrint(output, "{{}}", .{});
}

/// Starts the system's modal move/size loop for the app's own window,
/// keyed by a non-client hit-test code: HTCAPTION begins the move loop,
/// HTTOP/HTTOPLEFT/HTTOPRIGHT begin the matching resize loop. Both loops
/// track the physical mouse button the user is already holding (the
/// bridge command that lands here is invoked from a JS mousedown), so if
/// the button was released before this dispatch arrived the loop starts
/// and exits immediately -- no stuck-drag state is possible.
fn startWindowsNcGesture(hit_test: usize) !void {
    const hwnd = findOwnHostWindow() orelse user32.GetForegroundWindow() orelse user32.GetActiveWindow() orelse return error.WindowUnavailable;
    _ = user32.ReleaseCapture();
    _ = user32.PostMessageW(hwnd, WM_NCLBUTTONDOWN, hit_test, 0);
}

/// Top-edge resize for the chromeless Windows window. build.zig's
/// chromeless top-frame reclaim patch (see patchedWebview2HostSource)
/// removes DefWindowProc's top resize band -- the pixels that used to
/// answer HTTOP are now client area covered by WebView2, whose Chromium
/// HWNDs never yield hit-testing to the parent window. App.tsx renders a
/// slim strip along the window top instead and calls this command from
/// its mousedown; posting WM_NCLBUTTONDOWN with the matching hit-test
/// code starts the exact system resize loop the old band would have.
/// Left/right/bottom edges and their corners still use DefWindowProc's
/// real borders and never come through here.
fn windowStartResize(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    if (builtin.os.tag != .windows) {
        // The resize strip only renders on Windows (App.tsx gates it on
        // the platform); macOS chromeless windows keep whatever resize
        // affordances AppKit gives them. Accept-and-ignore keeps the
        // command's contract identical across platforms.
        return std.fmt.bufPrint(output, "{{}}", .{});
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { edge: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const hit_test: usize = if (std.mem.eql(u8, args.edge, "top"))
        HTTOP
    else if (std.mem.eql(u8, args.edge, "top-left"))
        HTTOPLEFT
    else if (std.mem.eql(u8, args.edge, "top-right"))
        HTTOPRIGHT
    else
        return error.InvalidRequest;
    try startWindowsNcGesture(hit_test);
    return std.fmt.bufPrint(output, "{{}}", .{});
}

const user32 = struct {
    extern "user32" fn GetForegroundWindow() callconv(.c) ?*anyopaque;
    extern "user32" fn GetActiveWindow() callconv(.c) ?*anyopaque;
    extern "user32" fn ShowWindow(hwnd: ?*anyopaque, cmd: c_int) callconv(.c) c_int;
    extern "user32" fn IsZoomed(hwnd: ?*anyopaque) callconv(.c) c_int;
    extern "user32" fn EnumWindows(callback: *const fn (?*anyopaque, isize) callconv(.c) c_int, lparam: isize) callconv(.c) c_int;
    extern "user32" fn GetWindowThreadProcessId(hwnd: ?*anyopaque, pid: *u32) callconv(.c) u32;
    extern "user32" fn GetClassNameW(hwnd: ?*anyopaque, buf: [*]u16, max_count: c_int) callconv(.c) c_int;
    extern "user32" fn IsWindowVisible(hwnd: ?*anyopaque) callconv(.c) c_int;
    extern "user32" fn ReleaseCapture() callconv(.c) c_int;
    extern "user32" fn PostMessageW(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.c) c_int;
};
const kernel32 = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.c) u32;
};

// src-zig/vendor/macos/window_corners.m: registers an observer that rounds
// the chromeless main window's corners once the SDK creates it (a plain
// NSWindowStyleMaskBorderless window renders with square hardware
// corners -- see that file for why this can't just live in the SDK's own
// window creation).
const macos_chrome = struct {
    extern fn maat_native_install_macos_window_corner_fixup() callconv(.c) void;
};

const SW_MAXIMIZE: c_int = 3;
const SW_RESTORE: c_int = 9;

// WM_NCLBUTTONDOWN's wparam is the hit-test code the click claims --
// posting it with these codes starts the system's modal move (HTCAPTION)
// or resize (HTTOP*) loop for the still-held physical press. See
// startWindowsNcGesture.
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const HTCAPTION: usize = 2;
const HTTOP: usize = 12;
const HTTOPLEFT: usize = 13;
const HTTOPRIGHT: usize = 14;

/// Set (and read back) only inside `findOwnHostWindow`'s single
/// synchronous `EnumWindows` call -- bridge handlers all run on the
/// single WebView2 UI thread, so this is never touched concurrently.
var enum_found_hwnd: ?*anyopaque = null;

fn enumWindowsFindHost(hwnd: ?*anyopaque, _: isize) callconv(.c) c_int {
    var pid: u32 = 0;
    _ = user32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != kernel32.GetCurrentProcessId()) return 1; // keep enumerating
    if (user32.IsWindowVisible(hwnd) == 0) return 1;
    var class_buf: [64]u16 = undefined;
    const len: usize = @intCast(user32.GetClassNameW(hwnd, &class_buf, class_buf.len));
    const wanted_class = std.unicode.utf8ToUtf16LeStringLiteral("NativeSdkWindowsHost");
    if (!std.mem.eql(u16, class_buf[0..len], wanted_class)) return 1;
    enum_found_hwnd = hwnd;
    return 0; // stop enumerating
}

/// Finds this process's own top-level app window by its Win32 class
/// name ("NativeSdkWindowsHost", the class webview2_host.cpp registers
/// for every window it creates) instead of trusting
/// GetForegroundWindow/GetActiveWindow: this process can own more than
/// one top-level HWND, and in a non-interactive/automation-driven
/// session neither of those APIs reliably resolves to the app's own
/// visible window -- confirmed live: GetForegroundWindow returned a
/// different, unrelated own-process HWND when window_toggle_maximize
/// was driven through `native automate bridge`, so the maximize/restore
/// below silently applied to the wrong window and IsZoomed never
/// flipped true.
fn findOwnHostWindow() ?*anyopaque {
    enum_found_hwnd = null;
    _ = user32.EnumWindows(enumWindowsFindHost, 0);
    return enum_found_hwnd;
}

/// No programmatic maximize/restore verb exists anywhere in the SDK
/// (confirmed absent in MIGRATION-BRIEF.md section 4/Blockers #1) --
/// only `minimizeWindow`/`closeWindow` are exposed. This is the Win32
/// fallback the brief calls for, resolving the app's own HWND via
/// `findOwnHostWindow` (see its doc comment) with the original
/// GetForegroundWindow/GetActiveWindow lookup kept as a last-resort
/// fallback.
fn windowToggleMaximize(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = context;
    _ = invocation;
    if (builtin.os.tag != .windows) {
        // No maximize/zoom verb exists anywhere in the Native SDK for
        // macOS either (confirmed against @native-sdk/cli 0.4.3's
        // src/platform/types.zig PlatformServices and
        // src/platform/macos/root.zig: only minimize_window_fn/
        // close_window_fn are wired -- the same gap MIGRATION-BRIEF.md
        // recorded for Windows, which is why the Win32 fallback below
        // exists). Unlike Windows, this migration doesn't vendor an
        // equivalent low-level (NSWindow zoom:) call for macOS, so this is
        // a documented no-op rather than a guess at one: macOS already
        // gives the user the OS's native double-click-titlebar zoom
        // convention for free (see windowStartDrag's
        // `start_window_drag_fn` doc comment -- macOS's
        // `performWindowDragWithEvent:` applies it automatically), and the
        // custom titlebar's mac-styled maximize control (App.tsx) is
        // otherwise inert here.
        return std.fmt.bufPrint(output, "{{\"maximized\":false}}", .{});
    }
    const hwnd = findOwnHostWindow() orelse user32.GetForegroundWindow() orelse user32.GetActiveWindow() orelse return error.WindowUnavailable;
    const was_zoomed = user32.IsZoomed(hwnd) != 0;
    _ = user32.ShowWindow(hwnd, if (was_zoomed) SW_RESTORE else SW_MAXIMIZE);
    const now_maximized = !was_zoomed;
    return std.fmt.bufPrint(output, "{{\"maximized\":{s}}}", .{if (now_maximized) "true" else "false"});
}

fn dialogOpenFiles(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    const runtime = self.runtime orelse return error.RuntimeUnavailable;
    var dialog_buffer: [platform.max_dialog_paths_bytes]u8 = undefined;
    const result = try runtime.showOpenDialog(.{
        .title = "Select files",
        .allow_directories = false,
        .allow_multiple = true,
    }, &dialog_buffer);

    var writer = std.Io.Writer.fixed(output);
    if (result.count == 0) {
        try writer.writeAll("{\"paths\":null}");
        return writer.buffered();
    }
    try writer.writeAll("{\"paths\":[");
    var scratch: [platform.max_dialog_path_bytes * 2 + 16]u8 = undefined;
    var start: usize = 0;
    var wrote_any = false;
    for (result.paths, 0..) |ch, pos| {
        if (ch == '\n') {
            if (wrote_any) try writer.writeByte(',');
            try writer.writeAll(bridge.writeJsonStringValue(&scratch, result.paths[start..pos]));
            start = pos + 1;
            wrote_any = true;
        }
    }
    if (start < result.paths.len) {
        if (wrote_any) try writer.writeByte(',');
        try writer.writeAll(bridge.writeJsonStringValue(&scratch, result.paths[start..]));
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

fn dialogOpenFolder(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    const runtime = self.runtime orelse return error.RuntimeUnavailable;
    var dialog_buffer: [platform.max_dialog_paths_bytes]u8 = undefined;
    const result = try runtime.showOpenDialog(.{
        .title = "Select folder",
        .allow_directories = true,
        .allow_multiple = false,
    }, &dialog_buffer);

    var writer = std.Io.Writer.fixed(output);
    if (result.count == 0) {
        try writer.writeAll("{\"path\":null}");
        return writer.buffered();
    }
    const newline = std.mem.indexOfScalar(u8, result.paths, '\n') orelse result.paths.len;
    var scratch: [platform.max_dialog_path_bytes * 2 + 16]u8 = undefined;
    try writer.writeAll("{\"path\":");
    try writer.writeAll(bridge.writeJsonStringValue(&scratch, result.paths[0..newline]));
    try writer.writeAll("}");
    return writer.buffered();
}

// ---- reveal_path (own implementation, bypassing the SDK's runtime.revealPath) ----
//
// The SDK's `runtime.revealPath` shells out to a *new* `explorer.exe
// /select,"path"` process (see @native-sdk/cli's webview2_host.cpp,
// `native_sdk_windows_reveal_path`). On this handler thread (never
// CoInitialize'd, and not pumping window messages the way a dedicated UI
// thread would) that call was observed to both (a) fail to select the file
// -- Explorer opened the right parent folder but with nothing highlighted
// -- and (b) far worse, wedge the *entire* bridge dispatcher: `dispatch()`
// runs handlers synchronously on the calling thread (see
// @native-sdk/cli's bridge/root.zig), so a handler that blocks forever
// blocks every subsequent command, and the whole window went Windows
// "(Not Responding)" until the process was force-killed.
//
// This calls the Shell COM API directly instead: CoInitializeEx as STA on
// this handler thread (required by SHOpenFolderAndSelectItems, and also
// what makes its internal blocking RPC wait pump messages instead of
// deadlocking), then SHParseDisplayName + SHOpenFolderAndSelectItems on
// the file's own PIDL (cidl=0, apidl=null selects pidlFolder itself) --
// the same technique used by e.g. Chromium's platform_util_win.cc and
// what Tauri's opener plugin does for "reveal in folder". Falls back to
// ShellExecuteW opening the parent directory (no selection, but the
// folder does open) if the shell API fails for any reason.
const win = struct {
    const HRESULT = i32;
    const S_OK: HRESULT = 0;
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
    const SW_SHOWNORMAL: i32 = 1;

    fn succeeded(hr: HRESULT) bool {
        return hr >= 0;
    }

    extern "ole32" fn CoInitializeEx(pv_reserved: ?*anyopaque, co_init: u32) callconv(.winapi) HRESULT;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "shell32" fn SHParseDisplayName(
        name: [*:0]const u16,
        bind_ctx: ?*anyopaque,
        pidl: *?*anyopaque,
        attrs_in: u32,
        attrs_out: ?*u32,
    ) callconv(.winapi) HRESULT;
    extern "shell32" fn SHOpenFolderAndSelectItems(
        pidl_folder: ?*anyopaque,
        cidl: u32,
        apidl: ?[*]const ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) HRESULT;
    extern "shell32" fn ILFree(pidl: ?*anyopaque) callconv(.winapi) void;
    extern "shell32" fn ShellExecuteW(
        hwnd: ?*anyopaque,
        operation: ?[*:0]const u16,
        file: [*:0]const u16,
        parameters: ?[*:0]const u16,
        directory: ?[*:0]const u16,
        show_cmd: i32,
    ) callconv(.winapi) ?*anyopaque;
};

fn revealPathSelectingFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const wide_path = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide_path);

    const co_hr = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED | win.COINIT_DISABLE_OLE1DDE);
    const co_initialized = win.succeeded(co_hr);
    defer if (co_initialized) win.CoUninitialize();

    if (co_initialized) select: {
        var pidl: ?*anyopaque = null;
        const parse_hr = win.SHParseDisplayName(wide_path.ptr, null, &pidl, 0, null);
        if (!win.succeeded(parse_hr) or pidl == null) break :select;
        defer win.ILFree(pidl);

        const open_hr = win.SHOpenFolderAndSelectItems(pidl, 0, null, 0);
        if (win.succeeded(open_hr)) return;
    }

    // Fallback: open the containing folder (no selection) via ShellExecuteW.
    const parent = std.fs.path.dirname(path) orelse path;
    const wide_parent = try std.unicode.utf8ToUtf16LeAllocZ(allocator, parent);
    defer allocator.free(wide_parent);
    const wide_open = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const result = win.ShellExecuteW(null, wide_open, wide_parent.ptr, null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) return error.RevealFailed;
}

fn revealPath(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = output;
    const self: *App = @ptrCast(@alignCast(context));

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Real JSON parsing (not the old raw-substring `jsonStringField`, which
    // returned still-escaped text -- Windows paths routinely contain literal
    // backslashes, so that scan handed a mangled, doubled-backslash path
    // downstream) (F3).
    const Args = struct { path: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    if (builtin.os.tag == .windows) {
        try revealPathSelectingFile(a, args.path);
    } else {
        // macOS: the SDK's own runtime.revealPath is fine to use directly
        // here, unlike on Windows (see revealPathSelectingFile's doc
        // comment above for why that one is bypassed). @native-sdk/cli
        // 0.4.3's macOS implementation
        // (src/platform/macos/root.zig:revealPath ->
        // native_sdk_appkit_reveal_path in appkit_host.m) shells
        // `NSWorkspace.activateFileViewerSelectingURLs:` directly on the
        // calling thread -- it both actually selects the file (confirmed
        // in appkit_host.m) and, being a plain Cocoa call with no blocking
        // RPC wait involved, has none of the wedge-the-bridge-dispatcher
        // failure mode the Windows `explorer.exe /select` shell-out had.
        const runtime = self.runtime orelse return error.RuntimeUnavailable;
        try runtime.revealPath(args.path);
    }
    return "null";
}

fn serverInfo(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    const file_server = self.file_server orelse return error.ServerUnavailable;
    // `uploadToken` (issue #2): the per-session random token bridge.ts must
    // send back as `X-Upload-Token` on every `POST /upload`. Plain hex, no
    // JSON escaping needed.
    return std.fmt.bufPrint(
        output,
        "{{\"assetBase\":\"http://127.0.0.1:{d}\",\"uploadToken\":\"{s}\"}}",
        .{ file_server.port, file_server.upload_token_hex },
    );
}

// ---- Import job commands ---------------------------------------------------

fn dupeOwnedStrings(allocator: std.mem.Allocator, src: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, src.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < src.len) : (i += 1) out[i] = try allocator.dupe(u8, src[i]);
    return out;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

const PathsJobArgs = struct {
    allocator: std.mem.Allocator,
    storage: *storage_mod.Storage,
    jobs: *JobRegistry,
    slot: *JobSlot,
    board_id: []u8,
    paths: [][]u8,
};

fn runPathsJob(args: *PathsJobArgs) void {
    defer {
        freeOwnedStrings(args.allocator, args.paths);
        args.allocator.free(args.board_id);
        args.allocator.destroy(args);
    }

    var arena = std.heap.ArenaAllocator.init(args.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path_slices = a.alloc([]const u8, args.paths.len) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    for (args.paths, 0..) |p, i| path_slices[i] = p;

    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    const report = ingest_mod.importPaths(a, io, args.storage, args.board_id, path_slices) catch |err| {
        finishJobError(args.jobs, args.slot, @errorName(err));
        return;
    };

    const json_tmp = report.toJson(a) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    const json_owned = args.allocator.dupe(u8, json_tmp) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    finishJobReport(args.jobs, args.slot, json_owned);
}

const UrlsJobArgs = struct {
    allocator: std.mem.Allocator,
    storage: *storage_mod.Storage,
    jobs: *JobRegistry,
    slot: *JobSlot,
    board_id: []u8,
    urls: [][]u8,
};

fn runUrlsJob(args: *UrlsJobArgs) void {
    defer {
        freeOwnedStrings(args.allocator, args.urls);
        args.allocator.free(args.board_id);
        args.allocator.destroy(args);
    }

    var arena = std.heap.ArenaAllocator.init(args.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url_slices = a.alloc([]const u8, args.urls.len) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    for (args.urls, 0..) |u, i| url_slices[i] = u;

    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    const report = ingest_mod.importExternalUrls(a, io, args.storage, args.board_id, url_slices) catch |err| {
        finishJobError(args.jobs, args.slot, @errorName(err));
        return;
    };

    const json_tmp = report.toJson(a) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    const json_owned = args.allocator.dupe(u8, json_tmp) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    finishJobReport(args.jobs, args.slot, json_owned);
}

/// `bytes` xor `uploadPath` is set, mirroring `ingest_mod.ClipboardItem`'s
/// two mutually exclusive payload shapes (issue #2). `bytes` is the
/// original inline-bytes shape (small payloads); `uploadPath` points at a
/// temp file server.zig's `POST /upload` handler already wrote to
/// `<storage_root>/.uploads/<id>` for anything too big to encode as a JSON
/// byte array under the bridge's ~1 MiB cap.
const ClipboardItemOwned = struct {
    name: []u8,
    mime: ?[]u8,
    bytes: ?[]u8,
    upload_path: ?[]u8,
};

const ClipboardJobArgs = struct {
    allocator: std.mem.Allocator,
    storage: *storage_mod.Storage,
    jobs: *JobRegistry,
    slot: *JobSlot,
    board_id: []u8,
    items: []ClipboardItemOwned,
};

fn freeClipboardItems(allocator: std.mem.Allocator, items: []ClipboardItemOwned) void {
    for (items) |item| {
        allocator.free(item.name);
        if (item.mime) |m| allocator.free(m);
        if (item.bytes) |b| allocator.free(b);
        if (item.upload_path) |p| allocator.free(p);
    }
    allocator.free(items);
}

fn runClipboardJob(args: *ClipboardJobArgs) void {
    defer {
        freeClipboardItems(args.allocator, args.items);
        args.allocator.free(args.board_id);
        args.allocator.destroy(args);
    }

    var arena = std.heap.ArenaAllocator.init(args.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = a.alloc(ingest_mod.ClipboardItem, args.items.len) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    for (args.items, 0..) |item, i| {
        items[i] = .{ .name = item.name, .mime = item.mime, .bytes = item.bytes, .uploadPath = item.upload_path };
    }

    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    const report = ingest_mod.importClipboardItems(a, io, args.storage, args.board_id, items) catch |err| {
        finishJobError(args.jobs, args.slot, @errorName(err));
        return;
    };

    const json_tmp = report.toJson(a) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    const json_owned = args.allocator.dupe(u8, json_tmp) catch {
        finishJobError(args.jobs, args.slot, "OutOfMemory");
        return;
    };
    finishJobReport(args.jobs, args.slot, json_owned);
}

fn importPathsStart(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, paths: []const []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const slot = self.jobs.reserve() orelse return error.TooManyJobs;

    // Persistent copies (outlive this handler call / the request-scoped
    // arena above -- the worker thread runs long after this call returns).
    const board_id = try self.allocator.dupe(u8, args.boardId);
    errdefer self.allocator.free(board_id);
    const paths = try dupeOwnedStrings(self.allocator, args.paths);
    errdefer freeOwnedStrings(self.allocator, paths);

    const job_args = try self.allocator.create(PathsJobArgs);
    errdefer self.allocator.destroy(job_args);
    job_args.* = .{
        .allocator = self.allocator,
        .storage = storage,
        .jobs = &self.jobs,
        .slot = slot,
        .board_id = board_id,
        .paths = paths,
    };

    // NOTE (accepted, not fixed): like the other two import job workers
    // below and the file server's connection threads (server.zig), a panic
    // on this thread kills the whole process -- Zig has no `catch_unwind`
    // equivalent to isolate it (see ingest.zig's module header for the
    // same acknowledgment re: per-file import errors, which are handled; a
    // genuine panic is not).
    //
    // The thread is joinable, not detached (issue #3): `App.stop` joins it
    // via `JobRegistry.drain` before closing `Storage`, so a still-running
    // import can never touch a closed connection.
    const thread = try std.Thread.spawn(.{}, runPathsJob, .{job_args});
    self.jobs.attachThread(slot, thread);

    return std.fmt.bufPrint(output, "{{\"jobId\":\"{s}\"}}", .{slot.id});
}

fn importUrlsStart(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { boardId: []const u8, urls: []const []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const slot = self.jobs.reserve() orelse return error.TooManyJobs;

    const board_id = try self.allocator.dupe(u8, args.boardId);
    errdefer self.allocator.free(board_id);
    const urls = try dupeOwnedStrings(self.allocator, args.urls);
    errdefer freeOwnedStrings(self.allocator, urls);

    const job_args = try self.allocator.create(UrlsJobArgs);
    errdefer self.allocator.destroy(job_args);
    job_args.* = .{
        .allocator = self.allocator,
        .storage = storage,
        .jobs = &self.jobs,
        .slot = slot,
        .board_id = board_id,
        .urls = urls,
    };

    // See the NOTE above `runPathsJob`'s spawn: a panic here also kills the
    // process (accepted, not fixed), and the thread is joined (not
    // detached) by `JobRegistry.drain` on shutdown.
    const thread = try std.Thread.spawn(.{}, runUrlsJob, .{job_args});
    self.jobs.attachThread(slot, thread);

    return std.fmt.bufPrint(output, "{{\"jobId\":\"{s}\"}}", .{slot.id});
}

fn importClipboardStart(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    const storage = try self.storagePtr();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two mutually exclusive shapes per item (issue #2): `bytes` is a raw
    // JSON array of 0-255 integers over the wire (NOT base64) per
    // COMMAND-CONTRACT.md -- std.json's slice parser handles a `[]const u8`
    // field element-wise when the next token is `[`, so this parses
    // directly into a byte slice -- still supported for small payloads.
    // `uploadPath` is the new shape bridge.ts uses for anything large
    // enough to have gone through `POST /upload` instead: a path already on
    // disk under `<storage_root>/.uploads/`.
    const ItemArg = struct { name: []const u8, mime: ?[]const u8 = null, bytes: ?[]const u8 = null, uploadPath: ?[]const u8 = null };
    const Args = struct { boardId: []const u8, items: []ItemArg };
    const args = try parsePayload(Args, a, invocation.request.payload);

    const slot = self.jobs.reserve() orelse return error.TooManyJobs;

    const board_id = try self.allocator.dupe(u8, args.boardId);
    errdefer self.allocator.free(board_id);

    const items = try self.allocator.alloc(ClipboardItemOwned, args.items.len);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| {
            self.allocator.free(item.name);
            if (item.mime) |m| self.allocator.free(m);
            if (item.bytes) |b| self.allocator.free(b);
            if (item.upload_path) |p| self.allocator.free(p);
        }
        self.allocator.free(items);
    }
    while (built < args.items.len) : (built += 1) {
        const src = args.items[built];
        items[built] = .{
            .name = try self.allocator.dupe(u8, src.name),
            .mime = if (src.mime) |m| try self.allocator.dupe(u8, m) else null,
            .bytes = if (src.bytes) |b| try self.allocator.dupe(u8, b) else null,
            .upload_path = if (src.uploadPath) |p| try self.allocator.dupe(u8, p) else null,
        };
    }

    const job_args = try self.allocator.create(ClipboardJobArgs);
    errdefer self.allocator.destroy(job_args);
    job_args.* = .{
        .allocator = self.allocator,
        .storage = storage,
        .jobs = &self.jobs,
        .slot = slot,
        .board_id = board_id,
        .items = items,
    };

    // See the NOTE above `runPathsJob`'s spawn: a panic here also kills the
    // process (accepted, not fixed), and the thread is joined (not
    // detached) by `JobRegistry.drain` on shutdown.
    const thread = try std.Thread.spawn(.{}, runClipboardJob, .{job_args});
    self.jobs.attachThread(slot, thread);

    return std.fmt.bufPrint(output, "{{\"jobId\":\"{s}\"}}", .{slot.id});
}

fn importJobStatus(context: *anyopaque, invocation: bridge.Invocation, output: []u8) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { jobId: []const u8 };
    const args = try parsePayload(Args, a, invocation.request.payload);
    const job_id = args.jobId;

    self.jobs.mutex.lock();
    var found: ?*JobSlot = null;
    for (&self.jobs.slots) |*slot| {
        if (!slot.in_use or !std.mem.eql(u8, &slot.id, job_id)) continue;
        found = slot;
        break;
    }
    const slot = found orelse {
        self.jobs.mutex.unlock();
        return std.fmt.bufPrint(output, "{{\"done\":true,\"report\":null,\"error\":\"unknown job\"}}", .{});
    };
    if (!slot.done) {
        self.jobs.mutex.unlock();
        return std.fmt.bufPrint(output, "{{\"done\":false,\"report\":null,\"error\":null}}", .{});
    }

    // "Job results retained until polled once after done, then freed."
    const result = slot.result;
    slot.result = null;
    self.jobs.mutex.unlock();

    // Joins the worker thread and only then marks the slot reusable (issue
    // #4/P2: without this, the slot's `std.Thread` handle was overwritten
    // by the next `reserve()` on this slot without ever being joined --
    // see `JobRegistry.recycle`'s doc comment).
    self.jobs.recycle(slot);

    var writer = std.Io.Writer.fixed(output);
    switch (result orelse JobResult{ .err = "unknown job" }) {
        .report => |r| {
            defer self.allocator.free(r);
            writer.print("{{\"done\":true,\"report\":{s},\"error\":null}}", .{r}) catch return error.PayloadTooLarge;
        },
        .err => |msg| {
            var scratch: [4096]u8 = undefined;
            const quoted = bridge.writeJsonStringValue(&scratch, msg);
            writer.print("{{\"done\":true,\"report\":null,\"error\":{s}}}", .{quoted}) catch return error.PayloadTooLarge;
        },
    }
    return writer.buffered();
}

// ---------------------------------------------------------------------------

fn computeStorageRoot(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = env_map.get("APPDATA") orelse return error.MissingAppData;
        return std.fs.path.join(allocator, &.{ appdata, "MaatNative" });
    }
    // macOS: ~/Library/Application Support/MaatNative -- the same
    // convention @native-sdk/cli's own app_dirs primitive uses for its
    // `.data` directory kind (src/primitives/app_dirs/root.zig's
    // macOS branch), so this lands in the same place a Native SDK app
    // using that primitive directly would.
    const home = env_map.get("HOME") orelse return error.MissingHome;
    return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "MaatNative" });
}

pub fn main(init: std.process.Init) !void {
    var app_state = App{
        .env_map = init.environ_map,
        .allocator = std.heap.page_allocator,
    };
    app_state.storage_root = try computeStorageRoot(app_state.allocator, init.environ_map);

    // Must run before runWithOptions -- that call blocks in the SDK's
    // native run loop, which is where the window actually gets created.
    if (builtin.os.tag == .macos) {
        macos_chrome.maat_native_install_macos_window_corner_fixup();
    }

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "Maat Native",
        .window_title = "Maat Native",
        .bundle_id = "com.lzitser.maat-native",
        .icon_path = "assets/icon.png",
        .bridge = app_state.bridge_(),
        .security = .{
            .navigation = .{ .allowed_origins = &app_origins },
        },
    }, init);
}

// Forces analysis of ingest.zig/storage.zig (and, transitively, their own
// `test { _ = @import(...) }` blocks) under `zig build test`'s `app_mod`
// binary. Zig's test discovery only surfaces `test` declarations in files
// that actually get semantically analyzed as part of a given compilation;
// `main.zig`'s `pub fn main` (and everything only reachable through it, e.g.
// the handler wiring that calls into ingest_mod/storage_mod) is dead code
// when building for `zig build test` (the test binary has its own
// synthesized entry point), so the plain `const ingest_mod = @import(...)`
// / `const storage_mod = @import(...)` aliases up top are otherwise never
// reached here -- without this, `ingest_test.zig`/`storage_test.zig` never
// actually ran under `zig build test` despite appearing to (confirmed by
// injecting a deliberate `@compileError` into `ingest_test.zig`, which did
// not fail the build before this was added).
test {
    _ = @import("ingest.zig");
    _ = @import("storage.zig");
    // Only the platform-neutral request-path/mime helpers carry tests in
    // there; nothing test-reachable touches the embedded `entries`, so
    // this stays green on a fresh checkout where dist/ hasn't been built
    // (the generated module is then just a decl-level @compileError that
    // lazy analysis never fires -- see build.zig's embeddedFrontendModule).
    _ = @import("embedded_frontend_server");
}

test "revealPath's JSON parsing round-trips a Windows path with backslashes and an embedded quote" {
    // F3 regression: the old `jsonStringField` returned the still-escaped
    // JSON substring (literal doubled backslashes), which is wrong for real
    // Windows paths. `revealPath` now runs the payload through
    // `parsePayload`/`std.json` like the domain handlers do -- this proves
    // that path decodes to the exact original, unescaped string.
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Args = struct { path: []const u8 };
    const payload =
        \\{"path":"C:\\Users\\test\\My \"Folder\"\\file.png"}
    ;
    const args = try parsePayload(Args, a, payload);
    try std.testing.expectEqualStrings(
        \\C:\Users\test\My "Folder"\file.png
    , args.path);
}

test "oversized bridge JSON spills losslessly instead of returning PayloadTooLarge" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try testAbsPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    const payload_size = 1024 * 1024 + 4096;
    const json = try allocator.alloc(u8, payload_size);
    defer allocator.free(json);
    @memset(json, 'x');
    const prefix = "{\"payload\":\"";
    @memcpy(json[0..prefix.len], prefix);
    json[json.len - 2] = '"';
    json[json.len - 1] = '}';

    var output: [1024]u8 = undefined;
    const marker = try copyJsonOrSpillAtRoot(allocator, io, tmp_root, &output, json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, marker, .{});
    defer parsed.deinit();
    const spill_path = parsed.value.object.get("__maatSpillPath").?.string;

    const spilled = try std.Io.Dir.cwd().readFileAlloc(io, spill_path, allocator, .limited(payload_size + 1));
    defer allocator.free(spilled);
    try std.testing.expectEqualSlices(u8, json, spilled);
}

// ---- JobRegistry shutdown-drain regression tests (issue #3) --------------
//
// JobRegistry (reserve/attachThread/drain), PathsJobArgs and runPathsJob
// never reference App/bridge/runtime, so the drain-during-import race can
// be exercised directly here: spawn a real ingest_mod.importPaths worker
// exactly the way import_paths_start does, then drain immediately (no
// sleep) so the worker is very likely still running when drain() joins it
// -- the point being that this is safe regardless of how the race lands,
// since drain always waits for real completion rather than racing/timing
// out.

fn testAbsPath(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn testWriteFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

test "shutdown drains an in-flight import job before storage closes, and the catalog survives reopen" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try testAbsPath(allocator, tmp.dir, io);
    defer allocator.free(tmp_root);

    // Enough files that the worker thread is realistically still looping
    // when drain() is called right after spawn, with no sleep in between.
    const file_count = 64;
    var paths_buf: [file_count][]const u8 = undefined;
    var built: usize = 0;
    defer for (paths_buf[0..built]) |p| allocator.free(p);
    for (0..file_count) |i| {
        const path = try std.fmt.allocPrint(allocator, "{s}/originals/file-{d}.txt", .{ tmp_root, i });
        // Content must be unique per file: importPaths dedupes by content
        // hash, and identical bytes would collapse all 64 into 1 asset,
        // which would defeat the "still looping" premise of this test.
        const contents = try std.fmt.allocPrint(allocator, "shutdown-drain regression fixture #{d}", .{i});
        defer allocator.free(contents);
        try testWriteFile(io, path, contents);
        paths_buf[built] = path;
        built += 1;
    }
    const paths: []const []const u8 = paths_buf[0..file_count];

    const storage_root = try std.fmt.allocPrint(allocator, "{s}/data", .{tmp_root});
    defer allocator.free(storage_root);
    var storage = try storage_mod.Storage.open(allocator, storage_root);

    const boards = try storage.listBoards(allocator);
    const board_id = try allocator.dupe(u8, boards[0].id);
    defer allocator.free(board_id);
    for (boards) |b| b.deinit(allocator);
    allocator.free(boards);

    var jobs = JobRegistry{};
    const slot = jobs.reserve() orelse return error.TestUnexpectedResult;

    const job_args = try allocator.create(PathsJobArgs);
    job_args.* = .{
        .allocator = allocator,
        .storage = &storage,
        .jobs = &jobs,
        .slot = slot,
        .board_id = try allocator.dupe(u8, board_id),
        .paths = try dupeOwnedStrings(allocator, paths),
    };

    // Mirrors import_paths_start's spawn + attachThread exactly.
    const thread = try std.Thread.spawn(.{}, runPathsJob, .{job_args});
    jobs.attachThread(slot, thread);

    // The shutdown path (App.stop): drain BEFORE the job is necessarily
    // done. If drain closed storage instead of joining the worker, the
    // still-running ingest_mod.importPaths call would UAF the sqlite
    // connection -- run under `zig test`'s allocator + real sqlite, so a
    // UAF/crash here fails the test instead of silently passing.
    jobs.drain(allocator);

    // No further jobs may start once the registry is closing.
    try std.testing.expect(jobs.reserve() == null);

    // Every slot was released and any retained result freed.
    for (&jobs.slots) |*s| {
        try std.testing.expect(!s.in_use);
        try std.testing.expect(s.result == null);
        try std.testing.expect(s.thread == null);
    }

    storage.close();

    // Reopen (models the app relaunch in the live acceptance check) and
    // confirm every asset that was fully imported before the drain is
    // present and queryable -- no partial rows, no corruption.
    var reopened = try storage_mod.Storage.open(allocator, storage_root);
    defer reopened.close();
    const view = try reopened.loadBoard(allocator, board_id);
    defer view.deinit(allocator);
    try std.testing.expectEqual(@as(usize, file_count), view.assets.len);
}

test "drain frees a retained-but-unpolled job result instead of leaking it" {
    const allocator = std.testing.allocator;

    var jobs = JobRegistry{};
    const slot = jobs.reserve() orelse return error.TestUnexpectedResult;
    const report_json = try allocator.dupe(u8, "{\"imported\":1}");
    finishJobReport(&jobs, slot, report_json);

    // No import_job_status poll happened for this job -- shutdown must
    // still free `report_json` rather than leaking it. std.testing.allocator
    // fails the test on any outstanding allocation once it deinits, so a
    // regression here (drain not freeing `.report` results) fails loudly.
    jobs.drain(allocator);

    try std.testing.expect(slot.result == null);
    try std.testing.expect(!slot.in_use);
}

// ---- JobRegistry.recycle regression test (issue #4/P2) -------------------
//
// Before the fix, `import_job_status`'s done-and-polled path set
// `slot.in_use = false` directly without ever touching `slot.thread` --
// so the joinable `std.Thread` handle attached by `attachThread` was simply
// overwritten (leaked, never joined) the next time `reserve()` picked that
// same slot. `JobRegistry.recycle` (called from `import_job_status` now)
// fixes that by joining the handle before the slot is marked reusable.
//
// This mirrors `import_job_status`'s exact sequence -- reserve, attach a
// real joinable thread, finish, "poll" (read+clear result under the lock),
// recycle -- run far more times than `max_jobs` (32) slots exist. If
// `recycle` failed to actually free a slot (e.g. left `in_use` true, or
// double-joined and panicked/hung), `reserve()` would eventually return
// `null` well before `iterations` is reached, or the test would hang/panic
// outright -- so a clean, fully-run pass is itself the "no leak, no crash"
// proof the review asked for (there is no direct way to assert an OS
// thread-handle count from Zig, but reusing every one of `max_jobs` slots
// far more times than there are slots -- while requiring each `recycle`
// call to have actually joined and reset its slot -- is only possible if
// every prior handle was properly released, not merely dropped).
test "polling a completed job joins its thread handle and the slot becomes fully reusable" {
    const allocator = std.testing.allocator;

    var jobs = JobRegistry{};

    const noop = struct {
        fn run() void {}
    }.run;

    const iterations = max_jobs * 4 + 8;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const slot = jobs.reserve() orelse return error.TestUnexpectedResult;
        try std.testing.expect(slot.thread == null);

        const thread = try std.Thread.spawn(.{}, noop, .{});
        jobs.attachThread(slot, thread);

        const report_json = try allocator.dupe(u8, "{}");
        finishJobReport(&jobs, slot, report_json);

        // Mirrors import_job_status's own sequence exactly: read+clear the
        // result under the lock, unlock, then recycle (join + release).
        jobs.mutex.lock();
        try std.testing.expect(slot.done);
        const result = slot.result;
        slot.result = null;
        jobs.mutex.unlock();

        jobs.recycle(slot);

        switch (result orelse return error.TestUnexpectedResult) {
            .report => |r| allocator.free(r),
            .err => return error.TestUnexpectedResult,
        }

        try std.testing.expect(!slot.in_use);
        try std.testing.expect(slot.thread == null);
    }

    // Every slot ends the run reusable and leak-free (no retained thread
    // handle, no retained result).
    for (&jobs.slots) |*s| {
        try std.testing.expect(!s.in_use);
        try std.testing.expect(s.thread == null);
        try std.testing.expect(s.result == null);
    }
}
