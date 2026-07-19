import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, MouseEvent, PointerEvent } from "react";
import {
  ArchiveRestore,
  ArrowDownAZ,
  Info,
  Maximize2,
  Minus,
  Moon,
  PanelLeft,
  PanelLeftClose,
  PencilLine,
  Redo2,
  RotateCcw,
  Search,
  Square,
  SquareDashed,
  Sun,
  Trash2,
  Undo2,
  X,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import { Canvas } from "./components/Canvas";
import { GridView } from "./components/GridView";
import { Inspector } from "./components/Inspector";
import { MaatMark } from "./components/Mark";
import { Sidebar } from "./components/Sidebar";
import { Button } from "./components/ui/Button";
import { DialogHost } from "./components/ui/Dialog";
import {
  closeWindow,
  createFrame,
  deleteBoard,
  deleteFrame,
  deleteSource,
  getAppState,
  importClipboardItems,
  importExternalUrls,
  importPaths,
  loadBoard,
  minimizeWindow,
  pickImportFolder,
  pickImportPaths,
  purgeAssets,
  renameBoard as renameBoardCommand,
  restoreAssets as restoreBoardAssets,
  startWindowDrag,
  toggleMaximizeWindow,
  trashAssets as trashBoardAssets,
  updateBoardDrawing,
  updateFrames,
  updateNodes,
} from "./lib/bridge";
import type { ClipboardImportItem } from "./lib/bridge";
import { confirmDialog } from "./lib/dialog";
import { arrangeNodes, fitViewport } from "./lib/layout";
import { queueModelThumbnails } from "./lib/modelThumbs";
import { filteredAssets, filteredNodes, scopeLabel } from "./lib/scope";
import { selectedAssets, useAppStore } from "./store";
import type { HistoryApply } from "./store";
import type { BoardNode, BoardScope, Frame, FrameUpdate, ViewMode } from "./types";

const MIN_SCALE = 0.12;
const MAX_SCALE = 2.8;
const ZOOM_IN_FACTOR = 1.12;
const ZOOM_OUT_FACTOR = 0.9;
const VIEWPORT_ANIMATION_MS = 180;
const MINIMAP_WIDTH = 198;
const MINIMAP_HEIGHT = 126;

type ViewportChangeOptions = { animate?: boolean };

const isMacLikePlatform = () => /mac|iphone|ipad|ipod/i.test(navigator.platform || navigator.userAgent);

export default function App() {
  const mainRef = useRef<HTMLElement | null>(null);
  const searchInputRef = useRef<HTMLInputElement | null>(null);
  const viewportRef = useRef({ scale: 0.82, offsetX: 260, offsetY: 132 });
  const viewportAnimationRef = useRef<number | null>(null);
  const drawingSaveTimersRef = useRef(new Map<string, number>());
  const pendingDrawingsRef = useRef(new Map<string, string>());
  const [canvasSize, setCanvasSize] = useState({ width: 1120, height: 760 });
  const [drawingMode, setDrawingMode] = useState(false);
  const [focusedNodeId, setFocusedNodeId] = useState<string | null>(null);
  const [inspectorNodeId, setInspectorNodeId] = useState<string | null>(null);
  const {
    theme,
    setTheme,
    loading,
    status,
    setStatus,
    setLoading,
    boards,
    view,
    activeBoardId,
    setInitialState,
    setBoards,
    setBoardDrawing,
    setView,
    renameBoard,
    query,
    setQuery,
    scope,
    setScope,
    scale,
    offsetX,
    offsetY,
    setViewport,
    selectedIds,
    select,
    upsertNodes,
    trashAssets,
    restoreAssets,
    commitNodes,
    undo,
    redo,
    undoStack,
    redoStack,
    upsertFrames,
    addFrame,
    removeFrame,
    commitFrameMove,
    sidebarOpen,
    setSidebarOpen,
    inspectorOpen,
    setInspectorOpen,
    viewMode,
    setViewMode,
    patchAsset,
  } = useAppStore();

  const immersive = viewMode === "infinity";

  useEffect(() => {
    document.documentElement.classList.toggle("dark", theme === "dark");
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  // 3D models import with previewStatus "fallback" (the engine can't rasterize them);
  // render their thumbnails here in the webview, one at a time, and patch results in.
  useEffect(() => {
    if (view) queueModelThumbnails(view.assets, patchAsset);
  }, [view, patchAsset]);

  useEffect(() => {
    viewportRef.current = { scale, offsetX, offsetY };
  }, [offsetX, offsetY, scale]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() !== "k" || (!event.metaKey && !event.ctrlKey) || event.altKey || event.shiftKey) return;
      event.preventDefault();
      searchInputRef.current?.focus();
      searchInputRef.current?.select();
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  // WebView2 (and Chromium generally) treats Ctrl+wheel / Ctrl+=/-/0 as a request to zoom the whole
  // page. Canvas.tsx already prevents that within its own bounds for its own zoom logic, but anywhere
  // else in the app (sidebar, header, inspector) the browser's page zoom would still fire and scale the
  // entire UI. Suppress it globally, once, at the app root — this only ever calls preventDefault, so it
  // can't affect the canvas's own ctrl+wheel zoom math.
  useEffect(() => {
    const handleWheel = (event: WheelEvent) => {
      if (event.ctrlKey) event.preventDefault();
    };
    window.addEventListener("wheel", handleWheel, { passive: false });
    return () => window.removeEventListener("wheel", handleWheel);
  }, []);

  useEffect(() => {
    const handleZoomShortcut = (event: KeyboardEvent) => {
      if ((!event.ctrlKey && !event.metaKey) || event.altKey) return;
      if (event.key === "=" || event.key === "+" || event.key === "-" || event.key === "0") {
        event.preventDefault();
      }
    };
    window.addEventListener("keydown", handleZoomShortcut);
    return () => window.removeEventListener("keydown", handleZoomShortcut);
  }, []);

  const cancelViewportAnimation = useCallback(() => {
    if (viewportAnimationRef.current === null) return;
    cancelAnimationFrame(viewportAnimationRef.current);
    viewportAnimationRef.current = null;
  }, []);

  const setViewportNow = useCallback(
    (nextScale: number, nextOffsetX: number, nextOffsetY: number) => {
      cancelViewportAnimation();
      setViewport(nextScale, nextOffsetX, nextOffsetY);
    },
    [cancelViewportAnimation, setViewport],
  );

  const setViewportAnimated = useCallback(
    (nextScale: number, nextOffsetX: number, nextOffsetY: number, options?: ViewportChangeOptions) => {
      if (!options?.animate) {
        setViewportNow(nextScale, nextOffsetX, nextOffsetY);
        return;
      }

      cancelViewportAnimation();
      const start = viewportRef.current;
      const startedAt = performance.now();

      const step = (now: number) => {
        const progress = clamp((now - startedAt) / VIEWPORT_ANIMATION_MS, 0, 1);
        const eased = easeOutCubic(progress);
        setViewport(
          lerp(start.scale, nextScale, eased),
          lerp(start.offsetX, nextOffsetX, eased),
          lerp(start.offsetY, nextOffsetY, eased),
        );
        if (progress < 1) {
          viewportAnimationRef.current = requestAnimationFrame(step);
        } else {
          viewportAnimationRef.current = null;
        }
      };

      viewportAnimationRef.current = requestAnimationFrame(step);
    },
    [cancelViewportAnimation, setViewport, setViewportNow],
  );

  useEffect(() => () => cancelViewportAnimation(), [cancelViewportAnimation]);

  useEffect(
    () => () => {
      drawingSaveTimersRef.current.forEach((timer) => window.clearTimeout(timer));
      drawingSaveTimersRef.current.clear();
    },
    [],
  );

  useEffect(() => {
    getAppState()
      .then((state) => setInitialState(state.boards, state.activeBoardId, state.view))
      .catch((error) => {
        console.error(error);
        setStatus(error instanceof Error ? error.message : "Failed to open board");
        setLoading(false);
      });
  }, [setInitialState, setLoading, setStatus]);

  useEffect(() => {
    const element = mainRef.current;
    if (!element) return;

    const updateCanvasSize = () => {
      const rect = element.getBoundingClientRect();
      setCanvasSize({ width: rect.width, height: rect.height });
    };
    updateCanvasSize();

    const observer = new ResizeObserver(updateCanvasSize);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const finishImport = async (report: Awaited<ReturnType<typeof importPaths>>) => {
    if (!view) return;
    const next = await loadBoard(view.board.id);
    setView(next);
    setStatus(
      [
        `Imported ${report.imported}`,
        `${report.skippedDuplicates} duplicate${report.skippedDuplicates === 1 ? "" : "s"} skipped`,
        report.failed > 0 ? `${report.failed} failed` : null,
      ]
        .filter(Boolean)
        .join("; "),
    );
  };

  const runImport = async (paths: string[]) => {
    if (!view || paths.length === 0) return;
    setLoading(true);
    setStatus(`Importing ${paths.length} source${paths.length === 1 ? "" : "s"}`);
    try {
      const report = await importPaths(view.board.id, paths);
      await finishImport(report);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Import failed");
    } finally {
      setLoading(false);
    }
  };

  const runExternalUrlImport = async (urls: string[]) => {
    if (!view || urls.length === 0) return;
    setLoading(true);
    setStatus(`Importing ${urls.length} remote image${urls.length === 1 ? "" : "s"}`);
    try {
      const report = await importExternalUrls(view.board.id, urls);
      await finishImport(report);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Remote import failed");
    } finally {
      setLoading(false);
    }
  };

  const runClipboardImport = async (items: ClipboardImportItem[]) => {
    if (!view || items.length === 0) return;
    setLoading(true);
    setStatus(`Importing ${items.length} pasted image${items.length === 1 ? "" : "s"}`);
    try {
      const report = await importClipboardItems(view.board.id, items);
      await finishImport(report);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Paste import failed");
    } finally {
      setLoading(false);
    }
  };

  const handleBoardChange = async (boardId: string) => {
    setLoading(true);
    setStatus("Switching board");
    try {
      await flushBoardDrawing(view?.board.id);
      const next = await loadBoard(boardId);
      setView(next);
      select([]);
      setFocusedNodeId(null);
      setInspectorNodeId(null);
      setStatus("Ready");
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not switch board");
    } finally {
      setLoading(false);
    }
  };

  const handleArrange = async () => {
    if (!view) return;
    closeSpotlight();
    const targetNodes = selectedIds.length > 0 ? view.nodes.filter((node) => selectedIds.includes(node.id)) : visibleNodes;
    const arranged = arrangeNodes(targetNodes, view.assets, []);
    commitNodes(arranged);
    await updateNodes(view.board.id, arranged.map(toNodeUpdate));
    const viewport = fitViewport(arranged.length > 0 ? arranged : targetNodes);
    setViewportAnimated(viewport.scale, viewport.offsetX, viewport.offsetY, { animate: true });
    setStatus(selectedIds.length > 0 ? "Arranged selection" : "Arranged board");
  };

  const handleFit = () => {
    if (!view) return;
    closeSpotlight();
    const nodes = selectedIds.length > 0 ? view.nodes.filter((node) => selectedIds.includes(node.id)) : visibleNodes;
    const viewport = fitViewport(nodes);
    setViewportAnimated(viewport.scale, viewport.offsetX, viewport.offsetY, { animate: true });
  };

  const handleFocusNode = (nodeId: string) => {
    if (!view) return;
    const node = view.nodes.find((item) => item.id === nodeId);
    if (!node) return;
    setFocusedNodeId(nodeId);
    setInspectorNodeId(null);
    select([nodeId]);
  };

  const handleClearFocus = () => {
    if (!focusedNodeId) return;
    setFocusedNodeId(null);
    setInspectorNodeId(null);
    select([]);
  };

  // Escape exits a focused/spotlighted asset first (Canvas, Grid, or Infinity, whichever is focused);
  // only once nothing is focused does a second Escape leave Infinity's immersive chrome-hiding and
  // return to Canvas -- otherwise the two would fight over the same keypress.
  useEffect(() => {
    const handleEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || isEditableKeyTarget(event.target)) return;
      if (focusedNodeId) {
        handleClearFocus();
        return;
      }
      if (viewMode === "infinity") setViewMode("canvas");
    };
    window.addEventListener("keydown", handleEscape);
    return () => window.removeEventListener("keydown", handleEscape);
  }, [focusedNodeId, handleClearFocus, viewMode, setViewMode]);

  const handleOpenInspector = (nodeId: string) => {
    setInspectorNodeId(nodeId);
    setInspectorOpen(true);
    select([nodeId]);
  };

  const zoomBy = (factor: number) => {
    const current = viewportRef.current;
    const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, current.scale * factor));
    const centerX = canvasSize.width / 2;
    const centerY = canvasSize.height / 2;
    const worldX = (centerX - current.offsetX) / current.scale;
    const worldY = (centerY - current.offsetY) / current.scale;
    setViewportAnimated(next, centerX - worldX * next, centerY - worldY * next, { animate: true });
  };

  const handleScopeChange = (nextScope: BoardScope) => {
    closeSpotlight();
    setScope(nextScope);
    setStatus(`Scope: ${scopeLabel(nextScope)}`);
    if (!view) return;
    const nodes = filteredNodes(view, nextScope, query);
    if (nodes.length > 0) {
      const viewport = fitViewport(nodes);
      setViewportAnimated(viewport.scale, viewport.offsetX, viewport.offsetY, { animate: true });
    }
  };

  const handleDrawingChange = useCallback(
    (boardId: string, drawingJson: string) => {
      setBoardDrawing(boardId, drawingJson);
      pendingDrawingsRef.current.set(boardId, drawingJson);
      const existingTimer = drawingSaveTimersRef.current.get(boardId);
      if (existingTimer) window.clearTimeout(existingTimer);

      const nextTimer = window.setTimeout(() => {
        drawingSaveTimersRef.current.delete(boardId);
        updateBoardDrawing(boardId, drawingJson)
          .then(() => {
            if (pendingDrawingsRef.current.get(boardId) === drawingJson) pendingDrawingsRef.current.delete(boardId);
          })
          .catch((error) => {
            console.error(error);
            setStatus(error instanceof Error ? error.message : "Could not save board drawing");
          });
      }, 350);
      drawingSaveTimersRef.current.set(boardId, nextTimer);
    },
    [setBoardDrawing, setStatus],
  );

  const flushBoardDrawing = useCallback(
    async (boardId: string | null | undefined) => {
      if (!boardId) return;
      const drawingJson = pendingDrawingsRef.current.get(boardId);
      if (drawingJson === undefined) return;

      const existingTimer = drawingSaveTimersRef.current.get(boardId);
      if (existingTimer) {
        window.clearTimeout(existingTimer);
        drawingSaveTimersRef.current.delete(boardId);
      }

      await updateBoardDrawing(boardId, drawingJson);
      if (pendingDrawingsRef.current.get(boardId) === drawingJson) pendingDrawingsRef.current.delete(boardId);
    },
    [],
  );

  const flushActiveBoardDrawing = useCallback(() => flushBoardDrawing(view?.board.id), [flushBoardDrawing, view?.board.id]);

  const closeSpotlight = useCallback(() => {
    setFocusedNodeId(null);
    setInspectorNodeId(null);
  }, []);

  const handleTrashSelection = useCallback(async () => {
    if (!view || selectedIds.length === 0) return;
    const selectedNodeIds = new Set(selectedIds);
    const assetIds = Array.from(new Set(view.nodes.filter((node) => selectedNodeIds.has(node.id)).map((node) => node.assetId)));
    if (assetIds.length === 0) return;

    closeSpotlight();
    setLoading(true);
    setStatus(`Moving ${assetIds.length} asset${assetIds.length === 1 ? "" : "s"} to trash`);
    try {
      const trashedAt = await trashBoardAssets(view.board.id, assetIds);
      trashAssets(assetIds, trashedAt);
      setStatus(`Moved ${assetIds.length} asset${assetIds.length === 1 ? "" : "s"} to trash`);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not delete selection");
    } finally {
      setLoading(false);
    }
  }, [closeSpotlight, selectedIds, setLoading, setStatus, trashAssets, view]);

  const selectedAssetIds = useCallback(() => {
    if (!view) return [];
    const selectedNodeIds = new Set(selectedIds);
    return Array.from(new Set(view.nodes.filter((node) => selectedNodeIds.has(node.id)).map((node) => node.assetId)));
  }, [selectedIds, view]);

  const handleRestoreSelection = useCallback(async () => {
    if (!view) return;
    const assetIds = selectedAssetIds();
    if (assetIds.length === 0) return;

    closeSpotlight();
    setLoading(true);
    setStatus(`Restoring ${assetIds.length} asset${assetIds.length === 1 ? "" : "s"}`);
    try {
      await restoreBoardAssets(view.board.id, assetIds);
      restoreAssets(assetIds);
      setStatus(`Restored ${assetIds.length} asset${assetIds.length === 1 ? "" : "s"}`);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not restore selection");
    } finally {
      setLoading(false);
    }
  }, [closeSpotlight, restoreAssets, selectedAssetIds, setLoading, setStatus, view]);

  // Permanent delete: removes Maat's managed copy from disk and is not undoable, so we reload the
  // board afterward (resetting history + refreshing source counts) rather than patching the store.
  const purgeAssetIds = useCallback(
    async (assetIds: string[], progress: string, done: string) => {
      if (!view || assetIds.length === 0) return;
      closeSpotlight();
      setLoading(true);
      setStatus(progress);
      try {
        await purgeAssets(view.board.id, assetIds);
        const next = await loadBoard(view.board.id);
        setView(next);
        select([]);
        setStatus(done);
      } catch (error) {
        console.error(error);
        setStatus(error instanceof Error ? error.message : "Could not delete items");
      } finally {
        setLoading(false);
      }
    },
    [closeSpotlight, select, setLoading, setStatus, setView, view],
  );

  const handlePurgeSelection = useCallback(async () => {
    const assetIds = selectedAssetIds();
    if (assetIds.length === 0) return;
    const count = `${assetIds.length} item${assetIds.length === 1 ? "" : "s"}`;
    const confirmed = await confirmDialog({
      title: "Permanently delete",
      message: `Permanently delete ${count}? This removes Maat's copy from disk and cannot be undone.`,
      confirmLabel: "Delete",
      danger: true,
    });
    if (!confirmed) return;
    await purgeAssetIds(assetIds, `Deleting ${count}`, `Permanently deleted ${count}`);
  }, [purgeAssetIds, selectedAssetIds]);

  const handleEmptyTrash = useCallback(async () => {
    if (!view) return;
    const assetIds = view.assets.filter((asset) => asset.trashedAt).map((asset) => asset.id);
    if (assetIds.length === 0) return;
    const count = `${assetIds.length} item${assetIds.length === 1 ? "" : "s"}`;
    const confirmed = await confirmDialog({
      title: "Empty trash",
      message: `Empty trash? This permanently deletes ${count} and cannot be undone.`,
      confirmLabel: "Empty trash",
      danger: true,
    });
    if (!confirmed) return;
    await purgeAssetIds(assetIds, "Emptying trash", `Emptied trash · ${count} deleted`);
  }, [purgeAssetIds, view]);

  const handleRenameBoard = async (boardId: string, name: string) => {
    const board = boards.find((candidate) => candidate.id === boardId);
    const trimmed = name.trim();
    if (!board || !trimmed || trimmed === board.name) return;
    try {
      const updated = await renameBoardCommand(boardId, trimmed);
      renameBoard(updated);
      setStatus(`Renamed to ${updated.name}`);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not rename board");
    }
  };

  const handleDeleteBoard = async (boardId: string) => {
    const board = boards.find((candidate) => candidate.id === boardId);
    if (!board) return;
    if (boards.length <= 1) {
      setStatus("Cannot delete the last board");
      return;
    }
    const confirmed = await confirmDialog({
      title: "Delete board",
      message: `Delete board "${board.name}"? This removes its Maat-managed assets and metadata.`,
      confirmLabel: "Delete",
      danger: true,
    });
    if (!confirmed) return;

    closeSpotlight();
    setLoading(true);
    setStatus(`Deleting ${board.name}`);
    try {
      const nextState = await deleteBoard(boardId);
      setBoards(nextState.boards, nextState.activeBoardId, nextState.view);
      select([]);
      setStatus(`Deleted ${board.name}`);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not delete board");
    } finally {
      setLoading(false);
    }
  };

  const handleDeleteSource = async (sourceId: string) => {
    if (!view) return;
    const source = view.sources.find((candidate) => candidate.id === sourceId);
    if (!source) return;
    const name = source.path.split(/[\\/]/).pop() || "source";
    const count = `${source.itemCount} item${source.itemCount === 1 ? "" : "s"}`;
    const confirmed = await confirmDialog({
      title: "Remove source",
      message: `Remove source "${name}"? This permanently deletes its ${count} and Maat's copies. This cannot be undone.`,
      confirmLabel: "Remove",
      danger: true,
    });
    if (!confirmed) return;

    closeSpotlight();
    setLoading(true);
    setStatus(`Removing ${name}`);
    try {
      const next = await deleteSource(view.board.id, sourceId);
      setView(next);
      select([]);
      if (scope.type === "source-folder" && scope.sourceId === sourceId) setScope({ type: "all" });
      setStatus(`Removed ${name}`);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not remove source");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    const handleDeleteKey = (event: KeyboardEvent) => {
      if (event.key !== "Delete" && event.key !== "Backspace") return;
      // In drawing mode, let Excalidraw own Delete/Backspace (deleting selected sketch elements).
      if (drawingMode) return;
      if (event.metaKey || event.ctrlKey || event.altKey || isEditableKeyTarget(event.target)) return;
      event.preventDefault();
      // In the Trash view the selection is already trashed, so Delete matches the visible
      // "Delete permanently" button (which confirms) instead of pointlessly re-trashing.
      if (scope.type === "trash") void handlePurgeSelection();
      else void handleTrashSelection();
    };

    window.addEventListener("keydown", handleDeleteKey);
    return () => window.removeEventListener("keydown", handleDeleteKey);
  }, [drawingMode, scope.type, handlePurgeSelection, handleTrashSelection]);

  const persistHistory = useCallback(
    (apply: HistoryApply | null) => {
      if (!apply) return;
      const board = useAppStore.getState().view?.board;
      if (!board) return;
      const tasks: Promise<unknown>[] = [updateNodes(board.id, apply.nodes.map(toNodeUpdate))];
      if (apply.toRestore.length > 0) tasks.push(restoreBoardAssets(board.id, apply.toRestore));
      if (apply.toTrash.length > 0) tasks.push(trashBoardAssets(board.id, apply.toTrash));
      if (apply.frames.length > 0) tasks.push(updateFrames(board.id, apply.frames));
      void Promise.all(tasks).catch((error) => {
        console.error(error);
        setStatus(error instanceof Error ? error.message : "Could not apply change");
      });
    },
    [setStatus],
  );

  const handleUndo = useCallback(() => {
    closeSpotlight();
    persistHistory(undo());
  }, [closeSpotlight, persistHistory, undo]);

  const handleRedo = useCallback(() => {
    closeSpotlight();
    persistHistory(redo());
  }, [closeSpotlight, persistHistory, redo]);

  useEffect(() => {
    const handleHistoryKey = (event: KeyboardEvent) => {
      const key = event.key.toLowerCase();
      if (key !== "z" && key !== "y") return;
      if ((!event.metaKey && !event.ctrlKey) || event.altKey) return;
      // Let Excalidraw own undo/redo while drawing, and never hijack it inside editable fields.
      if (drawingMode || isEditableKeyTarget(event.target)) return;
      event.preventDefault();
      if (key === "y" || event.shiftKey) handleRedo();
      else handleUndo();
    };

    window.addEventListener("keydown", handleHistoryKey);
    return () => window.removeEventListener("keydown", handleHistoryKey);
  }, [drawingMode, handleRedo, handleUndo]);

  const handleReset = () => {
    closeSpotlight();
    setDrawingMode(false);
    setViewportAnimated(0.82, 260, 132, { animate: true });
    select([]);
  };

  const handleAddFrame = () => {
    if (!view) return;
    closeSpotlight();
    setDrawingMode(false);
    const vp = viewportRef.current;
    const width = 520;
    const height = 360;
    const worldCenterX = (canvasSize.width / 2 - vp.offsetX) / vp.scale;
    const worldCenterY = (canvasSize.height / 2 - vp.offsetY) / vp.scale;
    const x = Math.round(worldCenterX - width / 2);
    const y = Math.round(worldCenterY - height / 2);
    createFrame(view.board.id, x, y, width, height, "Group")
      .then((frame) => {
        addFrame(frame);
        setStatus("Added frame");
      })
      .catch((error) => {
        console.error(error);
        setStatus(error instanceof Error ? error.message : "Could not add frame");
      });
  };

  const handleFrameChange = (frames: Frame[], nodes: BoardNode[], options?: { commit?: boolean }) => {
    if (!view) return;
    if (options?.commit === false) {
      upsertFrames(frames);
      if (nodes.length > 0) upsertNodes(nodes);
      return;
    }
    commitFrameMove(frames, nodes);
    const boardId = view.board.id;
    const tasks: Promise<unknown>[] = [updateFrames(boardId, frames.map(toFrameUpdate))];
    if (nodes.length > 0) tasks.push(updateNodes(boardId, nodes.map(toNodeUpdate)));
    void Promise.all(tasks).catch((error) => {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not save frame");
    });
  };

  const handleDeleteFrame = (frameId: string) => {
    if (!view) return;
    removeFrame(frameId);
    deleteFrame(view.board.id, frameId).catch((error) => {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not delete frame");
    });
  };

  const reportWindowError = (error: unknown) => {
    console.error(error);
    setStatus(error instanceof Error ? error.message : "Window action failed");
  };

  const runWindowAction = (action: () => Promise<void>) => {
    action().catch(reportWindowError);
  };

  const handleTitlebarMouseDown = (event: MouseEvent<HTMLElement>) => {
    if (event.button !== 0 || event.detail !== 1 || isInteractiveChromeTarget(event.target)) return;
    event.preventDefault();
    runWindowAction(startWindowDrag);
  };

  const handleTitlebarDoubleClick = (event: MouseEvent<HTMLElement>) => {
    if (isInteractiveChromeTarget(event.target)) return;
    event.preventDefault();
    runWindowAction(toggleMaximizeWindow);
  };

  const pickedAssets = selectedAssets(view, inspectorNodeId ? [inspectorNodeId] : []);
  const inspectorPanelOpen = inspectorOpen && !immersive;
  const immersiveInspectorOpen = inspectorOpen && immersive;
  const visibleNodes = filteredNodes(view, scope, query);
  const visibleCount = filteredAssets(view, scope, query).length;
  const currentScopeLabel = scopeLabel(scope);
  const trashCount = view?.assets.filter((asset) => asset.trashedAt).length ?? 0;
  const inTrash = scope.type === "trash";
  const useMacWindowControls = useMemo(isMacLikePlatform, []);
  const windowControls = (
    <div
      className={`window-controls ${useMacWindowControls ? "window-controls--mac" : "window-controls--windows"}`}
      data-drag-region="false"
      data-window-control
      data-testid="window-controls"
      data-platform={useMacWindowControls ? "mac" : "windows"}
    >
      {useMacWindowControls ? (
        <>
          <button
            type="button"
            aria-label="Close window"
            title="Close window"
            className="window-control window-control--mac window-control--close"
            onClick={() => runWindowAction(closeWindow)}
          />
          <button
            type="button"
            aria-label="Minimize window"
            title="Minimize window"
            className="window-control window-control--mac window-control--minimize"
            onClick={() => runWindowAction(minimizeWindow)}
          />
          <button
            type="button"
            aria-label="Maximize window"
            title="Maximize window"
            className="window-control window-control--mac window-control--maximize"
            onClick={() => runWindowAction(toggleMaximizeWindow)}
          />
        </>
      ) : (
        <>
          <button
            type="button"
            aria-label="Minimize window"
            title="Minimize window"
            className="window-control window-control--windows"
            onClick={() => runWindowAction(minimizeWindow)}
          >
            <Minus className="h-4 w-4" />
          </button>
          <button
            type="button"
            aria-label="Maximize window"
            title="Maximize window"
            className="window-control window-control--windows"
            onClick={() => runWindowAction(toggleMaximizeWindow)}
          >
            <Square className="h-3.5 w-3.5" />
          </button>
          <button
            type="button"
            aria-label="Close window"
            title="Close window"
            className="window-control window-control--windows window-control--close"
            onClick={() => runWindowAction(closeWindow)}
          >
            <X className="h-4 w-4" />
          </button>
        </>
      )}
    </div>
  );

  return (
    <div className="app-shell overflow-hidden bg-[var(--app-bg)] text-[var(--fg)]">
      <DialogHost />
      {immersive && (
        <>
          {/* The header (and its drag region) is unmounted while immersive, so keep a slim invisible
              strip along the top that still lets the window be dragged/maximized. */}
          <div
            className="absolute inset-x-0 top-0 z-40 h-2"
            data-drag-region="deep"
            onMouseDown={handleTitlebarMouseDown}
            onDoubleClick={handleTitlebarDoubleClick}
          />
          <div
            className={`absolute top-2 z-40 rounded-md border border-[var(--line)] bg-[var(--floating)] px-1 py-1 shadow-[var(--shadow-soft)] backdrop-blur ${
              useMacWindowControls ? "left-2" : "right-2"
            }`}
          >
            {windowControls}
          </div>
        </>
      )}

      <div
        className="app-grid grid h-full min-h-0"
        style={{
          gridTemplateColumns: immersive
            ? "0px minmax(0,1fr) 0px"
            : `${sidebarOpen ? 268 : 0}px minmax(0,1fr) ${inspectorOpen ? 316 : 0}px`,
          gridTemplateRows: immersive ? "0px minmax(0,1fr)" : "48px minmax(0,1fr)",
        }}
      >
        {!immersive && (
          <header
            data-drag-region="deep"
            onMouseDown={handleTitlebarMouseDown}
            onDoubleClick={handleTitlebarDoubleClick}
            className="col-span-full row-start-1 flex items-center border-b border-[var(--line)] bg-[var(--chrome)] px-3"
          >
          <div className="flex w-[252px] items-center gap-2">
            {useMacWindowControls ? windowControls : null}
            <Button
              variant="ghost"
              size="icon"
              title={sidebarOpen ? "Collapse sidebar" : "Expand sidebar"}
              aria-label={sidebarOpen ? "Collapse sidebar" : "Expand sidebar"}
              onClick={() => setSidebarOpen(!sidebarOpen)}
              className={useMacWindowControls ? "ml-3" : ""}
            >
              {sidebarOpen ? <PanelLeftClose className="h-4 w-4" /> : <PanelLeft className="h-4 w-4" />}
            </Button>
            <div className="flex items-center gap-2">
              <MaatMark className="h-[18px] w-[18px] text-[var(--fg)]" />
              <span className="font-display text-[15px] font-semibold leading-none tracking-[-0.02em]">Maat</span>
            </div>
          </div>

          <div className="flex min-w-0 flex-1 items-center justify-center">
            <div className="flex w-full max-w-[560px] items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--panel)] px-3 py-1.5">
              <Search className="h-4 w-4 text-[var(--muted)]" />
              <input
                ref={searchInputRef}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder={scope.type === "all" ? "Search board" : `Search ${currentScopeLabel.toLowerCase()}`}
                aria-keyshortcuts="Control+K Meta+K"
                className="h-6 flex-1 bg-transparent text-sm outline-none placeholder:text-[var(--muted)]"
              />
              <span className="text-xs tabular-nums text-[var(--muted)]">{visibleCount.toLocaleString()}</span>
            </div>
          </div>

          <div className="flex w-[456px] items-center justify-end gap-2">
            <Button
              variant="ghost"
              size="icon"
              title="Undo (Ctrl+Z)"
              aria-label="Undo"
              onClick={handleUndo}
              disabled={undoStack.length === 0 || loading || drawingMode}
            >
              <Undo2 className="h-4 w-4" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              title="Redo (Ctrl+Shift+Z)"
              aria-label="Redo"
              onClick={handleRedo}
              disabled={redoStack.length === 0 || loading || drawingMode}
            >
              <Redo2 className="h-4 w-4" />
            </Button>
            <div className="mx-0.5 h-5 w-px bg-[var(--line)]" aria-hidden="true" />
            <Button
              variant={drawingMode ? "secondary" : "ghost"}
              size="icon"
              title={drawingMode ? "Stop drawing" : "Draw on canvas"}
              aria-label={drawingMode ? "Stop drawing" : "Draw on canvas"}
              aria-pressed={drawingMode}
              disabled={viewMode !== "canvas"}
              onClick={() => {
                closeSpotlight();
                setDrawingMode((value) => !value);
              }}
            >
              <PencilLine className="h-4 w-4" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              title="Add group frame"
              aria-label="Add group frame"
              onClick={handleAddFrame}
              disabled={loading || viewMode !== "canvas"}
            >
              <SquareDashed className="h-4 w-4" />
            </Button>
            <Button variant="ghost" size="icon" title="Reset view" onClick={handleReset}>
              <RotateCcw className="h-4 w-4" />
            </Button>
            {inTrash && !drawingMode ? (
              <>
                {selectedIds.length > 0 && (
                  <>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Restore selected"
                      aria-label="Restore selected"
                      onClick={() => void handleRestoreSelection()}
                      disabled={loading}
                    >
                      <ArchiveRestore className="h-4 w-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Delete selected permanently"
                      aria-label="Delete selected permanently"
                      onClick={() => void handlePurgeSelection()}
                      disabled={loading}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </>
                )}
                {trashCount > 0 && (
                  <Button variant="ghost" size="sm" title="Permanently delete everything in trash" onClick={() => void handleEmptyTrash()} disabled={loading}>
                    Empty trash
                  </Button>
                )}
              </>
            ) : (
              selectedIds.length > 0 &&
              !drawingMode && (
                <Button variant="ghost" size="icon" title="Move selected to trash" onClick={() => void handleTrashSelection()} disabled={loading}>
                  <Trash2 className="h-4 w-4" />
                </Button>
              )
            )}
            <Button variant="ghost" size="icon" title="Toggle theme" onClick={() => setTheme(theme === "dark" ? "light" : "dark")}>
              {theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
            </Button>
            {!useMacWindowControls ? windowControls : null}
          </div>
          </header>
        )}

        <Sidebar
          boards={boards}
          activeBoardId={activeBoardId}
          view={view}
          scope={scope}
          loading={loading}
          collapsed={!sidebarOpen || immersive}
          onBeforeBoardChange={flushActiveBoardDrawing}
          onBoardChange={handleBoardChange}
          onRenameBoard={handleRenameBoard}
          onDeleteBoard={handleDeleteBoard}
          onDeleteSource={handleDeleteSource}
          onScopeChange={handleScopeChange}
          onImportFiles={async () => runImport(await pickImportPaths())}
          onImportFolder={async () => runImport(await pickImportFolder())}
        />

        <main ref={mainRef} className="relative row-start-2 col-start-2 min-h-0 min-w-0 overflow-hidden bg-[var(--canvas-bg)]">
          {viewMode === "grid" && view ? (
            <GridView
              view={view}
              nodes={visibleNodes}
              selectedIds={selectedIds}
              focusedNodeId={focusedNodeId}
              onSelect={select}
              onFocusNode={handleFocusNode}
              onClearFocus={handleClearFocus}
              onOpenInspector={handleOpenInspector}
            />
          ) : (
          <Canvas
            view={view}
            query={query}
            scope={scope}
            loading={loading}
            drawingMode={drawingMode}
            scale={scale}
            offsetX={offsetX}
            offsetY={offsetY}
            selectedIds={selectedIds}
            focusedNodeId={focusedNodeId}
            immersive={immersive}
            onViewportChange={setViewportAnimated}
            onSelect={select}
            onNodesChange={(nodes, options) => {
              if (!view) return;
              if (options?.commit === false) {
                upsertNodes(nodes);
                return;
              }
              commitNodes(nodes);
              updateNodes(view.board.id, nodes.map(toNodeUpdate)).catch((error) => {
                console.error(error);
                setStatus(error instanceof Error ? error.message : "Could not save board position");
              });
            }}
            onDropPaths={runImport}
            onDropExternalUrls={runExternalUrlImport}
            onPasteFiles={runClipboardImport}
            onFocusNode={handleFocusNode}
            onClearFocus={handleClearFocus}
            onOpenInspector={handleOpenInspector}
            onDrawingChange={handleDrawingChange}
            onRequestDraw={() => {
              closeSpotlight();
              setDrawingMode(true);
            }}
            onFrameChange={handleFrameChange}
            onDeleteFrame={handleDeleteFrame}
          />
          )}

          {viewMode === "canvas" && !focusedNodeId && !drawingMode && (
            <>
              <div className="absolute left-4 top-1/2 z-20 flex -translate-y-1/2 flex-col items-center gap-1 rounded-md border border-[var(--line)] bg-[var(--floating)] p-1 shadow-[var(--shadow-soft)] backdrop-blur">
                <Button variant="ghost" size="icon" title="Zoom in" onClick={() => zoomBy(ZOOM_IN_FACTOR)}>
                  <ZoomIn className="h-4 w-4" />
                </Button>
                <input
                  aria-label="Zoom"
                  type="range"
                  min={MIN_SCALE * 100}
                  max={MAX_SCALE * 100}
                  value={Math.round(scale * 100)}
                  onChange={(event) => {
                    const next = Number(event.currentTarget.value) / 100;
                    const centerX = canvasSize.width / 2;
                    const centerY = canvasSize.height / 2;
                    const current = viewportRef.current;
                    const worldX = (centerX - current.offsetX) / current.scale;
                    const worldY = (centerY - current.offsetY) / current.scale;
                    setViewportAnimated(next, centerX - worldX * next, centerY - worldY * next, { animate: true });
                  }}
                  className="vertical-zoom accent-[var(--focus)]"
                />
                <button
                  className="min-h-8 px-1 text-xs tabular-nums text-[var(--muted)]"
                  onClick={() => {
                    const current = viewportRef.current;
                    setViewportAnimated(1, current.offsetX, current.offsetY, { animate: true });
                  }}
                >
                  {Math.round(scale * 100)}%
                </button>
                <Button variant="ghost" size="icon" title="Zoom out" onClick={() => zoomBy(ZOOM_OUT_FACTOR)}>
                  <ZoomOut className="h-4 w-4" />
                </Button>
              </div>

              <CanvasNavigator
                nodes={visibleNodes}
                selectedIds={selectedIds}
                scale={scale}
                offsetX={offsetX}
                offsetY={offsetY}
                canvasSize={canvasSize}
                onViewportChange={setViewportAnimated}
                onFit={handleFit}
                onArrange={handleArrange}
              />
            </>
          )}

          {!drawingMode && (
            <div className="absolute bottom-4 left-1/2 z-30 -translate-x-1/2">
              <ViewModePill mode={viewMode} onChange={setViewMode} />
            </div>
          )}

          <Button
            variant="ghost"
            size="icon"
            title={inspectorOpen ? "Hide inspector" : "Show inspector"}
            aria-label={inspectorOpen ? "Hide inspector" : "Show inspector"}
            aria-pressed={inspectorOpen}
            onClick={() => setInspectorOpen(!inspectorOpen)}
            className="absolute bottom-4 right-4 z-40 rounded-md border border-[var(--line)] bg-[var(--floating)] shadow-[var(--shadow-soft)] backdrop-blur"
          >
            <Info className="h-4 w-4" />
          </Button>

          {/* Immersive mode collapses the docked inspector's grid column to 0px, so it floats over the
              canvas instead here -- otherwise toggling it in Infinity mode had no visible effect. */}
          {immersiveInspectorOpen && (
            <div className="absolute right-4 top-16 bottom-16 z-40 w-[300px]">
              <Inspector
                assets={pickedAssets}
                view={view}
                scale={scale}
                status={status}
                loading={loading}
                assetCount={visibleCount}
                nodeCount={visibleNodes.length}
                floating
              />
            </div>
          )}
        </main>

        {inspectorPanelOpen && (
          <Inspector
            assets={pickedAssets}
            view={view}
            scale={scale}
            status={status}
            loading={loading}
            assetCount={visibleCount}
            nodeCount={visibleNodes.length}
          />
        )}
      </div>
    </div>
  );
}

const VIEW_MODE_OPTIONS: { value: ViewMode; label: string }[] = [
  { value: "grid", label: "Grid" },
  { value: "canvas", label: "Canvas" },
  { value: "infinity", label: "Infinity" },
];

function ViewModePill({ mode, onChange }: { mode: ViewMode; onChange: (mode: ViewMode) => void }) {
  return (
    <div className="view-mode-pill" role="tablist" aria-label="View mode">
      {VIEW_MODE_OPTIONS.map((option) => (
        <button
          key={option.value}
          type="button"
          role="tab"
          aria-selected={mode === option.value}
          data-active={mode === option.value ? "true" : undefined}
          className="view-mode-pill__segment"
          onClick={() => onChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

function CanvasNavigator({
  nodes,
  selectedIds,
  scale,
  offsetX,
  offsetY,
  canvasSize,
  onViewportChange,
  onFit,
  onArrange,
}: {
  nodes: BoardNode[];
  selectedIds: string[];
  scale: number;
  offsetX: number;
  offsetY: number;
  canvasSize: { width: number; height: number };
  onViewportChange: (scale: number, offsetX: number, offsetY: number, options?: ViewportChangeOptions) => void;
  onFit: () => void;
  onArrange: () => void;
}) {
  const draggingRef = useRef(false);
  const model = useMemo(
    () => getMinimapModel(nodes, selectedIds, scale, offsetX, offsetY, canvasSize),
    [canvasSize, nodes, offsetX, offsetY, scale, selectedIds],
  );

  const panToPointer = (event: PointerEvent<HTMLDivElement>) => {
    if (!model) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const point = model.toWorld(event.clientX - rect.left, event.clientY - rect.top);
    onViewportChange(scale, canvasSize.width / 2 - point.x * scale, canvasSize.height / 2 - point.y * scale);
  };

  return (
    <div className="absolute bottom-4 left-4 z-20 rounded-md border border-[var(--line)] bg-[var(--floating)] p-1 shadow-[var(--shadow-soft)] backdrop-blur">
      <div className="mb-1 flex items-center gap-1">
        <Button variant="ghost" size="icon" title="Fit content" onClick={onFit}>
          <Maximize2 className="h-4 w-4" />
        </Button>
        <Button variant="ghost" size="icon" title="Arrange board" onClick={onArrange}>
          <ArrowDownAZ className="h-4 w-4" />
        </Button>
      </div>
      <div
        data-testid="canvas-minimap"
        className="relative cursor-crosshair overflow-hidden rounded border border-[var(--line)] bg-[var(--panel-strong)]"
        style={{ width: MINIMAP_WIDTH, height: MINIMAP_HEIGHT }}
        onPointerDown={(event) => {
          if (event.button !== 0) return;
          event.preventDefault();
          draggingRef.current = true;
          event.currentTarget.setPointerCapture(event.pointerId);
          panToPointer(event);
        }}
        onPointerMove={(event) => {
          if (draggingRef.current) panToPointer(event);
        }}
        onPointerUp={(event) => {
          draggingRef.current = false;
          event.currentTarget.releasePointerCapture(event.pointerId);
        }}
        onPointerCancel={() => {
          draggingRef.current = false;
        }}
      >
        {model?.rects.map((rect) => (
          <div
            key={rect.id}
            className={rect.selected ? "absolute bg-[var(--focus)]" : "absolute bg-[var(--muted)]"}
            style={rect.style}
          />
        ))}
        {model && <div className="absolute rounded-sm border border-[var(--focus)] bg-[var(--focus-soft)]" style={model.viewportStyle} />}
      </div>
    </div>
  );
}

function getMinimapModel(
  nodes: BoardNode[],
  selectedIds: string[],
  scale: number,
  offsetX: number,
  offsetY: number,
  canvasSize: { width: number; height: number },
) {
  if (scale <= 0 || canvasSize.width <= 0 || canvasSize.height <= 0) return null;

  const selected = new Set(selectedIds);
  const viewport = {
    x: -offsetX / scale,
    y: -offsetY / scale,
    width: canvasSize.width / scale,
    height: canvasSize.height / scale,
  };
  const boxes = nodes.map((node) => ({
    id: node.id,
    selected: selected.has(node.id),
    x: node.x,
    y: node.y,
    width: node.width,
    height: node.height,
  }));
  const boundsSource = [
    ...boxes,
    { id: "viewport", selected: false, x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height },
  ];
  const minX = Math.min(...boundsSource.map((box) => box.x));
  const minY = Math.min(...boundsSource.map((box) => box.y));
  const maxX = Math.max(...boundsSource.map((box) => box.x + box.width));
  const maxY = Math.max(...boundsSource.map((box) => box.y + box.height));
  const contentWidth = Math.max(1, maxX - minX);
  const contentHeight = Math.max(1, maxY - minY);
  const pad = Math.max(96, Math.max(contentWidth, contentHeight) * 0.08);
  const world = {
    x: minX - pad,
    y: minY - pad,
    width: contentWidth + pad * 2,
    height: contentHeight + pad * 2,
  };
  const minimapScale = Math.min(MINIMAP_WIDTH / world.width, MINIMAP_HEIGHT / world.height);
  const insetX = (MINIMAP_WIDTH - world.width * minimapScale) / 2;
  const insetY = (MINIMAP_HEIGHT - world.height * minimapScale) / 2;

  const toStyle = (box: { x: number; y: number; width: number; height: number }): CSSProperties => ({
    left: insetX + (box.x - world.x) * minimapScale,
    top: insetY + (box.y - world.y) * minimapScale,
    width: Math.max(3, box.width * minimapScale),
    height: Math.max(3, box.height * minimapScale),
  });

  return {
    rects: boxes.map((box) => ({ id: box.id, selected: box.selected, style: toStyle(box) })),
    viewportStyle: toStyle(viewport),
    toWorld: (x: number, y: number) => ({
      // Invert toStyle exactly, including the letterbox inset — otherwise clicks land offset from the pointer.
      x: world.x + (clamp(x, 0, MINIMAP_WIDTH) - insetX) / minimapScale,
      y: world.y + (clamp(y, 0, MINIMAP_HEIGHT) - insetY) / minimapScale,
    }),
  };
}

function toNodeUpdate(node: BoardNode) {
  return {
    id: node.id,
    x: node.x,
    y: node.y,
    width: node.width,
    height: node.height,
    z: node.z,
    locked: node.locked,
    arrangeGroup: node.arrangeGroup,
  };
}

function toFrameUpdate(frame: Frame): FrameUpdate {
  return { id: frame.id, x: frame.x, y: frame.y, width: frame.width, height: frame.height, label: frame.label };
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

function lerp(start: number, end: number, progress: number) {
  return start + (end - start) * progress;
}

function easeOutCubic(progress: number) {
  return 1 - (1 - progress) ** 3;
}

function isInteractiveChromeTarget(target: EventTarget) {
  return target instanceof Element && Boolean(target.closest("button, input, textarea, select, a, label, [data-window-control]"));
}

function isEditableKeyTarget(target: EventTarget | null) {
  return target instanceof Element && Boolean(target.closest("input, textarea, select, [contenteditable='true'], [contenteditable='']"));
}
