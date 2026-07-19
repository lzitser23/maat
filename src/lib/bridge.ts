import type { NativeSdkJson } from "../types/zero";
import type { AppStateDto, Asset, Board, BoardNode, BoardView, Frame, FrameUpdate, ImportReport, NodeUpdate, Source } from "../types";

export const isNative = () => typeof window !== "undefined" && Boolean(window.zero);

type UnlistenFn = () => void;

const IMPORT_JOB_POLL_INTERVAL_MS = 150;
const IMPORT_JOB_POLL_MAX_INTERVAL_MS = 1000;

function zero() {
  return window.zero!;
}

function rawInvoke<T>(command: string, payload?: Record<string, unknown>): Promise<T> {
  return zero().invoke<T>(command, payload as unknown as NativeSdkJson | undefined);
}

type BridgeSpillMarker = { __maatSpillPath: string };

function isBridgeSpillMarker(value: unknown): value is BridgeSpillMarker {
  return Boolean(
    value &&
      typeof value === "object" &&
      "__maatSpillPath" in value &&
      typeof (value as BridgeSpillMarker).__maatSpillPath === "string",
  );
}

async function invoke<T>(command: string, payload?: Record<string, unknown>): Promise<T> {
  const result = await rawInvoke<T | BridgeSpillMarker>(command, payload);
  if (!isBridgeSpillMarker(result)) return result;

  const serverInfo = await ensureServerInfo();
  const response = await fetch(`${serverInfo.assetBase}/file?p=${encodeURIComponent(result.__maatSpillPath)}`);
  if (!response.ok) throw new Error(`Could not read oversized bridge response: HTTP ${response.status}`);
  return (await response.json()) as T;
}

async function pollImportJob(jobId: string): Promise<ImportReport> {
  let delayMs = IMPORT_JOB_POLL_INTERVAL_MS;
  for (;;) {
    // A rejection here (backend dead, unknown jobId) is not caught -- it
    // propagates out of this function and rejects the import promise, same
    // as any other await. No overall timeout: large imports legitimately
    // take a long time.
    const status = await invoke<{ done: boolean; report: ImportReport | null; error: string | null }>("import_job_status", { jobId });
    if (status.done) {
      if (status.error) throw new Error(status.error);
      return status.report as ImportReport;
    }
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    delayMs = Math.min(delayMs * 2, IMPORT_JOB_POLL_MAX_INTERVAL_MS);
  }
}

type ServerInfo = { assetBase: string; uploadToken: string };

// `assetBaseCache` stays its own module-level binding (rather than folded
// into a single `serverInfo` cache object) because `assetPreviewUrl` below
// reads it synchronously on every render and must not turn into a promise
// consumer.
let assetBaseCache: string | null = null;
let uploadTokenCache: string | null = null;
let serverInfoPromise: Promise<ServerInfo> | null = null;

function ensureServerInfo(): Promise<ServerInfo> {
  if (assetBaseCache && uploadTokenCache) return Promise.resolve({ assetBase: assetBaseCache, uploadToken: uploadTokenCache });
  if (!serverInfoPromise) {
    serverInfoPromise = invoke<ServerInfo>("server_info")
      .then((info) => {
        assetBaseCache = info.assetBase;
        uploadTokenCache = info.uploadToken;
        return info;
      })
      .catch((err) => {
        // Don't cache a rejected promise forever -- clear it so the next
        // call retries instead of previews being broken for the rest of
        // the session.
        serverInfoPromise = null;
        throw err;
      });
  }
  return serverInfoPromise;
}

function ensureAssetBase(): Promise<string> {
  return ensureServerInfo().then((info) => info.assetBase);
}

export type ClipboardImportItem = {
  name: string;
  mime?: string | null;
  bytes: number[];
};

// A single clipboard item's `bytes` array encodes as JSON at roughly 3-5x
// its raw byte count (each byte becomes a decimal integer plus a comma).
// Anything larger than this per-item is uploaded via `POST /upload` instead
// (issue #2) and referenced by path.
const CLIPBOARD_UPLOAD_THRESHOLD_BYTES = 256 * 1024;

