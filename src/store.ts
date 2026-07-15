import { create } from "zustand";
import { allScope } from "./lib/scope";
import type { Asset, Board, BoardNode, BoardScope, BoardView, Frame, FrameUpdate, ThemeMode, ViewMode } from "./types";

type CanvasState = {
  scale: number;
  offsetX: number;
  offsetY: number;
  selectedIds: string[];
  query: string;
  scope: BoardScope;
  setViewport: (scale: number, offsetX: number, offsetY: number) => void;
  select: (ids: string[]) => void;
  setQuery: (query: string) => void;
  setScope: (scope: BoardScope) => void;
};

type AppStore = CanvasState & {
  theme: ThemeMode;
  boards: Board[];
  activeBoardId: string | null;
  view: BoardView | null;
  loading: boolean;
  status: string;
  // Chrome layout — persisted like theme, global (not per-board).
  sidebarOpen: boolean;
  inspectorOpen: boolean;
  viewMode: ViewMode;
  setSidebarOpen: (open: boolean) => void;
  setInspectorOpen: (open: boolean) => void;
  setViewMode: (mode: ViewMode) => void;
  setTheme: (theme: ThemeMode) => void;
  setLoading: (loading: boolean) => void;
  setStatus: (status: string) => void;
  setInitialState: (boards: Board[], activeBoardId: string, view: BoardView) => void;
  setBoards: (boards: Board[], activeBoardId: string, view: BoardView) => void;
  setView: (view: BoardView) => void;
  // In-place replace of one asset row (e.g. a model thumbnail arriving) -- leaves nodes,
  // history, and scope untouched, so it's safe mid-drag.
  patchAsset: (asset: Asset) => void;
  renameBoard: (board: Board) => void;
  setBoardDrawing: (boardId: string, drawingJson: string) => void;
  upsertNodes: (nodes: BoardNode[]) => void;
  trashAssets: (assetIds: string[], trashedAt: string) => void;
  restoreAssets: (assetIds: string[]) => void;
  // History for reversible canvas edits — node layout (drag/arrange), asset trashing, and frame geometry.
  // Backed by update_nodes + trash_assets/restore_assets + update_frames; reset on board switch/reload.
  undoStack: HistorySnapshot[];
  redoStack: HistorySnapshot[];
  baseline: HistorySnapshot;
  commitNodes: (nodes: BoardNode[]) => void;
  undo: () => HistoryApply | null;
  redo: () => HistoryApply | null;
  // Frames — labeled group containers. upsert is live (drag preview); add/remove reset history
  // (a structural change); commitFrameMove records one history entry for a frame drag/resize + its members.
  upsertFrames: (frames: Frame[]) => void;
  addFrame: (frame: Frame) => void;
  removeFrame: (frameId: string) => void;
  commitFrameMove: (frames: Frame[], nodes: BoardNode[]) => void;
};

// A point-in-time snapshot of the reversible board state.
type HistorySnapshot = {
  nodes: BoardNode[];
  trashed: Record<string, string | null>;
  frames: FrameUpdate[];
};

// What an undo/redo produced, for the caller to persist to the backend.
export type HistoryApply = {
  nodes: BoardNode[];
  toTrash: string[];
  toRestore: string[];
  frames: FrameUpdate[];
};

const HISTORY_LIMIT = 100;
const cloneNodes = (nodes: BoardNode[]): BoardNode[] => nodes.map((node) => ({ ...node }));
const frameGeometry = (frames: Frame[]): FrameUpdate[] =>
  frames.map((frame) => ({ id: frame.id, x: frame.x, y: frame.y, width: frame.width, height: frame.height, label: frame.label }));

const snapshotView = (view: BoardView): HistorySnapshot => ({
  nodes: cloneNodes(view.nodes),
  trashed: Object.fromEntries(view.assets.map((asset) => [asset.id, asset.trashedAt ?? null])),
  frames: frameGeometry(view.frames),
});

// Restore a snapshot onto the live view: node geometry + asset trashed flags + frame geometry, matched by id.
const applySnapshotToView = (view: BoardView, snapshot: HistorySnapshot): BoardView => {
  const nodeById = new Map(snapshot.nodes.map((node) => [node.id, node]));
  const nodes = view.nodes.map((node) => nodeById.get(node.id) ?? node);
  const assets = view.assets.map((asset) =>
    asset.id in snapshot.trashed ? { ...asset, trashedAt: snapshot.trashed[asset.id] } : asset,
  );
  const frameById = new Map(snapshot.frames.map((frame) => [frame.id, frame]));
  const frames = view.frames.map((frame) => {
    const target = frameById.get(frame.id);
    return target ? { ...frame, x: target.x, y: target.y, width: target.width, height: target.height, label: target.label } : frame;
  });
  return { ...view, nodes, assets, frames };
};

