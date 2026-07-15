import type { Asset, BoardNode } from "../types";

const VIEWPORT_WIDTH = 1120;
const VIEWPORT_HEIGHT = 760;

export function arrangeNodes(nodes: BoardNode[], assets: Asset[], selectedIds: string[]) {
  const targets = selectedIds.length > 0 ? nodes.filter((node) => selectedIds.includes(node.id)) : nodes;
  const assetById = new Map(assets.map((asset) => [asset.id, asset]));
  const columnWidth = 236;
  const gap = 24;
  const columns = Math.max(3, Math.ceil(Math.sqrt(targets.length || 1)));
  const heights = Array.from({ length: columns }, () => 0);

  return targets.map((node, index) => {
    const asset = assetById.get(node.assetId);
    const ratio = asset?.width && asset?.height ? asset.height / asset.width : 0.68 + ((index % 5) * 0.08);
    const width = asset?.kind === "image" || asset?.kind === "video" ? columnWidth : 212;
    const height = Math.max(126, Math.min(340, width * ratio));
    const column = heights.indexOf(Math.min(...heights));
    const x = column * (columnWidth + gap);
    const y = heights[column];
    heights[column] += height + gap;
    return {
      ...node,
      x,
      y,
      width,
      height,
      z: index,
      arrangeGroup: "auto",
    };
  });
}

export function fitViewport(nodes: BoardNode[], maxScale = 1.2) {
  if (nodes.length === 0) {
    return { scale: 0.82, offsetX: 260, offsetY: 132 };
  }

  const minX = Math.min(...nodes.map((node) => node.x));
  const minY = Math.min(...nodes.map((node) => node.y));
  const maxX = Math.max(...nodes.map((node) => node.x + node.width));
  const maxY = Math.max(...nodes.map((node) => node.y + node.height));
  const width = Math.max(1, maxX - minX);
  const height = Math.max(1, maxY - minY);
  const scale = Math.min(maxScale, Math.max(0.18, Math.min((VIEWPORT_WIDTH - 180) / width, (VIEWPORT_HEIGHT - 180) / height)));

  return {
    scale,
    offsetX: 112 + (VIEWPORT_WIDTH - width * scale) / 2 - minX * scale,
    offsetY: 126 + (VIEWPORT_HEIGHT - height * scale) / 2 - minY * scale,
  };
}
