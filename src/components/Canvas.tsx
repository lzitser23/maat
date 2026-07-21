import type { OrderedExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import type { ExcalidrawImperativeAPI, NormalizedZoomValue } from "@excalidraw/excalidraw/types";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type PointerEvent } from "react";
import { FileDown, Loader2, X } from "lucide-react";
import { assetIcon, assetKindLabel } from "../lib/asset";
import { assetPreviewUrl, listenForNativeDrops, type ClipboardImportItem } from "../lib/bridge";
import { formatBytes } from "../lib/format";
import { filteredNodes } from "../lib/scope";
import { FocusedAssetContent, getFocusedScale } from "./FocusedAsset";
import type { Asset, BoardNode, BoardScope, BoardView, Frame } from "../types";

// Excalidraw (plus its mermaid/katex/cytoscape dependency graph) is heavy — split it out of the
// entry chunk. The overlay still mounts as soon as the board renders (for two-way viewport sync and
// so saved sketches are visible), but the download no longer blocks the shell's first paint.
const DrawingOverlay = lazy(() => import("./DrawingOverlay"));

const FOCUS_NODE_EVENT = "maat-focus-node";
const MIN_SCALE = 0.12;
const MAX_SCALE = 2.8;
const WHEEL_ZOOM_STEP = 1.24;
const WHEEL_DELTA_STEP = 60;
const WHEEL_MAX_STEPS = 12;
const CLICK_DRAG_TOLERANCE = 4;
const SPOTLIGHT_DRIFT_PX = 120;
const FRAME_MIN = 80;

type FrameCorner = "nw" | "ne" | "sw" | "se";

type FrameDrag = {
  mode: "move" | "resize";
  corner?: FrameCorner;
  pointerId: number;
  startClientX: number;
  startClientY: number;
  startFrame: Frame;
  members: BoardNode[];
  moved: boolean;
};

type CanvasProps = {
  view: BoardView | null;
  query: string;
  scope: BoardScope;
  loading: boolean;
  drawingMode: boolean;
  scale: number;
  offsetX: number;
  offsetY: number;
  selectedIds: string[];
  focusedNodeId: string | null;
  // Immersive (Infinity view) mode: chrome is hidden elsewhere, and the spotlighted asset also shows
  // its name and "KIND · W × H" centered at the top, matching the reference's immersive spotlight.
  immersive?: boolean;
  onViewportChange: (scale: number, offsetX: number, offsetY: number, options?: { animate?: boolean }) => void;
  onSelect: (ids: string[]) => void;
  onNodesChange: (nodes: BoardNode[], options?: { commit?: boolean }) => void;
  onDropPaths: (paths: string[]) => void;
  onDropExternalUrls: (urls: string[]) => void;
  onPasteFiles: (items: ClipboardImportItem[]) => void;
  onDrawingChange: (boardId: string, drawingJson: string) => void;
  onFocusNode: (nodeId: string) => void;
  onClearFocus: () => void;
  onOpenInspector: (nodeId: string) => void;
  onRequestDraw: () => void;
  onFrameChange: (frames: Frame[], nodes: BoardNode[], options?: { commit?: boolean }) => void;
  onDeleteFrame: (frameId: string) => void;
};

type Viewport = {
  scale: number;
  offsetX: number;
  offsetY: number;
};

type DragState =
  | {
      type: "node";
      pointerId: number;
      startClientX: number;
      startClientY: number;
      startNode: BoardNode;
      latestNode: BoardNode;
      moved: boolean;
    }
  | {
      type: "pan";
      pointerId: number;
      startClientX: number;
      startClientY: number;
      startOffsetX: number;
      startOffsetY: number;
    };

