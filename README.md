# ePanel (Qt/C++)

A cross-platform desktop port of the ePanel link and note manager, built with Qt 6 and C++. Runs on **Windows 10**, **macOS 26**, and **Debian/Ubuntu**.

## Features

- **Links** — Store URLs, file paths, and other links. Double-click to open.
- **Folders** — Organize links into nested folders. Rename, move, delete, drag-and-drop.
- **Notes** — Simple auto-saving scratch pad stored in `notes.txt`.
- **Search** — Instant filtering across folders and entries.
- **Import / Export** — JSON and CSV export, plus one-time JSON/CSV import.
- **Safari Sync** *(macOS only)* — Bidirectional sync with Safari bookmarks and reading list.
- **Shared Data** — Uses the same `epanel.json` + `notes.txt` format as the original macOS app, so multiple instances can share a data folder.

## Quick Start

1. On first launch, choose or create a folder for `epanel.json` and `notes.txt`.
2. Type a link in the search/add field and press **Return** to add it.
3. Right-click folders or entries for actions, or drag them to reorganize.
4. Switch to the **Notes** tab for scratch notes, and **Settings** to change the data folder.

## Command Line

```bash
epanel --data-dir /path/to/epanel-data
```

If the folder does not contain `epanel.json`, an empty one is created.

## Building

### Prerequisites

You need a C++ compiler and **Qt 6** (Widgets, Core, Gui, Network). CMake is also required.

- **macOS**: install Qt 6 via Homebrew (`brew install qt@6`), the [Qt Online Installer](https://www.qt.io/download-qt-installer), or a self-contained download with [aqtinstall](https://github.com/miurahr/aqtinstall). CMake is also required (`brew install cmake`).
- **Linux (Debian/Ubuntu)**: `sudo apt install qt6-base-dev qt6-base-dev-tools libqt6network6-dev cmake build-essential`
- **Windows**: install Qt 6 and CMake via the Qt Online Installer or [aqtinstall](https://github.com/miurahr/aqtinstall), and use MSVC or MinGW.

### Compile

```bash
cd /path/to/epanel_cpp
cmake -B build -S . -DCMAKE_PREFIX_PATH=/path/to/qt6 -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

For exact platform commands, see [BUILD.md](BUILD.md).

## Compatibility

This Qt port reads and writes the same JSON format as the original SwiftUI ePanel, so existing exports can be opened directly.
