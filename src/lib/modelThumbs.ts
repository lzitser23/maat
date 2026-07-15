import { assetModelUrl, isNative, setAssetThumbnail } from "./bridge";
import type { Asset } from "../types";

// Background thumbnail generation for 3D model assets. The engine can't rasterize a GLB
// (previewMetadata in ingest.zig marks every non-image kind "fallback"), so the webview
// renders one offscreen WebGL frame per model and hands the PNG back to the engine via
// set_asset_thumbnail. From then on the asset has a normal persisted thumbnail like any
// image.
//
// Renders run strictly one at a time (a shared promise chain): each snapshot spins up and
// tears down a WebGL context, and browsers hard-cap live contexts.

const attempted = new Set<string>();
let chain: Promise<void> = Promise.resolve();

export function queueModelThumbnails(assets: Asset[], onUpdated: (asset: Asset) => void) {
  if (!isNative()) return;
  for (const asset of assets) {
    const needsThumbnail = asset.kind === "model" && !asset.trashedAt && (asset.previewStatus !== "ready" || !asset.thumbnailPath);
    // `attempted` also keeps failures from re-rendering on every board reload this
    // session: a model that can't load (e.g. a .gltf with external buffers) fails once.
    if (!needsThumbnail || attempted.has(asset.id)) continue;
    attempted.add(asset.id);
    chain = chain.then(async () => {
      try {
        const src = assetModelUrl(asset);
        if (!src) throw new Error("Asset server not ready");
        // Same lazy chunk as the spotlight viewer -- three.js never enters the entry bundle.
        const { renderModelSnapshot } = await import("../components/ModelViewer");
        const png = await renderModelSnapshot(src);
        const updated = await setAssetThumbnail(asset.boardId, asset.id, png);
        if (updated) onUpdated(updated);
      } catch (error) {
        console.error(`Model thumbnail failed for ${asset.name}`, error);
      }
    });
  }
}