// Which assets must be (un)trashed on the backend to move the live view to a target snapshot.
const trashDiff = (view: BoardView, snapshot: HistorySnapshot): { toTrash: string[]; toRestore: string[] } => {
  const toTrash: string[] = [];
  const toRestore: string[] = [];
  view.assets.forEach((asset) => {
    if (!(asset.id in snapshot.trashed)) return;
    const target = snapshot.trashed[asset.id];
    const current = asset.trashedAt ?? null;
    if (target && !current) toTrash.push(asset.id);
    else if (!target && current) toRestore.push(asset.id);
  });
  return { toTrash, toRestore };
};

const initialTheme = (): ThemeMode => {
  if (typeof localStorage === "undefined") return "dark";
  const stored = localStorage.getItem("maat.theme");
  if (stored === "light" || stored === "dark") return stored;
  return window.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
};

const initialSidebarOpen = (): boolean => {
  if (typeof localStorage === "undefined") return true;
  const stored = localStorage.getItem("maat.sidebarOpen");
  return stored === null ? true : stored === "true";
};

const initialInspectorOpen = (): boolean => {
  if (typeof localStorage === "undefined") return false;
  return localStorage.getItem("maat.inspectorOpen") === "true";
};

const initialViewMode = (): ViewMode => {
  if (typeof localStorage === "undefined") return "canvas";
  const stored = localStorage.getItem("maat.viewMode");
  return stored === "grid" || stored === "infinity" ? stored : "canvas";
};

