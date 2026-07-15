export type ThemeMode = "light" | "dark";

export type ViewMode = "canvas" | "grid" | "infinity";

export type Board = {
  id: string;
  name: string;
  path: string;
  drawingJson: string;
  createdAt: string;
  updatedAt: string;
};

export type Source = {
  id: string;
  boardId: string;
  kind: "eagle" | "folder" | "file";
  path: string;
  mode: "managed" | "linked";
  importedAt: string;
  itemCount: number;
};

export type AssetKind =
  | "image"
  | "video"
  | "audio"
  | "pdf"
  | "font"
  | "document"
  | "archive"
  | "design"
  | "unknown";

export type Asset = {
  id: string;
  boardId: string;
  sourceId?: string | null;
  name: string;
  originalPath: string;
  managedPath: string;
  mime: string;
  extension: string;
  size: number;
  hash: string;
  width?: number | null;
  height?: number | null;
  kind: AssetKind;
  previewStatus: "ready" | "fallback" | "error";
  thumbnailPath?: string | null;
  tags: string[];
  folders: string[];
  note?: string | null;
  sourceUrl?: string | null;
  trashedAt?: string | null;
  createdAt: string;
  metadataJson?: string | null;
};

export type BoardScope =
  | { type: "all" }
  | { type: "inbox" }
  | { type: "trash" }
  | { type: "folder"; value: string }
  | { type: "source-folder"; sourceId: string; value: string }
  | { type: "tag"; value: string }
  | { type: "kind"; value: AssetKind };

export type BoardNode = {
  id: string;
  boardId: string;
  assetId: string;
  x: number;
  y: number;
  width: number;
  height: number;
  z: number;
  locked: boolean;
  arrangeGroup?: string | null;
};

export type Frame = {
  id: string;
  boardId: string;
  x: number;
  y: number;
  width: number;
  height: number;
  label: string;
  createdAt: string;
  updatedAt: string;
};

export type FrameUpdate = {
  id: string;
  x: number;
  y: number;
  width: number;
  height: number;
  label: string;
};

export type BoardView = {
  board: Board;
  sources: Source[];
  assets: Asset[];
  nodes: BoardNode[];
  frames: Frame[];
};

export type AppStateDto = {
  boards: Board[];
  activeBoardId: string;
  view: BoardView;
};

export type ImportReport = {
  imported: number;
  skippedDuplicates: number;
  failed: number;
  sourceId: string;
  messages: string[];
};

export type NodeUpdate = {
  id: string;
  x: number;
  y: number;
  width: number;
  height: number;
  z: number;
  locked: boolean;
  arrangeGroup?: string | null;
};
