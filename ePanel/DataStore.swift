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

/// Serializable data stored in the shared epanel.json (folders/entries only).
/// Notes are stored in a separate notes.txt file alongside the JSON.
struct EPanelData: Codable {
    var rootFolder: Folder

    static var empty: EPanelData {
        EPanelData(
            rootFolder: Folder(id: FolderConstants.rootFolderID, name: FolderConstants.rootFolderName)
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
            guard !isApplyingExternalChange else { return }
            debouncedSaveData()
            if safariSyncEnabled && !isSyncingFromSafari {
                syncManager?.scheduleWriteback()
            }
        }
    }
    @Published var notes: String = "" {
        didSet {
            debouncedSaveNotes()
        }
    }
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var safariSyncEnabled: Bool = false
    @Published var lastSyncDate: Date?
    @Published var dataFileURL: URL?
    @Published var needsFileSelection: Bool = false

    private var saveDataWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.epanel.save", qos: .utility)
    private var syncManager: SafariSyncManager?
    private var isSyncingFromSafari = false
    private var fileMonitor: FileMonitor?
    private var notesFileMonitor: FileMonitor?
    private var dataPollTimer: DispatchSourceTimer?
    private var isApplyingExternalChange = false
    /// Whether we hold an open security scope grant for the file monitors
    private var dataFolderScopeAccessed = false
    private var lastWrittenNotesContent: String = ""
    /// Tracks the notes content we knew about when we last read — so we can detect external appends
    private var lastKnownNotesContent: String = ""
    /// Content hash of last JSON we wrote, to detect self-triggered changes
    private var lastWrittenDataHash: Int? = nil
    /// Resolved security-scoped bookmark URL for the data *folder* (grants access to all files inside)
    private var dataFolderURL: URL?

    private let syncEnabledKey = "safariSyncEnabled"
    static let dataFolderBookmarkKey = "dataFolderBookmarkKey"

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

    /// The companion notes file path (notes.txt alongside the JSON)
    private var notesFileURL: URL? {
        guard let jsonURL = dataFileURL else { return nil }
        return jsonURL.deletingLastPathComponent().appendingPathComponent("notes.txt")
    }

