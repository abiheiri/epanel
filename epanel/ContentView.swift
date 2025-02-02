// ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var dataStore = DataStore.shared
    @State private var textInput = ""
    @State private var searchFilter = ""
    @State private var selectedEntryID: UUID?
    @FocusState private var isTextFieldFocused: Bool
    
    var filteredEntries: [Entry] {
        searchFilter.isEmpty ? dataStore.entries : dataStore.entries.filter { $0.text.hasPrefix(searchFilter) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search or Add", text: $textInput)
                    .focused($isTextFieldFocused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addEntry)
                    .onChange(of: textInput) { newValue in
                        if isTextFieldFocused {
                            searchFilter = newValue
                        }
                    }
                    .frame(maxWidth: .infinity)
                
                Button("Add", action: addEntry)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            
            List(selection: $selectedEntryID) {
                ForEach(filteredEntries) { entry in
                    HStack {
                        Text(entry.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(dataStore.dateFormatter.string(from: entry.date))
                            .frame(width: 120, alignment: .trailing)
                    }
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedEntryID = entry.id
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded { _ in
                                openEntry(entry)
                            }
                    )
                    .contextMenu {
                        Button("Go") { openEntry(entry) }
                        Divider()
                        Button("Delete") { deleteEntry(entry) }
                    }
                    .listRowBackground(
                        selectedEntryID == entry.id
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                }
            }
            .environment(\.defaultMinListRowHeight, 30)
            .onCopyCommand { // Handle Copy command (menu item or keyboard shortcut)
                guard let selectedID = selectedEntryID,
                      let entry = dataStore.entries.first(where: { $0.id == selectedID }) else {
                    return []
                }
                let itemProvider = NSItemProvider(object: entry.text as NSString)
                return [itemProvider]
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .alert("Error", isPresented: $dataStore.showAlert) {
            Button("OK") { }
        } message: {
            Text(dataStore.alertMessage)
        }
        .background(
            Button(action: deleteSelectedEntry) {
                EmptyView()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .frame(width: 0, height: 0)
        )
    }
    
    private func addEntry() {
        guard !textInput.isEmpty else { return }
        let newEntry = Entry(text: textInput, date: Date())
        dataStore.entries.append(newEntry)
        selectedEntryID = newEntry.id
        // Clear both the display and filter so the list shows everything.
        textInput = ""
        searchFilter = ""
        // Optionally remove focus after adding.
        isTextFieldFocused = false
    }
    
    private func deleteEntry(_ entry: Entry) {
        dataStore.entries.removeAll { $0 == entry }
        if selectedEntryID == entry.id {
            selectedEntryID = nil
        }
    }
    
    private func deleteSelectedEntry() {
        guard let selectedId = selectedEntryID,
              let entry = dataStore.entries.first(where: { $0.id == selectedId }) else { return }
        deleteEntry(entry)
    }
    
    private func openEntry(_ entry: Entry) {
        let rawPath = entry.text
        let config = NSWorkspace.OpenConfiguration()
        
        if let url = URL(string: rawPath), url.scheme != nil {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error = error {
                    self.dataStore.showAlert(message: "URL Open Failed: \(error.localizedDescription)")
                }
            }
        } else {
            let fileURL = URL(fileURLWithPath: rawPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDirectory) else {
                dataStore.showAlert(message: "Path not found: \(rawPath)")
                return
            }
            if isDirectory.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } else {
                NSWorkspace.shared.openApplication(at: fileURL, configuration: config) { _, error in
                    if let error = error {
                        self.dataStore.showAlert(message: "File Open Failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
}
