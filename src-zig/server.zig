// Local file server for the Maat Native shell.
//
// Serves files from a single configurable storage root
// (main.zig passes %APPDATA%\MaatNative) over plain HTTP on
// 127.0.0.1 with an OS-assigned port. This exists because the
// Native SDK's packaged-asset WebView origin is fixed to one
// `frontend.dist` root at WebView-creation time -- there is no
// supported way to point the WebView at a second, growing,
// user-writable directory (see MIGRATION-BRIEF.md section 5).
//
// Endpoint: GET /file?p=<urlencoded absolute path>
//   200 + bytes + Content-Type   when the resolved path is under
//                                the storage root and exists (whole
//                                file, streamed in bounded chunks --
//                                see `serveFileChunked`)
//   206 + bytes + Content-Range  when a valid single-range `Range`
//                                request header is present
//   403                          when the resolved path escapes
//                                the storage root
//   404                          for anything else (missing file,
//                                bad method, malformed request)
//   416                          for a malformed or unsatisfiable
//                                `Range` header
//
// Endpoint: POST /upload  (issue #2 -- clipboard images beyond the
//   1 MiB bridge message cap)
//   Gated by `X-Upload-Token: <token>`, a per-process random token
//   generated at server start (see `Server.upload_token_hex`,
//   exposed to the frontend via the `server_info` bridge command).
//   Body is streamed (bounded buffer, never accumulated in memory)
//   to a temp file under `<storage_root>/.uploads/<uuid>`, capped at
//   `max_upload_bytes`. Response: `{"path":"<absolute temp path>"}`.
//     200  upload written, body is the JSON above
//     401  missing/incorrect X-Upload-Token
//     411  missing Content-Length
//     400  malformed Content-Length / zero-length body
//     413  Content-Length (or actual body) exceeds max_upload_bytes

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const ws2 = windows.ws2_32;
const is_windows = builtin.os.tag == .windows;

// The socket layer is plain Winsock2 on Windows, called directly via
// `extern "ws2_32"` declarations, NOT `std.Io.net`. `std.Io.net`'s Windows
// backend (`std.Io.Threaded`'s AFD-based accept/read path, brand new
// in this 0.16 std alongside the whole `std.Io` overhaul) was found to
// hang indefinitely on this machine: `accept()` returns, but the
// following `read()` never sees bytes the client already wrote,
// blocking forever instead of returning them (confirmed with a
// minimal standalone repro against a plain TCP client, isolated from
// everything else in this app -- `std.Io.Dir` file reads through the
// same `std.Io.Threaded` instance work fine, so the bug is scoped to
// networking specifically). Raw Winsock2 is the well-trodden, boring
// alternative and is precedented elsewhere in this migration (Win32
// calls are already required for window_toggle_maximize).
//
// On macOS (and any other POSIX target this ever runs on) there is no
// equivalent std.Io.net bug on record -- this instead uses raw BSD
// sockets via `std.c`'s libc bindings, kept deliberately symmetric with
// the Windows implementation (same direct, unbuffered extern-call shape)
// rather than mixing in a second, higher-level socket API for one
// platform only. The `sock*` helpers just below are the only
// platform-conditional surface in this file -- everything past them
// (request parsing, file serving, uploads, the tests) is
// platform-neutral and calls only through those helpers.
pub const SOCKET = if (is_windows) usize else std.c.fd_t;
const invalid_socket: SOCKET = if (is_windows) ~@as(SOCKET, 0) else -1;

extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.c) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.c) i32;
extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.c) SOCKET;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) i32;
extern "ws2_32" fn bind(s: SOCKET, name: *const ws2.sockaddr.in, namelen: i32) callconv(.c) i32;
extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.c) i32;
extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*i32) callconv(.c) SOCKET;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
extern "ws2_32" fn getsockname(s: SOCKET, name: *ws2.sockaddr.in, namelen: *i32) callconv(.c) i32;
extern "ws2_32" fn htons(hostshort: u16) callconv(.c) u16;
extern "ws2_32" fn ntohs(netshort: u16) callconv(.c) u16;
extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.c) i32;

/// One-time process-wide socket layer init. Winsock requires it; BSD
/// sockets don't.
fn sockStartup() !void {
    if (!is_windows) return;
    var wsadata: [512]u8 align(8) = undefined;
    if (WSAStartup(0x0202, &wsadata) != 0) return error.WinsockStartupFailed;
}

/// Creates a fresh TCP socket. Caller closes it with `sockClose`.
fn sockCreateTcp() !SOCKET {
    const sock = if (is_windows)
        socket(ws2.AF.INET, ws2.SOCK.STREAM, ws2.IPPROTO.TCP)
    else
        std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, std.c.IPPROTO.TCP);
    if (sock == invalid_socket) return error.SocketCreateFailed;
    return sock;
}

fn sockClose(s: SOCKET) void {
    if (is_windows) {
        _ = closesocket(s);
    } else {
        _ = std.c.close(s);
    }
}