// This threshold alone does NOT bound one `import_clipboard_start` request:
// several items each under CLIPBOARD_UPLOAD_THRESHOLD_BYTES can still add up
// past the bridge's ~1 MiB request cap once encoded together. Below,
// `importClipboardItems` tracks the *actual* encoded size of the inline
// items it has built so far (not an estimate) and spills any further item
// to upload once the running total would cross this aggregate budget, even
// if that item is individually small enough to stay inline on its own.
// Comfortably under the ~1 MiB cap to leave headroom for the rest of the
// request (boardId, per-item name/mime, JSON envelope).
const CLIPBOARD_AGGREGATE_REQUEST_BUDGET_BYTES = 700 * 1024;

// Bounded response sizes (issue #4): `load_board_page` streams a board's
// assets+nodes in pages instead of one unbounded response. `board`/
// `sources`/`frames` only arrive on the first page (`cursor: null`); later
// pages carry `null` for those and just more `assets`/`nodes`. This is an
// internal wire type -- `loadBoard`/`getAppState` below merge pages back
// into the existing `BoardView`/`AppStateDto` shapes, so callers are
// unaffected.
type BoardPageDto = {
  board: Board | null;
  sources: Source[] | null;
  frames: Frame[] | null;
  assets: Asset[];
  nodes: BoardNode[];
  nextCursor: string | null;
};

async function loadBoardPaged(boardId: string): Promise<BoardView> {
  let cursor: string | null = null;
  let board: Board | null = null;
  let sources: Source[] = [];
  let frames: Frame[] = [];
  const assets: Asset[] = [];
  const nodes: BoardNode[] = [];
  for (;;) {
    const page: BoardPageDto = await invoke<BoardPageDto>("load_board_page", { boardId, cursor });
    if (page.board) board = page.board;
    if (page.sources) sources = page.sources;
    if (page.frames) frames = page.frames;
    assets.push(...page.assets);
    nodes.push(...page.nodes);
    if (!page.nextCursor) break;
    cursor = page.nextCursor;
  }
  if (!board) throw new Error("Board not found");
  return { board, sources, assets, nodes, frames };
}

export async function getAppState(): Promise<AppStateDto> {
  if (!isNative()) return { ...mockState, boards: [...mockState.boards], view: cloneBoardView(mockState.view) };
  const { boards, activeBoardId } = await invoke<{ boards: Board[]; activeBoardId: string }>("list_boards_state");
  const view = await loadBoardPaged(activeBoardId);
  await ensureAssetBase().catch(() => undefined);
  return { boards, activeBoardId, view };
}

export async function createBoard(name: string): Promise<Board> {
  if (!isNative()) {
    const board = {
      id: `mock-${Date.now()}`,
      name,
      path: `~/Maat/${name}`,
      drawingJson: "[]",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    const view = { board, sources: [], assets: [], nodes: [], frames: [] };
    mockState.boards.push(board);
    mockViews.set(board.id, view);
    mockState.activeBoardId = board.id;
    mockState.view = view;
    return board;
  }
  return invoke<Board>("create_board", { name });
}

export async function renameBoard(boardId: string, name: string): Promise<Board> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    view.board = { ...view.board, name, updatedAt: new Date().toISOString() };
    if (mockState.activeBoardId === boardId) mockState.view = view;
    mockState.boards = mockState.boards.map((board) => (board.id === boardId ? view.board : board));
    return view.board;
  }
  return invoke<Board>("rename_board", { boardId, name });
}

export async function loadBoard(boardId: string): Promise<BoardView> {
  if (!isNative()) {
    return cloneBoardView(mockViews.get(boardId) ?? mockState.view);
  }
  return loadBoardPaged(boardId);
}

export async function deleteBoard(boardId: string): Promise<AppStateDto> {
  if (!isNative()) {
    if (mockState.boards.length <= 1) throw new Error("Cannot delete the last board");
    mockState.boards = mockState.boards.filter((board) => board.id !== boardId);
    mockViews.delete(boardId);
    const nextBoard = mockState.boards[0];
    const nextView = mockViews.get(nextBoard.id);
    if (!nextView) throw new Error("No board available");
    mockState.activeBoardId = nextBoard.id;
    mockState.view = nextView;
    return { ...mockState, boards: [...mockState.boards], view: cloneBoardView(mockState.view) };
  }
  // Bounded response (issue #4 follow-up): `delete_board` now returns just
  // the new active board id, not the full unpaginated AppStateDto -- the
  // rest is composed the same way `getAppState()` already does, through
  // the existing paged `list_boards_state` + `load_board_page` commands.
  // `activeBoardId` comes from `delete_board`'s own ack (the storage
  // layer's definitive "next-oldest remaining board" choice), not from
  // `list_boards_state`'s own (arbitrary "first board") pick.
  const { activeBoardId } = await invoke<{ activeBoardId: string }>("delete_board", { boardId });
  const { boards } = await invoke<{ boards: Board[]; activeBoardId: string }>("list_boards_state");
  const view = await loadBoardPaged(activeBoardId);
  return { boards, activeBoardId, view };
}

