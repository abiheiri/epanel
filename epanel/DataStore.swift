// DataStore.swift
import Foundation
import AppKit

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
}

struct EPanelData: Codable {
    var folders: [Folder]
    var rootEntries: [Entry]
    var notes: String

    static var empty: EPanelData {
        EPanelData(folders: [], rootEntries: [], notes: "")
    }
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
        var result = data.rootEntries
        func collectEntries(from folders: [Folder]) {
            for folder in folders {
                result.append(contentsOf: folder.entries)
                collectEntries(from: folder.subfolders)
            }
        }
        collectEntries(from: data.folders)
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

        // Try loading JSON first
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            do {
                let jsonData = try Data(contentsOf: jsonURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                data = try decoder.decode(EPanelData.self, from: jsonData)
                return
            } catch {
                print("Failed to load JSON: \(error)")
            }
        }

        // Migration: try loading old CSV + TXT format
        migrateFromCSV()
    }

    private func migrateFromCSV() {
        let csvURL = getDocumentsDirectory().appendingPathComponent("epanel.csv")
        let txtURL = getDocumentsDirectory().appendingPathComponent("epanel.txt")

        var migratedEntries: [Entry] = []
        var migratedNotes = ""

        // Load old entries
        if let csvData = try? String(contentsOf: csvURL) {
            migratedEntries = parseCSV(csvData)
        }

        // Load old notes
        if let notesData = try? String(contentsOf: txtURL) {
            migratedNotes = notesData
        }

        if !migratedEntries.isEmpty || !migratedNotes.isEmpty {
            data = EPanelData(folders: [], rootEntries: migratedEntries, notes: migratedNotes)
            saveDataSync()
            print("Migrated \(migratedEntries.count) entries from CSV")
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
                data = try decoder.decode(EPanelData.self, from: jsonData)
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

            // Create import folder
            let folderName = "Imported-\(dateFormatter.string(from: Date()))"
            let importFolder = Folder(name: folderName, entries: uniqueEntries)
            data.folders.append(importFolder)

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

            // Find or create "Imported-Safari" folder
            if let existingIndex = data.folders.firstIndex(where: { $0.name == "Imported-Safari" }) {
                // Merge into existing folder
                var stats = ImportStats()
                mergeFolder(importedFolder, into: &data.folders[existingIndex], existingURLs: &existingURLs, stats: &stats)
                showAlert(message: "Merged into 'Imported-Safari': \(stats.entriesAdded) new entries, \(stats.foldersAdded) new folders. \(stats.duplicatesSkipped) duplicates skipped.")
            } else {
                // Create new folder with deduplication
                var stats = ImportStats()
                var newFolder = Folder(name: "Imported-Safari")
                mergeFolder(importedFolder, into: &newFolder, existingURLs: &existingURLs, stats: &stats)
                data.folders.insert(newFolder, at: 0)
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

    func createFolder(name: String, in parentID: UUID? = nil) {
        let newFolder = Folder(name: name)
        if let parentID = parentID {
            modifyFolder(id: parentID) { folder in
                folder.subfolders.insert(newFolder, at: 0)
            }
        } else {
            data.folders.insert(newFolder, at: 0)
        }
    }

    func renameFolder(id: UUID, to newName: String) {
        modifyFolder(id: id) { folder in
            folder.name = newName
        }
    }

    func deleteFolder(id: UUID) {
        // Delete from root folders
        if let index = data.folders.firstIndex(where: { $0.id == id }) {
            data.folders.remove(at: index)
            return
        }
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
        _ = removeFromSubfolders(&data.folders)
    }

    func toggleFolderCollapsed(id: UUID) {
        modifyFolder(id: id) { folder in
            folder.isCollapsed.toggle()
        }
    }

    private func modifyFolder(id: UUID, modifier: (inout Folder) -> Void) {
        // Check root folders
        if let index = data.folders.firstIndex(where: { $0.id == id }) {
            modifier(&data.folders[index])
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
        _ = modifyInSubfolders(&data.folders)
    }

    // MARK: - Entry Operations

    func moveEntry(entryID: UUID, toFolderID: UUID?) {
        // First, find and remove the entry from its current location
        var entryToMove: Entry?

        // Check root entries
        if let index = data.rootEntries.firstIndex(where: { $0.id == entryID }) {
            entryToMove = data.rootEntries.remove(at: index)
        } else {
            // Check folders
            func removeFromFolders(_ folders: inout [Folder]) -> Entry? {
                for i in folders.indices {
                    if let index = folders[i].entries.firstIndex(where: { $0.id == entryID }) {
                        return folders[i].entries.remove(at: index)
                    }
                    if let entry = removeFromFolders(&folders[i].subfolders) {
                        return entry
                    }
                }
                return nil
            }
            entryToMove = removeFromFolders(&data.folders)
        }

        guard let entry = entryToMove else { return }

        // Add to destination
        if let folderID = toFolderID {
            modifyFolder(id: folderID) { folder in
                folder.entries.append(entry)
            }
        } else {
            data.rootEntries.append(entry)
        }
    }

    func deleteEntry(id: UUID) {
        // Check root entries
        if let index = data.rootEntries.firstIndex(where: { $0.id == id }) {
            data.rootEntries.remove(at: index)
            return
        }
        // Check folders
        func removeFromFolders(_ folders: inout [Folder]) -> Bool {
            for i in folders.indices {
                if let index = folders[i].entries.firstIndex(where: { $0.id == id }) {
                    folders[i].entries.remove(at: index)
                    return true
                }
                if removeFromFolders(&folders[i].subfolders) {
                    return true
                }
            }
            return false
        }
        _ = removeFromFolders(&data.folders)
    }

    func findEntry(id: UUID) -> Entry? {
        if let entry = data.rootEntries.first(where: { $0.id == id }) {
            return entry
        }
        func findInFolders(_ folders: [Folder]) -> Entry? {
            for folder in folders {
                if let entry = folder.entries.first(where: { $0.id == id }) {
                    return entry
                }
                if let entry = findInFolders(folder.subfolders) {
                    return entry
                }
            }
            return nil
        }
        return findInFolders(data.folders)
    }

    /// Add entry to a specific folder, or root if folderID is nil
    func addEntry(_ entry: Entry, toFolderID folderID: UUID?) {
        if let folderID = folderID {
            modifyFolder(id: folderID) { folder in
                folder.entries.append(entry)
            }
        } else {
            data.rootEntries.append(entry)
        }
    }

    /// Find the folder ID that contains the given item (entry or folder)
    /// Returns the folder ID if item is inside a folder, nil if at root
    func findParentFolderID(for itemID: UUID) -> UUID? {
        // Check if itemID is a folder - return its ID so entries add to it
        func findFolder(_ folders: [Folder]) -> UUID? {
            for folder in folders {
                if folder.id == itemID {
                    return folder.id
                }
                if let found = findFolder(folder.subfolders) {
                    return found
                }
            }
            return nil
        }
        if let folderID = findFolder(data.folders) {
            return folderID
        }

        // Check if itemID is an entry inside a folder - return that folder's ID
        func findEntryParent(_ folders: [Folder]) -> UUID? {
            for folder in folders {
                if folder.entries.contains(where: { $0.id == itemID }) {
                    return folder.id
                }
                if let found = findEntryParent(folder.subfolders) {
                    return found
                }
            }
            return nil
        }
        return findEntryParent(data.folders)
    }

    /// Move a folder to a new parent (or root if toParentID is nil)
    func moveFolder(folderID: UUID, toParentID: UUID?) {
        // Can't move folder into itself or its descendants
        if let parentID = toParentID {
            if folderID == parentID || isDescendant(folderID: parentID, of: folderID) {
                return
            }
        }

        // Find and remove the folder from its current location
        var folderToMove: Folder?

        // Check root folders
        if let index = data.folders.firstIndex(where: { $0.id == folderID }) {
            folderToMove = data.folders.remove(at: index)
        } else {
            // Check nested folders
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
            folderToMove = removeFromSubfolders(&data.folders)
        }

        guard let folder = folderToMove else { return }

        // Add to destination
        if let parentID = toParentID {
            modifyFolder(id: parentID) { parent in
                parent.subfolders.insert(folder, at: 0)
            }
        } else {
            data.folders.insert(folder, at: 0)
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
        func findAndCheck(_ folders: [Folder]) -> Bool {
            for folder in folders {
                if folder.id == ancestorID {
                    return checkSubfolders(folder.subfolders)
                }
                if findAndCheck(folder.subfolders) {
                    return true
                }
            }
            return false
        }

        return findAndCheck(data.folders)
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
