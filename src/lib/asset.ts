import {
  Archive,
  AudioLines,
  File,
  FileImage,
  FileText,
  FileType,
  Film,
  Layers3,
  Palette,
} from "lucide-react";
import type { Asset, AssetKind } from "../types";

export function assetKindLabel(kind: AssetKind) {
  switch (kind) {
    case "image":
      return "Image";
    case "video":
      return "Video";
    case "audio":
      return "Audio";
    case "pdf":
      return "PDF";
    case "font":
      return "Font";
    case "document":
      return "Document";
    case "archive":
      return "Archive";
    case "design":
      return "Design";
    case "model":
      return "3D Model";
    default:
      return "File";
  }
}

export function assetIcon(kind: AssetKind) {
  switch (kind) {
    case "image":
      return FileImage;
    case "video":
      return Film;
    case "audio":
      return AudioLines;
    case "pdf":
    case "document":
      return FileText;
    case "font":
      return FileType;
    case "archive":
      return Archive;
    case "design":
      return Palette;
    case "model":
      return Layers3;
    default:
      return File;
  }
}

export function assetAccent(asset: Asset) {
  const accents: Record<AssetKind, string> = {
    image: "from-black/10 to-white/0",
    video: "from-black/10 to-white/0",
    audio: "from-black/10 to-white/0",
    pdf: "from-black/10 to-white/0",
    font: "from-black/10 to-white/0",
    document: "from-black/10 to-white/0",
    archive: "from-black/10 to-white/0",
    design: "from-black/10 to-white/0",
    model: "from-black/10 to-white/0",
    unknown: "from-black/10 to-white/0",
  };
  return accents[asset.kind] ?? accents.unknown;
}