export async function importPaths(boardId: string, paths: string[]): Promise<ImportReport> {
  if (!isNative()) {
    mockImportAssets(boardId, paths.map((path) => path.split(/[\\/]/).pop() || "Imported file"));
    return {
      imported: paths.length,
      skippedDuplicates: 0,
      failed: 0,
      sourceId: "mock-source",
      messages: ["Browser preview mode: real imports run inside the native app."],
    };
  }
  const { jobId } = await invoke<{ jobId: string }>("import_paths_start", { boardId, paths });
  return pollImportJob(jobId);
}

export async function importExternalUrls(boardId: string, urls: string[]): Promise<ImportReport> {
  if (!isNative()) {
    mockImportAssets(boardId, urls.map((url) => url.split("/").pop()?.split("?")[0] || "Remote image"));
    return {
      imported: urls.length,
      skippedDuplicates: 0,
      failed: 0,
      sourceId: "mock-url-source",
      messages: ["Browser preview mode: remote imports run inside the native app."],
    };
  }
  const { jobId } = await invoke<{ jobId: string }>("import_urls_start", { boardId, urls });
  return pollImportJob(jobId);
}

// Wire shape `import_clipboard_start` accepts: either shape, per item (see
// ingest.zig's `ClipboardItem` doc comment).
type NativeClipboardItem = {
  name: string;
  mime?: string | null;
  bytes?: number[];
  uploadPath?: string;
};

export async function importClipboardItems(boardId: string, items: ClipboardImportItem[]): Promise<ImportReport> {
  if (!isNative()) {
    mockImportAssets(boardId, items.map((item) => item.name || "Pasted image"));
    return {
      imported: items.length,
      skippedDuplicates: 0,
      failed: 0,
      sourceId: "mock-clipboard-source",
      messages: ["Browser preview mode: pasted image imports run inside the native app."],
    };
  }

  // Large payloads go through POST /upload (issue #2) so they never have to
  // be JSON-encoded as a per-byte integer array over the bridge; small ones
  // keep the original inline-bytes shape, which is cheap enough as-is --
  // except once the *aggregate* of everything staying inline in this call
  // would cross CLIPBOARD_AGGREGATE_REQUEST_BUDGET_BYTES, in which case
  // this (and every later) item spills to upload too, regardless of its own
  // individual size.
  const nativeItems: NativeClipboardItem[] = [];
  let serverInfo: ServerInfo | null = null;
  let inlineEncodedBytes = 0;
  for (const item of items) {
    const inlineCandidate: NativeClipboardItem = { name: item.name, mime: item.mime, bytes: item.bytes };
    // The actual encoded size this item would add to the request, not an
    // estimate -- cheap enough here since inline candidates are already
    // capped at CLIPBOARD_UPLOAD_THRESHOLD_BYTES raw bytes each.
    const inlineEncodedSize = JSON.stringify(inlineCandidate).length;
    const wouldExceedAggregateBudget = inlineEncodedBytes + inlineEncodedSize > CLIPBOARD_AGGREGATE_REQUEST_BUDGET_BYTES;

    if (item.bytes.length > CLIPBOARD_UPLOAD_THRESHOLD_BYTES || wouldExceedAggregateBudget) {
      if (!serverInfo) serverInfo = await ensureServerInfo();
      const blob = new Blob([new Uint8Array(item.bytes)]);
      const response = await fetch(`${serverInfo.assetBase}/upload`, {
        method: "POST",
        headers: { "X-Upload-Token": serverInfo.uploadToken },
        body: blob,
      });
      if (!response.ok) {
        throw new Error(`Clipboard upload failed for ${item.name || "pasted image"}: HTTP ${response.status}`);
      }
      const { path } = (await response.json()) as { path: string };
      nativeItems.push({ name: item.name, mime: item.mime, uploadPath: path });
    } else {
      nativeItems.push(inlineCandidate);
      inlineEncodedBytes += inlineEncodedSize;
    }
  }

  const { jobId } = await invoke<{ jobId: string }>("import_clipboard_start", { boardId, items: nativeItems });
  return pollImportJob(jobId);
}

