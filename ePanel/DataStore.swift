// DataStore.swift
import Foundation
import AppKit
import UniformTypeIdentifiers

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

    /// Returns a copy with notes stripped — used when writing to the shared sync file
    var withoutNotes: EPanelData {
        EPanelData(rootFolder: rootFolder, notes: "")
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
            if safariSyncEnabled && !isSyncingFromSafari {
                syncManager?.scheduleWriteback()
            }
            if fileSyncEnabled && !isApplyingFileChange {
                scheduleFileSyncPush()
            }
        }
    }
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var safariSyncEnabled: Bool = false
    @Published var fileSyncEnabled: Bool = false
    @Published var lastSyncDate: Date?
    @Published var fileSyncURL: URL?

    private var saveDataWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.epanel.save", qos: .utility)
    private var syncManager: SafariSyncManager?
    private var isSyncingFromSafari = false
    private var isApplyingFileChange = false
    private var fileMonitor: FileMonitor?
    private var fileSyncPushWorkItem: DispatchWorkItem?
    private var fileMonitorRetryTimer: DispatchSourceTimer?

    private let syncEnabledKey = "safariSyncEnabled"
    static let dataFileBookmarkKey = "dataFileBookmarkData"
    static let fileSyncEnabledKey = "fileSyncEnabled"

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
        loadSyncSettings()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncManager?.stop()
            self?.saveDataSync()
        }
    }

    // MARK: - Load/Save

    /// The sandbox-local URL where full data (including notes) is always persisted.
    private var localDataURL: URL {
        getDocumentsDirectory().appendingPathComponent("epanel.json")
    }

    func loadData() {
        // If syncing, try the iCloud Drive shared file first
        if fileSyncEnabled, let sharedURL = resolveDataFileBookmark() {
            let needsStop = sharedURL.startAccessingSecurityScopedResource()
            defer { if needsStop { sharedURL.stopAccessingSecurityScopedResource() } }

            if FileManager.default.fileExists(atPath: sharedURL.path),
               let jsonData = try? Data(contentsOf: sharedURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let shared = try? decoder.decode(EPanelData.self, from: jsonData) {
                    data = shared
                    ensureValidRootFolder()
                    restoreLocalNotes()
                    return
                }
            }
            print("iCloud Drive file unreachable, falling back to local sandbox")
        }

        // Load from local sandbox (no sync, or fallback when shared is unreachable)
        if FileManager.default.fileExists(atPath: localDataURL.path) {
            do {
                let jsonData = try Data(contentsOf: localDataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                data = try decoder.decode(EPanelData.self, from: jsonData)
                ensureValidRootFolder()
                return
            } catch {
                print("Failed to load JSON from local: \(error)")
            }
        }

        data = .empty
    }

    /// Restore notes from the local sandbox after loading folders/entries from shared file.
    private func restoreLocalNotes() {
        guard FileManager.default.fileExists(atPath: localDataURL.path),
              let jsonData = try? Data(contentsOf: localDataURL),
              let local = try? JSONDecoder().decode(EPanelData.self, from: jsonData)
        else { return }
        data.notes = local.notes
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
        // Always save full data (including notes) to the local sandbox
        let fileURL = localDataURL
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
        // Skip if already in the target folder
        let currentParent = findParentFolderID(for: entryID)
        if currentParent == toFolderID { return }

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

    func moveEntries(entryIDs: [UUID], toFolderID: UUID) {
        for entryID in entryIDs {
            moveEntry(entryID: entryID, toFolderID: toFolderID)
        }
    }

    func deleteEntries(ids: Set<UUID>) {
        for id in ids {
            deleteEntry(id: id)
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

        // Skip if already in the target parent
        func findCurrentParent(_ folder: Folder) -> UUID? {
            if folder.subfolders.contains(where: { $0.id == folderID }) { return folder.id }
            for sub in folder.subfolders {
                if let found = findCurrentParent(sub) { return found }
            }
            return nil
        }
        if findCurrentParent(data.rootFolder) == toParentID { return }

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

    // MARK: - Safari Sync

    private func loadSyncSettings() {
        safariSyncEnabled = UserDefaults.standard.bool(forKey: syncEnabledKey)

        // Restore file sync FIRST so iCloud data is loaded before Safari sync.
        // This prevents a race where Safari sync replaces folders with new UUIDs,
        // then reloadAndMerge reads stale iCloud data and merges by UUID — creating
        // duplicates since the Safari-imported items have different UUIDs.
        let wasFileSyncEnabled = UserDefaults.standard.bool(forKey: Self.fileSyncEnabledKey)
        if wasFileSyncEnabled {
            if resolveDataFileBookmark() != nil {
                enableFileSyncMonitor()
            } else {
                // Bookmark stale, reset
                UserDefaults.standard.set(false, forKey: Self.fileSyncEnabledKey)
            }
        }

        // THEN start Safari sync (so iCloud data is already in memory)
        if safariSyncEnabled {
            let manager = SafariSyncManager()
            manager.dataStore = self
            if let url = manager.resolveBookmark() {
                syncManager = manager
                manager.start(with: url)
            } else {
                // Bookmark resolution failed; disable sync
                safariSyncEnabled = false
                UserDefaults.standard.set(false, forKey: syncEnabledKey)
            }
        }
    }

    func enableSafariSync(bookmarksPlistURL: URL) {
        let manager = SafariSyncManager()
        manager.dataStore = self

        guard manager.saveBookmarkData(for: bookmarksPlistURL) else {
            showAlert(message: "Failed to save file access permission.")
            return
        }

        // Move existing content to /my_original_epanel
        moveExistingContentToOriginalFolder()

        // Full import from Safari
        let accessed = bookmarksPlistURL.startAccessingSecurityScopedResource()
        if let (bookmarkFolders, readingList) = manager.performFullImport(from: bookmarksPlistURL) {
            applyFullSafariImport(bookmarkFolders: bookmarkFolders, readingList: readingList)
        }
        if accessed { bookmarksPlistURL.stopAccessingSecurityScopedResource() }

        // Persist setting and start continuous sync
        safariSyncEnabled = true
        UserDefaults.standard.set(true, forKey: syncEnabledKey)
        syncManager = manager
        manager.start(with: bookmarksPlistURL)
    }

    func disableSafariSync() {
        syncManager?.stop()
        syncManager = nil
        safariSyncEnabled = false
        UserDefaults.standard.set(false, forKey: syncEnabledKey)
    }

    private func moveExistingContentToOriginalFolder() {
        let hasContent = !data.rootFolder.entries.isEmpty || !data.rootFolder.subfolders.isEmpty
        guard hasContent else { return }

        // Don't re-migrate if the folder already exists
        if data.rootFolder.subfolders.contains(where: { $0.name == "my_original_epanel" }) { return }

        let originalFolder = Folder(
            name: "my_original_epanel",
            entries: data.rootFolder.entries,
            subfolders: data.rootFolder.subfolders
        )
        data.rootFolder.entries = []
        data.rootFolder.subfolders = [originalFolder]
    }

    private func applyFullSafariImport(bookmarkFolders: [Folder], readingList: Folder) {
        var existingURLs = Set(allEntries.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        var stats = ImportStats()

        // Import bookmark folders into root
        for sourceFolder in bookmarkFolders {
            var newFolder = Folder(name: sourceFolder.name)
            mergeFolder(sourceFolder, into: &newFolder, existingURLs: &existingURLs, stats: &stats)
            if !newFolder.entries.isEmpty || !newFolder.subfolders.isEmpty {
                data.rootFolder.subfolders.append(newFolder)
            }
        }

        // Import reading list as separate root folder
        if !readingList.entries.isEmpty || !readingList.subfolders.isEmpty {
            var rlFolder = Folder(name: "Reading List")
            mergeFolder(readingList, into: &rlFolder, existingURLs: &existingURLs, stats: &stats)
            data.rootFolder.subfolders.insert(rlFolder, at: 0)
        }

        lastSyncDate = Date()
    }

    /// Called by SafariSyncManager on the main thread when file changes are detected.
    /// Replaces synced folder contents with Safari's current state so that additions
    /// AND deletions in Safari are reflected. Non-synced folders (my_original_epanel,
    /// user-created root folders) are untouched.
    func applySafariSync(bookmarkFolders: [Folder], readingList: Folder) {
        isSyncingFromSafari = true
        defer { isSyncingFromSafari = false }

        // Capture folder collapsed/expanded state so replacement doesn't lose it
        var collapsedState: [String: Bool] = [:]
        func captureState(_ folder: Folder) {
            collapsedState[folder.name] = folder.isCollapsed
            for sub in folder.subfolders { captureState(sub) }
        }
        for sub in data.rootFolder.subfolders { captureState(sub) }

        func restoreState(_ folder: inout Folder) {
            if let state = collapsedState[folder.name] {
                folder.isCollapsed = state
            }
            for i in folder.subfolders.indices { restoreState(&folder.subfolders[i]) }
        }

        // print("applySafariSync: \(bookmarkFolders.count) bookmark folders, \(readingList.entries.count) reading list entries")

        // Replace each synced bookmark folder with Safari's current version
        for var safariFolder in bookmarkFolders {
            restoreState(&safariFolder)
            if let idx = data.rootFolder.subfolders.firstIndex(where: { $0.name == safariFolder.name }) {
                data.rootFolder.subfolders[idx] = safariFolder
            } else if !safariFolder.entries.isEmpty || !safariFolder.subfolders.isEmpty {
                data.rootFolder.subfolders.append(safariFolder)
            }
        }

        // Replace Reading List
        var rl = readingList
        rl.name = "Reading List"
        restoreState(&rl)
        if let rlIdx = data.rootFolder.subfolders.firstIndex(where: { $0.name == "Reading List" }) {
            data.rootFolder.subfolders[rlIdx] = rl
        } else if !rl.entries.isEmpty {
            data.rootFolder.subfolders.insert(rl, at: 0)
        }

        lastSyncDate = Date()
    }

    // MARK: - File Sync (iCloud Drive)

    /// Opens NSOpenPanel for the user to select their shared epanel.json in iCloud Drive
    func chooseDataFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the shared epanel.json file in your iCloud Drive folder"
        panel.prompt = "Use This File"

        // Default to iCloud Drive
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("ePanel", isDirectory: true)
        {
            try? FileManager.default.createDirectory(at: iCloudURL, withIntermediateDirectories: true, attributes: nil)
            panel.directoryURL = iCloudURL
        }

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.enableFileSync(with: url)
        }
    }

    /// Enable file sync with the given shared JSON file
    func enableFileSync(with url: URL) {
        // Save security-scoped bookmark
        guard saveDataFileBookmark(for: url) else {
            showAlert(message: "Failed to save file access permission.")
            return
        }

        // Reload data from the shared file (merge with current in-memory data)
        reloadAndMerge(from: url)

        // Persist setting
        fileSyncEnabled = true
        fileSyncURL = url
        UserDefaults.standard.set(true, forKey: Self.fileSyncEnabledKey)

        // Start file monitor
        startFileMonitor()
    }

    /// Disable file sync, revert to local sandbox storage
    func disableFileSync() {
        fileMonitor?.stop()
        fileMonitor = nil
        fileMonitorRetryTimer?.cancel()
        fileMonitorRetryTimer = nil
        fileSyncEnabled = false
        fileSyncURL = nil
        UserDefaults.standard.set(false, forKey: Self.fileSyncEnabledKey)
        UserDefaults.standard.removeObject(forKey: Self.dataFileBookmarkKey)

        // Save current data to sandbox container
        saveDataSync()
    }

    /// Restore file sync from saved bookmark (on app launch).
    /// Called after loadData() has already loaded from local sandbox (since fileSyncEnabled
    /// was still false at that point), so we now reload the shared file and merge.
    private func enableFileSyncMonitor() {
        guard let url = resolveDataFileBookmark() else { return }
        fileSyncEnabled = true
        fileSyncURL = url
        // Merge in shared content now that sync is back on
        reloadAndMerge(from: url)
        startFileMonitor()
    }

    // MARK: File Sync Internals

    private func saveDataFileBookmark(for url: URL) -> Bool {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: Self.dataFileBookmarkKey)
            return true
        } catch {
            print("Failed to create bookmark for data file: \(error)")
            return false
        }
    }

    private func resolveDataFileBookmark() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.dataFileBookmarkKey) else {
            return nil
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Refresh the bookmark
                _ = saveDataFileBookmark(for: url)
            }
            return url
        } catch {
            print("Failed to resolve data file bookmark: \(error)")
            return nil
        }
    }

    private func startFileMonitor() {
        guard let url = fileSyncURL, url.startAccessingSecurityScopedResource() else { return }

        // If the file exists now, start/restart the kernel monitor
        if FileManager.default.fileExists(atPath: url.path) {
            fileMonitorRetryTimer?.cancel()
            fileMonitorRetryTimer = nil

            // Only restart if not already monitoring this URL
            if fileMonitor == nil {
                let monitor = FileMonitor(url: url, queue: .main)
                monitor.onChange = { [weak self] in
                    self?.handleFileChanged()
                }
                monitor.start()
                fileMonitor = monitor
            }
            return
        }

        // File doesn't exist yet (iCloud Drive offline / evicted).
        // Stop any dead monitor and poll every 10 seconds.
        fileMonitor?.stop()
        fileMonitor = nil

        if fileMonitorRetryTimer != nil { return } // already retrying

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.startFileMonitor()
        }
        timer.resume()
        fileMonitorRetryTimer = timer
    }

    /// Called when the file monitor detects a change to the shared JSON file
    private func handleFileChanged() {
        guard let url = fileSyncURL else { return }
        reloadAndMerge(from: url)
    }

    /// Reload JSON from the given URL and merge with in-memory data
    private func reloadAndMerge(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard FileManager.default.fileExists(atPath: url.path),
              let jsonData = try? Data(contentsOf: url) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let incoming = try? decoder.decode(EPanelData.self, from: jsonData) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isApplyingFileChange = true
            defer { self.isApplyingFileChange = false }

            self.data = self.mergeData(local: self.data, remote: incoming)
            self.lastSyncDate = Date()
        }
    }

    /// Structured merge: union by UUID, prefer newer date on conflicting entries.
    /// Notes are intentionally excluded — they stay local-only per Mac.
    private func mergeData(local: EPanelData, remote: EPanelData) -> EPanelData {
        var merged = local

        // Merge root folder entries
        merged.rootFolder.entries = mergeEntries(local: local.rootFolder.entries, remote: remote.rootFolder.entries)

        // Merge subfolders recursively
        merged.rootFolder.subfolders = mergeFolders(local: local.rootFolder.subfolders, remote: remote.rootFolder.subfolders)

        // Notes: always keep local — not synced

        return merged
    }

    private func mergeEntries(local: [Entry], remote: [Entry]) -> [Entry] {
        var entryMap: [UUID: Entry] = [:]
        var urlMap: [String: UUID] = [:] // normalized URL → UUID

        for e in local {
            entryMap[e.id] = e
            urlMap[e.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] = e.id
        }
        for e in remote {
            let normalizedURL = e.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = entryMap[e.id] {
                // Same UUID — prefer entry with newer date
                if e.date > existing.date {
                    entryMap[e.id] = e
                }
            } else if let existingID = urlMap[normalizedURL], let existing = entryMap[existingID] {
                // Same URL, different UUID — duplicate from race between Safari sync and iCloud sync.
                // Keep the entry with the newer date.
                if e.date > existing.date {
                    entryMap[existingID] = e
                    urlMap[normalizedURL] = e.id
                }
            } else {
                entryMap[e.id] = e
                urlMap[normalizedURL] = e.id
            }
        }
        return entryMap.values.sorted { $0.date > $1.date }
    }

    private func mergeFolders(local: [Folder], remote: [Folder]) -> [Folder] {
        var folderMap: [UUID: Folder] = [:]
        for f in local { folderMap[f.id] = f }
        for f in remote {
            if var existing = folderMap[f.id] {
                // Merge entries and subfolders
                existing.entries = mergeEntries(local: existing.entries, remote: f.entries)
                existing.subfolders = mergeFolders(local: existing.subfolders, remote: f.subfolders)
                // Prefer remote name
                existing.name = f.name
                folderMap[f.id] = existing
            } else {
                folderMap[f.id] = f
            }
        }
        return folderMap.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Debounced push to shared file after local edits. Notes are stripped — they stay local-only.
    private func scheduleFileSyncPush() {
        fileSyncPushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.fileSyncEnabled, let url = self.fileSyncURL else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            // Temporarily stop monitoring to avoid self-triggering
            self.fileMonitor?.stop()
            defer { self.startFileMonitor() }

            // Strip notes — they are local-only per Mac
            let dataToWrite = self.data.withoutNotes
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(dataToWrite)
                try jsonData.write(to: url, options: .atomic)
            } catch {
                print("File sync push failed: \(error)")
            }
        }
        fileSyncPushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
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