export const useAppStore = create<AppStore>((set, get) => ({
  theme: initialTheme(),
  boards: [],
  activeBoardId: null,
  view: null,
  loading: true,
  status: "Opening Maat",
  scale: 0.82,
  offsetX: 260,
  offsetY: 132,
  selectedIds: [],
  query: "",
  scope: allScope,
  undoStack: [],
  redoStack: [],
  baseline: { nodes: [], trashed: {}, frames: [] },
  sidebarOpen: initialSidebarOpen(),
  inspectorOpen: initialInspectorOpen(),
  viewMode: initialViewMode(),
  setSidebarOpen: (open) => {
    localStorage.setItem("maat.sidebarOpen", String(open));
    set({ sidebarOpen: open });
  },
  setInspectorOpen: (open) => {
    localStorage.setItem("maat.inspectorOpen", String(open));
    set({ inspectorOpen: open });
  },
  setViewMode: (mode) => {
    localStorage.setItem("maat.viewMode", mode);
    set({ viewMode: mode });
  },
  setTheme: (theme) => {
    localStorage.setItem("maat.theme", theme);
    set({ theme });
  },
  setLoading: (loading) => set({ loading }),
  setStatus: (status) => set({ status }),
  setViewport: (scale, offsetX, offsetY) => set({ scale, offsetX, offsetY }),
  select: (selectedIds) => set({ selectedIds }),
  setQuery: (query) => set({ query }),
  setScope: (scope) => set({ scope, selectedIds: [] }),
  setInitialState: (boards, activeBoardId, view) =>
    set({
      boards,
      activeBoardId,
      view,
      scope: allScope,
      loading: false,
      status: "Ready",
      undoStack: [],
      redoStack: [],
      baseline: snapshotView(view),
    }),
  setBoards: (boards, activeBoardId, view) =>
    set({ boards, activeBoardId, view, scope: allScope, loading: false, undoStack: [], redoStack: [], baseline: snapshotView(view) }),
  setView: (view) =>
    set((state) => ({
      view,
      activeBoardId: view.board.id,
      boards: state.boards.some((board) => board.id === view.board.id)
        ? state.boards.map((board) => (board.id === view.board.id ? view.board : board))
        : [...state.boards, view.board],
      scope: state.activeBoardId === view.board.id ? state.scope : allScope,
      loading: false,
      // Reloading the same board (e.g. after an import) or switching boards both reset layout history.
      undoStack: [],
      redoStack: [],
      baseline: snapshotView(view),
    })),
  patchAsset: (asset) =>
    set((state) =>
      state.view && state.view.board.id === asset.boardId
        ? { view: { ...state.view, assets: state.view.assets.map((existing) => (existing.id === asset.id ? asset : existing)) } }
        : {},
    ),
  renameBoard: (board) =>
    set((state) => ({
      boards: state.boards.map((existing) => (existing.id === board.id ? board : existing)),
      view: state.view?.board.id === board.id ? { ...state.view, board } : state.view,
    })),
  setBoardDrawing: (boardId, drawingJson) =>
    set((state) => {
      const updatedBoards = state.boards.map((board) => (board.id === boardId ? { ...board, drawingJson } : board));
      const updatedView =
        state.view?.board.id === boardId ? { ...state.view, board: { ...state.view.board, drawingJson } } : state.view;
      return { boards: updatedBoards, view: updatedView };
    }),
  upsertNodes: (nodes) => {
    const view = get().view;
    if (!view) return;
    const byId = new Map(view.nodes.map((node) => [node.id, node]));
    nodes.forEach((node) => byId.set(node.id, node));
    set({ view: { ...view, nodes: Array.from(byId.values()) } });
  },
  trashAssets: (assetIds, trashedAt) => {
    const state = get();
    const view = state.view;
    if (!view) return;
    const targetIds = new Set(assetIds);
    const nextView = {
      ...view,
      assets: view.assets.map((asset) => (targetIds.has(asset.id) ? { ...asset, trashedAt } : asset)),
    };
    set({
      selectedIds: [],
      view: nextView,
      undoStack: [...state.undoStack, state.baseline].slice(-HISTORY_LIMIT),
      redoStack: [],
      baseline: snapshotView(nextView),
    });
  },
  restoreAssets: (assetIds) => {
    const state = get();
    const view = state.view;
    if (!view) return;
    const targetIds = new Set(assetIds);
    const nextView = {
      ...view,
      assets: view.assets.map((asset) => (targetIds.has(asset.id) ? { ...asset, trashedAt: null } : asset)),
    };
    set({
      selectedIds: [],
      view: nextView,
      undoStack: [...state.undoStack, state.baseline].slice(-HISTORY_LIMIT),
      redoStack: [],
      baseline: snapshotView(nextView),
    });
  },
  commitNodes: (nodes) => {
    const state = get();
    const view = state.view;
    if (!view) return;
    const byId = new Map(view.nodes.map((node) => [node.id, node]));
    nodes.forEach((node) => byId.set(node.id, node));
    const nextView = { ...view, nodes: Array.from(byId.values()) };
    set({
      view: nextView,
      undoStack: [...state.undoStack, state.baseline].slice(-HISTORY_LIMIT),
      redoStack: [],
      baseline: snapshotView(nextView),
    });
  },
  undo: () => {
    const state = get();
    const view = state.view;
    if (!view || state.undoStack.length === 0) return null;
    const undoStack = state.undoStack.slice();
    const previous = undoStack.pop()!;
    const diff = trashDiff(view, previous);
    const nextView = applySnapshotToView(view, previous);
    set({
      view: nextView,
      undoStack,
      redoStack: [...state.redoStack, snapshotView(view)].slice(-HISTORY_LIMIT),
      baseline: previous,
    });
    return { nodes: nextView.nodes, toTrash: diff.toTrash, toRestore: diff.toRestore, frames: previous.frames };
  },
  redo: () => {
    const state = get();
    const view = state.view;
    if (!view || state.redoStack.length === 0) return null;
    const redoStack = state.redoStack.slice();
    const next = redoStack.pop()!;
    const diff = trashDiff(view, next);
    const nextView = applySnapshotToView(view, next);
    set({
      view: nextView,
      undoStack: [...state.undoStack, snapshotView(view)].slice(-HISTORY_LIMIT),
      redoStack,
      baseline: next,
    });
    return { nodes: nextView.nodes, toTrash: diff.toTrash, toRestore: diff.toRestore, frames: next.frames };
  },
  upsertFrames: (frames) => {
    const view = get().view;
    if (!view) return;
    const byId = new Map(view.frames.map((frame) => [frame.id, frame]));
    frames.forEach((frame) => byId.set(frame.id, frame));
    set({ view: { ...view, frames: Array.from(byId.values()) } });
  },
  addFrame: (frame) => {
    const view = get().view;
    if (!view) return;
    const nextView = { ...view, frames: [...view.frames, frame] };
    // A new frame is a structural change → reset history (like an import).
    set({ view: nextView, undoStack: [], redoStack: [], baseline: snapshotView(nextView) });
  },
  removeFrame: (frameId) => {
    const view = get().view;
    if (!view) return;
    const nextView = { ...view, frames: view.frames.filter((frame) => frame.id !== frameId) };
    set({ view: nextView, undoStack: [], redoStack: [], baseline: snapshotView(nextView) });
  },
  commitFrameMove: (frames, nodes) => {
    const state = get();
    const view = state.view;
    if (!view) return;
    const framesById = new Map(view.frames.map((frame) => [frame.id, frame]));
    frames.forEach((frame) => framesById.set(frame.id, frame));
    const nodesById = new Map(view.nodes.map((node) => [node.id, node]));
    nodes.forEach((node) => nodesById.set(node.id, node));
    const nextView = { ...view, frames: Array.from(framesById.values()), nodes: Array.from(nodesById.values()) };
    set({
      view: nextView,
      undoStack: [...state.undoStack, state.baseline].slice(-HISTORY_LIMIT),
      redoStack: [],
      baseline: snapshotView(nextView),
    });
  },
}));

export function selectedAssets(view: BoardView | null, selectedIds: string[]): Asset[] {
  if (!view) return [];
  const assetById = new Map(view.assets.map((asset) => [asset.id, asset]));
  return selectedIds
    .map((nodeId) => view.nodes.find((node) => node.id === nodeId))
    .filter(Boolean)
    .map((node) => assetById.get(node!.assetId))
    .filter(Boolean) as Asset[];
}