export async function updateNodes(boardId: string, nodes: NodeUpdate[]): Promise<void> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    view.nodes = view.nodes.map((node) => {
      const update = nodes.find((candidate) => candidate.id === node.id);
      return update ? { ...node, ...update } : node;
    });
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return;
  }
  return invoke<void>("update_nodes", { boardId, nodes });
}

export async function trashAssets(boardId: string, assetIds: string[]): Promise<string> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    const trashedAt = new Date().toISOString();
    const ids = new Set(assetIds);
    view.assets = view.assets.map((asset) => (ids.has(asset.id) ? { ...asset, trashedAt } : asset));
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return trashedAt;
  }
  return invoke<string>("trash_assets", { boardId, assetIds });
}

export async function restoreAssets(boardId: string, assetIds: string[]): Promise<void> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    const ids = new Set(assetIds);
    view.assets = view.assets.map((asset) => (ids.has(asset.id) ? { ...asset, trashedAt: null } : asset));
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return;
  }
  await invoke<void>("restore_assets", { boardId, assetIds });
}

export async function purgeAssets(boardId: string, assetIds: string[]): Promise<void> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    const ids = new Set(assetIds);
    view.assets = view.assets.filter((asset) => !ids.has(asset.id));
    view.nodes = view.nodes.filter((node) => !ids.has(node.assetId));
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return;
  }
  await invoke<void>("purge_assets", { boardId, assetIds });
}

export async function deleteSource(boardId: string, sourceId: string): Promise<BoardView> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    const assetIds = new Set(view.assets.filter((asset) => asset.sourceId === sourceId).map((asset) => asset.id));
    view.sources = view.sources.filter((source) => source.id !== sourceId);
    view.assets = view.assets.filter((asset) => asset.sourceId !== sourceId);
    view.nodes = view.nodes.filter((node) => !assetIds.has(node.assetId));
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return cloneBoardView(view);
  }
  // Bounded response (issue #4 follow-up): `delete_source` now just acks
  // success; the bounded view is re-fetched through the existing
  // `load_board_page`-backed `loadBoard()`.
  await invoke<void>("delete_source", { boardId, sourceId });
  return loadBoard(boardId);
}

export async function createFrame(boardId: string, x: number, y: number, width: number, height: number, label: string): Promise<Frame> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    const frame: Frame = {
      id: `mock-frame-${Date.now()}`,
      boardId,
      x,
      y,
      width,
      height,
      label,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    view.frames = [...view.frames, frame];
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return frame;
  }
  return invoke<Frame>("create_frame", { boardId, x, y, width, height, label });
}

export async function updateFrames(boardId: string, frames: FrameUpdate[]): Promise<void> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    const byId = new Map(frames.map((frame) => [frame.id, frame]));
    view.frames = view.frames.map((frame) => {
      const update = byId.get(frame.id);
      return update ? { ...frame, ...update } : frame;
    });
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return;
  }
  await invoke<void>("update_frames", { boardId, frames });
}

export async function deleteFrame(boardId: string, frameId: string): Promise<void> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    view.frames = view.frames.filter((frame) => frame.id !== frameId);
    if (mockState.activeBoardId === boardId) mockState.view = view;
    return;
  }
  await invoke<void>("delete_frame", { boardId, frameId });
}

export async function updateBoardDrawing(boardId: string, drawingJson: string): Promise<void> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    view.board = { ...view.board, drawingJson, updatedAt: new Date().toISOString() };
    if (mockState.activeBoardId === boardId) mockState.view = view;
    mockState.boards = mockState.boards.map((board) => (board.id === boardId ? view.board : board));
    return;
  }
  return invoke<void>("update_board_drawing", { boardId, drawingJson });
}

export async function revealPath(path: string): Promise<void> {
  if (!isNative()) {
    console.info("Reveal path", path);
    return;
  }
  return invoke<void>("reveal_path", { path });
}

export async function startWindowDrag(): Promise<void> {
  if (!isNative()) return;
  await invoke<Record<string, never>>("window_start_drag", {});
}

export async function minimizeWindow(): Promise<void> {
  if (!isNative()) return;
  await invoke<Record<string, never>>("window_minimize", {});
}

export async function toggleMaximizeWindow(): Promise<void> {
  if (!isNative()) return;
  await invoke<{ maximized: boolean }>("window_toggle_maximize", {});
}

