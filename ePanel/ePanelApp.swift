import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ePanelApp: App {
    @StateObject private var dataStore = DataStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Remove only the default "New" command.
            CommandGroup(replacing: .newItem) { }

            CommandGroup(before: .saveItem) {
                Button("Open…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)

                Button("Import from Safari (One-Time)") { importFromSafari() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("Export as JSON…") { exportJSON() }
                    .keyboardShortcut("e", modifiers: .command)

                Button("Export as CSV…") { exportCSV() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }


            CommandGroup(replacing: .appInfo) {
                Button("About ePanel") {
                    showCustomAboutPanel()
                }
            }

            CommandGroup(after: .saveItem) {
                Divider()
                Button("Check for Updates…") {
                    checkForUpdates()
                }
            }

            CommandGroup(replacing: .help) {
                Button("ePanel Help") {
                    if let url = URL(string: "https://github.com/abiheiri/epanel/blob/main/README.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            dataStore.importFile(from: url)
        }
    }

    private func importFromSafari() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Safari Bookmarks.plist file"
        panel.prompt = "Import"

        // Try to set initial directory to Safari folder (~/Library/Safari)
        if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            panel.directoryURL = libraryURL.appendingPathComponent("Safari")
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            // Confirm before importing
            let alert = NSAlert()
            alert.messageText = "Import from Safari?"
            alert.informativeText = "This will import bookmarks into an 'Imported-Safari' folder. Duplicates will be skipped."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                self.dataStore.importFile(from: url)
            }
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "epanel.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            dataStore.exportJSON(to: url)
        }
    }

    private func checkForUpdates() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let apiURL = URL(string: "https://api.github.com/repos/abiheiri/epanel/releases/latest")!

        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = "Could not reach GitHub: \(error.localizedDescription)"
                    alert.runModal()
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else {
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = "Could not parse release information."
                    alert.runModal()
                    return
                }

                let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

                if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                    let alert = NSAlert()
                    alert.messageText = "Update Available"
                    alert.informativeText = "ePanel \(latestVersion) is available. You are running \(currentVersion)."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        if let url = URL(string: htmlURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "You're Up to Date"
                    alert.informativeText = "ePanel \(currentVersion) is the latest version."
                    alert.runModal()
                }
            }
        }.resume()
    }

    private func showCustomAboutPanel() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

        let linkText = "www.abiheiri.com"
        let attributed = NSMutableAttributedString(string: linkText)
        attributed.addAttributes([
            .link: URL(string: "https://www.abiheiri.com")!,
            .font: NSFont.systemFont(ofSize: 11)
        ], range: NSRange(location: 0, length: linkText.count))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ePanel",
            .applicationVersion: version,
            .version: build,
            .credits: attributed
        ])
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "epanel.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            dataStore.exportCSV(to: url)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    override init() {
        super.init()
        // Must be set before any windows are created
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            // Disable tabbing on all windows
            for window in NSApp.windows {
                window.tabbingMode = .disallowed
            }

            if let window = NSApp.windows.first,
               let miniaturizeButton = window.standardWindowButton(.miniaturizeButton) {
                miniaturizeButton.target = self
                miniaturizeButton.action = #selector(self.customMiniaturizeAction(_:))
            }
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc func customMiniaturizeAction(_ sender: Any?) {
        createStatusItem()
        NSApp.hide(nil)
    }
    
    @objc func statusItemClicked() {
        NSApp.unhide(nil)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        removeStatusItem()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        removeStatusItem()
    }
    
    private func createStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let icon = NSImage(systemSymbolName: "book.pages", accessibilityDescription: nil)
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(statusItemClicked)
        }
    }
    
    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }
}