/// Binds `s` to 127.0.0.1 on an OS-assigned port (port 0).
fn sockBindLoopback(s: SOCKET) !void {
    if (is_windows) {
        const bind_addr: ws2.sockaddr.in = .{
            .port = htons(0),
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        };
        if (bind(s, &bind_addr, @sizeOf(ws2.sockaddr.in)) != 0) return error.BindFailed;
    } else {
        const bind_addr: std.c.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, 0),
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        };
        if (std.c.bind(s, @ptrCast(&bind_addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    }
}

fn sockListen(s: SOCKET, backlog: i32) !void {
    const ok = if (is_windows) listen(s, backlog) == 0 else std.c.listen(s, @intCast(backlog)) == 0;
    if (!ok) return error.ListenFailed;
}

/// The OS-assigned port `sockBindLoopback` bound `s` to, in host byte order.
fn sockGetBoundPort(s: SOCKET) !u16 {
    if (is_windows) {
        var actual_addr: ws2.sockaddr.in = undefined;
        var actual_len: i32 = @sizeOf(ws2.sockaddr.in);
        if (getsockname(s, &actual_addr, &actual_len) != 0) return error.GetSockNameFailed;
        return ntohs(actual_addr.port);
    } else {
        var actual_addr: std.c.sockaddr.in = undefined;
        var actual_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.getsockname(s, @ptrCast(&actual_addr), &actual_len) != 0) return error.GetSockNameFailed;
        return std.mem.bigToNative(u16, actual_addr.port);
    }
}

fn sockAccept(listen_sock: SOCKET) SOCKET {
    return if (is_windows) accept(listen_sock, null, null) else std.c.accept(listen_sock, null, null);
}

/// Best-effort per-connection `recv()` timeout (F2) -- see `RECV_TIMEOUT_MS`.
fn sockSetRecvTimeout(s: SOCKET, timeout_ms: u32) void {
    if (is_windows) {
        // Windows' SO_RCVTIMEO takes a plain millisecond DWORD (unlike
        // POSIX's timeval).
        var t: u32 = timeout_ms;
        _ = setsockopt(s, ws2.SOL.SOCKET, ws2.SO.RCVTIMEO, @ptrCast(&t), @sizeOf(u32));
    } else {
        const tv: std.c.timeval = .{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(std.c.timeval));
    }
}

/// macOS (unlike Windows/Linux) raises SIGPIPE -- whose default action
/// kills the whole process -- on a `send()` to a socket the peer already
/// closed, instead of just failing the call with an error. A client
/// disconnecting mid-response (closing a video/image request early, say)
/// is routine here, so this disables that per-socket rather than letting
/// an ordinary client disconnect take down the whole app. No-op on every
/// other target: Windows has no SIGPIPE concept, and this server has only
/// ever run on Windows/macOS so far.
fn sockDisableSigpipe(s: SOCKET) void {
    if (builtin.os.tag != .macos) return;
    var one: c_int = 1;
    _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, @ptrCast(&one), @sizeOf(c_int));
}

fn sockRecv(s: SOCKET, buf: []u8) isize {
    return if (is_windows)
        recv(s, buf.ptr, @intCast(buf.len), 0)
    else
        std.c.recv(s, buf.ptr, buf.len, 0);
}

fn sockSend(s: SOCKET, buf: []const u8) isize {
    return if (is_windows)
        send(s, buf.ptr, @intCast(buf.len), 0)
    else
        std.c.send(s, buf.ptr, buf.len, 0);
}

/// recv() timeout applied to every accepted connection (F2): without this, a
/// client that connects and then never sends bytes would block that
/// connection's `recv()` forever. Combined with the thread-per-connection
/// model below, a stalled client now only ties up its own thread for at most
/// this long instead of blocking every other request.
const RECV_TIMEOUT_MS: u32 = 5000;

/// Fixed scratch-buffer size used to stream a file's body in bounded chunks
/// (both for GET /file responses and for reading POST /upload request
/// bodies) -- memory usage while serving/receiving is this constant,
/// independent of the file's total size (F5/issue #5).
pub const CHUNK_SIZE: usize = 256 * 1024;

/// Matches ingest.zig's `MAX_EXTERNAL_IMPORT_BYTES` (the existing clipboard/
/// URL import cap) -- an upload larger than this can never successfully
/// import anyway, so it's rejected here before a single byte is written to
/// disk.
const max_upload_bytes: u64 = 100 * 1024 * 1024;
const bridge_responses_dir_name = ".bridge-responses";