export async function closeWindow(): Promise<void> {
  if (!isNative()) return;
  await invoke<Record<string, never>>("window_close", {});
}

export async function pickImportPaths(): Promise<string[]> {
  if (!isNative()) return [];
  const result = await invoke<{ paths: string[] | null }>("dialog_open_files", {});
  return result.paths ?? [];
}

export async function pickImportFolder(): Promise<string[]> {
  if (!isNative()) return [];
  const result = await invoke<{ path: string | null }>("dialog_open_folder", {});
  return result.path ? [result.path] : [];
}

export async function listenForNativeDrops(onDrop: (paths: string[]) => void): Promise<UnlistenFn | null> {
  if (!isNative()) return null;
  return zero().on("drop:files", (detail) => {
    if (detail.paths && detail.paths.length > 0) {
      onDrop(detail.paths);
    }
  });
}

export function assetPreviewUrl(asset: Asset): string | null {
  if (asset.kind === "model") {
    // Model previews are webview-rendered PNGs (see lib/modelThumbs.ts) -- only the
    // thumbnail is an image; managedPath is the GLB itself and must never be an <img> src.
    if (asset.previewStatus !== "ready" || !asset.thumbnailPath) return null;
    if (!isNative()) return asset.thumbnailPath;
    if (!assetBaseCache) {
      void ensureAssetBase().catch(() => undefined);
      return null;
    }
    return `${assetBaseCache}/file?p=${encodeURIComponent(asset.thumbnailPath)}`;
  }
  if (asset.kind !== "image" || asset.previewStatus === "fallback") return null;
  const previewPath = asset.thumbnailPath ?? asset.managedPath;
  if (isNative()) {
    if (!previewPath) return null;
    if (!assetBaseCache) {
      // Fire-and-forget: swallow so a rejection doesn't surface as an
      // unhandled promise rejection on every render while retrying.
      void ensureAssetBase().catch(() => undefined);
      return null;
    }
    return `${assetBaseCache}/file?p=${encodeURIComponent(previewPath)}`;
  }
  return previewPath ? previewPath : mockImageDataUrl(asset);
}

// Full-resolution original (never the downscaled thumbnail) -- for the focused/spotlight view, which
// should not show the blurry thumbnail once the original is available.
export function assetOriginalUrl(asset: Asset): string | null {
  if (asset.kind !== "image" || asset.previewStatus === "fallback") return null;
  if (isNative()) {
    if (!asset.managedPath) return null;
    if (!assetBaseCache) {
      void ensureAssetBase().catch(() => undefined);
      return null;
    }
    return `${assetBaseCache}/file?p=${encodeURIComponent(asset.managedPath)}`;
  }
  return asset.managedPath ? asset.managedPath : mockImageDataUrl(asset);
}

// The raw model file (GLB/glTF) for the 3D viewer -- distinct from assetPreviewUrl, which
// for models is a rendered PNG thumbnail.
export function assetModelUrl(asset: Asset): string | null {
  if (asset.kind !== "model" || !asset.managedPath) return null;
  if (!isNative()) return asset.managedPath;
  if (!assetBaseCache) {
    void ensureAssetBase().catch(() => undefined);
    return null;
  }
  return `${assetBaseCache}/file?p=${encodeURIComponent(asset.managedPath)}`;
}

// Persists a webview-rendered preview PNG as an asset's thumbnail: uploads the bytes via
// POST /upload (same channel as oversized clipboard items), then hands the temp path to the
// engine, which moves it into the board's thumbs dir and flips previewStatus to "ready".
// Returns the updated asset row.
export async function setAssetThumbnail(boardId: string, assetId: string, png: Blob): Promise<Asset | null> {
  if (!isNative()) return null;
  const serverInfo = await ensureServerInfo();
  const response = await fetch(`${serverInfo.assetBase}/upload`, {
    method: "POST",
    headers: { "X-Upload-Token": serverInfo.uploadToken },
    body: png,
  });
  if (!response.ok) throw new Error(`Thumbnail upload failed: HTTP ${response.status}`);
  const { path } = (await response.json()) as { path: string };
  return invoke<Asset>("set_asset_thumbnail", { boardId, assetId, uploadPath: path });
}

