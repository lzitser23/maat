import { useEffect, useMemo, useRef, useState } from "react";
import { assetIcon, assetKindLabel } from "../lib/asset";
import { assetPreviewUrl } from "../lib/bridge";
import { arrangeNodes } from "../lib/layout";
import { formatBytes } from "../lib/format";
import { FocusedAssetContent, getFocusedScale } from "./FocusedAsset";
import type { Asset, BoardNode, BoardView } from "../types";

type GridViewProps = {
  view: BoardView;
  nodes: BoardNode[];
  selectedIds: string[];
  focusedNodeId: string | null;
  onSelect: (ids: string[]) => void;
  onFocusNode: (nodeId: string) => void;
  onClearFocus: () => void;
};

// Grid mode: a scrollable masonry page. Positions here are purely visual (reuses the shortest-column
// layout from lib/layout.ts) and are never written back to board_nodes — Canvas keeps the real positions.
export function GridView({ view, nodes, selectedIds, focusedNodeId, onSelect, onFocusNode, onClearFocus }: GridViewProps) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const [containerSize, setContainerSize] = useState({ width: 0, height: 0 });
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
  // Same fit-to-container math Canvas uses for its own focused card, so a spotlighted image presents
  // identically (whole image visible, centered, generous padding) in both view modes.
  const focusedScale = focusedNode ? getFocusedScale(focusedNode, containerSize) : 1;

  useEffect(() => {
    const element = rootRef.current;
    if (!element) return;

    const updateContainerSize = () => {
      const rect = element.getBoundingClientRect();
      setContainerSize({ width: rect.width, height: rect.height });
    };
    updateContainerSize();

    const observer = new ResizeObserver(updateContainerSize);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  return (
    // The focus overlay below is a sibling of the scrollable `.grid-view` (not a child of it) -- an
    // absolutely positioned child of a scrolling container scrolls away with its content, which would
    // otherwise carry the spotlighted image out of view if the masonry page had been scrolled.
    <div ref={rootRef} className="relative h-full w-full">
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
      </div>

      {/* `absolute inset-0` (not `fixed`) so the focus overlay is bounded by this view's own box --
          the same "main" area Canvas's own spotlight fits within -- instead of the whole browser
          window (which, for a portrait image, used to blow the fit up to a barely-recognizable crop). */}
      {focusedNode && focusedAsset && (
        <div
          className="absolute inset-0 z-40 flex items-center justify-center"
          style={{ background: "var(--canvas-bg)" }}
          onClick={() => onClearFocus()}
        >
          <article
            className="asset-card relative select-none overflow-hidden rounded-md border border-transparent bg-transparent shadow-none"
            data-spotlight="focused"
            style={{ width: focusedNode.width * focusedScale, height: focusedNode.height * focusedScale }}
            onClick={(event) => event.stopPropagation()}
          >
            <FocusedAssetContent asset={focusedAsset} />
          </article>
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
