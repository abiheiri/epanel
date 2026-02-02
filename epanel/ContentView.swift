import SwiftUI

struct EntryRowView: View {
    let entry: Entry
    let isSelected: Bool
    let dateFormatter: DateFormatter
    let onSelect: () -> Void
    let onDoubleTap: () -> Void
    let onGo: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Text(entry.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Added on: \(dateFormatter.string(from: entry.date))")
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { _ in onDoubleTap() }
            )
            .contextMenu {
                Button("Go", action: onGo)
                Divider()
                Button("Delete", action: onDelete)
            }
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

struct ContentView: View {
    @StateObject private var dataStore = DataStore.shared
    
    var body: some View {
        TabView {
            LinksView(dataStore: dataStore)
                .tabItem {
                    Label("Links", systemImage: "link")
                }
            
            NotesView(dataStore: dataStore)
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
        }
        .frame(minWidth: 500, minHeight: 400)
        .alert("Error", isPresented: $dataStore.showAlert) {
            Button("OK") { }
        } message: {
            Text(dataStore.alertMessage)
        }
    }
}

struct LinksView: View {
    @ObservedObject var dataStore: DataStore
    @State private var textInput = ""
    @State private var searchFilter = ""
    @State private var selectedEntryID: UUID?
    @FocusState private var isTextFieldFocused: Bool
    @State private var isAscending = true
    @State private var cachedFilteredEntries: [Entry] = []

    private func updateFilteredEntries() {
        let entries = searchFilter.isEmpty
            ? dataStore.entries
            : dataStore.entries.filter { $0.text.localizedCaseInsensitiveContains(searchFilter) }

        cachedFilteredEntries = entries.sorted {
            isAscending ? $0.text < $1.text : $0.text > $1.text
        }
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
                HStack {
                    Button {
                        withAnimation {
                            isAscending.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Name")
                            Image(systemName: isAscending ? "arrow.up" : "arrow.down")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                .listRowBackground(Color.clear)

                ForEach(cachedFilteredEntries) { entry in
                    EntryRowView(
                        entry: entry,
                        isSelected: selectedEntryID == entry.id,
                        dateFormatter: dataStore.dateFormatter,
                        onSelect: { selectedEntryID = entry.id },
                        onDoubleTap: { openEntry(entry) },
                        onGo: { openEntry(entry) },
                        onDelete: { deleteEntry(entry) }
                    )
                    .tag(entry.id)
                }
            }
            .environment(\.defaultMinListRowHeight, 30)
            .onCopyCommand {
                guard let selectedID = selectedEntryID,
                      let entry = dataStore.entries.first(where: { $0.id == selectedID })
                else { return [] }
                let itemProvider = NSItemProvider(object: entry.text as NSString)
                return [itemProvider]
            }
        }
        .background(
            Button(action: deleteSelectedEntry) {
                EmptyView()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .frame(width: 0, height: 0)
        )
        .onAppear {
            updateFilteredEntries()
        }
        .onChange(of: dataStore.entries) { _ in
            updateFilteredEntries()
        }
        .onChange(of: searchFilter) { _ in
            updateFilteredEntries()
        }
        .onChange(of: isAscending) { _ in
            updateFilteredEntries()
        }
    }
    
    private func addEntry() {
        guard !textInput.isEmpty else { return }
        let newEntry = Entry(text: textInput, date: Date())
        dataStore.entries.append(newEntry)
        selectedEntryID = newEntry.id
        textInput = ""
        searchFilter = ""
        isTextFieldFocused = false
    }
    
    private func deleteEntry(_ entry: Entry) {
        if let index = dataStore.entries.firstIndex(where: { $0.id == entry.id }) {
            dataStore.entries.remove(at: index)
        }
        if selectedEntryID == entry.id {
            selectedEntryID = nil
        }
    }
    
    private func deleteSelectedEntry() {
        guard let selectedId = selectedEntryID,
              let entry = dataStore.entries.first(where: { $0.id == selectedId })
        else { return }
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
            guard FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDirectory)
            else {
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

struct NotesView: View {
    @ObservedObject var dataStore: DataStore
    
    var body: some View {
        TextEditor(text: $dataStore.notesText)
            .font(.system(size: 14))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