const upload_token_hex_len: usize = 64;

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    threaded: std.Io.Threaded,
    listen_socket: SOCKET,
    root_dir: []u8,
    port: u16,
    thread: std.Thread,
    /// Per-process random token (32 random bytes, hex-encoded) required on
    /// every `POST /upload` via the `X-Upload-Token` header (issue #2).
    /// Generated once at `start()` and handed to the frontend through the
    /// `server_info` bridge response's `uploadToken` field -- never
    /// persisted, never logged.
    upload_token_hex: [upload_token_hex_len]u8,

    /// Starts the listener and its accept-loop worker thread. The
    /// returned pointer is heap-allocated and intentionally never
    /// freed -- the server lives for the whole process lifetime,
    /// same as the app window. File access (root-dir creation, and
    /// reads once a request resolves to a path) still goes through
    /// `std.Io.Dir` on `self.io` -- only sockets go through the raw
    /// platform socket layer (`sock*` helpers above).
    pub fn start(allocator: std.mem.Allocator, root_dir: []const u8) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.root_dir = try allocator.dupe(u8, root_dir);
        errdefer allocator.free(self.root_dir);

        self.threaded = std.Io.Threaded.init(allocator, .{});
        self.io = self.threaded.io();

        // Best-effort: first run on a machine with no MaatNative
        // folder yet. The server still starts even if this fails;
        // requests simply 404 until the directory shows up.
        std.Io.Dir.cwd().createDirPath(self.io, self.root_dir) catch {};

        // Sweep any `.uploads` leftovers from a prior run (a crash or
        // force-kill mid-transfer, or a temp file whose owning import job
        // never got to clean it up) before recreating the directory fresh
        // -- issue #2's "cleans up temp files ... on app start" requirement.
        {
            const uploads_dir = std.fs.path.join(allocator, &.{ self.root_dir, ".uploads" }) catch null;
            if (uploads_dir) |dir| {
                defer allocator.free(dir);
                std.Io.Dir.cwd().deleteTree(self.io, dir) catch {};
                std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
            }
        }

        // Bridge responses larger than Native SDK's fixed result buffer are
        // written here and fetched once by bridge.ts. Sweep crash leftovers
        // before accepting requests; successful GETs delete their own file.
        {
            const responses_dir = std.fs.path.join(allocator, &.{ self.root_dir, bridge_responses_dir_name }) catch null;
            if (responses_dir) |dir| {
                defer allocator.free(dir);
                std.Io.Dir.cwd().deleteTree(self.io, dir) catch {};
                std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
            }
        }

        var raw_token: [32]u8 = undefined;
        self.io.random(&raw_token);
        self.upload_token_hex = std.fmt.bytesToHex(raw_token, .lower);

        try sockStartup();

        const sock = try sockCreateTcp();
        errdefer sockClose(sock);

        try sockBindLoopback(sock);
        try sockListen(sock, 16);

        self.listen_socket = sock;
        self.port = try sockGetBoundPort(sock);
        // NOTE (accepted, not fixed): a panic on this thread, or on any
        // per-connection thread it spawns below, kills the whole process --
        // Zig has no `catch_unwind` equivalent to isolate a worker-thread
        // panic.
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    fn acceptLoop(self: *Server) void {
        while (true) {
            const client = sockAccept(self.listen_socket);
            if (client == invalid_socket) continue;

            // Best-effort: if this fails the connection is still served,
            // just without the stall guard.
            sockSetRecvTimeout(client, RECV_TIMEOUT_MS);
            // macOS-only (see sockDisableSigpipe's doc comment); a no-op
            // everywhere else.
            sockDisableSigpipe(client);

            // One thread per connection: this server is localhost-only,
            // serving asset previews to our own WebView, so connection
            // volume is low and a thread per connection is simple and cheap.
            // It also means the RCVTIMEO stall above only ties up its own
            // thread, not the accept loop, so one bad client can no longer
            // block every other request (F2).
            //
            // NOTE (accepted, not fixed): a panic inside `handleConnection`
            // on this thread still takes down the whole process -- Zig has
            // no `catch_unwind` equivalent to isolate a worker-thread panic.
            // `handleConnection` is straight-line request parsing/file I/O
            // with no identified panic path, so this is judged acceptable
            // here, same as the app's other worker threads (see the import
            // job threads in main.zig).
            const thread = std.Thread.spawn(.{}, Server.handleConnection, .{ self, client }) catch {
                sockClose(client);
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *Server, client: SOCKET) void {
        defer sockClose(client);

        var request_buf: [4096]u8 = undefined;
        const n = sockRecv(client, &request_buf);
        if (n <= 0) return;
        const request = request_buf[0..@intCast(n)];

        const line_end = std.mem.indexOfAny(u8, request, "\r\n") orelse request.len;
        const request_line = request[0..line_end];

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;

        // CORS (issue #2): the WebView page's origin (`zero://app`, see
        // main.zig's `app_origins`) is cross-origin relative to this
        // `http://127.0.0.1:<port>` server, so `fetch()`-based uploads --
        // unlike plain `<img src>`/`<video src>` GETs, which never trigger
        // CORS -- need both a preflight response and
        // `Access-Control-Allow-Origin` on the actual response. This server
        // only ever serves this one local app instance, so allowing any
        // origin to read responses is no wider than the access anyone on
        // localhost already has by hitting the port directly.
        if (std.mem.eql(u8, method, "OPTIONS") and std.mem.eql(u8, target, "/upload")) {
            writePreflightResponse(client);
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/upload")) {
            self.handleUpload(client, request);
            return;
        }

        if (!std.mem.eql(u8, method, "GET")) {
            writeSimpleResponse(client, 404, "Not Found");
            return;
        }

        const query_prefix = "/file?";
        if (!std.mem.startsWith(u8, target, query_prefix)) {
            writeSimpleResponse(client, 404, "Not Found");
            return;
        }
        const query = target[query_prefix.len..];
        const raw_p = extractQueryParam(query, "p") orelse {
            writeSimpleResponse(client, 404, "Not Found");
            return;
        };

        var decode_buf: [4096]u8 = undefined;
        const decoded = percentDecode(raw_p, &decode_buf) catch {
            writeSimpleResponse(client, 404, "Not Found");
            return;
        };

        const resolved = resolveUnderRoot(self.allocator, self.root_dir, decoded) catch |err| {
            switch (err) {
                error.OutsideRoot => writeSimpleResponse(client, 403, "Forbidden"),
                else => writeSimpleResponse(client, 404, "Not Found"),
            }
            return;
        };
        defer self.allocator.free(resolved);

        // Spill responses are one-shot. Register this defer before the file
        // close defer below so LIFO cleanup closes the Windows handle first,
        // then removes the file even when the client disconnects mid-stream.
        const delete_after_read = isBridgeResponsePath(self.allocator, self.root_dir, resolved);
        defer if (delete_after_read) std.Io.Dir.deleteFileAbsolute(self.io, resolved) catch {};

        var file = std.Io.Dir.openFileAbsolute(self.io, resolved, .{}) catch {
            writeSimpleResponse(client, 404, "Not Found");
            return;
        };
        defer file.close(self.io);

        const size = file.length(self.io) catch {
            writeSimpleResponse(client, 404, "Not Found");
            return;
        };

        // Single-range `Range: bytes=...` support (WebView2 requires this for
        // seekable media playback -- issue #5). Any other Range unit is
        // ignored (full content served, per RFC 7233); a malformed or
        // unsatisfiable `bytes=` range is rejected with 416 before any body
        // bytes are sent.
        const range_header = findHeaderValue(request, "Range");
        var range: RangeSpec = .{ .start = 0, .end = if (size == 0) 0 else size - 1 };
        var partial = false;
        if (size > 0) {
            if (range_header) |rh| {
                if (parseRangeHeader(rh, size)) |maybe_range| {
                    if (maybe_range) |r| {
                        range = r;
                        partial = true;
                    }
                } else |_| {
                    write416(client, size);
                    return;
                }
            }
        }

        const content_type = contentTypeFor(resolved);
        var header_buf: [384]u8 = undefined;
        const header = if (size == 0)
            std.fmt.bufPrint(
                &header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\n" ++ cors_header ++ "Content-Length: 0\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                .{content_type},
            ) catch return
        else if (partial)
            std.fmt.bufPrint(
                &header_buf,
                "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\n" ++ cors_header ++ "Content-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                .{ content_type, range.end - range.start + 1, range.start, range.end, size },
            ) catch return
        else
            std.fmt.bufPrint(
                &header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\n" ++ cors_header ++ "Content-Length: {d}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                .{ content_type, range.end - range.start + 1 },
            ) catch return;
        if (!sendAll(client, header)) return;
        if (size == 0) return;

        var writer_ctx = SocketWriter.init(client);
        serveFileChunked(self.allocator, self.io, &file, range, &writer_ctx.writer) catch return;
    }

    fn handleUpload(self: *Server, client: SOCKET, request: []const u8) void {
        const token = findHeaderValue(request, "X-Upload-Token") orelse {
            writeSimpleResponse(client, 401, "Unauthorized");
            return;
        };
        if (!std.mem.eql(u8, token, &self.upload_token_hex)) {
            writeSimpleResponse(client, 401, "Unauthorized");
            return;
        }

        const content_length_str = findHeaderValue(request, "Content-Length") orelse {
            writeSimpleResponse(client, 411, "Length Required");
            return;
        };
        const content_length = std.fmt.parseInt(u64, content_length_str, 10) catch {
            writeSimpleResponse(client, 400, "Bad Request");
            return;
        };
        if (content_length == 0) {
            writeSimpleResponse(client, 400, "Bad Request");
            return;
        }
        if (content_length > max_upload_bytes) {
            writeSimpleResponse(client, 413, "Payload Too Large");
            return;
        }

        // Body bytes already sitting in the initial recv() buffer (the
        // client's request headers + however much of the body fit in the
        // same TCP read), located just past the blank line ending the
        // header block.
        const headers_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            writeSimpleResponse(client, 400, "Bad Request");
            return;
        };
        const body_prefix = request[headers_end + 4 ..];

        const uploads_dir = std.fs.path.join(self.allocator, &.{ self.root_dir, ".uploads" }) catch {
            writeSimpleResponse(client, 500, "Internal Server Error");
            return;
        };
        defer self.allocator.free(uploads_dir);
        std.Io.Dir.cwd().createDirPath(self.io, uploads_dir) catch {};

        var uuid_buf: [uuid_hex_len]u8 = undefined;
        newUuidHex(self.io, &uuid_buf);
        const dest_path = std.fs.path.join(self.allocator, &.{ uploads_dir, &uuid_buf }) catch {
            writeSimpleResponse(client, 500, "Internal Server Error");
            return;
        };
        defer self.allocator.free(dest_path);

        var file = std.Io.Dir.createFileAbsolute(self.io, dest_path, .{}) catch {
            writeSimpleResponse(client, 500, "Internal Server Error");
            return;
        };
        var file_open = true;
        defer if (file_open) file.close(self.io);

        var received: u64 = 0;
        var write_failed = false;

        if (body_prefix.len > 0) {
            const take = @min(@as(u64, body_prefix.len), content_length);
            if (file.writePositionalAll(self.io, body_prefix[0..take], 0)) |_| {
                received = take;
            } else |_| {
                write_failed = true;
            }
        }

        var recv_buf: [CHUNK_SIZE]u8 = undefined;
        while (!write_failed and received < content_length) {
            const remaining = content_length - received;
            const want: usize = @intCast(@min(@as(u64, recv_buf.len), remaining));
            const n = sockRecv(client, recv_buf[0..want]);
            if (n <= 0) {
                write_failed = true;
                break;
            }
            const got: usize = @intCast(n);
            if (file.writePositionalAll(self.io, recv_buf[0..got], received)) |_| {
                received += got;
            } else |_| {
                write_failed = true;
            }
        }

        file.close(self.io);
        file_open = false;

        if (write_failed or received != content_length) {
            std.Io.Dir.deleteFileAbsolute(self.io, dest_path) catch {};
            // The client is either gone or timed out -- nothing useful to
            // send back in the write_failed (connection-level) case, but a
            // short-body edge case (received < content_length without a
            // transport error, which shouldn't happen given the loop above,
            // but keep this branch defensive) still gets a response.
            if (!write_failed) writeSimpleResponse(client, 400, "Bad Request");
            return;
        }

        var path_escaped_buf: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
        const path_escaped = jsonEscape(dest_path, &path_escaped_buf);

        var body_buf: [std.Io.Dir.max_path_bytes * 2 + 32]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"path\":\"{s}\"}}", .{path_escaped}) catch {
            writeSimpleResponse(client, 500, "Internal Server Error");
            return;
        };

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++ cors_header ++ "Content-Length: {d}\r\nConnection: close\r\n\r\n",
            .{body.len},
        ) catch return;
        if (!sendAll(client, header)) return;
        _ = sendAll(client, body);
    }
};

