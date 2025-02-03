import SwiftUI
import AppKit

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
                
                Divider()
                
                Button("Export…") { exportFile() }
                    .keyboardShortcut("e", modifiers: .command)
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
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            dataStore.importEntries(from: url)
        }
    }
    
    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "epanel.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            dataStore.exportEntries(to: url)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
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
    
    func applicationWillTerminate(_ notification: Notification) {
        DataStore.shared.saveEntries()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
