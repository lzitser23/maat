<p align="center">
  <img src="public/favicon.svg" alt="Maat logo" width="120" />
</p>

<h1 align="center">Maat</h1>

<p align="center">
  <strong>A local, private, infinite-canvas asset board — your visual library, entirely on your machine.</strong>
</p>

<p align="center">
  <a href="#features">Features</a> |
  <a href="#installation">Installation</a> |
  <a href="#quick-start">Quick Start</a> |
  <a href="#storage">Storage</a> |
  <a href="#development">Development</a> |
  <a href="#architecture">Architecture</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20macOS-orange" alt="Platform: Windows | macOS" />
  <img src="https://img.shields.io/badge/Native%20SDK-0.4-24C8DB" alt="Native SDK" />
  <img src="https://img.shields.io/badge/React-19-61DAFB" alt="React 19" />
  <img src="https://img.shields.io/badge/Zig-0.16-000000" alt="Zig 0.16" />
  <img src="https://img.shields.io/badge/local--first-no%20cloud-1B1B18" alt="Local-first, no cloud" />
</p>

---

## Overview

**Maat** is a desktop app for **Windows and macOS** for collecting project assets on a freeform infinite canvas — images, screenshots, 3D models, files, fonts, PDFs, and whole [Eagle](https://eagle.cool) `.library` folders — arranged the way you think. Each collection is a local **board**; drop things in, move them around, sketch on top, and find them later.

It's built to feel native and instant: a **Zig + SQLite** engine (via the [Native SDK](https://github.com/vercel-labs/native)) owns import, hashing, thumbnails, and persistence, while the UI stays fast and iterative in **React 19 + TypeScript**. The product boundary is strictly local-first — no account, no cloud backend, no telemetry. Your library lives on disk at `%APPDATA%\MaatNative` on Windows and `~/Library/Application Support/MaatNative` on macOS (see [Storage](#storage)) and nothing leaves the machine, save two things you ask for: pasting or dropping an image URL downloads that one image, and the launch-time update check asks GitHub whether a newer release exists (version metadata only — it never sends anything about you or your library, and failures are silent).

---

## Features

- **Infinite canvas** — freeform pan and zoom, drag assets anywhere, double-click to spotlight one in detail, and a bottom-left minimap to jump around large boards.
- **Local boards** — create as many boards as you like (one per project or collection) and switch between them instantly; everything is stored locally.
- **Import anything** — individual files, whole folders (imported recursively), Eagle `.library` folders (with their tags, folders, notes, and source URLs), OS drag-and-drop, remote image URLs, and clipboard paste. AI training datasets import cleanly: a `.txt` sharing an image's name becomes that image's **caption** instead of a stray text asset.
- **Managed, deduped storage** — imports are copied into a content-addressed local store and de-duplicated per board by SHA-256 hash, so libraries stay portable and never break on moved originals.
- **3D models** — import `.glb`/`.gltf` files like any asset: they get real rendered thumbnails on the board, and spotlighting one opens a Sketchfab-style orbit viewer (drag to rotate, scroll to zoom — confined to the card, so the canvas stays put).
- **Thumbnails** — fast generated previews for images and 3D models, with graceful fallback icons for video, audio, PDF, fonts, design files, and archives.
- **Three view modes** — **Canvas** (the freeform default), **Grid** (a scrollable masonry that never touches your manual layout), and **Infinity** (immersive: chrome hidden, spotlight shows the asset's name and dimensions). `Esc` always exits a focused asset first, then the mode.
- **Captions & prompts in the Inspector** — dataset captions imported from sidecar `.txt` files show read-only per asset, and a free-form **Prompt** field lets you keep the generation prompt with an AI-generated image — both stored locally in the catalog.
- **Drawing mode** — an [Excalidraw](https://excalidraw.com) layer over each board for freehand sketching and annotation, saved per board.
- **Trash + undo/redo** — soft-delete to Trash, and undo/redo for both canvas layout and trashing (`Ctrl/Cmd+Z` / `Ctrl/Cmd+Shift+Z`).
- **Search + scopes** — search names, types, tags, folders, notes, and source URLs (`Ctrl/Cmd+K`); filter by All / Inbox / Trash, by import source folder, or by tag.
- **Auto-arrange** — tidy the current selection or scope into a clean masonry layout without destroying your manual placement.
- **Native, small, and yours** — a frameless native window with a custom titlebar, dark/light themes, and a single ~20 MB portable exe on Windows (frontend and WebView2 loader embedded — no installer, no sibling files).
- **Keeps itself current** — a titlebar pill appears when a newer release is out; one click downloads it (SHA-256-verified against the release's sidecar), swaps the install, and relaunches. Right-click dismisses that version; update failures roll back and are reported once.

---

## Installation

### Download a release

Tagged versions (`v*`) publish to [**Releases**](https://github.com/lzitser23/maat/releases):

| Platform | Asset | Notes |
| --- | --- | --- |
| macOS | `Maat-vX.Y.Z.dmg` | Signed + notarized — open the DMG and drag **Maat** to **Applications** |
| macOS | `Maat-Native-macos-vX.Y.Z.zip` | The same signed, notarized `.app`, zipped |
| Windows | `Maat-portable-vX.Y.Z.exe` | Portable single file — download anywhere and double-click; nothing to unzip or install |

Each release also carries `.sha256` sidecars for the exe and the macOS zip — the in-app updater verifies downloads against them, and you can too.

### Download a CI build

Between releases, every merge to `main` builds both platforms via GitHub Actions (`.github/workflows/build.yml`); download from that run's **Artifacts** on the [Actions page](https://github.com/lzitser23/maat/actions):

| Platform | Asset | Notes |
| --- | --- | --- |
| Windows | `Maat-portable-windows` (single `maat-native.exe`) | Portable — run it from anywhere |
| macOS | `Maat-Native-macos-notarized` (zipped `.app`) | Signed + notarized — opens like any app |

**Windows:** builds are **unsigned**, so SmartScreen will warn on first run — choose **More info → Run anyway**.

**macOS:** release and `main` builds are signed and notarized. Unsigned CI artifacts (PR/`dev` builds, or the plain `Maat-Native-macos` artifact) need the quarantine flag stripped before first launch: `xattr -dr com.apple.quarantine "Maat Native.app"` — and, because GitHub's artifact zip drops file permissions, `chmod +x "Maat Native.app/Contents/MacOS/maat-native"`.

### Build from source

See [Development](#development).

---

## Quick Start

1. **Launch Maat** — it opens on a default board (**Maat Board**).
2. **Add assets** — drag files, a folder, or an Eagle `.library` onto the canvas; paste an image; or use **Import files** / **Import folder** in the sidebar.
3. **Navigate** — scroll (or two-finger swipe) to pan, `Ctrl/Cmd`+scroll to zoom, and `Alt`-drag or middle-drag to pan by hand.
4. **Organize** — drag cards around, or hit **Arrange** to auto-lay-out; filter with the sidebar scopes and search.
5. **Annotate** — toggle **drawing mode** (the pencil) to sketch over the board.
6. **Everything saves locally** — positions, imports, and drawings persist to a local SQLite catalog automatically.

---

## Storage

Maat writes to two separate directories — back up, migrate, or troubleshoot using the first one; the second is disposable.

| Path | What's there | Owned by |
| --- | --- | --- |
| Windows: `%APPDATA%\MaatNative` · macOS: `~/Library/Application Support/MaatNative` | Your data: the SQLite catalog (boards, tags, notes) and the content-addressed managed asset store. This is what you back up or migrate. | Maat (`src-zig/main.zig`) |
| Windows: `%LOCALAPPDATA%\com.lzitser.maat-native` (and the macOS equivalent, keyed by the same bundle id) | Window position/size restore state, diagnostic logs, and (Windows) the WebView2 loader the portable exe stages for itself on launch. Nothing here is user data — safe to delete any time; Maat just re-centers the window and recreates it all. | Native SDK shell + Maat (`src-zig/runner.zig`) |

---

## Stack

| Layer | Choice |
| --- | --- |
| App shell | [Native SDK](https://github.com/vercel-labs/native) (frameless window, custom titlebar) |
| Backend | Zig + bundled SQLite, SHA-256 dedupe, image-thumbnail engine |
| Frontend | React 19 + TypeScript + Vite 7 |
| Styling | Tailwind CSS v4 + the Maat design system (warm-neutral grayscale + ink) |
| Type | Bricolage Grotesque · Hanken Grotesk · JetBrains Mono (self-hosted) |
| State | zustand |
| Canvas drawing | Excalidraw |
| 3D viewer | three.js (lazy-loaded chunk — GLB/glTF orbit viewer + offscreen thumbnail renders) |
| Icons | lucide-react |
| Tests | Playwright (browser E2E) |

---

## Development

### Prerequisites

- **Node 22** and **pnpm 10.15.0** (the repo pins pnpm via `packageManager`).
- **Zig 0.16.0** (pinned via `build.zig.zon`'s `minimum_zig_version`).
- **`@native-sdk/cli@0.5.4`** installed globally: `npm install -g @native-sdk/cli@0.5.4` (pinned to match CI; see `.github/workflows/build.yml`).

### Commands

```bash
git clone https://github.com/lzitser23/maat.git
cd maat
pnpm install
```

```bash
# Run the desktop app (Native SDK + Vite)
pnpm native:dev

# Browser-only UI preview (no Zig backend; uses in-memory mock data)
pnpm dev
```

```bash
# Verify
pnpm build          # tsc + vite build
zig build test      # Zig backend tests
pnpm test:e2e       # Playwright E2E

# Build + package
pnpm native:build          # ReleaseFast binary into zig-out/bin/
pnpm portable:windows      # Windows: the portable single-file exe (zig-out/bin/maat-native.exe)
pnpm native:package:macos  # package for macOS (.app bundle)
```

### Branches & releases

PRs land on **`dev`** (the default branch); merging `dev` → `main` is the promotion step, where CI additionally signs and notarizes the macOS app. Pushing a `v*` tag publishes a GitHub release with both platforms' builds — the tag must match the version in `app.zon` and `package.json`, or the release job fails.

### Project Structure

```text
maat/
|-- src/          # React + TypeScript UI (canvas, sidebar, inspector, zustand store, native bridge)
|-- src-zig/      # Zig backend (commands, SQLite storage, import/ingest engine, local asset server)
|-- app.zon       # Native SDK app manifest
|-- build.zig     # Native SDK build graph
|-- tests/        # Playwright end-to-end tests
|-- public/       # Static assets (favicon / logo)
`-- .github/      # CI workflow (web checks + Windows portable exe + macOS package; notarization on main; releases on v* tags)
```

---

## Architecture

The React layer owns the canvas and UI state (a single `zustand` store in `src/store.ts`) and talks to Zig through a thin bridge (`src/lib/bridge.ts`, which also ships an in-memory mock backend for browser-only preview) over the Native SDK's `window.zero` JS bridge. Every mutation — importing, moving nodes, trashing, saving a drawing — is a command registered in `src-zig/main.zig`. On the Zig side, `storage.zig` owns the SQLite catalog (boards, sources, assets, board nodes) and `ingest.zig` owns the import pipeline: classify (file / folder / Eagle), hash with SHA-256, copy into content-addressed managed storage, extract metadata, and generate image thumbnails. (3D models are the one kind the engine can't rasterize itself — the webview renders each one offscreen with three.js and persists the PNG back through a `set_asset_thumbnail` command.) There is no cloud dependency — the catalog lives beside the app's data directory, and files are served to the webview by a local file server (`src-zig/server.zig`). On Windows the UI itself ships inside the binary: the built frontend is embedded at compile time and served over loopback by `src-zig/embedded_frontend_server.zig`, which is what makes the release a single portable exe.

---

## Acknowledgments

- [Native SDK](https://github.com/vercel-labs/native) — the desktop shell and Zig ↔ web bridge.
- [React](https://react.dev) and [Vite](https://vite.dev) — the UI runtime and build tooling.
- [Excalidraw](https://excalidraw.com) — the drawing layer.
- [Eagle](https://eagle.cool) — the asset-library format Maat imports.
- [Tailwind CSS](https://tailwindcss.com), [zustand](https://github.com/pmndrs/zustand), and [lucide](https://lucide.dev).
