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

    deinit {
        stop()
    }
}
