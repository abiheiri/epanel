# ePanel

## Overview

ePanel is a Mac app I created to consolidate frequently accessed links and notes in one central panel. I built it because I wanted a single place to organize my web pages, system folder locations, shared drives, and VNC connections, along with a space for quick notes. While Mac's built-in tools work well for many users, I found myself wanting everything in one spot. If you also prefer having your common links and notes unified in a single window, ePanel might be worth trying out.

The notes tab is intentionally basic - it's designed for quick thoughts and temporary text that you want to keep handy, similar to sticky notes. While it auto-saves your content, it's not meant to replace full-featured note-taking apps. Think of it more as a convenient scratch pad that's always there when you need it.

## Features

- **Manage Items**: Add via a text box, launch with a double-click, or delete with a right-click.
- **Open Paths & URLs**: Launch local files or URLs with the right app or Finder.
- **Search & Filter**: Instantly find items by typing in the search bar.
- **Auto-Save**: Links tab are saved in `epanel.csv` (CSV format) for easy backup and editing. Notes are saved as `epanel.txt`

## How It Works

- **Add**: Enter a path/URL, press enter or click 'Add.'
- **Launch**: Double-click to open with the default app or Finder.
- **Delete**: Right-click and select 'Delete.'
- **Search**: Type in the search bar to filter items.
- **Exit**: Auto-saves to `epanel.csv` on close.

## Data Format

Items are stored in a simple, comma-separated text file (`epanel.csv`) for easy manual edits.

## Examples

- **Apps**: `file:///Applications/TextEdit.app`
- **Remote**: `vnc://192.168.1.100`
- **Websites**: `http://www.example.com`
- **Folders**: `/Volumes/ExternalDrive` opens in Finder

---

ePanel is simple, fast, and perfect for quick access to your most-used resources.
