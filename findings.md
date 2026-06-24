# ePanel Code Optimization & Efficiency Findings

## P0 — UUID-Based Lookup Index (High Impact)

Nearly every CRUD operation in `DataStore.cpp` performs a full recursive tree walk from the root. Functions like `findEntry`, `findFolder`, `deleteEntry`, `deleteFolder`, `moveEntry`, `moveFolder`, `findParentFolderId`, and `isDescendant` all use `std::function` recursive lambdas that scan the entire tree in O(n).

**Fix:** Maintain a `QHash<QUuid, Folder*>` and `QHash<QUuid, QUuid>` (child → parent folder ID) index. Rebuild the index on load and keep it in sync during mutations. This turns lookup-heavy operations from O(n) to O(1).

---

## P0 — Redundant Repeated Traversals (High Impact)

Several methods trigger multiple redundant traversals of the same tree:

- **`moveFolder`**: calls `findParentFolderId` (1 traversal), `isDescendant` (1 traversal), then a custom `detach` lambda (3rd traversal). That is **3 separate tree walks** for one operation.
- **`deleteEntries`**: loops and calls `deleteEntry` individually — each `deleteEntry` does a full recursive search. For batch-deleting N items, this is O(n × m).
- **`moveEntries`**: same issue — moves each entry individually with full scans.
- **`isDescendant`**: first finds the ancestor by walking the entire tree, then searches its subtree. The first (ancestor-finding) step could be folded into a single traversal.

**Fix:** Consolidate into a single traversal where possible, or rely on the UUID index proposed above.

---

## P1 — O(n²) Matching in TreeModel::updateFolderNode (Medium Impact)

```cpp
// src/ui/TreeModel.cpp ~lines 80-130
for (const DesiredChild &want : desired) {
    // Linear scan for UUID match
    for (int i = row; i < parentNode->children.size(); ++i) { ... }
    // Fallback linear scan for name match
    for (int i = row; i < parentNode->children.size(); ++i) { ... }
}
```

**Fix:** Use `QHash<QUuid, Node*>` and `QHash<QString, Node*>` maps per parent node to get O(n) matching instead of O(n²).

---

## P1 — Copy-Heavy Operations (Medium Impact)

- `Entry` and `Folder` structs are **copied by value** extensively. In `applySafariSync`:
  ```cpp
  for (auto safariFolder : bookmarkFolders) { // copies each Folder
  ```
  Change to `const auto &`.

- `QVector::prepend()` is O(n) due to shifting all elements. Used in `createFolder`, `moveFolder`, `applySafariSync`. Consider `QList` (O(1) prepend) or appending instead.

- `QVector::removeAt(i)` is O(n) due to element shifting. Used in `deleteEntry`, `deleteFolder`, `moveEntry`, `moveFolder`.

- Folder objects are copied in all merge functions (`mergeFolder`, `applyFullSafariImport`, `importSafariBookmarks`). Use move semantics or work on the target directly.

---

## P2 — Polling Every 5 Seconds with Full SHA-256 (Medium Impact)

```cpp
// DataStore constructor
m_pollTimer->setInterval(5000); // polls every 5s
```

`handleExternalDataChange` reads the **entire** JSON file and computes a **SHA-256 hash** of it every 5 seconds regardless of whether anything changed. `QFileSystemWatcher` already handles most modification events.

**Fix:**
- Check `QFileInfo::lastModified()` as a lightweight pre-check.
- Increase poll interval (e.g., 30 seconds).
- Use file size + mtime instead of SHA-256 as the dirtiness check; only hash if those differ.

---

## P2 — Missing Memory Pre-allocation (Low-Medium Impact)

```cpp
// importCsv — no .reserve()
QVector<Entry> unique;
for (const auto &e : imported) { unique.append(e); }

// TreeModel::buildNode — no .reserve()
parentNode->children.append(folderNode);
```

**Fix:** Add `.reserve()` calls before loops where the count is known ahead of time.

---

## P2 — Redundant Data Structures in Constants (Low Impact)

```cpp
// static QUuid initialized from QString in DataStore.cpp and EPanelData.cpp
static const QUuid RootFolderID("00000000-0000-0000-0000-000000000000");
static QUuid s_rootFolderId("00000000-0000-0000-0000-000000000000");
```

Two separate static `QUuid` instances exist for the same concept. The `Folder::isRoot()` check uses `id.isNull()`, which is inconsistent with the explicit root UUID in `EPanelData::empty()`.

**Fix:** Consolidate to a single canonical root UUID definition.

---

## P3 — String Inefficiencies (Low Impact)

- `.toLower().trimmed()` is called repeatedly on the same strings in `foldersEqual`, `deduplicate`, `mergeFolder`, and `importSafariBookmarks`. Cache the normalized form.
- `QString("%1,%2").arg(...).arg(...)` creates intermediate strings in `formatCsv()`. Use `QStringBuilder` (`operator%`) for better performance.
- `QString::fromUtf8(file.readAll())` copies the byte data when `QJsonDocument::fromJson` could accept `QByteArray` directly in `loadNotes`.

---

## P3 — C++ Standard & Build Configuration (Low Impact)

- **C++ Standard**: Currently C++17. C++20 offers `std::span`, designated initializers, and `contains()` for associative containers.
- **Optimization flags**: No `CMAKE_BUILD_TYPE` or `-O2`/`-O3` flags are set in `CMakeLists.txt`.
- **HEADERS in `add_executable`**: Header files are passed to `add_executable`, which is unnecessary with Qt's AUTOMOC. This bloats the Ninja dependency graph.
- **No precompiled headers**: Qt headers (`<QObject>`, `<QString>`, `<QVector>`, etc.) are recompiled in every translation unit.

---

## P3 — NotesView Keystroke Handling (Low Impact)

```cpp
void NotesView::onTextChanged() {
    m_updating = true;
    m_store->setNotes(m_editor->toPlainText()); // reads full text on every keystroke
    m_updating = false;
}
```

`toPlainText()` is called on every keystroke and the result is copied into the store. For large notes, consider batching reads with a small timer.

---

## P3 — CSV Export Builds Full String in Memory (Low Impact)

```cpp
QString DataStore::formatCsv() const {
    QStringList lines;
    // collects every entry into a QStringList...
    return lines.join('\n'); // then joins into one giant string
}
```

**Fix:** Stream CSV directly to the output file instead of building the entire string in memory.

---

## Summary Priority Table

| Priority | Issue | Impact |
|----------|-------|--------|
| **P0** | Add UUID → Node/Entry/Folder index (eliminate O(n) lookups) | High |
| **P0** | Consolidate redundant traversals in moveFolder/deleteEntries | High |
| **P1** | O(n²) matching in `TreeModel::updateFolderNode` | Medium |
| **P1** | Use const refs instead of copying Folder/Entry in loops | Medium |
| **P2** | Lighter poll mechanism (file mtime instead of SHA-256) | Medium |
| **P2** | `.reserve()` on vectors before population loops | Low-Medium |
| **P2** | Consolidate duplicate root UUID definitions | Low |
| **P3** | Cache lowercased/trimmed strings | Low |
| **P3** | Build flags (optimization level, PCH, C++20) | Low |
| **P3** | Stream CSV export instead of building in-memory | Low |
| **P3** | Batch NotesView text reads on keystroke | Low |
