import { assetKindLabel } from "./asset";
import type { Asset, BoardNode, BoardScope, BoardView } from "../types";

export const allScope: BoardScope = { type: "all" };

export function scopeLabel(scope: BoardScope) {
  if (scope.type === "all") return "All";
  if (scope.type === "inbox") return "Inbox";
  if (scope.type === "trash") return "Trash";
  if (scope.type === "kind") return assetKindLabel(scope.value);
  return scope.value;
}

export function filteredAssets(view: BoardView | null, scope: BoardScope, query = "") {
  if (!view) return [];
  const normalized = query.trim().toLowerCase();
  return view.assets.filter((asset) => assetMatchesScope(asset, scope) && (!normalized || assetSearchText(asset).includes(normalized)));
}

export function filteredNodes(view: BoardView | null, scope: BoardScope, query = ""): BoardNode[] {
  if (!view) return [];
  const assets = new Map(view.assets.map((asset) => [asset.id, asset]));
  const normalized = query.trim().toLowerCase();
  return view.nodes.filter((node) => {
    const asset = assets.get(node.assetId);
    return asset ? assetMatchesScope(asset, scope) && (!normalized || assetSearchText(asset).includes(normalized)) : false;
  });
}

export function assetMatchesScope(asset: Asset, scope: BoardScope) {
  const isTrashed = Boolean(asset.trashedAt);
  switch (scope.type) {
    case "inbox":
      return !isTrashed;
    case "trash":
      return isTrashed;
    case "folder":
      return !isTrashed && asset.folders.includes(scope.value);
    case "source-folder":
      return !isTrashed && asset.sourceId === scope.sourceId && asset.folders.includes(scope.value);
    case "tag":
      return !isTrashed && asset.tags.includes(scope.value);
    case "kind":
      return !isTrashed && asset.kind === scope.value;
    default:
      return !isTrashed;
  }
}

export function assetSearchText(asset: Asset) {
  return [asset.name, asset.kind, asset.extension, asset.note, asset.sourceUrl, ...asset.tags, ...asset.folders]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
}
