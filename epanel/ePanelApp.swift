// ePanelApp.swift
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
            // Remove only default File menu items we're replacing
            CommandGroup(replacing: .newItem) { }
            
            // Add our custom File menu items
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
    func applicationWillTerminate(_ notification: Notification) {
        DataStore.shared.saveEntries()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Delay execution to ensure the main menu is fully set up.
        DispatchQueue.main.async {
            guard let mainMenu = NSApp.mainMenu,
                  let fileMenuItem = mainMenu.item(withTitle: "File") else { return }
            
            // Remove the File menu from its current position.
            mainMenu.removeItem(fileMenuItem)
            
            // Insert the File menu at the desired index.
            // Note: macOS always reserves index 0 for the application menu.
            // Inserting at index 1 places File right after it.
            mainMenu.insertItem(fileMenuItem, at: 1)
        }
    }

}