const cors_header = "Access-Control-Allow-Origin: *\r\n";

fn writeSimpleResponse(client: SOCKET, code: u16, text: []const u8) void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {d} {s}\r\n" ++ cors_header ++ "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ code, text, text.len, text },
    ) catch return;
    _ = sendAll(client, header);
}

fn write416(client: SOCKET, size: u64) void {
    var header_buf: [192]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 416 Range Not Satisfiable\r\n" ++ cors_header ++ "Content-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{size},
    ) catch return;
    _ = sendAll(client, header);
}

/// Response to an `OPTIONS /upload` CORS preflight request (a browser/
/// WebView sends this automatically before a cross-origin `POST` carrying a
/// non-simple header like `X-Upload-Token`).
fn writePreflightResponse(client: SOCKET) void {
    _ = sendAll(
        client,
        "HTTP/1.1 204 No Content\r\n" ++
            cors_header ++
            "Access-Control-Allow-Methods: POST, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: X-Upload-Token, Content-Type\r\n" ++
            "Access-Control-Max-Age: 600\r\n" ++
            "Content-Length: 0\r\nConnection: close\r\n\r\n",
    );
}

/// Returns `true` if every byte of `data` was sent, `false` on a
/// connection-level failure (partial sends are retried internally in the
/// loop below until either everything is sent or `send()` itself fails).
fn sendAll(client: SOCKET, data: []const u8) bool {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = sockSend(client, data[sent..]);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

/// Case-insensitive header lookup over the raw request buffer captured by
/// `handleConnection`'s single `recv()` call. Only scans up to the first
/// blank line (end of the header block); a request whose headers didn't fit
/// in that one read (or arrived across multiple TCP segments) simply won't
/// find the header here -- an accepted limitation shared with the rest of
/// this single-read request parser (see `handleConnection`'s existing
/// request-line parsing, which has the same constraint).
fn findHeaderValue(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) break; // blank line ends the header block
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

pub const RangeSpec = struct {
    /// Inclusive byte offsets, both already clamped to `[0, file_size)`.
    start: u64,
    end: u64,
};

pub const RangeParseError = error{ InvalidRange, UnsatisfiableRange };

/// Parses a `Range` header's value against a file of `file_size` bytes.
/// Returns:
///   `null`             -- not a `bytes=` range (unsupported unit); caller
///                         should ignore it and serve the full content.
///   `RangeSpec`         -- a valid single range, clamped to the file.
///   `error.InvalidRange`       -- malformed syntax, or multiple
///                                 comma-separated ranges (unsupported).
///   `error.UnsatisfiableRange` -- syntactically valid but outside the
///                                 file's bounds (e.g. `start >= file_size`).
/// Both errors map to a 416 response at the call site; they're kept
/// distinct only because it makes the unit tests self-documenting.
pub fn parseRangeHeader(value: []const u8, file_size: u64) RangeParseError!?RangeSpec {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const spec = value[prefix.len..];

    // Single-range only (issue #5's HITL decision) -- a comma indicates a
    // multi-range request, which this server doesn't support.
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return error.InvalidRange;

    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRange;
    const start_str = spec[0..dash];
    const end_str = spec[dash + 1 ..];

    if (start_str.len == 0) {
        // Suffix range: "-N" means the last N bytes.
        if (end_str.len == 0) return error.InvalidRange;
        const suffix_len = std.fmt.parseInt(u64, end_str, 10) catch return error.InvalidRange;
        if (suffix_len == 0 or file_size == 0) return error.UnsatisfiableRange;
        const start = if (suffix_len >= file_size) 0 else file_size - suffix_len;
        return RangeSpec{ .start = start, .end = file_size - 1 };
    }

    const start = std.fmt.parseInt(u64, start_str, 10) catch return error.InvalidRange;
    if (start >= file_size) return error.UnsatisfiableRange;

    if (end_str.len == 0) {
        return RangeSpec{ .start = start, .end = file_size - 1 };
    }

    const end_raw = std.fmt.parseInt(u64, end_str, 10) catch return error.InvalidRange;
    if (end_raw < start) return error.InvalidRange;
    const end = @min(end_raw, file_size - 1);
    return RangeSpec{ .start = start, .end = end };
}

/// Streams `range` (inclusive byte offsets) of `file` to `writer` using a
/// single `CHUNK_SIZE`-bounded scratch buffer obtained from `allocator` --
/// never a buffer sized to the range/file itself, so memory usage while
/// serving stays constant regardless of how large the file is (issue #5).
/// Exposed standalone (over `std.Io.Writer`, not tied to a live socket) so
/// it can be exercised directly by tests; production traffic goes through
/// `SocketWriter`, whose `drain` calls the same bounded-retry `sendAll` used
/// for headers.
pub fn serveFileChunked(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *std.Io.File,
    range: RangeSpec,
    writer: *std.Io.Writer,
) !void {
    const buf = try allocator.alloc(u8, CHUNK_SIZE);
    defer allocator.free(buf);

    var offset = range.start;
    while (offset <= range.end) {
        const remaining = range.end - offset + 1;
        const want: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const got = try file.readPositionalAll(io, buf[0..want], offset);
        if (got == 0) break;
        try writer.writeAll(buf[0..got]);
        offset += got;
    }
}

/// `std.Io.Writer` adapter over a raw client socket -- unbuffered (`buffer`
/// is empty, so every `writeAll` call reaches `drain` directly), draining
/// through the same bounded-retry `sendAll` helper the header-writing code
/// uses, so a slow client / partial `send()` is handled the same way in
/// both places.
const SocketWriter = struct {
    writer: std.Io.Writer,
    socket: SOCKET,

    fn init(client_socket: SOCKET) SocketWriter {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
            .socket = client_socket,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SocketWriter = @alignCast(@fieldParentPtr("writer", w));
        if (data.len == 0) return 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            if (chunk.len == 0) continue;
            if (!sendAll(self.socket, chunk)) return error.WriteFailed;
            written += chunk.len;
        }
        const last = data[data.len - 1];
        if (last.len > 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                if (!sendAll(self.socket, last)) return error.WriteFailed;
                written += last.len;
            }
        }
        return written;
    }
};

