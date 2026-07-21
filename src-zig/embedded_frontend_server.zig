// Embedded-frontend server for the portable Windows exe.
//
// Serves the frontend build that build.zig's embeddedFrontendModule()
// compiled straight into the binary (the generated `embedded_frontend`
// module -- one @embedFile per dist/ file) over plain HTTP on 127.0.0.1,
// so the shipped exe needs no dist/ directory beside it. The webview is
// pointed here by main.zig's `App.source()` instead of at the SDK's
// file-on-disk asset origin: the SDK's Windows host resolves
// `frontend.dist` as a plain relative path against the process working
// directory (assetFilePath() in @native-sdk/cli's webview2_host.cpp, still
// true as of 0.5.4) with no embed hook anywhere in its asset pipeline, so
// files-on-disk-next-to-the-exe was previously a hard shipping
// requirement. This server is what removes it.
//
// Fixed ports, not an OS-assigned one: the origin allowlist that gates
// both webview navigation and bridge-command dispatch (main.zig's
// `app_origins`) is resolved at comptime, so a port picked at runtime
// could never be added to it. Instead `ports` below is a small
// pre-declared set -- every entry is exported (comptime-formatted) via
// `origins` and appended to `app_origins`, and `Server.start()` walks the
// set until a bind succeeds. Each running instance of the app holds one
// port for its whole lifetime, so the set's size is also the concurrent-
// instance ceiling: a fifth simultaneous instance fails to start rather
// than silently launching with a webview it isn't allowed to bridge from.
//
// Windows-only by construction (raw Winsock2, same rationale as
// server.zig's socket layer: std.Io.net's Windows backend hangs on
// accept/read -- see the comment at the top of that file). Nothing here
// is analyzed on macOS/Linux builds: main.zig only reaches
// `Server.start()` behind a comptime `builtin.os.tag == .windows` gate,
// and Zig's lazy analysis never touches the extern declarations below
// (the pure request-path helpers at the bottom, which the shared test
// suite does analyze, are platform-neutral).

const std = @import("std");
const windows = std.os.windows;
const ws2 = windows.ws2_32;
const embedded_frontend = @import("embedded_frontend");

/// The pre-declared port set (see the module comment for why it must be
/// static). Chosen from the ephemeral/private range to keep collision odds
/// with well-known services low; distinct from the Vite dev ports (1421,
/// 1499) and the smoke scripts' CDP ports (9412/9413), which share this
/// machine during development and CI.
pub const ports = [_]u16{ 47821, 47822, 47823, 47824 };

/// `http://127.0.0.1:<port>` for every entry of `ports`, formatted at
/// comptime -- main.zig appends this to `app_origins` so the allowlist and
/// the port set can never drift apart.
pub const origins: [ports.len][]const u8 = blk: {
    var out: [ports.len][]const u8 = undefined;
    for (ports, 0..) |port, i| {
        out[i] = std.fmt.comptimePrint("http://127.0.0.1:{d}", .{port});
    }
    break :blk out;
};

pub const SOCKET = usize;
const invalid_socket: SOCKET = ~@as(SOCKET, 0);

extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.c) i32;
extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.c) SOCKET;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.c) i32;
extern "ws2_32" fn bind(s: SOCKET, name: *const ws2.sockaddr.in, namelen: i32) callconv(.c) i32;
extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.c) i32;
extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*i32) callconv(.c) SOCKET;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.c) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.c) i32;
extern "ws2_32" fn htons(hostshort: u16) callconv(.c) u16;
extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.c) i32;

/// Same stall guard as server.zig's RECV_TIMEOUT_MS: without it, a client
/// that connects and never sends bytes would pin its connection thread's
/// `recv()` forever.
const RECV_TIMEOUT_MS: u32 = 5000;

