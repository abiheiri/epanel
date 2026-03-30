# ePanel

A lightweight Mac app for managing links, notes, and Safari bookmarks in one place.

## What It Does

- **Links** — Store URLs, file paths, VNC connections, shared drives. Double-click to open.
- **Folders** — Organize links into nested folders with drag-and-drop.
- **Notes** — Simple scratch pad that auto-saves. Always there when you need it.
- **Safari Sync** — Bidirectional sync with Safari bookmarks and reading list. Enable in Settings.
- **Search** — Instant filtering across all folders and entries.
- **Import/Export** — JSON, CSV, and one-time Safari bookmark import.

## Quick Start

1. Add a link: type in the text field, press Enter
2. Open a link: double-click it
3. Organize: right-click for move, rename, delete. Drag to reorder.
4. Safari sync: go to Settings tab, toggle "Sync with Safari", select your `Bookmarks.plist`

## Safari Sync

When enabled, your existing ePanel content moves to a `my_original_epanel` folder. Safari's bookmarks and reading list are imported and kept in sync bidirectionally while the app is open. Changes in either direction are reflected within seconds.

## Data

Everything saves to `epanel.json` inside the app's sandboxed container. Auto-saves on every change. Use Export to back up your data.

## Install

Download from Releases. Since the app is not notarized, macOS will block it. Go to System Settings > Privacy & Security, scroll down, and click "Open Anyway" to allow it.