const uuid_hex_len: usize = 32;

/// Generates a random 32-hex-character identifier for a temp upload's
/// filename (not a spec-shaped UUID -- just enough entropy to avoid
/// collisions between concurrent uploads; the upload path is never parsed
/// back as a UUID by anything downstream).
fn newUuidHex(io: std.Io, out: *[uuid_hex_len]u8) void {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    out.* = std.fmt.bytesToHex(raw, .lower);
}

/// Writes a bridge result that cannot fit Native SDK's fixed response buffer
/// to a random one-shot file beneath the app storage root. The returned path
/// is allocator-owned and safe to expose only through the bridge spill marker.
pub fn writeBridgeSpill(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    bytes: []const u8,
) ![]u8 {
    const responses_dir = try std.fs.path.join(allocator, &.{ root_dir, bridge_responses_dir_name });
    defer allocator.free(responses_dir);
    try std.Io.Dir.cwd().createDirPath(io, responses_dir);

    var id: [uuid_hex_len]u8 = undefined;
    newUuidHex(io, &id);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{&id});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ responses_dir, filename });
    errdefer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    return path;
}

fn isBridgeResponsePath(allocator: std.mem.Allocator, root_dir: []const u8, candidate: []const u8) bool {
    const dir = std.fs.path.join(allocator, &.{ root_dir, bridge_responses_dir_name }) catch return false;
    defer allocator.free(dir);
    return isUnderRoot(dir, candidate);
}

