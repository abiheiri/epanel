// ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var dataStore = DataStore.shared
    @State private var textInput = ""          // Contents of the text field.
    @State private var searchFilter = ""       // Only used for filtering the list.
    @State private var selectedEntryID: UUID?
    @FocusState private var isTextFieldFocused: Bool  // Tracks whether the text field is focused.
    
    // Compute the list of entries to show.
    var filteredEntries: [Entry] {
        searchFilter.isEmpty ? dataStore.entries : dataStore.entries.filter { $0.text.hasPrefix(searchFilter) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search or Add", text: $textInput)
                    .focused($isTextFieldFocused)
                    .textFieldStyle(.roundedBorder)
                    // When the user submits (e.g. Return key) add the entry.
                    .onSubmit(addEntry)
                    // When text changes, update filtering only if the user is actively editing.
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
                    // A single tap selects the entry and updates the text field
                    .onTapGesture {
                        selectEntry(entry)
                    }
                    // A double tap opens the entry
                    .onTapGesture(count: 2) {
                        openEntry(entry)
                    }
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
        }
        .frame(minWidth: 500, minHeight: 400)
        .alert("Error", isPresented: $dataStore.showAlert) {
            Button("OK") { }
        } message: {
            Text(dataStore.alertMessage)
        }
        // Hidden button to support Command+Backspace for deleting the selected entry.
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
    
    // When a user clicks an entry, update the text field without triggering filtering.
    private func selectEntry(_ entry: Entry) {
        // Update the text field to show the clicked entry.
        textInput = entry.text
        // Clear the filtering string so the list remains unfiltered.
        searchFilter = ""
        selectedEntryID = entry.id
        // Remove focus so that the programmatic update of textInput does not trigger filtering.
        isTextFieldFocused = false
    }
}
