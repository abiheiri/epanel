# epanel

## Overview
Epanel is a versatile application for macOS designed to streamline the organization and launching of various types of links and paths. It enables users to store, manage, and directly open URLs or paths such as HTML files, VNC connections, SMB shares, and more, with a simple double-click action. The application is tailored to improve productivity by providing a centralized panel for all your frequently used links and paths.

## Features
- **Add New Items**: Users can input text into a text box and either press enter or click an 'Add' button to store new items.
- **Launch with a Double-Click**: Any stored item can be launched by double-clicking on it within the table view. Epanel will use the appropriate application to open the URL or path based on your system defaults.
- **Easy Deletion**: Items can be removed from the list via a delete option in a context menu.
- **Search and Filter**: A dynamic search feature allows users to filter through the stored items in real time, making it easy to find what you're looking for.
- **Data Persistence**: The contents of the panel are stored in a comma-separated text file (`epanel.txt`), allowing for easy data import/export and backup.
- **Context Menu**: Right-clicking on an item brings up a context menu with options to 'Go' (launch the item) or 'Delete' the item from the list.
- **Data Protection**: Epanel ensures that filtered views from search do not affect the data persistence, safeguarding against accidental data loss.

## How It Works
- **Adding Items**: Type a URL or path into the text box and press enter or click the 'Add' button. The item will appear in the table view below.
- **Launching Items**: Double-click an item in the table view to open it with the default application for its type (e.g., web links open in the default browser).
- **Deleting Items**: Right-click an item and select 'Delete' from the context menu to remove it from the table view and the data file.
- **Searching**: As you type in the text box, the table view will update to show only items that contain the typed characters. Clearing the text box will show all items again.
- **Exiting**: When closing Epanel or quitting the application, it automatically saves all currently stored items to `epanel.txt`.

## Data Format
The `epanel.txt` file is a simple, human-readable text file that stores each item on a new line, separated by commas. This format makes it easy to edit manually if needed, or to import/export from other applications.

## Usage Examples
- **Local Applications**: Open TextEdit by storing `file:///Applications/TextEdit.app`.
- **Remote Connections**: Connect to a VNC server by storing `vnc://192.168.1.100`.
- **Websites**: Visit a personal website by storing `http://www.abiheiri.com`.

---

Epanel is built to be intuitive and easy to use, whether you're managing a handful of links or hundreds of them. It's the perfect tool for users who frequently access various remote resources, websites, and files, and want a quick and organized way to launch them.