/// Minimal JSON string-content escaper (backslash + double-quote; Windows
/// paths only ever contain the former in practice, but both are handled for
/// correctness) for the `{"path":"..."}` upload response. Truncates rather
/// than overflowing `buf` -- `buf` is always sized generously relative to
/// `std.Io.Dir.max_path_bytes` at call sites, so truncation is not expected
/// to actually occur.
fn jsonEscape(s: []const u8, buf: []u8) []const u8 {
    var out: usize = 0;
    for (s) |ch| {
        const needed: usize = if (ch == '\\' or ch == '"') 2 else 1;
        if (out + needed > buf.len) break;
        if (needed == 2) {
            buf[out] = '\\';
            buf[out + 1] = ch;
        } else {
            buf[out] = ch;
        }
        out += needed;
    }
    return buf[0..out];
}

fn extractQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub const DecodeError = error{ InvalidEncoding, BufferTooSmall };

/// Percent-decodes a `encodeURIComponent`-style query value. `+` is left
/// literal (matching `encodeURIComponent`, which never emits `+` for
/// space) rather than being converted to a space.
pub fn percentDecode(input: []const u8, buf: []u8) DecodeError![]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '%') {
            if (i + 3 > input.len) return error.InvalidEncoding;
            const hi = hexDigit(input[i + 1]) orelse return error.InvalidEncoding;
            const lo = hexDigit(input[i + 2]) orelse return error.InvalidEncoding;
            if (out >= buf.len) return error.BufferTooSmall;
            buf[out] = (hi << 4) | lo;
            out += 1;
            i += 3;
        } else {
            if (out >= buf.len) return error.BufferTooSmall;
            buf[out] = c;
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub const ResolveError = error{ OutsideRoot, InvalidPath } || std.mem.Allocator.Error;

/// Normalizes `requested` (collapsing `.`/`..`) and verifies the result
/// falls under `root_dir`. Returns an allocator-owned normalized path on
/// success (caller frees); `error.OutsideRoot` if it escapes the root
/// (`..` traversal, or a sibling directory that merely shares a string
/// prefix with the root); `error.InvalidPath` if either input is not an
/// absolute path.
pub fn resolveUnderRoot(allocator: std.mem.Allocator, root_dir: []const u8, requested: []const u8) ResolveError![]u8 {
    if (requested.len == 0) return error.InvalidPath;
    if (!std.fs.path.isAbsolute(requested)) return error.InvalidPath;
    if (!std.fs.path.isAbsolute(root_dir)) return error.InvalidPath;

    const norm_requested = try std.fs.path.resolve(allocator, &.{requested});
    errdefer allocator.free(norm_requested);
    const norm_root = try std.fs.path.resolve(allocator, &.{root_dir});
    defer allocator.free(norm_root);

    if (!isUnderRoot(norm_root, norm_requested)) return error.OutsideRoot;
    return norm_requested;
}

fn isUnderRoot(root: []const u8, candidate: []const u8) bool {
    if (candidate.len < root.len) return false;
    if (!std.ascii.eqlIgnoreCase(candidate[0..root.len], root)) return false;
    if (candidate.len == root.len) return true;
    const next = candidate[root.len];
    return next == '\\' or next == '/';
}

pub fn contentTypeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0 or ext.len > 8) return "application/octet-stream";
    var lower_buf: [8]u8 = undefined;
    const lower = std.ascii.lowerString(lower_buf[0..ext.len], ext);
    if (std.mem.eql(u8, lower, ".png")) return "image/png";
    if (std.mem.eql(u8, lower, ".jpg") or std.mem.eql(u8, lower, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, lower, ".gif")) return "image/gif";
    if (std.mem.eql(u8, lower, ".webp")) return "image/webp";
    if (std.mem.eql(u8, lower, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, lower, ".mp4")) return "video/mp4";
    if (std.mem.eql(u8, lower, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, lower, ".json")) return "application/json";
    return "application/octet-stream";
}

