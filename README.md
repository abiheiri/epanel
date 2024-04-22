# ePanel

## Overview
ePanel is a macOS application designed to organize and launch various types of links and paths, enhancing productivity by providing a centralized panel for quick access to frequently used resources like HTML files, VNC connections, SMB shares, and more.

## Features
- **Add, Launch, and Delete Items**: Easily add items through a text box, launch them with a double-click, or delete them via a context menu.
- **Path and URL Handling**: Directly open both local paths and URLs with appropriate applications or Finder, based on the item type.
- **Search and Filter**: Dynamically filter stored items in real-time to quickly locate specific entries.
- **Data Persistence**: Stores items in a comma-separated text file (`epanel.txt`), supporting easy data management and backup.
- **User Alerts**: Displays user-friendly alerts for inaccessible paths or incorrect operations, enhancing the user interface and error handling.

## How It Works
- **Adding Items**: Enter a URL or path and either press enter or click 'Add' to store the item in the table view.
- **Launching Items**: Double-click an item to open it using the default application or Finder for files and directories.
- **Deleting Items**: Right-click an item and choose 'Delete' to remove it, ensuring it is also cleared from the persistent storage.
- **Searching**: Filter items by typing in the search box; the view updates to only show matching entries.
- **Exiting**: Automatically saves all entries to `epanel.txt` upon closing or quitting the application.

## Data Format
Items are stored in `epanel.txt` as human-readable text, with each item separated by commas, facilitating easy manual editing or external processing.

## Usage Examples
- **Open Local Applications**: `file:///Applications/TextEdit.app`
- **Remote Connections**: `vnc://192.168.1.100`
- **Websites**: `http://www.example.com`
- **Access Directories**: Open `/Volumes/ExternalDrive` to view contents in Finder.

---

ePanel combines ease of use with powerful functionality, ideal for users needing organized, quick access to a diverse range of digital resources.
