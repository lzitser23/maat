import { useEffect, useState } from "react";
import { ExternalLink, FolderOpen, Info, Layers3, Ruler, Sparkles, Tag } from "lucide-react";
import { assetIcon, assetKindLabel } from "../lib/asset";
import { revealPath } from "../lib/bridge";
import { formatBytes } from "../lib/format";
import type { Asset, BoardView } from "../types";
import { Button } from "./ui/Button";

type InspectorProps = {
  assets: Asset[];
  view: BoardView | null;
  scale: number;
  status: string;
  loading: boolean;
  assetCount: number;
  nodeCount: number;
  // Immersive (Infinity view) mode collapses the docked inspector's grid column to 0px, so callers
  // there render it floating over the canvas instead -- this switches the outer chrome accordingly.
  floating?: boolean;
  // Persists the user-entered AI-generation prompt for `assetId` (see PromptEditor below).
  // Omitted where the Inspector has no board context to save into.
  onSetAssetPrompt?: (assetId: string, prompt: string) => void;
};

export function Inspector({
  assets,
  view,
  scale,
  status,
  loading,
  assetCount,
  nodeCount,
  floating = false,
  onSetAssetPrompt,
}: InspectorProps) {
  const primary = assets[0];
  const Icon = primary ? assetIcon(primary.kind) : Sparkles;

  return (
    <aside
      className={
        floating
          ? "h-full min-h-0 overflow-auto rounded-md border border-[var(--line)] bg-[var(--inspector)] p-4 shadow-[var(--shadow-soft)] backdrop-blur"
          : "row-start-2 col-start-3 min-h-0 border-l border-[var(--line)] bg-[var(--inspector)] p-4"
      }
    >
      <div className="flex h-full flex-col gap-4">
        <section className="rounded-md border border-[var(--line)] bg-[var(--panel)] p-3">
          <div className="mb-3 flex items-center justify-between">
            <div className="flex items-center gap-2 text-sm font-semibold">
              <Info className="h-4 w-4 text-[var(--muted)]" />
              Inspector
            </div>
            <span className="text-xs tabular-nums text-[var(--muted)]">{Math.round(scale * 100)}%</span>
          </div>

          {primary ? (
            <div className="space-y-4">
              <div className="flex gap-3">
                <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-md border border-[var(--line)] bg-[var(--panel-strong)]">
                  <Icon className="h-5 w-5 text-[var(--muted)]" />
                </div>
                <div className="min-w-0">
                  <div className="truncate text-sm font-semibold">{primary.name}</div>
                  <div className="mt-1 text-xs text-[var(--muted)]">
                    {assetKindLabel(primary.kind)} · {formatBytes(primary.size)}
                  </div>
                </div>
              </div>

              <Meta label="Type" value={primary.mime || primary.extension || "Unknown"} />
              <Meta
                label="Dimensions"
                value={primary.width && primary.height ? `${primary.width} × ${primary.height}` : "Not available"}
              />
              <Meta label="Hash" value={primary.hash.slice(0, 16)} mono />
              <Meta label="Preview" value={primary.previewStatus} />
              {primary.tags.length > 0 && <TokenBlock icon={Tag} label="Tags" values={primary.tags} />}
              {primary.folders.length > 0 && <TokenBlock icon={FolderOpen} label="Folders" values={primary.folders} />}
              {primary.note && <TextBlock label="Note" value={primary.note} />}
              {primary.sourceUrl && <Meta label="Source URL" value={primary.sourceUrl} />}
              {onSetAssetPrompt && (
                <PromptEditor key={primary.id} asset={primary} onSetAssetPrompt={onSetAssetPrompt} />
              )}

              <Button variant="secondary" className="w-full" onClick={() => revealPath(primary.managedPath)}>
                <ExternalLink className="h-4 w-4" />
                Reveal managed file
              </Button>
              {primary.originalPath !== primary.managedPath && (
                <Button variant="ghost" className="w-full" onClick={() => revealPath(primary.originalPath)}>
                  <ExternalLink className="h-4 w-4" />
                  Reveal original file
                </Button>
              )}
            </div>
          ) : (
            <div className="space-y-3 text-sm text-[var(--muted)]">
              <p>Select an asset to inspect metadata, source, dimensions, and preview state.</p>
              <div className="grid grid-cols-2 gap-2">
                <Stat icon={Layers3} label="Assets" value={(view ? assetCount : 0).toLocaleString()} />
                <Stat icon={Ruler} label="Nodes" value={(view ? nodeCount : 0).toLocaleString()} />
              </div>
            </div>
          )}
        </section>

        {assets.length > 1 && (
          <section className="rounded-md border border-[var(--line)] bg-[var(--panel)] p-3">
            <div className="text-sm font-semibold">Selection</div>
            <div className="mt-1 text-sm text-[var(--muted)]">{assets.length} assets selected</div>
          </section>
        )}

        <section className="mt-auto rounded-md border border-[var(--line)] bg-[var(--panel)] p-3">
          <div className="flex items-center justify-between text-xs uppercase tracking-[0.14em] text-[var(--muted)]">
            <span>Status</span>
            <span>{loading ? "Working" : "Idle"}</span>
          </div>
          <div className="mt-2 text-sm">{status}</div>
        </section>
      </div>
    </aside>
  );
}