test "percentDecode decodes escaped bytes and leaves plain bytes alone" {
    var buf: [64]u8 = undefined;
    const decoded = try percentDecode("C%3A%5CUsers%5Ctest%5Cfile.png", &buf);
    try std.testing.expectEqualStrings("C:\\Users\\test\\file.png", decoded);
}

test "percentDecode leaves plus literal" {
    var buf: [64]u8 = undefined;
    const decoded = try percentDecode("a+b", &buf);
    try std.testing.expectEqualStrings("a+b", decoded);
}

test "percentDecode rejects truncated escapes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidEncoding, percentDecode("C%3", &buf));
}

test "percentDecode rejects invalid hex digits" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidEncoding, percentDecode("%zz", &buf));
}

test "contentTypeFor maps known extensions case-insensitively" {
    try std.testing.expectEqualStrings("image/png", contentTypeFor("C:\\x\\a.png"));
    try std.testing.expectEqualStrings("image/jpeg", contentTypeFor("a.JPEG"));
    try std.testing.expectEqualStrings("image/jpeg", contentTypeFor("a.jpg"));
    try std.testing.expectEqualStrings("image/gif", contentTypeFor("a.gif"));
    try std.testing.expectEqualStrings("image/webp", contentTypeFor("a.WEBP"));
    try std.testing.expectEqualStrings("image/svg+xml", contentTypeFor("a.svg"));
    try std.testing.expectEqualStrings("video/mp4", contentTypeFor("a.mp4"));
    try std.testing.expectEqualStrings("application/pdf", contentTypeFor("a.pdf"));
    try std.testing.expectEqualStrings("application/json", contentTypeFor("a.JSON"));
    try std.testing.expectEqualStrings("application/octet-stream", contentTypeFor("a.unknownext"));
    try std.testing.expectEqualStrings("application/octet-stream", contentTypeFor("a"));
}

// Platform-appropriate absolute-path fixtures for the resolveUnderRoot
// tests: `std.fs.path.isAbsolute` (which resolveUnderRoot calls first)
// answers per the compilation target, so `C:\...` fixtures are simply not
// absolute paths on macOS/Linux and would short-circuit every test below
// into error.InvalidPath there.
const test_root = if (is_windows)
    "C:\\Users\\test\\AppData\\Roaming\\MaatNative"
else
    "/Users/test/Library/Application Support/MaatNative";
const test_sep = if (is_windows) "\\" else "/";

test "resolveUnderRoot allows paths inside the storage root" {
    const allocator = std.testing.allocator;
    const inside = test_root ++ test_sep ++ "boards" ++ test_sep ++ "1" ++ test_sep ++ "assets" ++ test_sep ++ "a.png";
    const resolved = try resolveUnderRoot(allocator, test_root, inside);
    defer allocator.free(resolved);
    try std.testing.expect(std.ascii.eqlIgnoreCase(resolved, inside));
}

test "resolveUnderRoot rejects .. traversal outside the root" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.OutsideRoot, resolveUnderRoot(
        allocator,
        test_root,
        test_root ++ test_sep ++ ".." ++ test_sep ++ "Evil" ++ test_sep ++ "a.png",
    ));
}

test "resolveUnderRoot rejects sibling directories sharing only a string prefix" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.OutsideRoot, resolveUnderRoot(
        allocator,
        test_root,
        test_root ++ "Evil" ++ test_sep ++ "a.png",
    ));
}

test "resolveUnderRoot rejects relative paths" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, resolveUnderRoot(
        allocator,
        test_root,
        "boards" ++ test_sep ++ "1" ++ test_sep ++ "assets" ++ test_sep ++ "a.png",
    ));
}

