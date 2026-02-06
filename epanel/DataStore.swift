// DataStore.swift
import Foundation
import AppKit

// MARK: - Constants

enum FolderConstants {
    static let rootFolderID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let rootFolderName = "/"
}

// MARK: - Data Models

struct Entry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var text: String
    var date: Date

    init(id: UUID = UUID(), text: String, date: Date) {
        self.id = id
        self.text = text
        self.date = date
    }
}

struct Folder: Identifiable, Codable {
    let id: UUID
    var name: String
    var entries: [Entry]
    var subfolders: [Folder]
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String, entries: [Entry] = [], subfolders: [Folder] = [], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.entries = entries
        self.subfolders = subfolders
        self.isCollapsed = isCollapsed
    }

    var isRoot: Bool {
        id == FolderConstants.rootFolderID
    }
}

struct EPanelData: Codable {
    var rootFolder: Folder
    var notes: String

    static var empty: EPanelData {
        EPanelData(
            rootFolder: Folder(id: FolderConstants.rootFolderID, name: FolderConstants.rootFolderName),
            notes: ""
        )
    }
}

/// Legacy data format for importing old JSON exports
private struct LegacyEPanelData: Codable {
    var folders: [Folder]
    var rootEntries: [Entry]
    var notes: String
}

// MARK: - DataStore

class DataStore: ObservableObject {
    static let shared = DataStore()

    @Published var data: EPanelData = .empty {
        didSet {
            debouncedSaveData()
        }
    }
    @Published var showAlert = false
    @Published var alertMessage = ""

    private var saveDataWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.epanel.save", qos: .utility)

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // Computed property for flat UI compatibility
    var allEntries: [Entry] {
        var result: [Entry] = []
        func collectEntries(from folder: Folder) {
            result.append(contentsOf: folder.entries)
            for subfolder in folder.subfolders {
                collectEntries(from: subfolder)
            }
        }
        collectEntries(from: data.rootFolder)
        return result
    }

