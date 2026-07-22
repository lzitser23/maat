import { CaptureUpdateAction, Excalidraw, THEME } from "@excalidraw/excalidraw";
import type { OrderedExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import type { ExcalidrawImperativeAPI, NormalizedZoomValue, UIOptions } from "@excalidraw/excalidraw/types";
import { useCallback, useEffect, useState } from "react";

// Everything Excalidraw-specific lives in this module so it can be code-split behind React.lazy —
// importing it (even just for types with runtime value re-exports like CaptureUpdateAction/THEME)
// is what pulls in Excalidraw's mermaid/katex/cytoscape dependency graph. Canvas.tsx must not import
// any runtime symbol from "@excalidraw/excalidraw" so that graph stays out of the entry chunk.

const excalidrawUiOptions: Partial<UIOptions> = {
  canvasActions: {
    changeViewBackgroundColor: false,
    clearCanvas: false,
    export: false,
    loadScene: false,
    saveAsImage: false,
    saveToActiveFile: false,
    toggleTheme: null,
  },
  tools: {
    image: false,
  },
  welcomeScreen: false,
};

export type DrawingOverlayProps = {
  boardId: string;
  drawingMode: boolean;
  drawingElements: readonly OrderedExcalidrawElement[];
  isDark: boolean;
  scrollX: number;
  scrollY: number;
  zoom: { value: NormalizedZoomValue };
  // When false (not drawing, no live sketches on the board), skip the per-tick scene sync —
  // otherwise every pan/zoom tick forces Excalidraw to redraw its whole canvas for nothing.
  syncViewport: boolean;
  onApiReady: (api: ExcalidrawImperativeAPI) => void;
  onChange: (elements: readonly OrderedExcalidrawElement[], appState: { scrollX: number; scrollY: number; zoom: { value: number } }) => void;
};

export default function DrawingOverlay({
  boardId,
  drawingMode,
  drawingElements,
  isDark,
  scrollX,
  scrollY,
  zoom,
  syncViewport,
  onApiReady,
  onChange,
}: DrawingOverlayProps) {
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null);

  const handleApi = useCallback(
    (nextApi: ExcalidrawImperativeAPI) => {
      setApi(nextApi);
      onApiReady(nextApi);
    },
    [onApiReady],
  );

  // Two-way viewport sync: push the board's pan/zoom into the Excalidraw scene without recording it
  // as an undoable scene change. Gated off while nothing drawn is visible; when syncViewport flips
  // back on (entering drawing mode), this effect re-runs and catches the scene up.
  useEffect(() => {
    if (!api || !syncViewport) return;
    api.updateScene({
      appState: {
        scrollX,
        scrollY,
        zoom,
        viewBackgroundColor: "transparent",
      },
      captureUpdate: CaptureUpdateAction.NEVER,
    });
  }, [api, scrollX, scrollY, syncViewport, zoom]);

  return (
    <Excalidraw
      key={boardId}
      excalidrawAPI={handleApi}
      onChange={onChange}
      initialData={{
        elements: drawingElements,
        appState: {
          gridModeEnabled: false,
          scrollX,
          scrollY,
          viewBackgroundColor: "transparent",
          zoom,
        },
      }}
      UIOptions={excalidrawUiOptions}
      detectScroll={false}
      handleKeyboardGlobally={drawingMode}
      gridModeEnabled={false}
      theme={isDark ? THEME.DARK : THEME.LIGHT}
      viewModeEnabled={!drawingMode}
      zenModeEnabled={!drawingMode}
    />
  );
}