export function Canvas({
  view,
  query,
  scope,
  loading,
  drawingMode,
  scale,
  offsetX,
  offsetY,
  selectedIds,
  focusedNodeId,
  immersive = false,
  onViewportChange,
  onSelect,
  onNodesChange,
  onDropPaths,
  onDropExternalUrls,
  onPasteFiles,
  onDrawingChange,
  onFocusNode,
  onClearFocus,
  onOpenInspector,
  onRequestDraw,
  onFrameChange,
  onDeleteFrame,
}: CanvasProps) {
  const [dropActive, setDropActive] = useState(false);
  const [panning, setPanning] = useState(false);
  const [editingFrameId, setEditingFrameId] = useState<string | null>(null);
  const [excalidrawApi, setExcalidrawApi] = useState<ExcalidrawImperativeAPI | null>(null);
  const [canvasSize, setCanvasSize] = useState({ width: 0, height: 0 });
  const canvasRef = useRef<HTMLDivElement | null>(null);
  const excalidrawShellRef = useRef<HTMLDivElement | null>(null);
  const dragRef = useRef<DragState | null>(null);
  const frameDragRef = useRef<FrameDrag | null>(null);
  const viewportRef = useRef<Viewport>({ scale, offsetX, offsetY });
  const transferHandlersRef = useRef({ onDropPaths, onDropExternalUrls, onPasteFiles });

  const assetById = useMemo(() => new Map(view?.assets.map((asset) => [asset.id, asset]) ?? []), [view]);
  const visibleNodes = useMemo(() => filteredNodes(view, scope, query), [query, scope, view]);
  const focusedNode = useMemo(() => visibleNodes.find((node) => node.id === focusedNodeId) ?? null, [focusedNodeId, visibleNodes]);
  const selected = useMemo(() => new Set(selectedIds), [selectedIds]);
  const isDarkTheme = document.documentElement.classList.contains("dark");
  const boardId = view?.board.id ?? "empty-board";
  const drawingJson = view?.board.drawingJson ?? "[]";
  const drawingElements = useMemo(() => parseDrawingElements(drawingJson), [drawingJson]);
  const [drawingElementCount, setDrawingElementCount] = useState(() => countLiveDrawingElements(drawingElements));
  const lastDrawingJsonRef = useRef(drawingJson);
  const excalidrawScrollX = toExcalidrawScroll(offsetX, scale);
  const excalidrawScrollY = toExcalidrawScroll(offsetY, scale);

  useEffect(() => {
    viewportRef.current = { scale, offsetX, offsetY };
  }, [offsetX, offsetY, scale]);

  // macOS WKWebView reports trackpad pinch as WebKit's proprietary gesturestart/change/end events,
  // not the ctrl+wheel Chromium synthesizes — without these listeners pinch does nothing on the
  // board while Excalidraw (which subscribes to them) still zooms in drawing mode. Chromium never
  // fires them, so this is inert on Windows. React has no onGestureChange prop; attach natively.
  useEffect(() => {
    const element = canvasRef.current;
    if (!element || drawingMode) return;

    type WebKitGestureEvent = Event & { scale: number; clientX: number; clientY: number };
    // Cumulative pinch scale is relative to the gesture's start; 0 doubles as "no active gesture".
    let baseScale = 0;

    const handleStart = (event: Event) => {
      if (event.target instanceof Element && event.target.closest("[data-model-viewer]")) return;
      event.preventDefault();
      baseScale = viewportRef.current.scale;
    };
    const handleChange = (event: Event) => {
      if (baseScale === 0) return;
      event.preventDefault();
      const gesture = event as WebKitGestureEvent;
      const current = viewportRef.current;
      const rect = element.getBoundingClientRect();
      const nextScale = clamp(baseScale * gesture.scale, MIN_SCALE, MAX_SCALE);
      const pointer = { x: gesture.clientX - rect.left, y: gesture.clientY - rect.top };
      const worldX = (pointer.x - current.offsetX) / current.scale;
      const worldY = (pointer.y - current.offsetY) / current.scale;
      onViewportChange(nextScale, pointer.x - worldX * nextScale, pointer.y - worldY * nextScale);
    };
    const handleEnd = (event: Event) => {
      event.preventDefault();
      baseScale = 0;
    };

    element.addEventListener("gesturestart", handleStart);
    element.addEventListener("gesturechange", handleChange);
    element.addEventListener("gestureend", handleEnd);
    return () => {
      element.removeEventListener("gesturestart", handleStart);
      element.removeEventListener("gesturechange", handleChange);
      element.removeEventListener("gestureend", handleEnd);
    };
  }, [drawingMode, onViewportChange]);

  useEffect(() => {
    lastDrawingJsonRef.current = drawingJson;
    setDrawingElementCount(countLiveDrawingElements(drawingElements));
  }, [boardId, drawingElements, drawingJson]);

  useEffect(() => {
    transferHandlersRef.current = { onDropPaths, onDropExternalUrls, onPasteFiles };
  }, [onDropExternalUrls, onDropPaths, onPasteFiles]);

  useEffect(() => {
    const element = canvasRef.current;
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

  useEffect(() => {
    let unlisten: (() => void) | null = null;
    let disposed = false;
    listenForNativeDrops((paths) => {
      setDropActive(false);
      onDropPaths(paths);
    }).then((cleanup) => {
      if (disposed) {
        cleanup?.();
      } else {
        unlisten = cleanup;
      }
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [onDropPaths]);

  const consumeTransferPayload = useCallback((data: DataTransfer | null) => {
    if (!data) return false;
    const payload = extractTransferPayload(data);
    if (!payload.hasContent) return false;
    const handlers = transferHandlersRef.current;
    if (payload.paths.length > 0) handlers.onDropPaths(payload.paths);
    if (payload.urls.length > 0) handlers.onDropExternalUrls(payload.urls);
    if (payload.files.length > 0) {
      void filesToClipboardItems(payload.files).then(handlers.onPasteFiles).catch(console.error);
    }
    return true;
  }, []);

  useEffect(() => {
    const handleWindowPaste = (event: ClipboardEvent) => {
      if (isEditableTransferTarget(event.target) && !hasImageFileTransferContent(event.clipboardData)) return;
      if (!consumeTransferPayload(event.clipboardData)) return;
      event.preventDefault();
      event.stopPropagation();
    };

    const handleWindowDragOver = (event: DragEvent) => {
      if (!event.dataTransfer || !hasPotentialTransferContent(event.dataTransfer)) return;
      event.preventDefault();
      setDropActive(true);
    };

    const handleWindowDrop = (event: DragEvent) => {
      setDropActive(false);
      if (!consumeTransferPayload(event.dataTransfer)) return;
      event.preventDefault();
      event.stopPropagation();
    };

    const handleWindowDragLeave = (event: DragEvent) => {
      if (!event.relatedTarget) setDropActive(false);
    };

    window.addEventListener("paste", handleWindowPaste, true);
    window.addEventListener("dragover", handleWindowDragOver, true);
    window.addEventListener("drop", handleWindowDrop, true);
    window.addEventListener("dragleave", handleWindowDragLeave, true);
    return () => {
      window.removeEventListener("paste", handleWindowPaste, true);
      window.removeEventListener("dragover", handleWindowDragOver, true);
      window.removeEventListener("drop", handleWindowDrop, true);
      window.removeEventListener("dragleave", handleWindowDragLeave, true);
    };
  }, [consumeTransferPayload]);

  useEffect(() => {
    const listener = (event: Event) => {
      const detail = (event as CustomEvent<string>).detail;
      if (detail) onFocusNode(detail);
    };
    window.addEventListener(FOCUS_NODE_EVENT, listener);
    return () => window.removeEventListener(FOCUS_NODE_EVENT, listener);
  }, [onFocusNode]);

  useEffect(() => {
    const element = excalidrawShellRef.current;
    if (!element) return;

    const scrubControls = () => scrubExcalidrawControls(element);
    scrubControls();

    const observer = new MutationObserver(scrubControls);
    observer.observe(element, {
      attributes: true,
      attributeFilter: ["aria-label", "class", "title"],
      childList: true,
      subtree: true,
    });
    return () => observer.disconnect();
  }, [excalidrawApi]);

  const handleDrop = (event: React.DragEvent) => {
    if (!consumeTransferPayload(event.dataTransfer)) return;
    event.preventDefault();
    event.stopPropagation();
    setDropActive(false);
  };

  const handlePaste = (event: React.ClipboardEvent) => {
    if (isEditableTransferTarget(event.target) && !hasImageFileTransferContent(event.clipboardData)) return;
    if (!consumeTransferPayload(event.clipboardData)) return;
    event.preventDefault();
    event.stopPropagation();
  };

  const handleWheel = (event: React.WheelEvent) => {
    // Wheel over a spotlighted 3D model dollies the model (OrbitControls' own listener),
    // not the board — this handler runs at the capture phase, so it must step aside
    // before the event ever reaches the viewer's canvas.
    if (event.target instanceof Element && event.target.closest("[data-model-viewer]")) return;
    event.preventDefault();
    const current = viewportRef.current;

    // Ctrl/Cmd + wheel (or pinch-zoom, which browsers report as ctrl+wheel) zooms, centered on the pointer.
    if (event.ctrlKey || event.metaKey) {
      const rect = event.currentTarget.getBoundingClientRect();
      const wheelSteps = clamp(-normalizedWheelDeltaY(event) / WHEEL_DELTA_STEP, -WHEEL_MAX_STEPS, WHEEL_MAX_STEPS);
      const nextScale = clamp(current.scale * WHEEL_ZOOM_STEP ** wheelSteps, MIN_SCALE, MAX_SCALE);
      const pointer = { x: event.clientX - rect.left, y: event.clientY - rect.top };
      const worldX = (pointer.x - current.offsetX) / current.scale;
      const worldY = (pointer.y - current.offsetY) / current.scale;
      onViewportChange(nextScale, pointer.x - worldX * nextScale, pointer.y - worldY * nextScale);
      return;
    }

    // Plain wheel / trackpad scroll pans the board, like any scrollable surface. Shift maps a
    // vertical mouse wheel to horizontal.
    let deltaX = event.deltaX;
    let deltaY = event.deltaY;
    if (event.shiftKey && deltaX === 0) {
      deltaX = deltaY;
      deltaY = 0;
    }
    const panX = normalizedWheelDelta(deltaX, event.deltaMode, window.innerWidth);
    const panY = normalizedWheelDelta(deltaY, event.deltaMode, window.innerHeight);
    onViewportChange(current.scale, current.offsetX - panX, current.offsetY - panY);
  };

  const handleExcalidrawChange = useCallback(
    (elements: readonly OrderedExcalidrawElement[], appState: { scrollX: number; scrollY: number; zoom: { value: number } }) => {
      if (!drawingMode) return;
      const current = viewportRef.current;
      const nextScale = clamp(appState.zoom.value, MIN_SCALE, MAX_SCALE);
      const nextOffsetX = fromExcalidrawScroll(appState.scrollX, nextScale);
      const nextOffsetY = fromExcalidrawScroll(appState.scrollY, nextScale);
      const viewportUnchanged =
        Math.abs(current.scale - nextScale) < 0.001 &&
        Math.abs(current.offsetX - nextOffsetX) < 0.5 &&
        Math.abs(current.offsetY - nextOffsetY) < 0.5;

      if (!viewportUnchanged) {
        onViewportChange(nextScale, nextOffsetX, nextOffsetY);
      }

      const nextDrawingJson = serializeDrawingElements(elements);
      setDrawingElementCount(countLiveDrawingElements(elements));
      if (view?.board.id && nextDrawingJson !== lastDrawingJsonRef.current) {
        lastDrawingJsonRef.current = nextDrawingJson;
        onDrawingChange(view.board.id, nextDrawingJson);
      }
    },
    [drawingMode, onDrawingChange, onViewportChange, view?.board.id],
  );

  // Hit-test the Excalidraw scene at a screen point → the topmost drawn element there, if any.
  const drawingElementAtClient = (clientX: number, clientY: number) => {
    const api = excalidrawApi;
    const canvas = canvasRef.current;
    if (!api || !canvas) return null;
    const rect = canvas.getBoundingClientRect();
    const state = api.getAppState();
    const zoom = state.zoom?.value || 1;
    const sceneX = (clientX - rect.left) / zoom - state.scrollX;
    const sceneY = (clientY - rect.top) / zoom - state.scrollY;
    const pad = 6 / zoom;
    const elements = api.getSceneElements();
    for (let i = elements.length - 1; i >= 0; i--) {
      const el = elements[i];
      if (sceneX >= el.x - pad && sceneX <= el.x + el.width + pad && sceneY >= el.y - pad && sceneY <= el.y + el.height + pad) {
        return el;
      }
    }
    return null;
  };

  // If a drawing sits under the pointer (and we're neither focused nor already drawing), jump into
  // drawing mode with that element selected — so sketches can be grabbed and deleted without first
  // toggling the pencil, even when they sit on top of an image.
  const tryEditDrawingAt = (event: PointerEvent<HTMLElement>) => {
    if (drawingMode || focusedNodeId || event.button !== 0) return false;
    const drawn = drawingElementAtClient(event.clientX, event.clientY);
    if (!drawn) return false;
    event.preventDefault();
    event.stopPropagation();
    onRequestDraw();
    const api = excalidrawApi;
    if (api) {
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          api.setActiveTool({ type: "selection" });
          api.updateScene({ appState: { selectedElementIds: { [drawn.id]: true } } });
        }),
      );
    }
    return true;
  };

  const handleCanvasPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    const isMiddlePan = event.button === 1;
    const isModifierPan = event.button === 0 && event.altKey;
    const isBackgroundLeft = event.button === 0 && event.target === event.currentTarget;

    // A plain left click on empty space: clear the spotlight; else, if a drawing sits under the pointer,
    // jump into drawing mode with it selected; else deselect. No panning.
    if (isBackgroundLeft && !isModifierPan) {
      event.preventDefault();
      if (focusedNodeId) {
        onClearFocus();
        return;
      }
      if (tryEditDrawingAt(event)) return;
      onSelect([]);
      return;
    }

    // Pan with middle mouse (anywhere) or Alt + left drag (the hand tool).
    if (!isMiddlePan && !isModifierPan) return;
    event.preventDefault();
    if (focusedNodeId) onClearFocus();
    event.currentTarget.setPointerCapture(event.pointerId);
    setPanning(true);
    dragRef.current = {
      type: "pan",
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startOffsetX: offsetX,
      startOffsetY: offsetY,
    };
  };

  const handleNodePointerDown = (event: PointerEvent<HTMLElement>, node: BoardNode) => {
    // Let Alt + drag bubble to the canvas so the hand tool pans even when starting over a card.
    if (event.button !== 0 || event.altKey) return;
    // A drawing on top of this card wins the click (enters drawing mode with it selected).
    if (tryEditDrawingAt(event)) return;
    event.preventDefault();
    event.stopPropagation();
    onSelect([node.id]);
    if (node.locked) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = {
      type: "node",
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startNode: node,
      latestNode: node,
      moved: false,
    };
  };

  const handlePointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;

    if (drag.type === "pan") {
      onViewportChange(scale, drag.startOffsetX + event.clientX - drag.startClientX, drag.startOffsetY + event.clientY - drag.startClientY);
      return;
    }

    const deltaX = event.clientX - drag.startClientX;
    const deltaY = event.clientY - drag.startClientY;
    if (!drag.moved && Math.hypot(deltaX, deltaY) < CLICK_DRAG_TOLERANCE) return;
    drag.moved = true;

    const nextNode = {
      ...drag.startNode,
      x: Math.round(drag.startNode.x + deltaX / scale),
      y: Math.round(drag.startNode.y + deltaY / scale),
    };
    drag.latestNode = nextNode;
    onNodesChange([nextNode], { commit: false });
  };

  const finishPointerDrag = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;

    if (drag.type === "node" && drag.moved) {
      onNodesChange([drag.latestNode], { commit: true });
    } else if (drag.type === "node") {
      onFocusNode(drag.startNode.id);
    }
    dragRef.current = null;
    setPanning(false);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  };

  // --- Group frames: screen box, membership, move/resize drag ---
  const frameBox = (frame: Frame) => ({
    left: offsetX + frame.x * scale,
    top: offsetY + frame.y * scale,
    width: frame.width * scale,
    height: frame.height * scale,
  });

  const nodeCenterInFrame = (node: BoardNode, frame: Frame) => {
    const cx = node.x + node.width / 2;
    const cy = node.y + node.height / 2;
    return cx >= frame.x && cx <= frame.x + frame.width && cy >= frame.y && cy <= frame.y + frame.height;
  };

  const computeFrameDrag = (drag: FrameDrag, event: PointerEvent<HTMLElement>): { frame: Frame; nodes: BoardNode[] } => {
    const dx = (event.clientX - drag.startClientX) / scale;
    const dy = (event.clientY - drag.startClientY) / scale;
    if (drag.mode === "move") {
      const frame = { ...drag.startFrame, x: drag.startFrame.x + dx, y: drag.startFrame.y + dy };
      const nodes = drag.members.map((node) => ({ ...node, x: Math.round(node.x + dx), y: Math.round(node.y + dy) }));
      return { frame, nodes };
    }
    let { x, y, width, height } = drag.startFrame;
    const corner = drag.corner!;
    if (corner.includes("e")) width = Math.max(FRAME_MIN, drag.startFrame.width + dx);
    if (corner.includes("s")) height = Math.max(FRAME_MIN, drag.startFrame.height + dy);
    if (corner.includes("w")) {
      width = Math.max(FRAME_MIN, drag.startFrame.width - dx);
      x = drag.startFrame.x + (drag.startFrame.width - width);
    }
    if (corner.includes("n")) {
      height = Math.max(FRAME_MIN, drag.startFrame.height - dy);
      y = drag.startFrame.y + (drag.startFrame.height - height);
    }
    return { frame: { ...drag.startFrame, x, y, width, height }, nodes: [] };
  };

  const startFrameMove = (event: PointerEvent<HTMLElement>, frame: Frame) => {
    if (event.button !== 0 || editingFrameId === frame.id) return;
    event.preventDefault();
    event.stopPropagation();
    const members = view ? view.nodes.filter((node) => nodeCenterInFrame(node, frame)) : [];
    frameDragRef.current = {
      mode: "move",
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startFrame: frame,
      members,
      moved: false,
    };
    event.currentTarget.setPointerCapture(event.pointerId);
  };

  const startFrameResize = (event: PointerEvent<HTMLElement>, frame: Frame, corner: FrameCorner) => {
    if (event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    frameDragRef.current = {
      mode: "resize",
      corner,
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startFrame: frame,
      members: [],
      moved: false,
    };
    event.currentTarget.setPointerCapture(event.pointerId);
  };

  const handleFramePointerMove = (event: PointerEvent<HTMLElement>) => {
    const drag = frameDragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    if (!drag.moved && Math.hypot(event.clientX - drag.startClientX, event.clientY - drag.startClientY) < CLICK_DRAG_TOLERANCE) return;
    drag.moved = true;
    const { frame, nodes } = computeFrameDrag(drag, event);
    onFrameChange([frame], nodes, { commit: false });
  };

  const finishFramePointerDrag = (event: PointerEvent<HTMLElement>) => {
    const drag = frameDragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    if (drag.moved) {
      const { frame, nodes } = computeFrameDrag(drag, event);
      onFrameChange([frame], nodes, { commit: true });
    }
    frameDragRef.current = null;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  };

  const commitFrameLabel = (frame: Frame, label: string) => {
    setEditingFrameId(null);
    const trimmed = label.trim();
    if (trimmed === frame.label) return;
    onFrameChange([{ ...frame, label: trimmed }], [], { commit: true });
  };

  const framePointerHandlers = {
    onPointerMove: handleFramePointerMove,
    onPointerUp: finishFramePointerDrag,
    onPointerCancel: finishFramePointerDrag,
  };

  return (
    <div
      ref={canvasRef}
      data-testid="maat-canvas"
      className="canvas-grid relative h-full w-full overflow-hidden"
      onWheelCapture={drawingMode ? undefined : handleWheel}
      onPasteCapture={handlePaste}
      onDragOverCapture={(event) => {
        if (!hasPotentialTransferContent(event.dataTransfer)) return;
        event.preventDefault();
        setDropActive(true);
      }}
      onDragLeaveCapture={() => setDropActive(false)}
      onDropCapture={handleDrop}
    >
      <div
        ref={excalidrawShellRef}
        data-testid="drawing-surface"
        data-drawing={drawingMode ? "true" : undefined}
        data-spotlight={focusedNodeId ? "true" : undefined}
        data-board-id={boardId}
        data-drawing-elements={drawingElementCount}
        data-viewport-scale={scale}
        data-viewport-offset-x={offsetX}
        data-viewport-offset-y={offsetY}
        data-excalidraw-scroll-x={excalidrawScrollX}
        data-excalidraw-scroll-y={excalidrawScrollY}
        className="excalidraw-shell absolute inset-0 z-20"
        aria-hidden={!drawingMode}
        inert={!drawingMode}
      >
        <Suspense fallback={<DrawingOverlayLoading visible={drawingMode} />}>
          <DrawingOverlay
            boardId={boardId}
            drawingMode={drawingMode}
            drawingElements={drawingElements}
            isDark={isDarkTheme}
            scrollX={excalidrawScrollX}
            scrollY={excalidrawScrollY}
            zoom={toExcalidrawZoom(scale)}
            onApiReady={setExcalidrawApi}
            onChange={handleExcalidrawChange}
          />
        </Suspense>
      </div>

      {view && !focusedNodeId && (
        <div className="pointer-events-none absolute inset-0 z-[4]">
          {view.frames.map((frame) => {
            const box = frameBox(frame);
            return (
              <div
                key={frame.id}
                className="board-frame"
                style={{ left: box.left, top: box.top, width: box.width, height: box.height }}
              />
            );
          })}
        </div>
      )}

      <div
        className={`absolute inset-0 z-10 ${panning ? "cursor-grabbing" : "cursor-default"} ${drawingMode ? "pointer-events-none" : ""}`}
        onPointerDown={handleCanvasPointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={finishPointerDrag}
        onPointerCancel={finishPointerDrag}
        onAuxClick={(event) => {
          if (event.button === 1) event.preventDefault();
        }}
      >
        {visibleNodes.map((node) => {
          const asset = assetById.get(node.assetId);
          if (!asset) return null;
          const spotlight = focusedNodeId ? (node.id === focusedNodeId ? "focused" : "dimmed") : undefined;
          return (
            <AssetCard
              key={node.id}
              asset={asset}
              node={node}
              selected={selected.has(node.id)}
              scale={scale}
              offsetX={offsetX}
              offsetY={offsetY}
              canvasSize={canvasSize}
              spotlight={spotlight}
              spotlightOffset={spotlight === "dimmed" && focusedNode ? getSpotlightOffset(node, focusedNode) : null}
              visible={nodeIntersectsViewport(node, { scale, offsetX, offsetY }, canvasSize)}
              onPointerDown={handleNodePointerDown}
              onOpenInspector={onOpenInspector}
            />
          );
        })}
      </div>

      {view && !focusedNodeId && !drawingMode && (
        <div className="pointer-events-none absolute inset-0 z-[15]">
          {view.frames.map((frame) => {
            const box = frameBox(frame);
            const editing = editingFrameId === frame.id;
            return (
              <div
                key={frame.id}
                className="frame-chrome"
                style={{ left: box.left, top: box.top, width: box.width, height: box.height }}
              >
                <div className="frame-header" onPointerDown={(event) => startFrameMove(event, frame)} {...framePointerHandlers} onDoubleClick={() => setEditingFrameId(frame.id)}>
                  {editing ? (
                    <input
                      className="frame-header__input"
                      autoFocus
                      defaultValue={frame.label}
                      onPointerDown={(event) => event.stopPropagation()}
                      onBlur={(event) => commitFrameLabel(frame, event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") {
                          event.preventDefault();
                          event.currentTarget.blur();
                        } else if (event.key === "Escape") {
                          event.preventDefault();
                          setEditingFrameId(null);
                        }
                      }}
                    />
                  ) : (
                    <span className="frame-header__label">{frame.label || "Group"}</span>
                  )}
                  <button
                    type="button"
                    className="frame-header__delete"
                    title="Delete frame"
                    aria-label="Delete frame"
                    onPointerDown={(event) => event.stopPropagation()}
                    onClick={(event) => {
                      event.stopPropagation();
                      onDeleteFrame(frame.id);
                    }}
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </div>
                {(["nw", "ne", "sw", "se"] as FrameCorner[]).map((corner) => (
                  <div
                    key={corner}
                    className={`frame-handle frame-handle--${corner}`}
                    onPointerDown={(event) => startFrameResize(event, frame, corner)}
                    {...framePointerHandlers}
                  />
                ))}
              </div>
            );
          })}
        </div>
      )}

      {focusedNode && immersive && (
        <div data-testid="spotlight-meta" className="pointer-events-none absolute inset-x-0 top-6 z-30 flex flex-col items-center gap-1 text-center">
          <div className="text-sm font-semibold text-[var(--fg)]">{assetById.get(focusedNode.assetId)?.name}</div>
          <div className="font-mono text-[11px] uppercase tracking-[0.14em] text-[var(--muted)]">
            {spotlightMetaLine(assetById.get(focusedNode.assetId))}
          </div>
        </div>
      )}

      {!view && !loading && <EmptyState title="No board" description="Create a board to begin collecting." />}

      {view && view.assets.length === 0 && !loading && (
        <EmptyState title="Drop anything" description="Import an Eagle library, screenshots, files, PDFs, videos, fonts, and folders." />
      )}

      {view && view.assets.length > 0 && visibleNodes.length === 0 && !loading && (
        <EmptyState title="No matches" description="Clear the search or switch scope to see more assets." />
      )}

      {loading && (
        // Sits well above the Grid/Canvas/Infinity mode-switcher pill (also bottom-center, z-30) so the
        // two never fight for the same z-index at the same spot -- this one wins visibility outright.
        <div className="absolute bottom-20 left-1/2 z-40 flex -translate-x-1/2 items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--floating)] px-3 py-2 text-sm shadow-[var(--shadow-soft)] backdrop-blur">
          <Loader2 className="h-4 w-4 animate-spin text-[var(--muted)]" />
          Working
        </div>
      )}

      {dropActive && (
        <div className="absolute inset-4 z-30 flex items-center justify-center rounded-lg border border-dashed border-[var(--focus)] bg-[var(--drop)] text-sm font-medium">
          <FileDown className="mr-2 h-5 w-5" />
          Drop to import into this board
        </div>
      )}
    </div>
  );
}

