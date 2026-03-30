import Foundation
import AppKit

// MARK: - File Monitor (DispatchSource-based, near-zero CPU when idle)

final class FileMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let url: URL
    private let queue: DispatchQueue
    var onChange: (() -> Void)?

    init(url: URL, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
    }

    func start() {
        setupSource()
    }

    func stop() {
        if let src = source {
            src.cancel()
            source = nil
        }
        // File descriptor is closed in the cancel handler
    }

    private func setupSource() {
        // Clean up previous source if any
        if let src = source {
            src.cancel()
            source = nil
        }

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: queue
        )

        let fd = fileDescriptor

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was atomically replaced (Safari writes a temp file then renames).
                // The old file descriptor points to the unlinked inode. Re-establish.
                src.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    self.setupSource()
                    self.onChange?()
                }
            } else {
                self.onChange?()
            }
        }

        src.setCancelHandler {
            close(fd)
        }

        self.source = src
        src.resume()
    }

    deinit {
        stop()
    }
}

// MARK: - Safari Sync Manager

final class SafariSyncManager {
    weak var dataStore: DataStore?

    private let queue = DispatchQueue(label: "com.epanel.safari-sync", qos: .utility)
    private var fileMonitor: FileMonitor?
    private var fallbackTimer: DispatchSourceTimer?
    private var bookmarkURL: URL?
    private var isAccessingResource = false
    private var lastModificationDate: Date?

    static let bookmarkDataKey = "safariBookmarkData"

    // MARK: - Lifecycle

    func start(with url: URL) {
        bookmarkURL = url

        if url.startAccessingSecurityScopedResource() {
            isAccessingResource = true
        }

        // Primary: event-driven file monitoring via kernel vnode events
        fileMonitor = FileMonitor(url: url, queue: queue)
        fileMonitor?.onChange = { [weak self] in
            self?.handleFileChanged()
        }
        fileMonitor?.start()

        // Fallback: low-frequency poll as safety net (every 30s, 10% leeway)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            self?.handleFileChanged()
        }
        fallbackTimer = timer
        timer.resume()

