# ePanel Optimization Audit

Merged from analyses by Kimi Code CLI and GitHub Copilot (DeepSeek). Research only, no code changes made.

## Executive Summary

The codebase already does several things well: `DataStore` keeps hash indexes for folders/entries, `TreeModel::updateFromData()` diffs with O(1) UUID maps, and bulk operations group by parent folder. The main remaining hotspots are **recursive recomputation**, **hot-path allocations in the model**, and **search re-filtering on every keystroke**.

---

## 🔴 Top Priority (high impact, likely noticeable)

### 1. `Folder::totalEntryCount()` is O(n²) during tree builds ✅ **DONE** `15e937a`
- **Where:** `src/models/Folder.cpp:22`, called from `TreeModel.cpp:154` and `TreeModel.cpp:193`
- **Issue:** It recursively walks the entire subtree on every call, and `buildNode()`/`updateFolderNode()` call it once per folder.
- **Impact:** CPU, gets worse with deep/nested folders.
- **Fix:** ~~Cache the count in `Folder` and invalidate on structural changes, or compute counts bottom-up in a single post-order pass.~~
  Added `entryCount` field to `Folder`, computed bottom-up via `recomputeEntryCount()`, and incrementally maintained via `adjustEntryCounts()` on all mutations.

### 2. Search re-filters + `expandAll()` on every keystroke ✅ **DONE** `5c7beba`
- **Where:** `src/ui/LinksView.cpp:78` (recursive filtering), `src/ui/LinksView.cpp:308-309`
- **Issue:** `setRecursiveFilteringEnabled(true)` — each character re-runs the proxy filter across the whole tree and then expands all matching branches.
- **Impact:** CPU + UI latency while typing.
- **Fix:** ~~Add a debounce timer (~150ms) to `onSearchTextChanged()` so filtering/expansion only happens after typing pauses.~~
  Added 150ms debounce timer (`m_searchDebounceTimer`). `onSearchTextChanged()` now stores pending text and starts the timer; `applySearchFilter()` does the actual filtering/expandAll.

### 3. `TreeModel::data()` allocates in a hot path ✅ **DONE** `e7a2beb`
- **Where:** `src/ui/TreeModel.cpp:267-283`
- **Issue:** `QIcon::fromTheme()` and a fresh `QVariantMap` are created every time the view asks for decoration/user-role data — i.e., on every paint.
- **Impact:** Allocations + CPU during scrolling and rendering.
- **Fix:** ~~Cache folder/entry icons once in the model and pre-build user-role data in the `Node`.~~
  Added `m_folderIcon`/`m_entryIcon` cached in constructor. `Node` struct now has `QVariantMap userData` populated at build time and returned by `data()` without allocation.

### 4. Full tree diff on every `dataChanged` signal ✅ **DONE** `5a8770c`
- **Where:** `src/ui/TreeModel.cpp:55-150` (`updateFromData`)
- **Issue:** Even a single-entry addition triggers a complete diff of the entire tree, including string normalization (`.toLower().trimmed()`) for every entry and folder name.
- **Impact:** CPU — work scales linearly with data size on every user action.
- **Fix:** ~~Use targeted `beginInsertRows`/`beginRemoveRows` for simple operations (add/delete/move/rename), reserving the full diff only for external file changes.~~
  Added `folderDataChanged(const QUuid &folderId)` signal to DataStore. All per-folder mutation methods now emit this instead of `dataChanged()`. `TreeModel::updateFolderById()` performs a targeted subtree update via `updateFolderNode()` on just the affected folder. `LinksView::onFolderDataChanged()` saves/restores selection and expansion around the targeted update. Bulk operations (import/merge/external change) still use the full `dataChanged()` → `updateFromData()` path.

### 5. Shadow `Node` tree in `TreeModel` doubles memory ✅ **DONE** `078532a`
- **Where:** `src/ui/TreeModel.h:76` (`Node` struct), `buildNode()` in `TreeModel.cpp`
- **Issue:** The model stores a full parallel tree of `Node` structs containing `text` — data already present in the `Folder`/`Entry` objects. For large datasets, this doubles memory usage.
- **Impact:** Memory.
- **Fix:** ~~Stop storing `text` in `Node` — resolve it from the `DataStore` via `id` lookup. Reduce `Node` to just `id`, `type`, `parent`, and `children`.~~
  Removed `QString text` from Node struct. Added `nodeText()` helper that resolves text via `DataStore::findFolder()`/`findEntry()` O(1) lookups. Made `findFolder()` public. Updated `data()`, `setData()`, `updateFromData()` diff algorithm to use `nodeText()`.

### 6. SHA-256 hash computed on every save ✅ **DONE** `02d92d4`
- **Where:** `src/datastore/DataStore.cpp:298-300`
- **Issue:** `QCryptographicHash::hash(jsonBytes, QCryptographicHash::Sha256)` hashes the entire JSON blob on every save. SHA-256 is cryptographic-grade and overkill for detecting own-write-vs-external-change.
- **Impact:** CPU on every save.
- **Fix:** ~~Use a lighter non-cryptographic hash (e.g., `qHash` or CRC32), or rely solely on the mtime+size pre-check and compare byte-for-byte.~~
  Replaced `QCryptographicHash::Sha256` with `qHash(QByteArrayView(...))`. Changed `m_lastWrittenDataHash` from `QByteArray` to `size_t`. Removed `#include <QCryptographicHash>`.