pub const Server = struct {
    listen_socket: SOCKET,
    port: u16,
    thread: std.Thread,

    /// Starts the listener and its accept-loop worker thread, binding the
    /// first free entry of `ports`. The returned pointer is heap-allocated
    /// and intentionally never freed -- the server lives for the whole
    /// process lifetime, same as server.zig's file server.
    pub fn start() !*Server {
        const self = try std.heap.page_allocator.create(Server);
        errdefer std.heap.page_allocator.destroy(self);

        var wsadata: [512]u8 align(8) = undefined;
        if (WSAStartup(0x0202, &wsadata) != 0) return error.WinsockStartupFailed;

        // First free port of the set wins; every port already taken means
        // `ports.len` other live instances (or an unrelated squatter on
        // every entry) -- fail rather than launch a webview whose origin
        // the comptime allowlist doesn't cover.
        var bound: ?SOCKET = null;
        var bound_port: u16 = 0;
        for (ports) |port| {
            const sock = socket(ws2.AF.INET, ws2.SOCK.STREAM, ws2.IPPROTO.TCP);
            if (sock == invalid_socket) return error.SocketCreateFailed;
            const bind_addr: ws2.sockaddr.in = .{
                .port = htons(port),
                .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
            };
            if (bind(sock, &bind_addr, @sizeOf(ws2.sockaddr.in)) != 0) {
                _ = closesocket(sock);
                continue;
            }
            if (listen(sock, 16) != 0) {
                _ = closesocket(sock);
                continue;
            }
            bound = sock;
            bound_port = port;
            break;
        }
        const sock = bound orelse return error.NoFrontendPortAvailable;

        self.listen_socket = sock;
        self.port = bound_port;
        // NOTE (accepted, matching server.zig): a panic on this thread or
        // any per-connection thread kills the whole process -- Zig has no
        // catch_unwind equivalent to isolate a worker-thread panic.
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    fn acceptLoop(self: *Server) void {
        while (true) {
            const client = accept(self.listen_socket, null, null);
            if (client == invalid_socket) continue;

            // Best-effort, same as server.zig: a failed setsockopt just
            // means this connection lacks the stall guard.
            var timeout: u32 = RECV_TIMEOUT_MS;
            _ = setsockopt(client, ws2.SOL.SOCKET, ws2.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(u32));

            // One thread per connection -- localhost-only, serving one
            // webview's asset requests, so volume is low and a thread per
            // connection is simple and keeps one stalled client from
            // blocking the accept loop.
            const thread = std.Thread.spawn(.{}, handleConnection, .{client}) catch {
                _ = closesocket(client);
                continue;
            };
            thread.detach();
        }
    }
};

fn handleConnection(client: SOCKET) void {
    defer _ = closesocket(client);

    var request_buf: [4096]u8 = undefined;
    const n = recv(client, &request_buf, request_buf.len, 0);
    if (n <= 0) return;
    const request = request_buf[0..@intCast(n)];

    const line_end = std.mem.indexOfAny(u8, request, "\r\n") orelse request.len;
    const request_line = request[0..line_end];
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const raw_target = parts.next() orelse return;

    if (!std.mem.eql(u8, method, "GET")) {
        writeSimpleResponse(client, 404, "Not Found");
        return;
    }

    const asset_path = requestAssetPath(raw_target);

    // SPA fallback mirrors the on-disk asset origin this replaced: app.zon
    // declares `.spa_fallback = true`, and the SDK's host serves the entry
    // document for any missing path (assetWebResourceResponse in
    // webview2_host.cpp) so client-side routes deep-link correctly.
    const entry = findEntry(asset_path) orelse findEntry("index.html") orelse {
        writeSimpleResponse(client, 404, "Not Found");
        return;
    };

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ mimeTypeFor(entry.path), entry.data.len },
    ) catch return;
    if (!sendAll(client, header)) return;
    _ = sendAll(client, entry.data);
}

fn findEntry(path: []const u8) ?embedded_frontend.Entry {
    // Linear scan: dist/ is ~150 entries and every hit is followed by a
    // full response write that dwarfs the scan; a comptime map isn't worth
    // the build-graph complexity.
    for (embedded_frontend.entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

fn sendAll(client: SOCKET, data: []const u8) bool {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = send(client, data[sent..].ptr, @intCast(data.len - sent), 0);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

fn writeSimpleResponse(client: SOCKET, code: u16, text: []const u8) void {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ code, text, text.len, text },
    ) catch return;
    _ = sendAll(client, header);
}

/// Maps a raw HTTP request target onto an embedded-entry key: strips the
/// query/fragment and the leading slash, and maps the bare origin ("/") to
/// the entry document. Pure and platform-neutral so it stays testable under
/// `zig build test` on every host (the socket layer above never is).
pub fn requestAssetPath(raw_target: []const u8) []const u8 {
    const suffix_start = std.mem.indexOfAny(u8, raw_target, "?#") orelse raw_target.len;
    var path = raw_target[0..suffix_start];
    if (path.len > 0 and path[0] == '/') path = path[1..];
    if (path.len == 0) return "index.html";
    return path;
}

/// Covers exactly the asset kinds Vite emits into this app's dist/ (plus
/// html itself); anything else falls back to octet-stream, same shape as
/// server.zig's contentTypeFor.
pub fn mimeTypeFor(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    if (std.mem.eql(u8, ext, "html") or std.mem.eql(u8, ext, "htm")) return "text/html";
    if (std.mem.eql(u8, ext, "js") or std.mem.eql(u8, ext, "mjs")) return "text/javascript";
    if (std.mem.eql(u8, ext, "css")) return "text/css";
    if (std.mem.eql(u8, ext, "json")) return "application/json";
    if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, "png")) return "image/png";
    if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, "woff")) return "font/woff";
    if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, "wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
    return "application/octet-stream";
}

test "requestAssetPath maps the bare origin to the entry document" {
    try std.testing.expectEqualStrings("index.html", requestAssetPath("/"));
    try std.testing.expectEqualStrings("index.html", requestAssetPath("/?boot=1"));
}

test "requestAssetPath strips the leading slash and query/fragment" {
    try std.testing.expectEqualStrings("assets/app.js", requestAssetPath("/assets/app.js"));
    try std.testing.expectEqualStrings("assets/app.js", requestAssetPath("/assets/app.js?v=2"));
    try std.testing.expectEqualStrings("index.html", requestAssetPath("/index.html#section"));
}

test "mimeTypeFor maps the dist asset kinds and falls back to octet-stream" {
    try std.testing.expectEqualStrings("text/html", mimeTypeFor("index.html"));
    try std.testing.expectEqualStrings("text/javascript", mimeTypeFor("assets/index-4Mqw7QCc.js"));
    try std.testing.expectEqualStrings("text/css", mimeTypeFor("assets/index.css"));
    try std.testing.expectEqualStrings("font/woff2", mimeTypeFor("assets/font.woff2"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeTypeFor("favicon.svg"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeTypeFor("noextension"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeTypeFor("file.unknown"));
}

test "origins mirror the port set one-to-one" {
    try std.testing.expectEqual(ports.len, origins.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:47821", origins[0]);
}