function AssetCard({
  asset,
  node,
  selected,
  scale,
  offsetX,
  offsetY,
  canvasSize,
  spotlight,
  spotlightOffset,
  visible,
  onPointerDown,
  onOpenInspector,
}: {
  asset: Asset;
  node: BoardNode;
  selected: boolean;
  scale: number;
  offsetX: number;
  offsetY: number;
  canvasSize: { width: number; height: number };
  spotlight?: "focused" | "dimmed";
  spotlightOffset: { x: number; y: number } | null;
  visible: boolean;
  onPointerDown: (event: PointerEvent<HTMLElement>, node: BoardNode) => void;
  onOpenInspector: (nodeId: string) => void;
}) {
  const Icon = assetIcon(asset.kind);
  const focused = spotlight === "focused";
  const previewUrl = assetPreviewUrl(asset);

  const focusedScale = getFocusedScale(node, canvasSize);
  const effectiveScale = focused ? focusedScale : scale;
  const left =
    focused && canvasSize.width > 0
      ? (canvasSize.width - node.width * effectiveScale) / 2
      : offsetX + node.x * scale + (spotlightOffset?.x ?? 0);
  const top =
    focused && canvasSize.height > 0
      ? (canvasSize.height - node.height * effectiveScale) / 2
      : offsetY + node.y * scale + (spotlightOffset?.y ?? 0);
  // Focused card is sized to its final pixel dimensions directly (translate only, no CSS `scale`)
  // instead of the regular grid's translate+scale transform. Scaling the whole card would also scale
  // the overlay chrome inside it (the inspect button); counter-scaling that button back down is a
  // scale-up-then-scale-down round trip that visibly blurs it and displaces its position on some
  // compositors (observed on macOS/WebKit) -- sizing directly avoids the round trip entirely.
  const style: CSSProperties = focused
    ? {
        width: node.width * effectiveScale,
        height: node.height * effectiveScale,
        transform: `translate(${left}px, ${top}px)`,
        visibility: visible ? "visible" : "hidden",
        zIndex: 10000,
      }
    : {
        width: node.width,
        height: node.height,
        transform: `translate(${left}px, ${top}px) scale(${effectiveScale})`,
        transformOrigin: "top left",
        visibility: visible ? "visible" : "hidden",
        zIndex: node.z,
      };

  return (
    <article
      className="asset-card absolute select-none overflow-hidden rounded-md border border-transparent bg-transparent shadow-none transition-colors"
      data-selected={selected ? "true" : undefined}
      data-spotlight={spotlight}
      style={style}
      onPointerDown={(event) => onPointerDown(event, node)}
      onDoubleClick={(event) => {
        event.stopPropagation();
        window.dispatchEvent(new CustomEvent(FOCUS_NODE_EVENT, { detail: node.id }));
      }}
    >
      {focused ? (
        <FocusedAssetContent asset={asset} onOpenInspector={() => onOpenInspector(node.id)} />
      ) : (
        <div className="relative flex h-full flex-col">
          <div className="asset-card__media min-h-0 flex-1 overflow-hidden bg-[var(--asset-media)]">
            {previewUrl ? (
              <img
                src={previewUrl}
                alt=""
                // Model thumbnails are square renders on a transparent background — cropping
                // them with object-cover lops off the model itself.
                className={`h-full w-full ${asset.kind === "model" ? "object-contain" : "object-cover"}`}
                draggable={false}
              />
            ) : (
              <div className="flex h-full w-full flex-col items-center justify-center gap-3 p-5 text-center">
                <div className="flex h-14 w-14 items-center justify-center rounded-md border border-[var(--line)] bg-[var(--panel)]">
                  <Icon className="h-7 w-7 text-[var(--muted)]" />
                </div>
                <div>
                  <div className="text-sm font-semibold">{assetKindLabel(asset.kind)}</div>
                  <div className="mt-1 text-xs text-[var(--muted)]">{asset.extension || "file"}</div>
                </div>
              </div>
            )}
          </div>
          <div className="asset-card__footer bg-[var(--asset-footer)] px-1.5 pb-0 pt-2">
            <div className="truncate text-sm font-medium">{asset.name}</div>
            <div className="mt-0.5 flex items-center justify-between text-[10px] uppercase tracking-[0.08em] text-[var(--muted)]">
              <span>{assetKindLabel(asset.kind)}</span>
              <span>{formatBytes(asset.size)}</span>
            </div>
          </div>
        </div>
      )}
    </article>
  );
}