    init() {
        // Try to restore the previously-selected data folder from security-scoped bookmark
        if let savedFolderURL = resolveDataFolderBookmark() {
            dataFolderURL = savedFolderURL
            let jsonURL = savedFolderURL.appendingPathComponent("epanel.json")
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                dataFileURL = jsonURL
                loadAllData(from: jsonURL)
                startFileMonitoring(for: jsonURL)
            } else {
                needsFileSelection = true
            }
        } else {
            needsFileSelection = true
        }
        loadSyncSettings()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncManager?.stop()
            self?.saveDataSync()
            self?.saveNotesSync()
        }
    }

    // MARK: - File Selection

    /// Ask the user to select the folder containing their ePanel data
    func promptForDataFile() {
        let alert = NSAlert()
        alert.messageText = "Welcome to ePanel"
        alert.informativeText = "Select the folder that contains your ePanel data (epanel.json + notes.txt), or create a new one."
        alert.addButton(withTitle: "Open Existing Folder…")
        alert.addButton(withTitle: "Create New…")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            chooseExistingFolder()
        case .alertSecondButtonReturn:
            createNewFile()
        default:
            NSApplication.shared.terminate(nil)
        }
    }

    private func chooseExistingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder containing your epanel.json file"
        panel.prompt = "Select Folder"
        panel.canCreateDirectories = true

        // Default to iCloud Drive
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            panel.directoryURL = iCloudURL
        }

        panel.begin { [weak self] response in
            guard let self, response == .OK, let folderURL = panel.url else {
                self?.promptForDataFile()
                return
            }
            let jsonURL = folderURL.appendingPathComponent("epanel.json")
            if !FileManager.default.fileExists(atPath: jsonURL.path) {
                // Create empty data file
                let emptyData = EPanelData.empty
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let jsonData = try encoder.encode(emptyData)
                    try jsonData.write(to: jsonURL, options: .atomic)
                } catch {
                    self.showAlert(message: "Failed to create epanel.json: \(error.localizedDescription)")
                    self.promptForDataFile()
                    return
                }
            }
            self.setDataFolder(folderURL)
        }
    }

    private func createNewFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for your new ePanel data"
        panel.prompt = "Select Folder"
        panel.canCreateDirectories = true

        // Default to iCloud Drive / ePanel folder
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("ePanel", isDirectory: true)
        {
            try? FileManager.default.createDirectory(at: iCloudURL, withIntermediateDirectories: true, attributes: nil)
            panel.directoryURL = iCloudURL
        }

        panel.begin { [weak self] response in
            guard let self, response == .OK, let folderURL = panel.url else {
                self?.promptForDataFile()
                return
            }
            let jsonURL = folderURL.appendingPathComponent("epanel.json")

            // Write empty data
            let emptyData = EPanelData.empty
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(emptyData)
                try jsonData.write(to: jsonURL, options: .atomic)
            } catch {
                self.showAlert(message: "Failed to create file: \(error.localizedDescription)")
                self.promptForDataFile()
                return
            }
            // Create empty notes file too
            let notesURL = folderURL.appendingPathComponent("notes.txt")
            if !FileManager.default.fileExists(atPath: notesURL.path) {
                try? "".write(to: notesURL, atomically: true, encoding: .utf8)
            }
            self.setDataFolder(folderURL)
        }
    }

    /// Switch to a different data folder (called from settings too)
    func changeDataFile() {
        stopFileMonitoring()
        dataFileURL = nil
        dataFolderURL = nil
        needsFileSelection = true
        promptForDataFile()
    }

    /// Set the data folder, save directory-scoped bookmark, load data, start monitoring
    private func setDataFolder(_ folderURL: URL) {
        guard saveDataFolderBookmark(for: folderURL) else {
            showAlert(message: "Failed to save folder access permission.")
            promptForDataFile()
            return
        }
        dataFolderURL = folderURL
        let jsonURL = folderURL.appendingPathComponent("epanel.json")
        dataFileURL = jsonURL
        needsFileSelection = false
        loadAllData(from: jsonURL)
        startFileMonitoring(for: jsonURL)
    }

    // MARK: - Load/Save

    /// Load both JSON data and notes from the given file URL
    private func loadAllData(from url: URL) {
        // Load JSON (folders/entries)
        loadData(from: url)
        // Load notes from companion notes.txt
        loadNotes(from: url)
    }

    private func loadData(from url: URL) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        let scopeAccessed = dataFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scopeAccessed { dataFolderURL?.stopAccessingSecurityScopedResource() } }
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readURL in
            guard FileManager.default.fileExists(atPath: readURL.path),
                  let jsonData = try? Data(contentsOf: readURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if var loaded = try? decoder.decode(EPanelData.self, from: jsonData) {
                loaded.rootFolder = self.deduplicateFolder(loaded.rootFolder)
                DispatchQueue.main.async {
                    self.data = loaded
                    self.ensureValidRootFolder()
                }
            }
        }
        if let error {
            print("File coordination read error: \(error)")
        }
    }

    private func loadNotes(from url: URL) {
        let notesURL = url.deletingLastPathComponent().appendingPathComponent("notes.txt")
        // Scope the data folder — grants access to all files inside it
        let scopeAccessed = dataFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scopeAccessed { dataFolderURL?.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: notesURL.path),
              let content = try? String(contentsOf: notesURL, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async {
            self.notes = content
            self.lastKnownNotesContent = content
            self.lastWrittenNotesContent = content
        }
    }

    private func ensureValidRootFolder() {
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
        guard let url = dataFileURL else { return }
        saveQueue.async { [weak self] in
            self?.writeJSON(url: url)
        }
    }

    func saveDataSync() {
        guard let url = dataFileURL else { return }
        saveDataWorkItem?.cancel()
        writeJSON(url: url)
    }

    private func writeJSON(url: URL) {
        let dataToWrite = data
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        // Scope the data folder — grants access to all files inside it
        let scopeAccessed = dataFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scopeAccessed { dataFolderURL?.stopAccessingSecurityScopedResource() } }
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { writeURL in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(dataToWrite)
                // Record hash *before* writing so monitor can skip our own writes
                self.lastWrittenDataHash = jsonData.hashValue
                try jsonData.write(to: writeURL, options: .atomic)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showAlert(message: "Failed to save data: \(error.localizedDescription)")
                }
            }
        }
        if let error = coordinationError {
            print("File coordination write error: \(error)")
        }
    }

    // MARK: - Notes Management

    private func debouncedSaveNotes() {
        saveDataWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveNotes()
        }
        saveDataWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    func saveNotes() {
        guard let url = notesFileURL else { return }
        saveQueue.async { [weak self] in
            self?.writeNotes(url: url)
        }
    }

    func saveNotesSync() {
        guard let url = notesFileURL else { return }
        saveDataWorkItem?.cancel()
        writeNotes(url: url)
    }

    private func writeNotes(url: URL) {
        let contentToWrite = notes
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        // Scope the data folder — grants access to all files inside it (including notes.txt)
        let scopeAccessed = dataFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scopeAccessed { dataFolderURL?.stopAccessingSecurityScopedResource() } }
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { writeURL in
            self.notesFileMonitor?.stop()
            defer { self.notesFileMonitor?.start() }

            do {
                try contentToWrite.write(to: writeURL, atomically: true, encoding: .utf8)
                self.lastWrittenNotesContent = contentToWrite
                self.lastKnownNotesContent = contentToWrite
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showAlert(message: "Failed to save notes: \(error.localizedDescription)")
                }
            }
        }
        if let error = coordinationError {
            print("File coordination notes write error: \(error)")
        }
    }

    // MARK: - Deduplication

    /// Deduplicate all entries in a folder tree. For entries with the same normalized URL,
    /// keep the one with the newest date. Handles same-UUID duplicates and different-UUID-same-URL.
    private func deduplicateFolder(_ folder: Folder) -> Folder {
        var result = folder
        result.entries = deduplicateEntries(result.entries)
        result.subfolders = result.subfolders.map { deduplicateFolder($0) }
        return result
    }

    private func deduplicateEntries(_ entries: [Entry]) -> [Entry] {
        var seenURLs: Set<String> = []
        var result: [Entry] = []

        for entry in entries {
            let normalized = entry.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if seenURLs.contains(normalized) {
                continue // skip duplicate — first occurrence (in order) wins
            }
            seenURLs.insert(normalized)
            result.append(entry)
        }

        return result
    }

    // MARK: - External Change Detection

    /// Handle external changes to the JSON file — re-read and merge
    private func handleExternalDataChange() {
        guard let url = dataFileURL else { return }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        let scopeAccessed = dataFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scopeAccessed { dataFolderURL?.stopAccessingSecurityScopedResource() } }
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readURL in
            guard FileManager.default.fileExists(atPath: readURL.path),
                  let jsonData = try? Data(contentsOf: readURL) else { return }

            // Skip if this was our own write
            if jsonData.hashValue == self.lastWrittenDataHash {
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let incoming = try? decoder.decode(EPanelData.self, from: jsonData) else { return }

            DispatchQueue.main.async {
                // Check if anything actually changed (deep comparison across all folders)
                guard self.hasDataChanged(local: self.data, remote: incoming) else { return }

                self.isApplyingExternalChange = true
                defer { self.isApplyingExternalChange = false }

                // Adopt the remote data directly — the TUI writes the complete file,
                // so this correctly picks up additions AND deletions.
                self.data = incoming
                self.lastSyncDate = Date()
            }
        }
    }

    /// Handle external changes to the notes file — adopt disk content as truth.
    /// The TUI writes the complete file on every save, so pick up additions AND deletions.
    private func handleExternalNotesChange() {
        guard let url = notesFileURL else { return }

        let scopeAccessed = dataFolderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scopeAccessed { dataFolderURL?.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path),
              let diskContent = try? String(contentsOf: url, encoding: .utf8) else { return }

        DispatchQueue.main.async {
            // Skip if this matches what we last knew about (including our own writes)
            if diskContent == self.lastKnownNotesContent { return }

            // Adopt the on-disk version as authoritative — the TUI writes the full file
            self.lastKnownNotesContent = diskContent
            self.lastWrittenNotesContent = diskContent
            self.notes = diskContent
        }
    }

    /// Deep-compare two datasets to see if content actually differs.
    /// Recursively checks all entries and subfolder contents across the entire tree.
    private func hasDataChanged(local: EPanelData, remote: EPanelData) -> Bool {
        return !foldersAreEqual(local.rootFolder, remote.rootFolder)
    }

    /// Recursively compare two folders by entry identity and subtree structure.
    private func foldersAreEqual(_ a: Folder, _ b: Folder) -> Bool {
        // Fast checks: count mismatch = definitely different
        guard a.entries.count == b.entries.count,
              a.subfolders.count == b.subfolders.count else { return false }

        // Compare entries as sets of normalized URLs
        let aEntries = Set(a.entries.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let bEntries = Set(b.entries.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        guard aEntries == bEntries else { return false }

        // Compare subfolders recursively
        for subA in a.subfolders {
            guard let subB = b.subfolders.first(where: { $0.name.lowercased() == subA.name.lowercased() }),
                  foldersAreEqual(subA, subB) else { return false }
        }

        return true
    }

    /// Structured merge: union by UUID/name, deduplicate entries, preserve local order.
    /// New entries from remote are appended at the end of each folder.
    private func mergeData(local: EPanelData, remote: EPanelData) -> EPanelData {
        var merged = local

        // Preserve local entries in order, append truly new remote entries
        let localURLs = Set(local.rootFolder.entries.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let newRemoteEntries = remote.rootFolder.entries.filter {
            !localURLs.contains($0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        merged.rootFolder.entries = local.rootFolder.entries + newRemoteEntries

        merged.rootFolder.subfolders = mergeFolders(local: local.rootFolder.subfolders, remote: remote.rootFolder.subfolders)
        return merged
    }

    private func mergeFolders(local: [Folder], remote: [Folder]) -> [Folder] {
        // Preserve local folder order, merge matching folders in place, append new ones
        var result = local
        var localNameMap: [String: Int] = [:] // lowercase name → index
        for (i, f) in local.enumerated() {
            localNameMap[f.name.lowercased()] = i
        }

        for remoteFolder in remote {
            let remoteName = remoteFolder.name.lowercased()
            if let localIndex = localNameMap[remoteName] {
                // Merge into existing folder — preserve local entry order
                let existing = result[localIndex]
                let existingURLs = Set(existing.entries.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
                let newEntries = remoteFolder.entries.filter {
                    !existingURLs.contains($0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
                }
                result[localIndex].entries = existing.entries + newEntries
                result[localIndex].subfolders = mergeFolders(local: existing.subfolders, remote: remoteFolder.subfolders)
            } else {
                // Brand new folder — append it
                localNameMap[remoteName] = result.count
                result.append(deduplicateFolder(remoteFolder))
            }
        }

        return result
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
        alert.informativeText = "Importing this JSON file will replace all your existing entries and folders. This cannot be undone."
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
                        )
                    )
                    // Import legacy notes into the notes file if they exist
                    if !oldData.notes.isEmpty {
                        notes = oldData.notes
                    }
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

    // MARK: - File Monitoring & Bookmarks

    /// Start monitoring both the JSON and notes files for external changes.
    /// Holds the security scope open for as long as monitoring is active.
    private func startFileMonitoring(for url: URL) {
        // Hold security scope open so FileMonitor's open(O_EVTONLY) succeeds in sandbox
        if !dataFolderScopeAccessed, let folderURL = dataFolderURL {
            if folderURL.startAccessingSecurityScopedResource() {
                dataFolderScopeAccessed = true
            }
        }

        // Monitor the JSON file
        let jsonMonitor = FileMonitor(url: url, queue: .main)
        jsonMonitor.onChange = { [weak self] in
            self?.handleExternalDataChange()
        }
        jsonMonitor.start()
        fileMonitor = jsonMonitor

        // Polling fallback for epanel.json — catches atomic renames the kernel event may miss
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.handleExternalDataChange()
        }
        timer.resume()
        dataPollTimer = timer

        // Monitor the notes file
        let notesURL = url.deletingLastPathComponent().appendingPathComponent("notes.txt")
        if FileManager.default.fileExists(atPath: notesURL.path) {
            let notesMonitor = FileMonitor(url: notesURL, queue: .main)
            notesMonitor.onChange = { [weak self] in
                self?.handleExternalNotesChange()
            }
            notesMonitor.start()
            notesFileMonitor = notesMonitor
        }
    }

    private func stopFileMonitoring() {
        fileMonitor?.stop()
        fileMonitor = nil
        dataPollTimer?.cancel()
        dataPollTimer = nil
        notesFileMonitor?.stop()
        notesFileMonitor = nil

        // Release the held security scope
        if dataFolderScopeAccessed, let folderURL = dataFolderURL {
            folderURL.stopAccessingSecurityScopedResource()
            dataFolderScopeAccessed = false
        }
    }

    // MARK: - Security-Scoped Bookmark

    /// Save a directory-scoped bookmark for the data folder (covers both epanel.json and notes.txt)
    private func saveDataFolderBookmark(for url: URL) -> Bool {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: Self.dataFolderBookmarkKey)
            return true
        } catch {
            print("Failed to create directory bookmark: \(error)")
            return false
        }
    }

    /// Resolve a previously-saved directory-scoped bookmark
    private func resolveDataFolderBookmark() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.dataFolderBookmarkKey) else {
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
                _ = saveDataFolderBookmark(for: url)
            }
            return url
        } catch {
            print("Failed to resolve directory bookmark: \(error)")
            // Clear stale bookmark so user gets re-prompted
            UserDefaults.standard.removeObject(forKey: Self.dataFolderBookmarkKey)
            return nil
        }
    }

    // MARK: - Helpers

    func showAlert(message: String) {
        DispatchQueue.main.async {
            self.alertMessage = message
            self.showAlert = true
        }
    }
}
