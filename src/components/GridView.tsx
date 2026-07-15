import { useEffect, useMemo, useState } from "react";
import { Info } from "lucide-react";
import { assetIcon, assetKindLabel } from "../lib/asset";
import { assetOriginalUrl, assetPreviewUrl } from "../lib/bridge";
import { arrangeNodes } from "../lib/layout";
import { formatBytes } from "../lib/format";
import type { Asset, BoardNode, BoardView } from "../types";

type GridViewProps = {
  view: BoardView;
  nodes: BoardNode[];
  selectedIds: string[];
  focusedNodeId: string | null;
  onSelect: (ids: string[]) => void;
  onFocusNode: (nodeId: string) => void;
  onClearFocus: () => void;
  onOpenInspector: (nodeId: string) => void;
};

// Grid mode: a scrollable masonry page. Positions here are purely visual (reuses the shortest-column
// layout from lib/layout.ts) and are never written back to board_nodes — Canvas keeps the real positions.
export function GridView({ view, nodes, selectedIds, focusedNodeId, onSelect, onFocusNode, onClearFocus, onOpenInspector }: GridViewProps) {
  const assetById = useMemo(() => new Map(view.assets.map((asset) => [asset.id, asset])), [view.assets]);
  const arranged = useMemo(() => arrangeNodes(nodes, view.assets, []), [nodes, view.assets]);
  const bounds = useMemo(() => {
    const width = arranged.reduce((max, node) => Math.max(max, node.x + node.width), 0);
    const height = arranged.reduce((max, node) => Math.max(max, node.y + node.height), 0);
    return { width: width + 24, height: height + 24 };
  }, [arranged]);
  const selected = useMemo(() => new Set(selectedIds), [selectedIds]);
  const focusedNode = focusedNodeId ? (arranged.find((node) => node.id === focusedNodeId) ?? null) : null;
  const focusedAsset = focusedNode ? assetById.get(focusedNode.assetId) : null;
  const focusedPreviewUrl = focusedAsset ? assetPreviewUrl(focusedAsset) : null;
  // Focused view: start from the (already-loaded) thumbnail, then swap to the full-res original once
  // it's decoded, so focusing an image doesn't show a permanently blurry downscaled thumbnail.
  const focusedOriginalUrl = focusedAsset ? assetOriginalUrl(focusedAsset) : null;
  const [originalLoaded, setOriginalLoaded] = useState(false);
  useEffect(() => {
    setOriginalLoaded(false);
  }, [focusedOriginalUrl]);
  const focusedDisplayUrl = originalLoaded && focusedOriginalUrl ? focusedOriginalUrl : focusedPreviewUrl;

  return (
    <div
      data-testid="grid-view"
      className="grid-view"
      onClick={(event) => {
        if (event.target === event.currentTarget) onClearFocus();
      }}
    >
      <div className="relative" style={{ width: bounds.width, height: Math.max(bounds.height, 1) }}>
        {arranged.map((node) => {
          const asset = assetById.get(node.assetId);
          if (!asset) return null;
          return (
            <GridCard
              key={node.id}
              asset={asset}
              node={node}
              selected={selected.has(node.id)}
              onClick={() => {
                onSelect([node.id]);
                onFocusNode(node.id);
              }}
            />
          );
        })}
      </div>

      {focusedNode && focusedAsset && (
        <div
          className="fixed inset-0 z-40 flex items-center justify-center p-10"
          style={{ background: "var(--canvas-bg)" }}
          onClick={() => onClearFocus()}
        >
          <div className="relative flex max-h-full max-w-full items-center justify-center" onClick={(event) => event.stopPropagation()}>
            {focusedDisplayUrl ? (
              <img src={focusedDisplayUrl} alt="" className="max-h-full max-w-full rounded-lg object-contain" draggable={false} />
            ) : (
              <div className="flex h-64 w-64 flex-col items-center justify-center gap-3 rounded-lg border border-[var(--line)] bg-[var(--asset-media)] p-5 text-center">
                <div className="text-sm font-semibold">{assetKindLabel(focusedAsset.kind)}</div>
                <div className="text-xs text-[var(--muted)]">{focusedAsset.name}</div>
              </div>
            )}
            <button
              type="button"
              aria-label="Open inspector"
              title="Open inspector"
              className="asset-card__inspect"
              onClick={() => onOpenInspector(focusedNode.id)}
            >
              <Info className="h-4 w-4" />
            </button>
            {focusedOriginalUrl && !originalLoaded && (
              // Invisible preloader: once the full-res original finishes decoding, `focusedDisplayUrl`
              // above swaps to it (already cached, so the swap is instant with no flicker).
              <img src={focusedOriginalUrl} alt="" style={{ display: "none" }} onLoad={() => setOriginalLoaded(true)} />
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function GridCard({ asset, node, selected, onClick }: { asset: Asset; node: BoardNode; selected: boolean; onClick: () => void }) {
  const Icon = assetIcon(asset.kind);
  const previewUrl = assetPreviewUrl(asset);

  return (
    <article
      className="asset-card absolute select-none overflow-hidden rounded-md border border-transparent bg-transparent shadow-none"
      data-selected={selected ? "true" : undefined}
      style={{ left: node.x, top: node.y, width: node.width, height: node.height }}
      onClick={onClick}
    >
      <div className="relative flex h-full flex-col">
        <div className="asset-card__media min-h-0 flex-1 overflow-hidden bg-[var(--asset-media)]">
          {previewUrl ? (
            <img src={previewUrl} alt="" className="h-full w-full object-contain" draggable={false} />
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
    </article>
  );
}