function Meta({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <div className="text-xs uppercase tracking-[0.14em] text-[var(--muted)]">{label}</div>
      <div className={`mt-1 truncate text-sm ${mono ? "font-mono" : ""}`}>{value}</div>
    </div>
  );
}

type Icon = React.ComponentType<{ className?: string }>;

function TokenBlock({ icon: Icon, label, values }: { icon: Icon; label: string; values: string[] }) {
  return (
    <div>
      <div className="mb-2 flex items-center gap-1.5 text-xs uppercase tracking-[0.14em] text-[var(--muted)]">
        <Icon className="h-3.5 w-3.5" />
        {label}
      </div>
      <div className="flex flex-wrap gap-1.5">
        {values.map((value) => (
          <span key={value} className="max-w-full truncate rounded-md border border-[var(--line)] bg-[var(--panel-strong)] px-2 py-1 text-xs">
            {value}
          </span>
        ))}
      </div>
    </div>
  );
}

// Editable AI-generation/training prompt. Until the user sets one, an asset imported from a
// dataset folder shows its sidecar-`.txt` caption here (see ingest.zig's sidecar pairing) --
// the caption IS the training prompt, so it surfaces in the one editable box rather than as a
// separate read-only section. Editing saves to `prompt` only; the imported `caption` stays
// untouched underneath (a prompt explicitly cleared to "" sticks as empty -- nullish fallback
// only, so the caption doesn't resurrect over a deliberate clear). Local draft state lets
// typing feel instant; the value only round-trips through the bridge on blur. Mounted with
// `key={asset.id}` by the caller so switching the selected asset always remounts with a fresh
// draft instead of carrying over stale text.
function PromptEditor({ asset, onSetAssetPrompt }: { asset: Asset; onSetAssetPrompt: (assetId: string, prompt: string) => void }) {
  const initial = asset.prompt ?? asset.caption ?? "";
  const [draft, setDraft] = useState(initial);

  useEffect(() => {
    setDraft(asset.prompt ?? asset.caption ?? "");
  }, [asset.id, asset.prompt, asset.caption]);

  return (
    <div>
      <div className="text-xs uppercase tracking-[0.14em] text-[var(--muted)]">Prompt</div>
      <textarea
        aria-label="Prompt"
        value={draft}
        placeholder="Add the generation prompt for this asset…"
        rows={3}
        onChange={(event) => setDraft(event.target.value)}
        onBlur={() => {
          if (draft !== initial) onSetAssetPrompt(asset.id, draft);
        }}
        className="mt-1 w-full resize-none rounded-md border border-[var(--line)] bg-[var(--panel-strong)] p-2 text-sm leading-5 text-[var(--fg)] outline-none focus:ring-1 focus:ring-inset focus:ring-[var(--focus)]"
      />
    </div>
  );
}

function TextBlock({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-xs uppercase tracking-[0.14em] text-[var(--muted)]">{label}</div>
      <p className="mt-1 max-h-24 overflow-auto rounded-md border border-[var(--line)] bg-[var(--panel-strong)] p-2 text-sm leading-5 text-[var(--fg)]">
        {value}
      </p>
    </div>
  );
}

function Stat({ icon: Icon, label, value }: { icon: Icon; label: string; value: string }) {
  return (
    <div className="rounded-md border border-[var(--line)] bg-[var(--panel-strong)] p-2">
      <Icon className="mb-2 h-4 w-4 text-[var(--muted)]" />
      <div className="text-base font-semibold text-[var(--fg)]">{value}</div>
      <div className="text-[11px] uppercase tracking-[0.14em]">{label}</div>
    </div>
  );
}
