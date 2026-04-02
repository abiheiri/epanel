import SwiftUI
import UniformTypeIdentifiers

// MARK: - Move Item Wrapper (for sheet presentation)

struct MoveItem: Identifiable {
    let id: UUID
}

// MARK: - Entry Row View

struct EntryRowView: View {
    let entry: Entry
    let isSelected: Bool
    let depth: Int
    let dateFormatter: DateFormatter
    let selectedItemIDs: Set<UUID>
    let onSelect: () -> Void
    let onCommandSelect: () -> Void
    let onDoubleTap: () -> Void
    let onGo: () -> Void
    let onDelete: () -> Void
    let onMoveTo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .foregroundColor(.secondary)
                .font(.caption)
            Text(entry.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(depth) * 16)
        .help("Added on: \(dateFormatter.string(from: entry.date))")
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                onCommandSelect()
            } else {
                onSelect()
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in onDoubleTap() }
        )
        .contextMenu {
            Button("Go", action: onGo)
            Divider()
            Button("Move to...", action: onMoveTo)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .onDrag {
            if selectedItemIDs.contains(entry.id) && selectedItemIDs.count > 1 {
                let payload = selectedItemIDs.map { $0.uuidString }.joined(separator: ",")
                return NSItemProvider(object: payload as NSString)
            }
            return NSItemProvider(object: entry.id.uuidString as NSString)
        }
    }
}

// MARK: - Folder Row View

struct FolderRowView: View {
    let folder: Folder
    let isSelected: Bool
    let isExpanded: Bool  // Passed from parent to reflect actual expansion state
    let depth: Int
    @ObservedObject var dataStore: DataStore
    let onSelect: () -> Void
    let onCommandSelect: () -> Void
    let onToggle: () -> Void
    let onMoveTo: () -> Void
    @Binding var renamingFolderID: UUID?
    @Binding var newFolderName: String
    let commitRename: () -> Void
    @State private var isDropTargeted = false
    @FocusState private var isRenameFieldFocused: Bool

    /// Counts all entries in this folder and all subfolders recursively
    private var totalEntryCount: Int {
        func countEntries(in folder: Folder) -> Int {
            folder.entries.count + folder.subfolders.reduce(0) { $0 + countEntries(in: $1) }
        }
        return countEntries(in: folder)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .foregroundColor(.accentColor)

            if renamingFolderID == folder.id {
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.plain)
                    .focused($isRenameFieldFocused)
                    .onSubmit {
                        commitRename()
                    }
                    .onAppear {
                        newFolderName = folder.name
                        // Delay focus to ensure view is ready
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isRenameFieldFocused = true
                        }
                    }
            } else {
                Text(folder.name)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(totalEntryCount)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(isDropTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                onCommandSelect()
            } else {
                onSelect()
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { _ in onToggle() }
        )
        .contextMenu {
            Button("Rename") {
                newFolderName = folder.name
                renamingFolderID = folder.id
            }
            Button("New Subfolder") {
                dataStore.createFolder(name: "New Folder", in: folder.id)
            }
            Divider()
            Button("Move to...", action: onMoveTo)
            Divider()
            Button("Delete Folder", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "Delete '\(folder.name)'?"
                let count = totalEntryCount
                let subfolderCount = folder.subfolders.count
                var message = "This will delete the folder"
                if subfolderCount > 0 {
                    message += ", \(subfolderCount) subfolder\(subfolderCount == 1 ? "" : "s"),"
                }
                message += " and \(count) entr\(count == 1 ? "y" : "ies") inside. This cannot be undone."
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    dataStore.deleteFolder(id: folder.id)
                }
            }
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .onDrag {
            // Prefix with "folder:" to distinguish from entry drags
            NSItemProvider(object: ("folder:" + folder.id.uuidString) as NSString)
        }
        .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                guard let dragString = item as? String else { return }
                DispatchQueue.main.async {
                    if dragString.hasPrefix("folder:") {
                        let folderIDString = String(dragString.dropFirst(7))
                        if let folderID = UUID(uuidString: folderIDString) {
                            dataStore.moveFolder(folderID: folderID, toParentID: folder.id)
                        }
                    } else {
                        // Entry drag - may be comma-separated for multi-select
                        let entryIDs = dragString.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                        dataStore.moveEntries(entryIDs: entryIDs, toFolderID: folder.id)
                    }
                }
            }
            return true
        }
    }
}

