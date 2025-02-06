
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

    var filteredEntries: [Entry] {
        let entries = searchFilter.isEmpty
            ? dataStore.entries
            : dataStore.entries.filter { $0.text.localizedCaseInsensitiveContains(searchFilter) }
        
        return entries.sorted {
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

                ForEach(filteredEntries) { entry in
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
        dataStore.entries.removeAll { $0 == entry }
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
    @State private var showFindReplace = false
    @State private var searchText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var wholeWords = false
    @State private var matchCount = 0
    @State private var currentMatchIndex = 0
    @State private var matches: [Range<String.Index>] = []
    @State private var isPerformingReplace = false
    @State private var skipClearMatches = false

    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            TextEditor(text: $dataStore.notesText)
                .font(.system(size: 14))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    Group {
                        if matchCount > 0 {
                            Text("\(currentMatchIndex + 1)/\(matchCount)")
                                .padding(4)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                                .padding(.trailing, 8)
                        }
                    },
                    alignment: .bottomTrailing
                )
            
            if showFindReplace {
                findReplacePanel
                    .transition(.move(edge: .top))
                    .padding()
            }
        }
        .animation(.easeInOut, value: showFindReplace)
        .onChange(of: dataStore.notesText) { _ in
//            print("Text changed, isPerformingReplace: \(isPerformingReplace)")
            if skipClearMatches {
                // Skip clearing matches for programmatic changes.
                return
            }
            clearMatches()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowFindReplace"))) { _ in
            showFindReplace = true
        }
    }
    
    private var findReplacePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Find", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(findNext)
                
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(replaceNext)
            }
            
            HStack {
                Toggle("Case Sensitive", isOn: $caseSensitive)
                    .toggleStyle(.checkbox)
                
                Toggle("Whole Words", isOn: $wholeWords)
                    .toggleStyle(.checkbox)
                
                Spacer()
                
                Text(matchCount == 0 ? "No matches" : "\(matchCount) matches")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Button("Replace All", action: replaceAll)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                
                Spacer()
                
                Button("Previous", action: findPrevious)
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                
                Button("Next", action: findNext)
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                
                Button("Replace", action: replaceNext)
                    .keyboardShortcut(.defaultAction)
                
                Button("Close") {
                    showFindReplace = false
                    clearMatches()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 5)
        .frame(width: 500)
        .onAppear(perform: findMatches)
        .onChange(of: searchText) { _ in findMatches() }
        .onChange(of: caseSensitive) { _ in findMatches() }
        .onChange(of: wholeWords) { _ in findMatches() }
    }
    
    private func findMatches() {
        guard !searchText.isEmpty else {
            clearMatches()
            return
        }
        
        do {
            let pattern: String
            if wholeWords {
                pattern = "\\b\(NSRegularExpression.escapedPattern(for: searchText))\\b"
            } else {
                pattern = NSRegularExpression.escapedPattern(for: searchText)
            }
            
            let options: NSRegularExpression.Options = caseSensitive ? [] : .caseInsensitive
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let nsString = dataStore.notesText as NSString
            let results = regex.matches(in: dataStore.notesText,
                                      range: NSRange(location: 0, length: nsString.length))
            
            // Convert NSRange to Range<String.Index> safely
            matches = results.compactMap { result -> Range<String.Index>? in
                let nsRange = result.range
                guard nsRange.location != NSNotFound else { return nil }
                
                let startUTF16 = dataStore.notesText.utf16.index(
                    dataStore.notesText.utf16.startIndex,
                    offsetBy: nsRange.location,
                    limitedBy: dataStore.notesText.utf16.endIndex
                )
                
                let endUTF16 = dataStore.notesText.utf16.index(
                    dataStore.notesText.utf16.startIndex,
                    offsetBy: nsRange.location + nsRange.length,
                    limitedBy: dataStore.notesText.utf16.endIndex
                )
                
                guard let startUTF16 = startUTF16,
                      let endUTF16 = endUTF16,
                      let start = startUTF16.samePosition(in: dataStore.notesText),
                      let end = endUTF16.samePosition(in: dataStore.notesText)
                else {
                    return nil
                }
                
                return start..<end
            }
            
            matchCount = matches.count
            let _ = print(currentMatchIndex)
            currentMatchIndex = matches.isEmpty ? -1 : 0
            let _ = print(currentMatchIndex)

        } catch {
            clearMatches()
        }
    }
    
    private func clearMatches() {
        let _ = print(currentMatchIndex)
        matches = []
        matchCount = 0
        currentMatchIndex = -1
        let _ = print(currentMatchIndex)

    }
    private func findNext() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
    }
    
    private func findPrevious() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
    }
    
    private func replaceNext() {
        guard !matches.isEmpty else { return }
        
        // Prevent the onChange from clearing the matches during this programmatic change.
        skipClearMatches = true
        defer {
            // Re-enable clearing on subsequent user edits.
            DispatchQueue.main.async {
                skipClearMatches = false
            }
        }
        
        // Get current match before modifying text
        let originalMatch = matches[currentMatchIndex]
//        print(originalMatch)
//        print(matches[currentMatchIndex])
//        print(currentMatchIndex)
        
        // Perform replacement
        var text = dataStore.notesText
        text.replaceSubrange(originalMatch, with: replaceText)
        dataStore.notesText = text
        
        // Update the matches for the modified text
        findMatches()
        
        // Adjust currentMatchIndex if needed
        if !matches.isEmpty {
            currentMatchIndex = min(currentMatchIndex, matches.count - 1)
        } else {
            currentMatchIndex = -1
        }
        
//        print(currentMatchIndex)
    }

    
    private func replaceAll() {
        guard !matches.isEmpty else { return }
        
        var text = dataStore.notesText
        for range in matches.reversed() {
            text.replaceSubrange(range, with: replaceText)
        }
        dataStore.notesText = text
        clearMatches()
    }
}