// ---------------------------------------------------------------------------
// parseRangeHeader (issue #5)
// ---------------------------------------------------------------------------

test "parseRangeHeader parses start-end" {
    const r = (try parseRangeHeader("bytes=0-99", 1000)).?;
    try std.testing.expectEqual(@as(u64, 0), r.start);
    try std.testing.expectEqual(@as(u64, 99), r.end);
}

test "parseRangeHeader parses open-ended start-" {
    const r = (try parseRangeHeader("bytes=100-", 1000)).?;
    try std.testing.expectEqual(@as(u64, 100), r.start);
    try std.testing.expectEqual(@as(u64, 999), r.end);
}

test "parseRangeHeader parses suffix -N" {
    const r = (try parseRangeHeader("bytes=-500", 1000)).?;
    try std.testing.expectEqual(@as(u64, 500), r.start);
    try std.testing.expectEqual(@as(u64, 999), r.end);
}

test "parseRangeHeader clamps a suffix larger than the file to the whole file" {
    const r = (try parseRangeHeader("bytes=-5000", 1000)).?;
    try std.testing.expectEqual(@as(u64, 0), r.start);
    try std.testing.expectEqual(@as(u64, 999), r.end);
}

test "parseRangeHeader clamps an end past the file size" {
    const r = (try parseRangeHeader("bytes=900-2000", 1000)).?;
    try std.testing.expectEqual(@as(u64, 900), r.start);
    try std.testing.expectEqual(@as(u64, 999), r.end);
}

test "parseRangeHeader ignores a non-bytes unit" {
    try std.testing.expectEqual(@as(?RangeSpec, null), try parseRangeHeader("items=0-5", 1000));
}

test "parseRangeHeader rejects a start beyond the file size" {
    try std.testing.expectError(error.UnsatisfiableRange, parseRangeHeader("bytes=5000-6000", 1000));
}

test "parseRangeHeader rejects a zero-length suffix" {
    try std.testing.expectError(error.UnsatisfiableRange, parseRangeHeader("bytes=-0", 1000));
}

test "parseRangeHeader rejects an empty file with any range" {
    try std.testing.expectError(error.UnsatisfiableRange, parseRangeHeader("bytes=0-", 0));
}

test "parseRangeHeader rejects end before start" {
    try std.testing.expectError(error.InvalidRange, parseRangeHeader("bytes=5-3", 1000));
}

test "parseRangeHeader rejects non-numeric bounds" {
    try std.testing.expectError(error.InvalidRange, parseRangeHeader("bytes=abc-5", 1000));
}

test "parseRangeHeader rejects a missing dash" {
    try std.testing.expectError(error.InvalidRange, parseRangeHeader("bytes=500", 1000));
}

test "parseRangeHeader rejects multiple comma-separated ranges" {
    try std.testing.expectError(error.InvalidRange, parseRangeHeader("bytes=0-10,20-30", 1000));
}

// ---------------------------------------------------------------------------
// findHeaderValue
// ---------------------------------------------------------------------------

test "findHeaderValue finds a header case-insensitively and trims whitespace" {
    const request = "GET /file?p=x HTTP/1.1\r\nHost: 127.0.0.1\r\nrange: bytes=0-9\r\nX-Upload-Token:  abc123  \r\n\r\n";
    try std.testing.expectEqualStrings("bytes=0-9", findHeaderValue(request, "Range").?);
    try std.testing.expectEqualStrings("abc123", findHeaderValue(request, "X-Upload-Token").?);
    try std.testing.expect(findHeaderValue(request, "Nonexistent") == null);
}

// ---------------------------------------------------------------------------
// serveFileChunked (issue #5's allocation-bounded regression test)
// ---------------------------------------------------------------------------

test "serveFileChunked streams a file larger than the chunk buffer without a file-sized allocation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Deliberately not a multiple of CHUNK_SIZE, and comfortably over 1 MiB.
    const size: usize = CHUNK_SIZE * 5 + 777;
    const contents = try allocator.alloc(u8, size);
    defer allocator.free(contents);
    for (contents, 0..) |*b, i| b.* = @truncate(i);

    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "big.bin" });
    defer allocator.free(file_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = contents });

    var file = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer file.close(io);

    // Sized for exactly one CHUNK_SIZE scratch buffer plus a little
    // bookkeeping slack -- well under `size`. If `serveFileChunked` ever
    // regresses to a file-sized (or otherwise size-proportional) allocation,
    // this fixed buffer runs out and the call below fails with
    // error.OutOfMemory instead of silently passing.
    var fixed_buf: [CHUNK_SIZE + 4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed_buf);

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try serveFileChunked(fba.allocator(), io, &file, .{ .start = 0, .end = size - 1 }, &sink.writer);

    try std.testing.expectEqualSlices(u8, contents, sink.written());
}

test "serveFileChunked honors a sub-range (partial content)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents = "the quick brown fox jumps over the lazy dog";
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, "small.bin" });
    defer allocator.free(file_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = contents });

    var file = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer file.close(io);

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    // "quick brown" starts at offset 4, 11 bytes long.
    try serveFileChunked(std.testing.allocator, io, &file, .{ .start = 4, .end = 14 }, &sink.writer);
    try std.testing.expectEqualStrings("quick brown", sink.written());
}