// MARK: - Folder Destination Item (for picker)

struct FolderDestination: Identifiable, Hashable {
    let stableID: UUID  // Always non-nil for Identifiable
    let folderID: UUID?  // nil means root
    let name: String
    let depth: Int

    var id: UUID { stableID }

    init(folderID: UUID?, name: String, depth: Int) {
        self.stableID = folderID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        self.folderID = folderID
        self.name = name
        self.depth = depth
    }

    static func == (lhs: FolderDestination, rhs: FolderDestination) -> Bool {
        lhs.stableID == rhs.stableID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stableID)
    }
}

// MARK: - Move Entry Sheet

struct MoveEntrySheet: View {
    @ObservedObject var dataStore: DataStore
    let entryID: UUID
    let dismiss: () -> Void
    @State private var selectedFolderID: UUID = FolderConstants.rootFolderID

    var body: some View {
        VStack(spacing: 16) {
            Text("Move Entry To")
                .font(.headline)

            Picker("Destination", selection: $selectedFolderID) {
                Text("/").tag(FolderConstants.rootFolderID)
                ForEach(flattenedFolders, id: \.id) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Move") {
                    dataStore.moveEntry(entryID: entryID, toFolderID: selectedFolderID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var flattenedFolders: [Folder] {
        var result: [Folder] = []
        func collect(_ folders: [Folder]) {
            for folder in folders {
                result.append(folder)
                collect(folder.subfolders)
            }
        }
        collect(dataStore.data.rootFolder.subfolders)
        return result
    }
}

// MARK: - Move Multiple Entries Sheet

struct MoveEntriesSheet: View {
    @ObservedObject var dataStore: DataStore
    let entryIDs: [UUID]
    let dismiss: () -> Void
    @State private var selectedFolderID: UUID = FolderConstants.rootFolderID

    var body: some View {
        VStack(spacing: 16) {
            Text("Move \(entryIDs.count) Items To")
                .font(.headline)

            Picker("Destination", selection: $selectedFolderID) {
                Text("/").tag(FolderConstants.rootFolderID)
                ForEach(flattenedFolders, id: \.id) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Move") {
                    dataStore.moveEntries(entryIDs: entryIDs, toFolderID: selectedFolderID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var flattenedFolders: [Folder] {
        var result: [Folder] = []
        func collect(_ folders: [Folder]) {
            for folder in folders {
                result.append(folder)
                collect(folder.subfolders)
            }
        }
        collect(dataStore.data.rootFolder.subfolders)
        return result
    }
}

// MARK: - Move Folder Sheet

struct MoveFolderSheet: View {
    @ObservedObject var dataStore: DataStore
    let folderID: UUID
    let dismiss: () -> Void
    @State private var selectedFolderID: UUID = FolderConstants.rootFolderID

    var body: some View {
        VStack(spacing: 16) {
            Text("Move Folder To")
                .font(.headline)

            Picker("Destination", selection: $selectedFolderID) {
                Text("/").tag(FolderConstants.rootFolderID)
                ForEach(validDestinations, id: \.id) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Move") {
                    dataStore.moveFolder(folderID: folderID, toParentID: selectedFolderID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var validDestinations: [Folder] {
        var result: [Folder] = []
        func collect(_ folders: [Folder]) {
            for folder in folders {
                // Skip self and descendants
                if folder.id != folderID && !dataStore.isDescendant(folderID: folder.id, of: folderID) {
                    result.append(folder)
                }
                collect(folder.subfolders)
            }
        }
        collect(dataStore.data.rootFolder.subfolders)
        return result
    }
}

// MARK: - New Folder Sheet

struct NewFolderSheet: View {
    @ObservedObject var dataStore: DataStore
    @Binding var isPresented: Bool
    @State private var folderName = "New Folder"
    @State private var selectedParentID: UUID = FolderConstants.rootFolderID
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Create New Folder")
                .font(.headline)

            TextField("Folder Name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFieldFocused)

            Picker("Location", selection: $selectedParentID) {
                Text("/").tag(FolderConstants.rootFolderID)
                ForEach(flattenedFolders, id: \.id) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    if !folderName.isEmpty {
                        dataStore.createFolder(name: folderName, in: selectedParentID)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            isNameFieldFocused = true
        }
    }

    private var flattenedFolders: [Folder] {
        var result: [Folder] = []
        func collect(_ folders: [Folder]) {
            for folder in folders {
                result.append(folder)
                collect(folder.subfolders)
            }
        }
        collect(dataStore.data.rootFolder.subfolders)
        return result
    }
}

// MARK: - Content View

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

            SettingsView(dataStore: dataStore)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .frame(minWidth: 500, minHeight: 400)
        .alert("Notice", isPresented: $dataStore.showAlert) {
            Button("OK") { }
        } message: {
            Text(dataStore.alertMessage)
        }
    }
}

// MARK: - Links View

struct LinksView: View {
    @ObservedObject var dataStore: DataStore
    @State private var textInput = ""
    @State private var searchFilter = ""
    @State private var selectedItemIDs: Set<UUID> = []
    @FocusState private var isTextFieldFocused: Bool
    @State private var renamingFolderID: UUID?
    @State private var newFolderName = ""
    @State private var isRootDropTargeted = false
    @State private var showNewFolderSheet = false
    @State private var searchExpandedFolders: Set<UUID> = []
    @State private var moveEntryItem: MoveItem?
    @State private var moveMultipleEntryIDs: [UUID]?
    @State private var moveFolderItem: MoveItem?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                TextField("Search or Add", text: $textInput)
                    .focused($isTextFieldFocused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addEntry)
                    .onChange(of: textInput) { newValue in
                        if isTextFieldFocused {
                            searchFilter = newValue
                            // Reset manual expansions when search changes
                            searchExpandedFolders.removeAll()
                        }
                    }
                    .frame(maxWidth: .infinity)

                Button("Add", action: addEntry)
                    .keyboardShortcut(.defaultAction)

                Button(action: { showNewFolderSheet = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Create new folder")
            }
            .padding()

            // Tree List
            List {
                // Root "/" folder row - clickable to add entries to root
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text("/")
                        .fontWeight(.medium)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectItem(FolderConstants.rootFolderID)
                }
                .listRowBackground(
                    selectedItemIDs.contains(FolderConstants.rootFolderID)
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                )

                // Folders section
                ForEach(filteredFolders) { folder in
                    FolderSection(
                        folder: folder,
                        depth: 0,
                        dataStore: dataStore,
                        searchFilter: searchFilter,
                        searchExpandedFolders: $searchExpandedFolders,
                        selectedItemIDs: $selectedItemIDs,
                        renamingFolderID: $renamingFolderID,
                        newFolderName: $newFolderName,
                        commitRename: commitRename,
                        openEntry: openEntry,
                        showMoveEntry: { entryID in
                            if selectedItemIDs.count > 1 && selectedItemIDs.contains(entryID) {
                                moveMultipleEntryIDs = Array(selectedItemIDs)
                            } else {
                                moveEntryItem = MoveItem(id: entryID)
                            }
                        },
                        showMoveFolder: { folderID in
                            moveFolderItem = MoveItem(id: folderID)
                        }
                    )
                }

                // Root folder entries (displayed at top level, no special header)
                ForEach(filteredRootEntries) { entry in
                    EntryRowView(
                        entry: entry,
                        isSelected: selectedItemIDs.contains(entry.id),
                        depth: 0,
                        dateFormatter: dataStore.dateFormatter,
                        selectedItemIDs: selectedItemIDs,
                        onSelect: { selectItem(entry.id) },
                        onCommandSelect: { toggleSelectItem(entry.id) },
                        onDoubleTap: { openEntry(entry) },
                        onGo: { openEntry(entry) },
                        onDelete: {
                            if selectedItemIDs.count > 1 && selectedItemIDs.contains(entry.id) {
                                dataStore.deleteEntries(ids: selectedItemIDs)
                                selectedItemIDs.removeAll()
                            } else {
                                dataStore.deleteEntry(id: entry.id)
                                selectedItemIDs.remove(entry.id)
                            }
                        },
                        onMoveTo: {
                            if selectedItemIDs.count > 1 && selectedItemIDs.contains(entry.id) {
                                moveMultipleEntryIDs = Array(selectedItemIDs)
                            } else {
                                moveEntryItem = MoveItem(id: entry.id)
                            }
                        }
                    )
                    .tag(entry.id)
                }
            }
            .onDrop(of: [.plainText], isTargeted: $isRootDropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let dragString = item as? String else { return }
                    DispatchQueue.main.async {
                        if dragString.hasPrefix("folder:") {
                            let folderIDString = String(dragString.dropFirst(7))
                            if let folderID = UUID(uuidString: folderIDString) {
                                dataStore.moveFolder(folderID: folderID, toParentID: FolderConstants.rootFolderID)
                            }
                        } else {
                            let entryIDs = dragString.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                            dataStore.moveEntries(entryIDs: entryIDs, toFolderID: FolderConstants.rootFolderID)
                        }
                    }
                }
                return true
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 28)
            .onCopyCommand {
                let texts = selectedItemIDs.compactMap { dataStore.findEntry(id: $0)?.text }
                guard !texts.isEmpty else { return [] }
                let combined = texts.joined(separator: "\n")
                return [NSItemProvider(object: combined as NSString)]
            }
        }
        .background(
            Button(action: deleteSelectedItems) {
                EmptyView()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(dataStore: dataStore, isPresented: $showNewFolderSheet)
        }
        .sheet(item: $moveEntryItem) { item in
            MoveEntrySheet(dataStore: dataStore, entryID: item.id, dismiss: { moveEntryItem = nil })
        }
        .sheet(isPresented: Binding(
            get: { moveMultipleEntryIDs != nil },
            set: { if !$0 { moveMultipleEntryIDs = nil } }
        )) {
            if let ids = moveMultipleEntryIDs {
                MoveEntriesSheet(dataStore: dataStore, entryIDs: ids, dismiss: { moveMultipleEntryIDs = nil })
            }
        }
        .sheet(item: $moveFolderItem) { item in
            MoveFolderSheet(dataStore: dataStore, folderID: item.id, dismiss: { moveFolderItem = nil })
        }
    }

    // MARK: - Selection & Rename

    private func selectItem(_ id: UUID) {
        if renamingFolderID != nil && renamingFolderID != id {
            commitRename()
        }
        selectedItemIDs = [id]
    }

    private func toggleSelectItem(_ id: UUID) {
        if renamingFolderID != nil && renamingFolderID != id {
            commitRename()
        }
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func commitRename() {
        guard let folderID = renamingFolderID else { return }
        if !newFolderName.isEmpty {
            dataStore.renameFolder(id: folderID, to: newFolderName)
        }
        renamingFolderID = nil
        newFolderName = ""
    }

    // MARK: - Filtered Data

    private var filteredFolders: [Folder] {
        if searchFilter.isEmpty {
            return dataStore.data.rootFolder.subfolders
        }
        return dataStore.data.rootFolder.subfolders.filter { folderMatchesSearch($0) }
    }

    private var filteredRootEntries: [Entry] {
        if searchFilter.isEmpty {
            return dataStore.data.rootFolder.entries
        }
        return dataStore.data.rootFolder.entries.filter {
            $0.text.localizedCaseInsensitiveContains(searchFilter)
        }
    }

    private func folderMatchesSearch(_ folder: Folder) -> Bool {
        // Folder name matches
        if folder.name.localizedCaseInsensitiveContains(searchFilter) {
            return true
        }
        // Any entry matches
        if folder.entries.contains(where: { $0.text.localizedCaseInsensitiveContains(searchFilter) }) {
            return true
        }
        // Any subfolder matches
        return folder.subfolders.contains(where: { folderMatchesSearch($0) })
    }

    // MARK: - Actions

    private func addEntry() {
        guard !textInput.isEmpty else { return }
        let newEntry = Entry(text: textInput, date: Date())

        // Determine target folder based on selection (default to root)
        var targetFolderID: UUID = FolderConstants.rootFolderID
        if let selectedID = selectedItemIDs.first {
            targetFolderID = dataStore.findParentFolderID(for: selectedID)
        }

        dataStore.addEntry(newEntry, toFolderID: targetFolderID)
        selectedItemIDs = [newEntry.id]
        textInput = ""
        searchFilter = ""
        isTextFieldFocused = false
    }

    private func deleteSelectedItems() {
        guard !selectedItemIDs.isEmpty else { return }
        dataStore.deleteEntries(ids: selectedItemIDs)
        selectedItemIDs.removeAll()
    }

    private func openEntry(_ entry: Entry) {
        let rawPath = entry.text
        let config = NSWorkspace.OpenConfiguration()

        if let url = URL(string: rawPath), url.scheme != nil {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error = error {
                    dataStore.showAlert(message: "URL Open Failed: \(error.localizedDescription)")
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
                        dataStore.showAlert(message: "File Open Failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

// MARK: - Folder Section (Recursive)

struct FolderSection: View {
    let folder: Folder
    let depth: Int
    @ObservedObject var dataStore: DataStore
    let searchFilter: String
    @Binding var searchExpandedFolders: Set<UUID>
    @Binding var selectedItemIDs: Set<UUID>
    @Binding var renamingFolderID: UUID?
    @Binding var newFolderName: String
    let commitRename: () -> Void
    let openEntry: (Entry) -> Void
    let showMoveEntry: (UUID) -> Void
    let showMoveFolder: (UUID) -> Void

    // Determine if folder should show expanded
    private var shouldShowExpanded: Bool {
        if searchFilter.isEmpty {
            // Normal mode: use folder's collapsed state
            return !folder.isCollapsed
        } else {
            // Search mode: check if entries match OR user manually expanded
            let hasMatchingEntries = folder.entries.contains(where: {
                $0.text.localizedCaseInsensitiveContains(searchFilter)
            })
            let hasMatchingSubfolders = folder.subfolders.contains(where: { folderMatchesSearch($0) })

            // Auto-expand if entries match, or user manually expanded
            return hasMatchingEntries || hasMatchingSubfolders || searchExpandedFolders.contains(folder.id)
        }
    }

    var body: some View {
        FolderRowView(
            folder: folder,
            isSelected: selectedItemIDs.contains(folder.id),
            isExpanded: shouldShowExpanded,
            depth: depth,
            dataStore: dataStore,
            onSelect: {
                if renamingFolderID != nil && renamingFolderID != folder.id {
                    commitRename()
                }
                selectedItemIDs = [folder.id]
            },
            onCommandSelect: {
                if renamingFolderID != nil && renamingFolderID != folder.id {
                    commitRename()
                }
                if selectedItemIDs.contains(folder.id) {
                    selectedItemIDs.remove(folder.id)
                } else {
                    selectedItemIDs.insert(folder.id)
                }
            },
            onToggle: {
                if searchFilter.isEmpty {
                    dataStore.toggleFolderCollapsed(id: folder.id)
                } else {
                    // In search mode, toggle manual expansion
                    if searchExpandedFolders.contains(folder.id) {
                        searchExpandedFolders.remove(folder.id)
                    } else {
                        searchExpandedFolders.insert(folder.id)
                    }
                }
            },
            onMoveTo: { showMoveFolder(folder.id) },
            renamingFolderID: $renamingFolderID,
            newFolderName: $newFolderName,
            commitRename: commitRename
        )
        .tag(folder.id)

        if shouldShowExpanded {
            // Subfolders
            ForEach(filteredSubfolders) { subfolder in
                FolderSection(
                    folder: subfolder,
                    depth: depth + 1,
                    dataStore: dataStore,
                    searchFilter: searchFilter,
                    searchExpandedFolders: $searchExpandedFolders,
                    selectedItemIDs: $selectedItemIDs,
                    renamingFolderID: $renamingFolderID,
                    newFolderName: $newFolderName,
                    commitRename: commitRename,
                    openEntry: openEntry,
                    showMoveEntry: showMoveEntry,
                    showMoveFolder: showMoveFolder
                )
            }

            // Entries - show all if user manually expanded, otherwise filter
            ForEach(displayedEntries) { entry in
                EntryRowView(
                    entry: entry,
                    isSelected: selectedItemIDs.contains(entry.id),
                    depth: depth + 1,
                    dateFormatter: dataStore.dateFormatter,
                    selectedItemIDs: selectedItemIDs,
                    onSelect: {
                        if renamingFolderID != nil {
                            commitRename()
                        }
                        selectedItemIDs = [entry.id]
                    },
                    onCommandSelect: {
                        if renamingFolderID != nil {
                            commitRename()
                        }
                        if selectedItemIDs.contains(entry.id) {
                            selectedItemIDs.remove(entry.id)
                        } else {
                            selectedItemIDs.insert(entry.id)
                        }
                    },
                    onDoubleTap: { openEntry(entry) },
                    onGo: { openEntry(entry) },
                    onDelete: {
                        if selectedItemIDs.count > 1 && selectedItemIDs.contains(entry.id) {
                            dataStore.deleteEntries(ids: selectedItemIDs)
                            selectedItemIDs.removeAll()
                        } else {
                            dataStore.deleteEntry(id: entry.id)
                            selectedItemIDs.remove(entry.id)
                        }
                    },
                    onMoveTo: { showMoveEntry(entry.id) }
                )
                .tag(entry.id)
            }
        }
    }

    private var filteredSubfolders: [Folder] {
        if searchFilter.isEmpty {
            return folder.subfolders
        }
        return folder.subfolders.filter { folderMatchesSearch($0) }
    }

    private var displayedEntries: [Entry] {
        if searchFilter.isEmpty {
            return folder.entries
        }
        // If user manually expanded this folder, show all entries
        if searchExpandedFolders.contains(folder.id) {
            return folder.entries
        }
        // Otherwise show only matching entries
        return folder.entries.filter {
            $0.text.localizedCaseInsensitiveContains(searchFilter)
        }
    }

    private func folderMatchesSearch(_ folder: Folder) -> Bool {
        if folder.name.localizedCaseInsensitiveContains(searchFilter) {
            return true
        }
        if folder.entries.contains(where: { $0.text.localizedCaseInsensitiveContains(searchFilter) }) {
            return true
        }
        return folder.subfolders.contains(where: { folderMatchesSearch($0) })
    }
}

// MARK: - Notes View

struct NotesView: View {
    @ObservedObject var dataStore: DataStore

    var body: some View {
        TextEditor(text: $dataStore.data.notes)
            .font(.system(size: 14))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var dataStore: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Safari Sync") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Sync with Safari", isOn: Binding(
                        get: { dataStore.safariSyncEnabled },
                        set: { newValue in
                            if newValue {
                                promptForSafariBookmarks()
                            } else {
                                dataStore.disableSafariSync()
                            }
                        }
                    ))

                    if dataStore.safariSyncEnabled {
                        if let lastSync = dataStore.lastSyncDate {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Last synced: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Safari bookmarks and reading list sync automatically while ePanel is open. Your original ePanel content was moved to the 'my_original_epanel' folder.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("When enabled, your existing ePanel content will be moved to a 'my_original_epanel' folder. Safari bookmarks will be imported into the root, and Reading List will appear as a separate folder. New Safari additions sync automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func promptForSafariBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.propertyList]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Safari Bookmarks.plist file to enable sync"
        panel.prompt = "Enable Sync"

        if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            panel.directoryURL = libraryURL.appendingPathComponent("Safari")
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let alert = NSAlert()
            alert.messageText = "Enable Safari Sync?"
            alert.informativeText = "Your existing ePanel content will be moved to a 'my_original_epanel' folder. Safari bookmarks and reading list will be imported and kept in sync."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                dataStore.enableSafariSync(bookmarksPlistURL: url)
            }
        }
    }
}