    init() {
        loadData()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveDataSync()
        }
    }

    // MARK: - Load/Save

    func loadData() {
        let jsonURL = getDocumentsDirectory().appendingPathComponent("epanel.json")

        if FileManager.default.fileExists(atPath: jsonURL.path) {
            do {
                let jsonData = try Data(contentsOf: jsonURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                data = try decoder.decode(EPanelData.self, from: jsonData)
                ensureValidRootFolder()
                return
            } catch {
                print("Failed to load JSON: \(error)")
                // Fall through to create fresh data
            }
        }

        // Create fresh data with root folder
        data = .empty
    }

    private func ensureValidRootFolder() {
        // If root folder ID is wrong, fix it
        if data.rootFolder.id != FolderConstants.rootFolderID {
            data.rootFolder = Folder(
                id: FolderConstants.rootFolderID,
                name: FolderConstants.rootFolderName,
                entries: data.rootFolder.entries,
                subfolders: data.rootFolder.subfolders,
                isCollapsed: false
            )
            saveDataSync()
        }
    }

    private func parseCSV(_ csvString: String) -> [Entry] {
        csvString.components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let parts = line.components(separatedBy: ",")
            guard parts.count >= 2,
                  let date = dateFormatter.date(from: parts.last!) else { return nil }
            // Handle text that may contain commas
            let text = parts.dropLast().joined(separator: ",")
            return Entry(text: text, date: date)
        }
    }

    private func debouncedSaveData() {
        saveDataWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveData()
        }
        saveDataWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    func saveData() {
        let dataToSave = data
        saveQueue.async { [weak self] in
            self?.writeJSON(dataToSave)
        }
    }

    func saveDataSync() {
        saveDataWorkItem?.cancel()
        writeJSON(data)
    }

    private func writeJSON(_ dataToWrite: EPanelData) {
        let fileURL = getDocumentsDirectory().appendingPathComponent("epanel.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(dataToWrite)
            try jsonData.write(to: fileURL, options: .atomic)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.showAlert(message: "Failed to save data: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Import/Export

    func importFile(from url: URL) {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "json":
            importJSON(from: url)
        case "plist":
            importSafariBookmarks(from: url)
        default:
            importCSV(from: url)
        }
    }

    private func importJSON(from url: URL) {
        // Show confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Replace All Data?"
        alert.informativeText = "Importing this JSON file will replace all your existing entries, folders, and notes. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                let jsonData = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                // Try new format first
                if let newData = try? decoder.decode(EPanelData.self, from: jsonData) {
                    data = newData
                    ensureValidRootFolder()
                    return
                }

                // Try old format and migrate
                if let oldData = try? decoder.decode(LegacyEPanelData.self, from: jsonData) {
                    data = EPanelData(
                        rootFolder: Folder(
                            id: FolderConstants.rootFolderID,
                            name: FolderConstants.rootFolderName,
                            entries: oldData.rootEntries,
                            subfolders: oldData.folders
                        ),
                        notes: oldData.notes
                    )
                    return
                }

                showAlert(message: "Unrecognized JSON format")
            } catch {
                showAlert(message: "Failed to import JSON: \(error.localizedDescription)")
            }
        }
    }

    private func importCSV(from url: URL) {
        do {
            let csvString = try String(contentsOf: url)
            let importedEntries = parseCSV(csvString)

            guard !importedEntries.isEmpty else {
                showAlert(message: "No valid entries found in CSV file")
                return
            }

            // Deduplicate against existing entries
            let existingTexts = Set(allEntries.map { $0.text })
            let uniqueEntries = importedEntries.filter { !existingTexts.contains($0.text) }
            let duplicateCount = importedEntries.count - uniqueEntries.count

            guard !uniqueEntries.isEmpty else {
                showAlert(message: "All \(importedEntries.count) entries already exist. Nothing imported.")
                return
            }

            // Create import folder under root
            let folderName = "Imported-\(dateFormatter.string(from: Date()))"
            let importFolder = Folder(name: folderName, entries: uniqueEntries)
            data.rootFolder.subfolders.append(importFolder)

            var message = "Created '\(folderName)' with \(uniqueEntries.count) entries."
            if duplicateCount > 0 {
                message += " \(duplicateCount) duplicates were skipped."
            }
            showAlert(message: message)

        } catch {
            showAlert(message: "Failed to read CSV file: \(error.localizedDescription)")
        }
    }

    // MARK: - Safari Bookmarks Import

    private func importSafariBookmarks(from url: URL) {
        do {
            let plistData = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                  let children = plist["Children"] as? [[String: Any]] else {
                showAlert(message: "Invalid Safari bookmarks file format")
                return
            }

            // Convert Safari bookmarks to ePanel folder structure
            let importedFolder = convertSafariBookmarks(children)

            // Collect all existing URLs for deduplication
            var existingURLs = Set(allEntries.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })

            // Find or create "Imported-Safari" folder under root
            if let existingIndex = data.rootFolder.subfolders.firstIndex(where: { $0.name == "Imported-Safari" }) {
                // Merge into existing folder
                var stats = ImportStats()
                mergeFolder(importedFolder, into: &data.rootFolder.subfolders[existingIndex], existingURLs: &existingURLs, stats: &stats)
                showAlert(message: "Merged into 'Imported-Safari': \(stats.entriesAdded) new entries, \(stats.foldersAdded) new folders. \(stats.duplicatesSkipped) duplicates skipped.")
            } else {
                // Create new folder with deduplication
                var stats = ImportStats()
                var newFolder = Folder(name: "Imported-Safari")
                mergeFolder(importedFolder, into: &newFolder, existingURLs: &existingURLs, stats: &stats)
                data.rootFolder.subfolders.insert(newFolder, at: 0)
                showAlert(message: "Created 'Imported-Safari' with \(stats.entriesAdded) entries and \(stats.foldersAdded) folders. \(stats.duplicatesSkipped) duplicates skipped.")
            }

        } catch {
            showAlert(message: "Failed to read Safari bookmarks: \(error.localizedDescription)")
        }
    }

    private struct ImportStats {
        var entriesAdded = 0
        var foldersAdded = 0
        var duplicatesSkipped = 0
    }

    private func convertSafariBookmarks(_ children: [[String: Any]]) -> Folder {
        var folder = Folder(name: "")

        for child in children {
            let bookmarkType = child["WebBookmarkType"] as? String ?? ""
            let title = child["Title"] as? String ?? ""

            if bookmarkType == "WebBookmarkTypeLeaf" {
                // This is a bookmark entry
                if let urlString = child["URLString"] as? String ?? child["URL"] as? String,
                   !urlString.isEmpty {
                    let entry = Entry(text: urlString, date: Date())
                    folder.entries.append(entry)
                }
            } else if bookmarkType == "WebBookmarkTypeList" {
                // This is a folder
                if let subChildren = child["Children"] as? [[String: Any]] {
                    var subfolder = convertSafariBookmarks(subChildren)
                    subfolder.name = title.isEmpty ? "Untitled Folder" : title
                    folder.subfolders.append(subfolder)
                }
            }
        }

        return folder
    }

    private func mergeFolder(_ source: Folder, into target: inout Folder, existingURLs: inout Set<String>, stats: inout ImportStats) {
        // Add entries that don't already exist
        for entry in source.entries {
            let normalizedURL = entry.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !existingURLs.contains(normalizedURL) {
                target.entries.append(entry)
                existingURLs.insert(normalizedURL)
                stats.entriesAdded += 1
            } else {
                stats.duplicatesSkipped += 1
            }
        }

        // Merge subfolders
        for sourceSubfolder in source.subfolders {
            let normalizedName = sourceSubfolder.name.lowercased()
            if let existingIndex = target.subfolders.firstIndex(where: { $0.name.lowercased() == normalizedName }) {
                // Folder exists - merge recursively
                mergeFolder(sourceSubfolder, into: &target.subfolders[existingIndex], existingURLs: &existingURLs, stats: &stats)
            } else {
                // Folder doesn't exist - add it (with deduplication for its contents)
                var newSubfolder = Folder(name: sourceSubfolder.name)
                mergeFolder(sourceSubfolder, into: &newSubfolder, existingURLs: &existingURLs, stats: &stats)
                target.subfolders.append(newSubfolder)
                stats.foldersAdded += 1
            }
        }
    }

    func exportJSON(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: url, options: .atomic)
        } catch {
            showAlert(message: "Export failed: \(error.localizedDescription)")
        }
    }

    func exportCSV(to url: URL) {
        let csvString = allEntries.map {
            "\($0.text),\(dateFormatter.string(from: $0.date))"
        }.joined(separator: "\n")

        do {
            try csvString.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showAlert(message: "Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Folder Operations

    func createFolder(name: String, in parentID: UUID = FolderConstants.rootFolderID) {
        let newFolder = Folder(name: name)
        modifyFolder(id: parentID) { folder in
            folder.subfolders.insert(newFolder, at: 0)
        }
    }

    func renameFolder(id: UUID, to newName: String) {
        // Cannot rename root folder
        guard id != FolderConstants.rootFolderID else { return }
        modifyFolder(id: id) { folder in
            folder.name = newName
        }
    }

    func deleteFolder(id: UUID) {
        // Cannot delete root folder
        guard id != FolderConstants.rootFolderID else { return }

        // Delete from nested folders
        func removeFromSubfolders(_ folders: inout [Folder]) -> Bool {
            for i in folders.indices {
                if folders[i].id == id {
                    folders.remove(at: i)
                    return true
                }
                if removeFromSubfolders(&folders[i].subfolders) {
                    return true
                }
            }
            return false
        }
        _ = removeFromSubfolders(&data.rootFolder.subfolders)
    }

    func toggleFolderCollapsed(id: UUID) {
        // Cannot collapse root folder
        guard id != FolderConstants.rootFolderID else { return }
        modifyFolder(id: id) { folder in
            folder.isCollapsed.toggle()
        }
    }

    private func modifyFolder(id: UUID, modifier: (inout Folder) -> Void) {
        // Check if modifying root folder
        if id == FolderConstants.rootFolderID {
            modifier(&data.rootFolder)
            return
        }
        // Check nested folders
        func modifyInSubfolders(_ folders: inout [Folder]) -> Bool {
            for i in folders.indices {
                if folders[i].id == id {
                    modifier(&folders[i])
                    return true
                }
                if modifyInSubfolders(&folders[i].subfolders) {
                    return true
                }
            }
            return false
        }
        _ = modifyInSubfolders(&data.rootFolder.subfolders)
    }

    // MARK: - Entry Operations

    func moveEntry(entryID: UUID, toFolderID: UUID) {
        // Find and remove the entry from its current location
        var entryToMove: Entry?

        func removeFromFolder(_ folder: inout Folder) -> Entry? {
            if let index = folder.entries.firstIndex(where: { $0.id == entryID }) {
                return folder.entries.remove(at: index)
            }
            for i in folder.subfolders.indices {
                if let entry = removeFromFolder(&folder.subfolders[i]) {
                    return entry
                }
            }
            return nil
        }
        entryToMove = removeFromFolder(&data.rootFolder)

        guard let entry = entryToMove else { return }

        // Add to destination folder
        modifyFolder(id: toFolderID) { folder in
            folder.entries.append(entry)
        }
    }

    func deleteEntry(id: UUID) {
        func removeFromFolder(_ folder: inout Folder) -> Bool {
            if let index = folder.entries.firstIndex(where: { $0.id == id }) {
                folder.entries.remove(at: index)
                return true
            }
            for i in folder.subfolders.indices {
                if removeFromFolder(&folder.subfolders[i]) {
                    return true
                }
            }
            return false
        }
        _ = removeFromFolder(&data.rootFolder)
    }

    func findEntry(id: UUID) -> Entry? {
        func findInFolder(_ folder: Folder) -> Entry? {
            if let entry = folder.entries.first(where: { $0.id == id }) {
                return entry
            }
            for subfolder in folder.subfolders {
                if let entry = findInFolder(subfolder) {
                    return entry
                }
            }
            return nil
        }
        return findInFolder(data.rootFolder)
    }

    /// Add entry to a specific folder (defaults to root folder)
    func addEntry(_ entry: Entry, toFolderID folderID: UUID = FolderConstants.rootFolderID) {
        modifyFolder(id: folderID) { folder in
            folder.entries.append(entry)
        }
    }

    /// Find the folder ID that contains the given item (entry or folder)
    /// Returns the folder ID if item is a folder, or the parent folder ID if item is an entry
    /// Defaults to root folder ID if not found
    func findParentFolderID(for itemID: UUID) -> UUID {
        // Check if itemID is a folder - return its ID so entries add to it
        func findFolder(_ folder: Folder) -> UUID? {
            if folder.id == itemID {
                return folder.id
            }
            for subfolder in folder.subfolders {
                if let found = findFolder(subfolder) {
                    return found
                }
            }
            return nil
        }
        if let folderID = findFolder(data.rootFolder) {
            return folderID
        }

        // Check if itemID is an entry inside a folder - return that folder's ID
        func findEntryParent(_ folder: Folder) -> UUID? {
            if folder.entries.contains(where: { $0.id == itemID }) {
                return folder.id
            }
            for subfolder in folder.subfolders {
                if let found = findEntryParent(subfolder) {
                    return found
                }
            }
            return nil
        }
        if let parentID = findEntryParent(data.rootFolder) {
            return parentID
        }

        // Default to root folder
        return FolderConstants.rootFolderID
    }

    /// Move a folder to a new parent
    func moveFolder(folderID: UUID, toParentID: UUID) {
        // Can't move root folder
        guard folderID != FolderConstants.rootFolderID else { return }

        // Can't move folder into itself or its descendants
        if folderID == toParentID || isDescendant(folderID: toParentID, of: folderID) {
            return
        }

        // Find and remove the folder from its current location
        var folderToMove: Folder?

        func removeFromSubfolders(_ folders: inout [Folder]) -> Folder? {
            for i in folders.indices {
                if folders[i].id == folderID {
                    return folders.remove(at: i)
                }
                if let folder = removeFromSubfolders(&folders[i].subfolders) {
                    return folder
                }
            }
            return nil
        }
        folderToMove = removeFromSubfolders(&data.rootFolder.subfolders)

        guard let folder = folderToMove else { return }

        // Add to destination
        modifyFolder(id: toParentID) { parent in
            parent.subfolders.insert(folder, at: 0)
        }
    }

    /// Check if folderID is a descendant (child, grandchild, etc.) of ancestorID
    func isDescendant(folderID: UUID, of ancestorID: UUID) -> Bool {
        func checkSubfolders(_ folders: [Folder]) -> Bool {
            for folder in folders {
                if folder.id == folderID {
                    return true
                }
                if checkSubfolders(folder.subfolders) {
                    return true
                }
            }
            return false
        }

        // Find the ancestor folder and check its subfolders
        func findAndCheck(_ folder: Folder) -> Bool {
            if folder.id == ancestorID {
                return checkSubfolders(folder.subfolders)
            }
            for subfolder in folder.subfolders {
                if findAndCheck(subfolder) {
                    return true
                }
            }
            return false
        }

        return findAndCheck(data.rootFolder)
    }

    // MARK: - Helpers

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func showAlert(message: String) {
        DispatchQueue.main.async {
            self.alertMessage = message
            self.showAlert = true
        }
    }
}