        // Initial sync
        handleFileChanged()
    }

    func stop() {
        fileMonitor?.stop()
        fileMonitor = nil

        fallbackTimer?.cancel()
        fallbackTimer = nil

        if isAccessingResource, let url = bookmarkURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingResource = false
        }
        bookmarkURL = nil
        lastModificationDate = nil
    }

    // MARK: - Security-Scoped Bookmarks

    func saveBookmarkData(for url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkDataKey)
            return true
        } catch {
            return false
        }
    }

    func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkDataKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            _ = saveBookmarkData(for: url)
        }

        return url
    }

    // MARK: - Change Detection

    private func handleFileChanged() {
        guard let url = bookmarkURL else { return }

        // Tier 1: Check modification date (single stat() call, essentially free)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else { return }

        if let lastMod = lastModificationDate, modDate <= lastMod {
            return // File unchanged since last sync
        }
        lastModificationDate = modDate

        // Tier 2: Parse plist and apply changes
        guard let (bookmarkFolders, readingList) = parseSafariPlist(from: url) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.dataStore?.applySafariSync(bookmarkFolders: bookmarkFolders, readingList: readingList)
        }
    }

    // MARK: - Full Import (first-time sync enable)

    func performFullImport(from url: URL) -> (bookmarkFolders: [Folder], readingList: Folder)? {
        return parseSafariPlist(from: url)
    }

    // MARK: - Plist Parsing

    private func parseSafariPlist(from url: URL) -> (bookmarkFolders: [Folder], readingList: Folder)? {
        guard let plistData = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil
              ) as? [String: Any],
              let children = plist["Children"] as? [[String: Any]] else {
            return nil
        }

        var bookmarkFolders: [Folder] = []
        var readingList = Folder(name: "Reading List")

        for child in children {
            let title = child["Title"] as? String ?? ""
            let bookmarkType = child["WebBookmarkType"] as? String ?? ""

            guard bookmarkType == "WebBookmarkTypeList",
                  let subChildren = child["Children"] as? [[String: Any]] else { continue }

            if title == "com.apple.ReadingList" {
                readingList = Self.convertChildren(subChildren)
                readingList.name = "Reading List"
            } else {
                var subfolder = Self.convertChildren(subChildren)
                switch title {
                case "BookmarksBar":
                    subfolder.name = "Favorites"
                case "BookmarksMenu":
                    subfolder.name = "Bookmarks Menu"
                default:
                    subfolder.name = title.isEmpty ? "Untitled Folder" : title
                }
                bookmarkFolders.append(subfolder)
            }
        }

        return (bookmarkFolders, readingList)
    }

    /// Recursively converts Safari plist children array into a Folder structure
    private static func convertChildren(_ children: [[String: Any]]) -> Folder {
        var folder = Folder(name: "")

        for child in children {
            let bookmarkType = child["WebBookmarkType"] as? String ?? ""

            if bookmarkType == "WebBookmarkTypeLeaf" {
                if let urlString = child["URLString"] as? String ?? child["URL"] as? String,
                   !urlString.isEmpty {
                    folder.entries.append(Entry(text: urlString, date: Date()))
                }
            } else if bookmarkType == "WebBookmarkTypeList" {
                let title = child["Title"] as? String ?? ""
                if let subChildren = child["Children"] as? [[String: Any]] {
                    var subfolder = convertChildren(subChildren)
                    subfolder.name = title.isEmpty ? "Untitled Folder" : title
                    folder.subfolders.append(subfolder)
                }
            }
        }

        return folder
    }

    // MARK: - Write-back to Safari

    private var writebackWorkItem: DispatchWorkItem?

    /// Schedule a debounced write of ePanel's state back to Safari's Bookmarks.plist.
    /// Waits 2 seconds after the last call to coalesce rapid changes.
    func scheduleWriteback() {
        writebackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let dataStore = self.dataStore else { return }
            let rootFolder = DispatchQueue.main.sync { dataStore.data.rootFolder }
            self.performWriteback(rootFolder: rootFolder)
        }
        writebackWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func performWriteback(rootFolder: Folder) {
        guard let url = bookmarkURL else { return }

        // Read existing plist to preserve Safari's metadata (UUIDs, Sync keys, CloudKit, etc.)
        guard let existingData = try? Data(contentsOf: url),
              let existingPlist = try? PropertyListSerialization.propertyList(
                  from: existingData, options: [], format: nil
              ) as? [String: Any],
              let existingChildren = existingPlist["Children"] as? [[String: Any]] else { return }

        // Build lookup maps from existing plist for metadata preservation
        var urlToLeaf: [String: [String: Any]] = [:]
        Self.collectLeaves(from: existingChildren, into: &urlToLeaf)

        var titleToFolder: [String: [String: Any]] = [:]
        Self.collectFolders(from: existingChildren, into: &titleToFolder)

        // Build new Children array
        var newChildren: [[String: Any]] = []

        // Preserve History proxy and other non-standard top-level entries
        for child in existingChildren {
            if (child["WebBookmarkType"] as? String) == "WebBookmarkTypeProxy" {
                newChildren.append(child)
            }
        }

        // Map ePanel folders back to Safari's top-level structure
        let favoritesFolder = rootFolder.subfolders.first(where: { $0.name == "Favorites" })
        let bookmarksMenuFolder = rootFolder.subfolders.first(where: { $0.name == "Bookmarks Menu" })
        let readingListFolder = rootFolder.subfolders.first(where: { $0.name == "Reading List" })

        // Folders that aren't special mappings or the original backup
        let specialNames: Set<String> = ["Favorites", "Bookmarks Menu", "Reading List", "my_original_epanel"]
        let otherFolders = rootFolder.subfolders.filter { !specialNames.contains($0.name) }

        // BookmarksBar (Favorites)
        if let fav = favoritesFolder {
            newChildren.append(Self.buildSafariFolder(
                from: fav, safariTitle: "BookmarksBar",
                urlToLeaf: urlToLeaf, titleToFolder: titleToFolder
            ))
        } else if let existing = existingChildren.first(where: { ($0["Title"] as? String) == "BookmarksBar" }) {
            newChildren.append(existing)
        }

        // BookmarksMenu — also include other custom ePanel folders and root-level entries
        let bmEntries = (bookmarksMenuFolder?.entries ?? []) + rootFolder.entries
        let bmSubfolders = (bookmarksMenuFolder?.subfolders ?? []) + otherFolders
        let mergedBM = Folder(name: "Bookmarks Menu", entries: bmEntries, subfolders: bmSubfolders)
        newChildren.append(Self.buildSafariFolder(
            from: mergedBM, safariTitle: "BookmarksMenu",
            urlToLeaf: urlToLeaf, titleToFolder: titleToFolder
        ))

        // Reading List
        if let rl = readingListFolder {
            newChildren.append(Self.buildSafariReadingList(
                from: rl, urlToLeaf: urlToLeaf,
                existingRL: existingChildren.first(where: { ($0["Title"] as? String) == "com.apple.ReadingList" })
            ))
        } else if let existing = existingChildren.first(where: { ($0["Title"] as? String) == "com.apple.ReadingList" }) {
            newChildren.append(existing)
        }

        // Reconstruct plist preserving all root-level keys
        var newPlist = existingPlist
        newPlist["Children"] = newChildren

        // Write as binary plist (Safari's native format)
        do {
            let binaryData = try PropertyListSerialization.data(
                fromPropertyList: newPlist, format: .binary, options: 0
            )
            try binaryData.write(to: url, options: .atomic)

            // Update lastModificationDate so our file monitor skips this change
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date {
                lastModificationDate = modDate
            }
        } catch {
            // Silent failure for background write-back
        }
    }

    // MARK: - Plist Construction Helpers

    private static func buildSafariFolder(
        from folder: Folder,
        safariTitle: String,
        urlToLeaf: [String: [String: Any]],
        titleToFolder: [String: [String: Any]]
    ) -> [String: Any] {
        let existing = titleToFolder[safariTitle]

        var dict: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": safariTitle,
            "WebBookmarkUUID": existing?["WebBookmarkUUID"] as? String ?? UUID().uuidString
        ]

        // Preserve existing metadata keys (Sync, SyncKey, etc.)
        if let existing {
            for (key, value) in existing where key != "Children" && dict[key] == nil {
                dict[key] = value
            }
        }

        var children: [[String: Any]] = []
        for subfolder in folder.subfolders {
            children.append(buildSafariSubfolder(from: subfolder, urlToLeaf: urlToLeaf, titleToFolder: titleToFolder))
        }
        for entry in folder.entries {
            children.append(buildSafariLeaf(from: entry, urlToLeaf: urlToLeaf))
        }

        if !children.isEmpty {
            dict["Children"] = children
        }
        return dict
    }

    private static func buildSafariSubfolder(
        from folder: Folder,
        urlToLeaf: [String: [String: Any]],
        titleToFolder: [String: [String: Any]]
    ) -> [String: Any] {
        let existing = titleToFolder[folder.name]

        var dict: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": folder.name,
            "WebBookmarkUUID": existing?["WebBookmarkUUID"] as? String ?? UUID().uuidString
        ]

        if let existing {
            for (key, value) in existing where key != "Children" && dict[key] == nil {
                dict[key] = value
            }
        }

        var children: [[String: Any]] = []
        for subfolder in folder.subfolders {
            children.append(buildSafariSubfolder(from: subfolder, urlToLeaf: urlToLeaf, titleToFolder: titleToFolder))
        }
        for entry in folder.entries {
            children.append(buildSafariLeaf(from: entry, urlToLeaf: urlToLeaf))
        }

        if !children.isEmpty {
            dict["Children"] = children
        }
        return dict
    }

    private static func buildSafariLeaf(from entry: Entry, urlToLeaf: [String: [String: Any]]) -> [String: Any] {
        let normalized = entry.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Reuse existing plist entry to preserve UUID and all metadata
        if let existing = urlToLeaf[normalized] {
            return existing
        }

        // Create a new bookmark entry
        return [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": UUID().uuidString,
            "URLString": entry.text,
            "URIDictionary": ["title": entry.text] as [String: Any]
        ]
    }

    private static func buildSafariReadingList(
        from folder: Folder,
        urlToLeaf: [String: [String: Any]],
        existingRL: [String: Any]?
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": "com.apple.ReadingList",
            "WebBookmarkUUID": existingRL?["WebBookmarkUUID"] as? String ?? UUID().uuidString
        ]

        if let existingRL {
            for (key, value) in existingRL where key != "Children" && dict[key] == nil {
                dict[key] = value
            }
        }

        var children: [[String: Any]] = []
        for entry in folder.entries {
            let normalized = entry.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = urlToLeaf[normalized] {
                children.append(existing)
            } else {
                children.append([
                    "WebBookmarkType": "WebBookmarkTypeLeaf",
                    "WebBookmarkUUID": UUID().uuidString,
                    "URLString": entry.text,
                    "URIDictionary": ["title": entry.text] as [String: Any],
                    "ReadingList": [
                        "DateAdded": entry.date,
                        "PreviewText": ""
                    ] as [String: Any],
                    "ReadingListNonSync": [
                        "neverFetchMetadata": false
                    ] as [String: Any]
                ] as [String: Any])
            }
        }

        if !children.isEmpty {
            dict["Children"] = children
        }
        return dict
    }

    // MARK: - Plist Traversal Helpers

    /// Builds a map of normalized URL → full plist leaf entry for metadata preservation
    private static func collectLeaves(from children: [[String: Any]], into map: inout [String: [String: Any]]) {
        for child in children {
            let type = child["WebBookmarkType"] as? String ?? ""
            if type == "WebBookmarkTypeLeaf", let url = child["URLString"] as? String {
                let normalized = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                map[normalized] = child
            } else if type == "WebBookmarkTypeList", let sub = child["Children"] as? [[String: Any]] {
                collectLeaves(from: sub, into: &map)
            }
        }
    }

    /// Builds a map of folder title → full plist folder entry for UUID/metadata preservation
    private static func collectFolders(from children: [[String: Any]], into map: inout [String: [String: Any]]) {
        for child in children {
            if (child["WebBookmarkType"] as? String) == "WebBookmarkTypeList" {
                if let title = child["Title"] as? String {
                    map[title] = child
                }
                if let sub = child["Children"] as? [[String: Any]] {
                    collectFolders(from: sub, into: &map)
                }
            }
        }
    }

    deinit {
        stop()
    }
}