### 7. Full deep copy in `EPanelData::loadFromFile()` ✅ **DONE** `41ec094`
- **Where:** `src/models/EPanelData.cpp:57`
- **Issue:** `*this = fromJsonDocument(doc)` performs a deep copy of the entire folder tree from a temporary that is immediately destroyed.
- **Impact:** Memory spike during load.
- **Fix:** ~~Use move assignment: `*this = std::move(fromJsonDocument(doc))`, or deserialize directly into `this`.~~
  Added explicit `std::move` to guarantee move semantics.

---

## 🟡 Medium Priority

### 8. Per-folder entry lookup is still linear 🔵 **DEFERRED**
- **Where:** `DataStore::deleteEntry`, `moveEntry`, `findEntry`
- **Issue:** Even though `DataStore` knows the parent folder from `m_entryParentIndex`, finding the actual `Entry` inside that folder's `QVector` scans linearly.
- **Decision:** Only worthwhile if folder sizes routinely exceed ~200 entries. Current linear scan within a single folder is O(n) where n is that folder's entry count (typically small).

### 9. Repeated string normalization (`toLower().trimmed()`) ✅ **DONE** `f9ca649`
- **Where:** `updateFolderNode()`, `deduplicate()`, `foldersEqual()`, `mergeFolder()`, import paths
- **Issue:** Same text is normalized repeatedly for comparisons. Each call allocates a new `QString`.
- **Impact:** CPU — moderate with large datasets.
- **Fix:** ~~Normalize once per entry and cache, or use a case-insensitive comparator.~~
  Cached `sourceSub.name.toLower()` into `const QString key` in both `importSafariBookmarks` and `applyFullSafariImport` merge lambdas, avoiding duplicate normalization on find+insert. Added `m_normalizedTexts` index (#10) which further reduces normalization during sync.

### 10. Safari sync re-parses the whole plist and rebuilds URL sets ✅ **DONE** `ad8f8c5`
- **Where:** `DataStore.cpp:843-848`, `1118-1148`, `SafariSyncManager.mm:196-211`
- **Issue:** Each poll/file-change event recursively scans the entire tree to build a `QSet` of existing URLs.
- **Impact:** CPU on sync polls.
- **Fix:** ~~Maintain a global case-insensitive URL/text index in `DataStore` and update it incrementally.~~
  Added `m_normalizedTexts` (QSet<QString>) to DataStore, maintained via `rebuildTextIndex()` and updated on `addEntry()`. `importSafariBookmarks()` and `applyFullSafariImport()` now copy from this index instead of doing recursive tree walks.

### 11. `TreeModel::indexForNode()` uses linear `indexOf` ✅ **DONE** `e478c35`
- **Where:** `src/ui/TreeModel.cpp:219`
- **Issue:** Scans `parent->children` to find a node's row, called from `parent()` and update paths.
- **Impact:** Minor CPU — children lists are typically small.
- **Fix:** ~~Store each `Node`'s row index and update it on insert/remove.~~
  Added `int row` field to Node struct. Rows set in `buildNode()` and updated via `Node::renumberChildren()` after every insert/remove in `updateFolderNode()`. `indexForNode()` now returns `createIndex(node->row, 0, node)` — O(1).

### 12. Triple data copy during save 🔵 **DEFERRED**
- **Where:** `src/datastore/DataStore.cpp:299`
- **Issue:** The full JSON bytes are materialized into a `QByteArray` for hashing, then written.
- **Decision:** Inherent to JSON serialization — `toJson()` returns QByteArray which must exist for both hashing and writing. `qHash` (replaced from SHA-256 in #6) makes this negligible. True streaming requires replacing `QJsonDocument` with a streaming serializer.

### 13. Temporary `QSet` constructed from `QVector` in `moveEntries()` ✅ **DONE** `0d8bc33`
- **Where:** `src/datastore/DataStore.cpp:709`
- **Issue:** `QSet<QUuid> moveSet(toMove.begin(), toMove.end())` creates a hash set solely for O(1) contains-checks in a single loop.
- **Fix:** ~~Since `toMove` is typically small (from user drag-select), use `std::find` on the vector, or sort + binary search.~~
  Replaced `QSet<QUuid> moveSet` with `std::sort` + `std::binary_search` on a copy of the vector.

### 14. `EPanelData` struct copies in external-change and import functions ✅ **DONE** `0d8bc33`
- **Where:** `handleExternalDataChange()`, `importJson()`, `mergeData()`
- **Issue:** `EPanelData` is copied by value (e.g., `EPanelData incoming = fromJson(doc)` then `m_data = incoming`). The struct contains a full folder tree.
- **Fix:** ~~Use `std::move` where the temporary is discarded after assignment.~~
  Added `std::move` in `handleExternalDataChange()` (line 445), `loadData()` (line 216), and `importJson()` (line 836).

---

## 🟢 Lower Priority

### 15. `std::function` overhead for recursive lambdas ✅ **DONE** `4b08333`
- **Where:** `DataStore.cpp` and `LinksView.cpp` in several recursive helpers
- **Issue:** Type-erasure overhead — plain recursive lambdas with `auto &self` would avoid this.
- **Fix:** ~~Replace `std::function` with `auto &self` recursive lambda pattern.~~
  Replaced 7 `std::function` recursive lambdas across DataStore.cpp, LinksView.cpp, and TreeModel.cpp with deduplicated `auto &self` pattern. Simplified the `walk` lambda in `descendantFolderIds()` since both branches called `walk(sub)`.
  `modifyFolder()` keeps `std::function` as it's a public API.

### 16. Full JSON rebuilt on every save 🔵 **NOTE**
- **Where:** `DataStore.cpp:314`
- **Issue:** Serializes the entire tree after each edit.
- **Note:** Acceptable for typical sizes. True differential persistence or an append-only journal would require replacing `QJsonDocument` with a streaming serializer — a major architectural change not justified for current data volumes.

### 17. Dialogs clone the folder tree into `QTreeWidget` 🔵 **NOTE**
- **Where:** `AddEntryDialog`, `MoveItemDialog`, `NewFolderDialog`
- **Issue:** Each dialog allocates a full copy of the folder hierarchy.
- **Note:** Dialogs are short-lived and `QTreeWidgetItem` objects are lightweight (just text + UUID). Switching to a shared `QTreeView` + `TreeModel` would add complexity (filtering out excluded folders, different display needs) disproportionate to the benefit.

### 18. `SettingsView::updateLabels()` reassigns strings unconditionally ✅ **DONE** `82f8ed3`
- **Where:** `SettingsView.cpp:100-127`
- **Issue:** Label text is rebuilt even when nothing changed.
- **Fix:** ~~Compare before `setText()`.~~
  Added text comparison guards before all three `setText()`/`clear()` calls.

### 19. `QStringList lines = csv.split('\n')` copies all lines ✅ **DONE** `4b08333`
- **Where:** `parseCsv()` in `DataStore.cpp`
- **Issue:** `split` creates a `QStringList` with copies of every line.
- **Fix:** ~~Use `QStringView` with `split` (Qt 6) or iterate with `indexOf`.~~
  Replaced `QStringList lines = csv.split('\n')` with `QStringTokenizer{csv, u'\n'}` range-for loop, avoiding the intermediate QStringList allocation.

### 20. No `reserve()` on `QJsonArray` in `toJson()`/`fromJson()` 🔵 **NOTE**
- **Where:** `src/models/Folder.cpp:40-50`
- **Issue:** Pre-reserving array capacity would reduce reallocations during serialization.
- **Note:** `QJsonArray` in Qt 6 does not expose a `reserve()` method. The internal `QList` backing may benefit from reserve but the API doesn't allow it.

---

## ✅ Verified Strengths (already well-optimized)

| Component | Status | Details |
|---|---|---|
| **UUID Index** (3 hashes) | ✅ Optimal | `m_folderIndex`, `m_entryParentIndex`, `m_folderParentIndex` — O(1) lookups |
| **TreeModel child matching** | ✅ Optimal | `QHash<QUuid, Node*>` + `QHash<QString, Node*>` — O(1) |
| **File monitoring** | ✅ Optimal | 30s poll + mtime/size pre-check avoids unnecessary reads |
| **NotesView** | ✅ Optimal | 300ms debounce + `m_updating` re-entrancy guard |
| **`moveFolder`** | ✅ Optimal | `std::move` + `removeAt` avoids deep copy |
| **`deduplicate`** | ✅ Optimal | `unique.reserve(folder.entries.size())` |
| **`parseCsv`** | ✅ Optimal | `const QString &line` — no string copy in loop |
| **Batch operations** | ✅ Optimal | `deleteEntries`/`moveEntries` group by parent, single-pass, `reserve()` |
| **Build config** | ✅ Optimal | C++17, Release (`-O3 -DNDEBUG`), proper Qt6 AUTOMOC |
| **Root UUID** | ✅ Canonical | Single `Folder::rootFolderId()` definition |

---

## Quick Wins (small code, decent payoff)

1. **Debounce search** (#2) — biggest perceived UI improvement.
2. **Cache icons + user-role data in `TreeModel`** (#3) — removes the hottest allocation path.
3. **Cache `totalEntryCount()`** (#1) — removes the O(n²) model build.
4. **Move semantics in `loadFromFile()`** (#7) — one-line fix, cuts memory during load.
5. **Replace SHA-256 with lighter comparison** (#6) — one-line fix, cuts CPU on save.

---

## Conclusion

The codebase is in good shape with solid architecture. Several optimizations are available that range from trivial one-liners to medium-effort structural changes. The quick wins above offer the best return on effort, with search debounce and entry-count caching delivering the most noticeable user-facing improvement.

