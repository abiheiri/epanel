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
            // Remove only the default File menu items we're replacing.
            CommandGroup(replacing: .newItem) { }
            
            // Add our custom File menu items.
            CommandMenu("File") {
                Button("Open...") { openFile() }
                    .keyboardShortcut("o")
                
                Button("Close Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w")
                
                Divider()
                
                Button("Export...") { exportFile() }
                    .keyboardShortcut("e")
            }
            
            // Replace the default Help menu with our custom Help command.
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
    // The status item appears only when the app is hidden.
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Delay to ensure the window is ready.
        DispatchQueue.main.async {
            self.reorderFileMenu()
            if let window = NSApp.windows.first {
                // Override the minimize (miniaturize) button's target and action.
                if let miniaturizeButton = window.standardWindowButton(.miniaturizeButton) {
                    miniaturizeButton.target = self
                    miniaturizeButton.action = #selector(self.customMiniaturizeAction(_:))
                }
            }
        }
        
        // When the app becomes active, remove the status item.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc func customMiniaturizeAction(_ sender: Any?) {
        createStatusItem()
        // Hide the application instead of actually miniaturizing.
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
        reorderFileMenu()
        removeStatusItem()
    }
    
    private func createStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let icon = NSImage(systemSymbolName: "book.pages", accessibilityDescription: nil)
            icon?.isTemplate = true  // Ensures it adapts to light/dark mode
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
    
    private func reorderFileMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenuItem = mainMenu.item(withTitle: "File") else { return }
        mainMenu.removeItem(fileMenuItem)
        // Insert the File menu immediately after the Application menu (index 1).
        mainMenu.insertItem(fileMenuItem, at: 1)
    }
}
