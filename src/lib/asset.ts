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
import type { AssetKind } from "../types";

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