function EmptyState({ title, description }: { title: string; description: string }) {
  return (
    <div className="absolute left-1/2 top-1/2 z-20 w-[360px] -translate-x-1/2 -translate-y-1/2 rounded-lg border border-[var(--line)] bg-[var(--floating)] p-6 text-center shadow-[var(--shadow-soft)]">
      <div className="text-lg font-semibold">{title}</div>
      <p className="mt-2 text-sm leading-6 text-[var(--muted)]">{description}</p>
    </div>
  );
}

// Shown in place of Excalidraw while its chunk is still downloading. Only meaningfully visible once
// drawing mode is entered (otherwise the shell is pointer-events:none and mostly invisible anyway, so
// no need to flash a loader on every board load).
function DrawingOverlayLoading({ visible }: { visible: boolean }) {
  if (!visible) return null;
  return (
    <div data-testid="drawing-surface-loading" className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center">
      <div className="flex items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--floating)] px-3 py-2 text-sm text-[var(--muted)] shadow-[var(--shadow-soft)]">
        <Loader2 className="h-4 w-4 animate-spin" />
        Loading drawing tools
      </div>
    </div>
  );
}

function extractTransferPayload(data: DataTransfer) {
  const files = Array.from(data.files);
  const paths = files
    .map((file) => (file as File & { path?: string }).path)
    .filter(Boolean) as string[];
  const blobFiles = files.filter((file) => !(file as File & { path?: string }).path && file.type.startsWith("image/"));
  const urls = uniqueUrls([
    ...extractUrls(data.getData("text/uri-list")),
    ...extractUrls(data.getData("text/plain")),
    ...extractHtmlImageUrls(data.getData("text/html")),
  ]);

  return {
    paths,
    files: blobFiles,
    urls,
    hasContent: paths.length > 0 || blobFiles.length > 0 || urls.length > 0,
  };
}

