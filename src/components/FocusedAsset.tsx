import { lazy, Suspense, useEffect, useState } from "react";
import { Info, Loader2 } from "lucide-react";
import { assetIcon, assetKindLabel } from "../lib/asset";
import { assetModelUrl, assetOriginalUrl, assetPreviewUrl } from "../lib/bridge";
import { formatBytes } from "../lib/format";
import type { Asset } from "../types";

// Same lazy boundary as Canvas.tsx / GridView.tsx -- three.js only downloads once a model asset is
// actually spotlighted.
const ModelViewer = lazy(() => import("./ModelViewer"));

const SPOTLIGHT_PADDING_X = 56;
const SPOTLIGHT_PADDING_Y = 56;

// Scales a node's stored box (which preserves the asset's aspect ratio) to fit within a container with
// generous padding -- shared by Canvas and Grid focus so a spotlighted image presents identically
// (whole image visible, centered) in both view modes.
export function getFocusedScale(node: { width: number; height: number }, containerSize: { width: number; height: number }) {
  if (containerSize.width <= 0 || containerSize.height <= 0) return 1;
  return Math.min(
    Math.max(1, containerSize.width - SPOTLIGHT_PADDING_X) / node.width,
    Math.max(1, containerSize.height - SPOTLIGHT_PADDING_Y) / node.height,
  );
}

// The focused/spotlight content shared by Canvas's focused AssetCard and Grid's focus overlay: full-res
// image swap, the 3D orbit viewer for models, the inspect button, and the name/kind/size footer (the
// footer is hidden while focused via the `.asset-card[data-spotlight="focused"]` CSS rule the caller's
// wrapper is expected to carry).
export function FocusedAssetContent({ asset, onOpenInspector }: { asset: Asset; onOpenInspector: () => void }) {
  const Icon = assetIcon(asset.kind);
  const modelUrl = asset.kind === "model" ? assetModelUrl(asset) : null;
  const previewUrl = assetPreviewUrl(asset);
  // Focused view: start from the (already-loaded) thumbnail, then swap to the full-res original once
  // it's decoded, so focusing an image doesn't show a permanently blurry downscaled thumbnail.
  const originalUrl = assetOriginalUrl(asset);
  const [originalLoaded, setOriginalLoaded] = useState(false);
  useEffect(() => {
    setOriginalLoaded(false);
  }, [originalUrl]);
  const displayUrl = originalLoaded && originalUrl ? originalUrl : previewUrl;

  return (
    <div className="relative flex h-full flex-col">
      <button
        type="button"
        aria-label="Open inspector"
        title="Open inspector"
        className="asset-card__inspect"
        onPointerDown={(event) => event.stopPropagation()}
        onClick={(event) => {
          event.stopPropagation();
          onOpenInspector();
        }}
      >
        <Info className="h-4 w-4" />
      </button>
      <div className="asset-card__media min-h-0 flex-1 overflow-hidden bg-[var(--asset-media)]">
        {modelUrl ? (
          <Suspense
            fallback={
              <div className="flex h-full w-full items-center justify-center">
                <Loader2 className="h-5 w-5 animate-spin text-[var(--muted)]" />
              </div>
            }
          >
            <ModelViewer src={modelUrl} />
          </Suspense>
        ) : displayUrl ? (
          <img
            src={displayUrl}
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
      {originalUrl && !originalLoaded && (
        // Invisible preloader: once the full-res original finishes decoding, `displayUrl` above
        // swaps to it (already cached, so the swap is instant with no flicker).
        <img src={originalUrl} alt="" style={{ display: "none" }} onLoad={() => setOriginalLoaded(true)} />
      )}
      <div className="asset-card__footer bg-[var(--asset-footer)] px-1.5 pb-0 pt-2">
        <div className="truncate text-sm font-medium">{asset.name}</div>
        <div className="mt-0.5 flex items-center justify-between text-[10px] uppercase tracking-[0.08em] text-[var(--muted)]">
          <span>{assetKindLabel(asset.kind)}</span>
          <span>{formatBytes(asset.size)}</span>
        </div>
      </div>
    </div>
  );
}