// Persists the user-editable AI-generation prompt for an asset. Mirrors renameBoard's
// shape: the mock branch mutates the in-memory view directly; the native branch round-trips
// through the set_asset_prompt bridge command and returns the updated row.
export async function setAssetPrompt(boardId: string, assetId: string, prompt: string): Promise<Asset> {
  if (!isNative()) {
    const view = mockViews.get(boardId) ?? mockState.view;
    const updated = view.assets.map((asset) => (asset.id === assetId ? { ...asset, prompt } : asset));
    view.assets = updated;
    if (mockState.activeBoardId === boardId) mockState.view = view;
    const asset = updated.find((candidate) => candidate.id === assetId);
    if (!asset) throw new Error("Asset not found");
    return asset;
  }
  return invoke<Asset>("set_asset_prompt", { boardId, assetId, prompt });
}

const board: Board = {
  id: "mock-board",
  name: "Maat Studio",
  path: "~/Library/Application Support/Maat/boards/mock-board",
  drawingJson: "[]",
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
};

const mockDetails: Record<string, Pick<Asset, "tags" | "folders" | "note" | "sourceUrl" | "caption" | "prompt">> = {
  a1: {
    tags: ["identity", "brand", "launch"],
    folders: ["Maat", "References"],
    note: "Primary board for the product language.",
    sourceUrl: "https://example.com/maat",
    caption: null,
    prompt: null,
  },
  a2: {
    tags: ["motion", "desktop"],
    folders: ["Maat", "Inspiration"],
    note: "Zoom pacing and canvas motion reference.",
    sourceUrl: null,
    caption: null,
    prompt: null,
  },
  a9: {
    tags: ["spatial", "ui"],
    folders: ["Maat", "References"],
    note: "Large-detail still used for focus zoom checks.",
    sourceUrl: null,
    caption: null,
    prompt: null,
  },
  a10: {
    tags: ["palette", "screenshot"],
    folders: ["Maat", "Capture"],
    note: "Useful for color contrast checks.",
    sourceUrl: null,
    // Sample AI-training-dataset sidecar caption, for e2e coverage of the
    // Inspector's Caption section (see tests/e2e/app.spec.ts).
    caption: "A warm-toned palette swatch captured from a desktop wallpaper.",
    prompt: null,
  },
};

const mockAssets: Asset[] = [
  mockAsset("a1", "Eagle brand board", "image", "png", 320000, 1280, 860),
  mockAsset("a2", "Launch motion reference", "video", "mp4", 18200000, null, null),
  mockAsset("a3", "Typeface specimen", "font", "otf", 740000, null, null),
  mockAsset("a4", "Investor one-pager", "pdf", "pdf", 2100000, null, null),
  mockAsset("a5", "Mobile onboarding flow", "design", "fig", 4400000, null, null),
  mockAsset("a6", "Texture pack", "archive", "zip", 116000000, null, null),
  mockAsset("a7", "Voice memo", "audio", "wav", 9200000, null, null),
  mockAsset("a8", "Research notes", "document", "md", 46000, null, null),
  mockAsset("a9", "Spatial UI still", "image", "jpg", 920000, 1600, 900),
  mockAsset("a10", "Palette capture", "image", "webp", 180000, 960, 1200),
];

const mockNodes: BoardNode[] = mockAssets.map((asset, index) => ({
  id: `n-${asset.id}`,
  boardId: board.id,
  assetId: asset.id,
  x: (index % 4) * 258 + (index % 2) * 22,
  y: Math.floor(index / 4) * 248 + (index % 3) * 18,
  width: asset.kind === "image" ? 224 : 204,
  height: asset.width && asset.height ? Math.max(132, Math.min(322, 224 * (asset.height / asset.width))) : 166,
  z: index,
  locked: false,
  arrangeGroup: "mock",
}));

const mockState: AppStateDto = {
  boards: [board],
  activeBoardId: board.id,
  view: {
    board,
    sources: [
      {
        id: "mock-eagle",
        boardId: board.id,
        kind: "eagle",
        path: "/Design/Eagle Library.library",
        mode: "managed",
        importedAt: new Date().toISOString(),
        itemCount: mockAssets.length,
      },
    ],
    assets: mockAssets,
    nodes: mockNodes,
    frames: [],
  },
};

const mockViews = new Map<string, BoardView>([[board.id, mockState.view]]);