function hasPotentialTransferContent(data: DataTransfer) {
  if (data.files.length > 0) return true;
  return Array.from(data.types).some((type) => type === "Files" || type === "text/uri-list" || type === "text/plain" || type === "text/html");
}

function hasImageFileTransferContent(data: DataTransfer | null) {
  if (!data) return false;
  return Array.from(data.files).some((file) => file.type.startsWith("image/"));
}

function isEditableTransferTarget(target: EventTarget | null) {
  return target instanceof Element && Boolean(target.closest("input, textarea, select, [contenteditable='true'], [contenteditable='']"));
}

function extractUrls(raw: string) {
  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"))
    .flatMap((line) => line.split(/\s+/))
    .map(toHttpUrl)
    .filter(Boolean) as string[];
}

function extractHtmlImageUrls(html: string) {
  if (!html.trim()) return [];
  const urls: string[] = [];
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("img[src], source[srcset], meta[property='og:image'][content]").forEach((node) => {
    if (node instanceof HTMLImageElement) urls.push(node.src);
    if (node instanceof HTMLSourceElement) urls.push(...node.srcset.split(",").map((item) => item.trim().split(/\s+/)[0]));
    if (node instanceof HTMLMetaElement) urls.push(node.content);
  });
  const regex = /https?:\/\/[^"'<> ]+\.(?:png|jpe?g|gif|webp|avif)(?:\?[^"'<> ]*)?/gi;
  for (const match of html.matchAll(regex)) urls.push(match[0]);
  return urls.map(toHttpUrl).filter(Boolean) as string[];
}

function toHttpUrl(raw: string) {
  try {
    const url = new URL(raw.trim());
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function uniqueUrls(urls: string[]) {
  return Array.from(new Set(urls));
}

async function filesToClipboardItems(files: File[]): Promise<ClipboardImportItem[]> {
  return Promise.all(
    files.map(async (file, index) => ({
      name: file.name || `pasted-image-${Date.now()}-${index}.${extensionFromMime(file.type)}`,
      mime: file.type || null,
      bytes: Array.from(new Uint8Array(await file.arrayBuffer())),
    })),
  );
}

function extensionFromMime(mime: string) {
  switch (mime) {
    case "image/jpeg":
      return "jpg";
    case "image/gif":
      return "gif";
    case "image/webp":
      return "webp";
    case "image/avif":
      return "avif";
    default:
      return "png";
  }
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

function normalizedWheelDeltaY(event: React.WheelEvent) {
  if (event.deltaMode === 1) return event.deltaY * 40;
  if (event.deltaMode === 2) return event.deltaY * window.innerHeight;
  return event.deltaY;
}

// Normalize a wheel delta to pixels regardless of deltaMode (pixels / lines / pages).
function normalizedWheelDelta(delta: number, deltaMode: number, pageSize: number) {
  if (deltaMode === 1) return delta * 40;
  if (deltaMode === 2) return delta * pageSize;
  return delta;
}

function toExcalidrawZoom(value: number) {
  return { value: clamp(value, MIN_SCALE, MAX_SCALE) as NormalizedZoomValue };
}

function toExcalidrawScroll(offset: number, scale: number) {
  return scale === 0 ? 0 : offset / scale;
}

function fromExcalidrawScroll(scroll: number, scale: number) {
  return scroll * scale;
}

function parseDrawingElements(raw: string): readonly OrderedExcalidrawElement[] {
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as OrderedExcalidrawElement[]) : [];
  } catch {
    return [];
  }
}

function serializeDrawingElements(elements: readonly OrderedExcalidrawElement[]) {
  return JSON.stringify(elements);
}

function countLiveDrawingElements(elements: readonly OrderedExcalidrawElement[]) {
  return elements.filter((element) => !element.isDeleted).length;
}

function nodeIntersectsViewport(node: BoardNode, viewport: Viewport, canvasSize: { width: number; height: number }) {
  if (canvasSize.width <= 0 || canvasSize.height <= 0) return true;
  const margin = 96;
  const left = viewport.offsetX + node.x * viewport.scale;
  const top = viewport.offsetY + node.y * viewport.scale;
  const right = left + node.width * viewport.scale;
  const bottom = top + node.height * viewport.scale;
  return right >= -margin && bottom >= -margin && left <= canvasSize.width + margin && top <= canvasSize.height + margin;
}

function getSpotlightOffset(node: BoardNode, focusedNode: BoardNode) {
  const nodeCenterX = node.x + node.width / 2;
  const nodeCenterY = node.y + node.height / 2;
  const focusedCenterX = focusedNode.x + focusedNode.width / 2;
  const focusedCenterY = focusedNode.y + focusedNode.height / 2;
  const deltaX = nodeCenterX - focusedCenterX;
  const deltaY = nodeCenterY - focusedCenterY;
  const distance = Math.hypot(deltaX, deltaY) || 1;
  return {
    x: (deltaX / distance) * SPOTLIGHT_DRIFT_PX,
    y: (deltaY / distance) * SPOTLIGHT_DRIFT_PX,
  };
}

function spotlightMetaLine(asset: Asset | undefined) {
  if (!asset) return "";
  const label = assetKindLabel(asset.kind);
  return asset.width && asset.height ? `${label} · ${asset.width} × ${asset.height}` : label;
}

function scrubExcalidrawControls(element: HTMLElement) {
  element.querySelectorAll<HTMLElement>(".zoom-button").forEach((control) => {
    if (control.getAttribute("aria-hidden") !== "true") control.setAttribute("aria-hidden", "true");
    if (control.hasAttribute("aria-label")) control.removeAttribute("aria-label");
    if (control.hasAttribute("title")) control.removeAttribute("title");
    if (control.tabIndex !== -1) control.tabIndex = -1;
  });
}
