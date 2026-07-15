import { useMemo, useRef, useState } from "react";
import { ChevronDown, ChevronRight, Database, Folder, FolderInput, HardDrive, ImagePlus, Inbox, LayoutDashboard, Plus, Tag, Trash2 } from "lucide-react";
import { Button } from "./ui/Button";
import { MaatMark } from "./Mark";
import { createBoard, loadBoard } from "../lib/bridge";
import { promptDialog } from "../lib/dialog";
import { formatCount } from "../lib/format";
import { filteredAssets, scopeLabel } from "../lib/scope";
import { useAppStore } from "../store";
import type { Asset, Board, BoardScope, BoardView } from "../types";

type SidebarProps = {
  boards: Board[];
  activeBoardId: string | null;
  view: BoardView | null;
  scope: BoardScope;
  loading: boolean;
  collapsed?: boolean;
  onBeforeBoardChange: () => Promise<void>;
  onBoardChange: (boardId: string) => void;
  onRenameBoard: (boardId: string, name: string) => void;
  onDeleteBoard: (boardId: string) => void;
  onDeleteSource: (sourceId: string) => void;
  onScopeChange: (scope: BoardScope) => void;
  onImportFiles: () => void;
  onImportFolder: () => void;
};

export function Sidebar({
  boards,
  activeBoardId,
  view,
  scope,
  loading,
  collapsed = false,
  onBeforeBoardChange,
  onBoardChange,
  onRenameBoard,
  onDeleteBoard,
  onDeleteSource,
  onScopeChange,
  onImportFiles,
  onImportFolder,
}: SidebarProps) {
  const { setView, setStatus, setLoading } = useAppStore();
  const [collapsedSourceIds, setCollapsedSourceIds] = useState<Set<string>>(() => new Set());
  const [editingBoardId, setEditingBoardId] = useState<string | null>(null);
  const [draftName, setDraftName] = useState("");
  const cancelRenameRef = useRef(false);
  const assets = view?.assets.filter((asset) => !asset.trashedAt).length ?? 0;
  const inboxAssets = assets;
  const trashAssets = view?.assets.filter((asset) => asset.trashedAt).length ?? 0;
  const scopedAssets = filteredAssets(view, scope).length;
  const sourceFolders = useMemo(() => countFoldersBySource(view), [view]);
  const tags = useMemo(() => countValues(view?.assets ?? [], "tags"), [view]);

  const handleCreate = async () => {
    const name = await promptDialog({ title: "New board", label: "Board name", defaultValue: "New Board", confirmLabel: "Create" });
    if (!name?.trim()) return;
    setLoading(true);
    try {
      await onBeforeBoardChange();
      const board = await createBoard(name.trim());
      const next = await loadBoard(board.id);
      setView(next);
      setStatus(`Created ${board.name}`);
    } catch (error) {
      console.error(error);
      setStatus(error instanceof Error ? error.message : "Could not create board");
    } finally {
      setLoading(false);
    }
  };

  const toggleSource = (sourceId: string) => {
    setCollapsedSourceIds((current) => {
      const next = new Set(current);
      if (next.has(sourceId)) {
        next.delete(sourceId);
      } else {
        next.add(sourceId);
      }
      return next;
    });
  };

  const startRename = (board: Board) => {
    setEditingBoardId(board.id);
    setDraftName(board.name);
    cancelRenameRef.current = false;
  };

  const finishRename = (board: Board) => {
    const commit = !cancelRenameRef.current;
    cancelRenameRef.current = false;
    setEditingBoardId(null);
    if (commit) onRenameBoard(board.id, draftName);
  };

  return (
    <aside
      className="row-start-2 col-start-1 min-h-0 overflow-hidden border-r border-[var(--line)] bg-[var(--sidebar)] p-3"
      aria-hidden={collapsed || undefined}
      inert={collapsed || undefined}
    >
      <div className="flex h-full flex-col gap-4">
        <div className="flex items-center gap-2 px-1 pt-1">
          <MaatMark className="h-5 w-5 text-[var(--fg)]" />
          <span className="font-display text-[19px] font-semibold leading-none tracking-[-0.02em] text-[var(--fg)]">Maat</span>
        </div>
        <section>
          <div className="mb-2 px-1">
            <span className="font-mono text-[11px] font-medium uppercase tracking-[0.14em] text-[var(--muted)]">Boards</span>
          </div>
          <div className="space-y-1">
            {boards.map((board) => {
              const editing = editingBoardId === board.id;
              return (
                <div
                  key={board.id}
                  className={`flex items-center rounded-md transition ${
                    activeBoardId === board.id
                      ? "bg-[var(--active)] text-[var(--active-fg)]"
                      : "text-[var(--fg)] hover:bg-[var(--panel-hover)]"
                  }`}
                >
                  {editing ? (
                    <input
                      autoFocus
                      aria-label={`Rename ${board.name}`}
                      value={draftName}
                      onChange={(event) => setDraftName(event.target.value)}
                      onFocus={(event) => event.currentTarget.select()}
                      onKeyDown={(event) => {
                        if (event.key === "Enter") event.currentTarget.blur();
                        else if (event.key === "Escape") {
                          cancelRenameRef.current = true;
                          event.currentTarget.blur();
                        }
                      }}
                      onBlur={() => finishRename(board)}
                      className="min-w-0 flex-1 rounded-md bg-transparent px-2.5 py-2 text-sm outline-none ring-1 ring-inset ring-[var(--focus)]"
                    />
                  ) : (
                    <button
                      onClick={() => onBoardChange(board.id)}
                      onDoubleClick={() => startRename(board)}
                      title="Double-click to rename"
                      className="flex min-w-0 flex-1 items-center gap-2 px-2.5 py-2 text-left text-sm"
                    >
                      <LayoutDashboard className="h-4 w-4 shrink-0" />
                      <span className="truncate">{board.name}</span>
                    </button>
                  )}
                  {!editing && (
                    <button
                      type="button"
                      aria-label={`Delete ${board.name}`}
                      title="Delete board"
                      className="mr-1 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-[var(--muted)] hover:bg-[var(--panel-hover)] hover:text-[var(--fg)]"
                      onClick={() => onDeleteBoard(board.id)}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        </section>

        <div className="min-h-0 flex-1 space-y-4 overflow-auto pr-1">
          <section>
            <div className="mb-2 px-1 font-mono text-[11px] font-medium uppercase tracking-[0.14em] text-[var(--muted)]">Board</div>
            <nav className="space-y-1">
              <SidebarItem icon={Database} label="All" count={assets} active={scope.type === "all"} onClick={() => onScopeChange({ type: "all" })} />
              <SidebarItem
                icon={Inbox}
                label="Inbox"
                count={inboxAssets}
                active={scope.type === "inbox"}
                onClick={() => onScopeChange({ type: "inbox" })}
              />
              <SidebarItem
                icon={Trash2}
                label="Trash"
                count={trashAssets}
                active={scope.type === "trash"}
                onClick={() => onScopeChange({ type: "trash" })}
              />
            </nav>
          </section>

          <section>
            <div className="mb-2 px-1 font-mono text-[11px] font-medium uppercase tracking-[0.14em] text-[var(--muted)]">Sources</div>
            <div className="space-y-1">
              {view?.sources.length ? (
                view.sources.map((source) => {
                  const folders = sourceFolders.get(source.id) ?? [];
                  const collapsed = collapsedSourceIds.has(source.id);
                  const SourceChevron = collapsed ? ChevronRight : ChevronDown;
                  return (
                    <div key={source.id} className="group rounded-md">
                      <div className="flex items-center">
                        <button
                          type="button"
                          className="min-w-0 flex-1 rounded-md px-2.5 py-2 text-left text-sm transition hover:bg-[var(--panel-hover)]"
                          aria-expanded={folders.length > 0 ? !collapsed : undefined}
                          onClick={() => {
                            if (folders.length > 0) toggleSource(source.id);
                          }}
                        >
                          <div className="flex items-center justify-between gap-2">
                            <span className="flex min-w-0 items-center gap-2">
                              {folders.length > 0 ? (
                                <SourceChevron className="h-3.5 w-3.5 shrink-0 text-[var(--muted)]" />
                              ) : (
                                <span className="h-3.5 w-3.5 shrink-0" />
                              )}
                              <Folder className="h-4 w-4 shrink-0 text-[var(--muted)]" />
                              <span className="truncate">{source.path.split(/[\\/]/).pop()}</span>
                            </span>
                            <span className="text-xs tabular-nums text-[var(--muted)]">{source.itemCount}</span>
                          </div>
                          <div className="mt-1 pl-[38px] text-[11px] uppercase tracking-[0.1em] text-[var(--muted)]">{source.kind}</div>
                        </button>
                        <button
                          type="button"
                          aria-label={`Remove ${source.path.split(/[\\/]/).pop()}`}
                          title="Remove source and its assets"
                          className="mr-1 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-[var(--muted)] opacity-0 transition hover:bg-[var(--panel-hover)] hover:text-[var(--fg)] focus-visible:opacity-100 group-hover:opacity-100"
                          onClick={() => onDeleteSource(source.id)}
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                      {folders.length > 0 && !collapsed && (
                        <div className="ml-8 mt-1 space-y-1 border-l border-[var(--line)] pl-3">
                          {folders.map((folder) => (
                            <SidebarItem
                              key={folder.value}
                              icon={Folder}
                              label={folder.value}
                              count={folder.count}
                              active={scope.type === "source-folder" && scope.sourceId === source.id && scope.value === folder.value}
                              onClick={() => onScopeChange({ type: "source-folder", sourceId: source.id, value: folder.value })}
                            />
                          ))}
                        </div>
                      )}
                    </div>
                  );
                })
              ) : (
                <div className="rounded-md border border-dashed border-[var(--line)] p-3 text-sm text-[var(--muted)]">
                  Import an Eagle library or a folder to start.
                </div>
              )}
            </div>
          </section>

          <ScopeSection
            title="Tags"
            icon={Tag}
            empty="Imported tags will appear here."
            items={tags}
            isActive={(value) => scope.type === "tag" && scope.value === value}
            onSelect={(value) => onScopeChange({ type: "tag", value })}
          />
        </div>

        <section className="space-y-2">
          <Button className="w-full" variant="secondary" onClick={handleCreate} disabled={loading}>
            <Plus className="h-4 w-4" />
            New board
          </Button>
          <Button className="w-full" variant="secondary" onClick={onImportFiles} disabled={loading}>
            <ImagePlus className="h-4 w-4" />
            Import files
          </Button>
          <Button className="w-full" onClick={onImportFolder} disabled={loading}>
            <FolderInput className="h-4 w-4" />
            Import folder
          </Button>
          <div className="flex items-center gap-2 rounded-md border border-[var(--line)] bg-[var(--panel)] px-3 py-2 text-xs text-[var(--muted)]">
            <HardDrive className="h-4 w-4" />
            <span className="truncate">{view ? `${scopeLabel(scope)} · ${formatCount(scopedAssets, "asset")}` : "No board open"}</span>
          </div>
        </section>
      </div>
    </aside>
  );
}

type Icon = React.ComponentType<{ className?: string }>;

function SidebarItem({
  icon: Icon,
  label,
  count,
  active = false,
  onClick,
}: {
  icon: Icon;
  label: string;
  count: number;
  active?: boolean;
  onClick?: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={`flex w-full items-center justify-between rounded-md px-2.5 py-2 text-sm transition ${
        active ? "bg-[var(--active)] text-[var(--active-fg)]" : "text-[var(--muted)] hover:bg-[var(--panel-hover)] hover:text-[var(--fg)]"
      }`}
    >
      <span className="flex items-center gap-2">
        <Icon className="h-4 w-4" />
        {label}
      </span>
      <span className="text-xs tabular-nums">{count.toLocaleString()}</span>
    </button>
  );
}

function ScopeSection({
  title,
  icon,
  items,
  empty,
  isActive,
  onSelect,
}: {
  title: string;
  icon: Icon;
  items: Array<{ value: string; count: number }>;
  empty: string;
  isActive: (value: string) => boolean;
  onSelect: (value: string) => void;
}) {
  return (
    <section>
      <div className="mb-2 px-1 font-mono text-[11px] font-medium uppercase tracking-[0.14em] text-[var(--muted)]">{title}</div>
      <div className="space-y-1">
        {items.length > 0 ? (
          items.map((item) => (
            <SidebarItem
              key={item.value}
              icon={icon}
              label={item.value}
              count={item.count}
              active={isActive(item.value)}
              onClick={() => onSelect(item.value)}
            />
          ))
        ) : (
          <div className="rounded-md border border-dashed border-[var(--line)] p-3 text-sm text-[var(--muted)]">{empty}</div>
        )}
      </div>
    </section>
  );
}

function countValues(assets: Asset[], key: "folders" | "tags") {
  const counts = new Map<string, number>();
  assets.forEach((asset) => {
    asset[key].forEach((value) => counts.set(value, (counts.get(value) ?? 0) + 1));
  });
  return Array.from(counts, ([value, count]) => ({ value, count })).sort((a, b) => b.count - a.count || a.value.localeCompare(b.value));
}

function countFoldersBySource(view: BoardView | null) {
  const countsBySource = new Map<string, Map<string, number>>();
  const sourceIds = new Set(view?.sources.map((source) => source.id) ?? []);
  view?.assets.forEach((asset) => {
    if (!asset.sourceId || !sourceIds.has(asset.sourceId)) return;
    let counts = countsBySource.get(asset.sourceId);
    if (!counts) {
      counts = new Map<string, number>();
      countsBySource.set(asset.sourceId, counts);
    }
    asset.folders.forEach((folder) => counts.set(folder, (counts.get(folder) ?? 0) + 1));
  });

  return new Map(
    Array.from(countsBySource, ([sourceId, counts]) => [
      sourceId,
      Array.from(counts, ([value, count]) => ({ value, count })).sort((a, b) => b.count - a.count || a.value.localeCompare(b.value)),
    ]),
  );
}