function mockAsset(
  id: string,
  name: string,
  kind: Asset["kind"],
  extension: string,
  size: number,
  width: number | null,
  height: number | null,
  boardId = board.id,
  sourceId = "mock-eagle",
  previewStatusOverride?: Asset["previewStatus"],
): Asset {
  const details = mockDetails[id] ?? { tags: [], folders: [], note: null, sourceUrl: null, caption: null, prompt: null };
  return {
    id,
    boardId,
    sourceId,
    name,
    originalPath: `/source/${name}.${extension}`,
    managedPath: "",
    mime: kind === "image" ? `image/${extension}` : "application/octet-stream",
    extension,
    size,
    hash: `${id}84fe83d18ad9e91b27ef0fbdcbda`,
    width,
    height,
    kind,
    previewStatus: previewStatusOverride ?? (kind === "image" ? "ready" : "fallback"),
    thumbnailPath: null,
    tags: details.tags,
    folders: details.folders,
    note: details.note,
    sourceUrl: details.sourceUrl,
    trashedAt: null,
    createdAt: new Date().toISOString(),
    metadataJson: null,
    caption: details.caption,
    prompt: details.prompt,
  };
}

function mockImportAssets(boardId: string, names: string[]) {
  const view = mockViews.get(boardId) ?? mockState.view;
  const sourceId = `mock-source-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  view.sources = [
    {
      id: sourceId,
      boardId,
      kind: "folder",
      path: `/mock/${names[0] ?? "Imported folder"}`,
      mode: "managed",
      importedAt: new Date().toISOString(),
      itemCount: names.length,
    },
    ...view.sources,
  ];

  for (const rawName of names) {
    const name = rawName || "Imported image";
    const id = `mock-import-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const extension = name.includes(".") ? name.split(".").pop() || "png" : "png";
    // Test hook: a filename containing "corrupt" simulates an undecodable
    // import (previewStatus "fallback") so e2e can cover the broken-<img>
    // regression without perturbing the other image fixtures/tests.
    const previewStatus = /corrupt/i.test(name) ? "fallback" : undefined;
    const asset = mockAsset(id, name, "image", extension, 240000, 1024, 768, boardId, sourceId, previewStatus);
    view.assets = [asset, ...view.assets];
    view.nodes = [
      {
        id: `n-${asset.id}`,
        boardId,
        assetId: asset.id,
        x: (view.nodes.length % 5) * 248,
        y: Math.floor(view.nodes.length / 5) * 220,
        width: 224,
        height: 168,
        z: view.nodes.length,
        locked: false,
        arrangeGroup: "mock",
      },
      ...view.nodes,
    ];
  }

  mockViews.set(boardId, view);
  if (mockState.activeBoardId === boardId) mockState.view = view;
}

function cloneBoardView(view: BoardView): BoardView {
  return {
    board: { ...view.board },
    sources: [...view.sources],
    assets: [...view.assets],
    nodes: [...view.nodes],
    frames: [...view.frames],
  };
}

// Placeholder art sized to the asset's own width/height (falling back to a 480×320 landscape default)
// so a portrait-metadata mock asset (e.g. "Palette capture") actually renders as a portrait image,
// not a landscape placeholder squashed into a portrait box -- needed to exercise real fit-to-viewport
// behavior for focus/spotlight in the browser preview and in e2e.
function mockImageDataUrl(asset: Asset) {
  const title = asset.name.slice(0, 22).replace(/[<&>"]/g, "");
  const width = asset.width && asset.width > 0 ? asset.width : 480;
  const height = asset.height && asset.height > 0 ? asset.height : 320;
  const short = Math.min(width, height);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><rect width="${width}" height="${height}" fill="#fff"/><rect x="${short * 0.04}" y="${short * 0.04}" width="${width - short * 0.08}" height="${height - short * 0.08}" fill="none" stroke="#000" stroke-width="4"/><path d="M${width * 0.08} ${height * 0.78} L${width * 0.33} ${height * 0.44} L${width * 0.5} ${height * 0.6} L${width * 0.62} ${height * 0.44} L${width * 0.9} ${height * 0.86}" fill="none" stroke="#000" stroke-width="${Math.max(4, short * 0.02)}" stroke-linejoin="round"/><circle cx="${width * 0.74}" cy="${height * 0.24}" r="${short * 0.09}" fill="#000"/><text x="${width * 0.08}" y="${height * 0.11}" fill="#000" font-family="Arial, sans-serif" font-size="${Math.max(14, short * 0.05)}" font-weight="700">${title}</text></svg>`;
  return `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`;
}
