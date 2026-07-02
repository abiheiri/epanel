#include "DataStore.h"
#include "models/EPanelData.h"
#include <QSettings>
#include <QFileDialog>
#include <QMessageBox>
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QLockFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QRegularExpression>
#include <QByteArrayView>
#include <QDesktopServices>
#include <QApplication>
#include <QPushButton>
#include <algorithm>
#include <utility>
#include "models/Folder.h"

#ifdef Q_OS_MACOS
#include "platform/SafariSyncManager.h"
#endif

static const QString DataFolderKey = "dataFolderPath";
static const QString SafariSyncEnabledKey = "safariSyncEnabled";

DataStore::DataStore(QObject *parent)
    : QObject(parent)
{
    m_saveDataTimer = new QTimer(this);
    m_saveDataTimer->setSingleShot(true);
    m_saveDataTimer->setInterval(1000);
    connect(m_saveDataTimer, &QTimer::timeout, this, &DataStore::saveDataNow);

    m_saveNotesTimer = new QTimer(this);
    m_saveNotesTimer->setSingleShot(true);
    m_saveNotesTimer->setInterval(1000);
    connect(m_saveNotesTimer, &QTimer::timeout, this, &DataStore::saveNotesNow);

    m_fileWatcher = new QFileSystemWatcher(this);
    connect(m_fileWatcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &path) {
        if (path == jsonFilePath()) {
            handleExternalDataChange();
        } else if (path == notesFilePath()) {
            handleExternalNotesChange();
        }
    });

    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(30000);
    connect(m_pollTimer, &QTimer::timeout, this, [this]() {
        handleExternalDataChange();
        handleExternalNotesChange();
    });

    QSettings settings;
    const QString folder = settings.value(DataFolderKey).toString();
    if (!folder.isEmpty() && QDir(folder).exists()) {
        const QString jsonPath = QDir(folder).filePath("epanel.json");
        if (QFile::exists(jsonPath)) {
            setDataFolder(folder);
        } else {
            m_needsFileSelection = true;
        }
    } else {
        m_needsFileSelection = true;
    }

    m_safariSyncEnabled = settings.value(SafariSyncEnabledKey, false).toBool();
#ifdef Q_OS_MACOS
    if (m_safariSyncEnabled) {
        auto manager = std::make_unique<SafariSyncManager>(this);
        QString plistPath = manager->resolveBookmark();
        if (!plistPath.isEmpty()) {
            m_syncManager = std::move(manager);
            m_syncManager->start(plistPath);
        } else {
            m_safariSyncEnabled = false;
            settings.setValue(SafariSyncEnabledKey, false);
        }
    }
#endif
}

DataStore::~DataStore()
{
    saveDataNow();
    saveNotesNow();
#ifdef Q_OS_MACOS
    // Stop the manager but do not persist a disabled state; otherwise sync
    // would be turned off every time the app quits.
    if (m_syncManager) {
        m_syncManager->stop();
        m_syncManager.reset();
    }
#endif
}

QUuid DataStore::rootFolderId()
{
    return Folder::rootFolderId();
}

const QString &DataStore::dataFolderPath() const
{
    return m_dataFolderPath;
}

QString DataStore::jsonFilePath() const
{
    if (m_dataFolderPath.isEmpty()) return QString();
    return QDir(m_dataFolderPath).filePath("epanel.json");
}

QString DataStore::notesFilePath() const
{
    if (m_dataFolderPath.isEmpty()) return QString();
    return QDir(m_dataFolderPath).filePath("notes.txt");
}

void DataStore::setNotes(const QString &newNotes)
{
    if (m_notes == newNotes) return;
    m_notes = newNotes;
    emit notesChanged(m_notes);
    scheduleSaveNotes();
}

void DataStore::promptForDataFile()
{
    QMessageBox box(QMessageBox::Question, tr("Welcome to ePanel"),
                    tr("Select the folder that contains your ePanel data (epanel.json + notes.txt), or create a new one."));
    const QAbstractButton *openBtn = box.addButton(tr("Open Existing Folder…"), QMessageBox::AcceptRole);
    const QAbstractButton *createBtn = box.addButton(tr("Create New…"), QMessageBox::AcceptRole);
    box.addButton(tr("Quit"), QMessageBox::RejectRole);
    box.exec();

    if (box.clickedButton() == openBtn) {
        const QString dir = QFileDialog::getExistingDirectory(nullptr, tr("Select ePanel Data Folder"),
                                                              QDir::homePath(),
                                                              QFileDialog::ShowDirsOnly | QFileDialog::DontResolveSymlinks);
        if (dir.isEmpty()) {
            promptForDataFile();
            return;
        }
        const QString jsonPath = QDir(dir).filePath("epanel.json");
        if (!QFile::exists(jsonPath)) {
            EPanelData::empty().saveToFile(jsonPath);
        }
        setDataFolder(dir);
    } else if (box.clickedButton() == createBtn) {
        const QString dir = QFileDialog::getExistingDirectory(nullptr, tr("Choose Folder for ePanel Data"),
                                                              QDir::homePath(),
                                                              QFileDialog::ShowDirsOnly | QFileDialog::DontResolveSymlinks);
        if (dir.isEmpty()) {
            promptForDataFile();
            return;
        }
        const QString jsonPath = QDir(dir).filePath("epanel.json");
        EPanelData::empty().saveToFile(jsonPath);
        QFile notesFile(QDir(dir).filePath("notes.txt"));
        if (!notesFile.exists()) {
            bool opened = notesFile.open(QIODevice::WriteOnly);
            if (opened) notesFile.close();
        }
        setDataFolder(dir);
    } else {
        qApp->quit();
    }
}

void DataStore::changeDataFile()
{
    stopFileMonitoring();
    m_dataFolderPath.clear();
    m_needsFileSelection = true;
    promptForDataFile();
}

void DataStore::setDataFolderPath(const QString &folderPath)
{
    setDataFolder(folderPath);
}

void DataStore::setDataFolder(const QString &folderPath)
{
    stopFileMonitoring();
    m_dataFolderPath = folderPath;
    m_needsFileSelection = false;
    QSettings().setValue(DataFolderKey, folderPath);
    loadAllData();
    startFileMonitoring();
    emit dataFileChanged();
}

void DataStore::loadAllData()
{
    loadData();
    loadNotes();
}

void DataStore::loadData()
{
    QString path = jsonFilePath();
    if (path.isEmpty() || !QFile::exists(path)) return;

    QString error;
    EPanelData loaded;
    if (!loaded.loadFromFile(path, &error)) {
        showAlert(tr("Failed to load data: %1").arg(error));
        return;
    }
    deduplicate(loaded.rootFolder);
    m_data = std::move(loaded);
    rebuildIndex();

    QFileInfo info(path);
    m_lastJsonModified = info.lastModified();
    m_lastJsonSize = info.size();

    emit dataChanged();
}

void DataStore::rebuildIndex()
{
    m_folderIndex.clear();
    m_entryParentIndex.clear();
    m_folderParentIndex.clear();
    m_normalizedTexts.clear();
    indexFolder(m_data.rootFolder, QUuid());
    recomputeAllEntryCounts(m_data.rootFolder);
    rebuildTextIndex();
}

void DataStore::indexFolder(Folder &folder, const QUuid &parentId)
{
    if (!folder.id.isNull()) {
        m_folderIndex[folder.id] = &folder;
        m_folderParentIndex[folder.id] = parentId;
    }
    for (const Entry &entry : folder.entries) {
        if (!entry.id.isNull()) {
            m_entryParentIndex[entry.id] = folder.id;
        }
    }
    for (Folder &sub : folder.subfolders) {
        indexFolder(sub, folder.id);
    }
}

void DataStore::unindexFolderRecursively(Folder &folder)
{
    if (!folder.id.isNull()) {
        m_folderIndex.remove(folder.id);
        m_folderParentIndex.remove(folder.id);
    }
    for (const Entry &entry : folder.entries) {
        if (!entry.id.isNull()) {
            m_entryParentIndex.remove(entry.id);
        }
    }
    for (Folder &sub : folder.subfolders) {
        unindexFolderRecursively(sub);
    }
}

void DataStore::unindexEntry(const QUuid &entryId)
{
    m_entryParentIndex.remove(entryId);
}

void DataStore::rebuildTextIndex()
{
    m_normalizedTexts.clear();
    auto collect = [&](auto &self, const Folder &folder) -> void {
        for (const auto &e : folder.entries)
            m_normalizedTexts.insert(e.text.toLower().trimmed());
        for (const auto &sub : folder.subfolders)
            self(self, sub);
    };
    collect(collect, m_data.rootFolder);
}

void DataStore::recomputeAllEntryCounts(Folder &folder)
{
    folder.recomputeEntryCount();
}

void DataStore::adjustEntryCounts(const QUuid &folderId, int delta)
{
    QUuid current = folderId;
    while (!current.isNull()) {
        Folder *f = findFolder(current);
        if (!f) break;
        f->entryCount += delta;
        auto it = m_folderParentIndex.find(current);
        if (it == m_folderParentIndex.end()) break;
        current = it.value();
    }
}

void DataStore::loadNotes()
{
    QString path = notesFilePath();
    if (path.isEmpty() || !QFile::exists(path)) return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;
    const QString content = QString::fromUtf8(file.readAll());
    m_notes = content;
    m_lastKnownNotesContent = content;

    QFileInfo info(path);
    m_lastNotesModified = info.lastModified();
    m_lastNotesSize = info.size();

    emit notesChanged(m_notes);
}

void DataStore::scheduleSaveData()
{
    m_saveDataTimer->start();
}

void DataStore::saveData()
{
    scheduleSaveData();
}

void DataStore::saveDataNow()
{
    const QString path = jsonFilePath();
    if (path.isEmpty()) return;

    m_saveDataTimer->stop();

    QLockFile lock(path + QStringLiteral(".lock"));
    lock.setStaleLockTime(5000);
    if (!lock.tryLock(2000)) {
        // Another instance is currently writing; retry shortly.
        scheduleSaveData();
        return;
    }

    QJsonDocument doc = m_data.toJsonDocument();
    QByteArray jsonBytes = doc.toJson(QJsonDocument::Indented);
    m_lastWrittenDataHash = qHash(QByteArrayView(jsonBytes));

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        showAlert(tr("Failed to save data: %1").arg(file.errorString()));
        return;
    }
    file.write(jsonBytes);
    if (!file.commit()) {
        showAlert(tr("Failed to save data: %1").arg(file.errorString()));
        return;
    }
    QFileInfo info(path);
    m_lastJsonModified = info.lastModified();
    m_lastJsonSize = info.size();
}

void DataStore::scheduleSaveNotes()
{
    m_saveNotesTimer->start();
}

void DataStore::saveNotes()
{
    scheduleSaveNotes();
}

void DataStore::saveNotesNow()
{
    const QString path = notesFilePath();
    if (path.isEmpty()) return;

    m_saveNotesTimer->stop();
    m_lastKnownNotesContent = m_notes;

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        showAlert(tr("Failed to save notes: %1").arg(file.errorString()));
        return;
    }
    file.write(m_notes.toUtf8());
    if (!file.commit()) {
        showAlert(tr("Failed to save notes: %1").arg(file.errorString()));
        return;
    }
    QFileInfo info(path);
    m_lastNotesModified = info.lastModified();
    m_lastNotesSize = info.size();
}

void DataStore::startFileMonitoring()
{
    QStringList paths;
    if (!jsonFilePath().isEmpty()) paths << jsonFilePath();
    if (!notesFilePath().isEmpty()) paths << notesFilePath();
    if (!paths.isEmpty()) {
        m_fileWatcher->addPaths(paths);
    }
    m_pollTimer->start();
}

void DataStore::stopFileMonitoring()
{
    const QStringList paths = m_fileWatcher->files();
    if (!paths.isEmpty()) {
        m_fileWatcher->removePaths(paths);
    }
    m_pollTimer->stop();
}

void DataStore::handleExternalDataChange()
{
    const QString path = jsonFilePath();
    if (path.isEmpty() || !QFile::exists(path)) return;

    // Lightweight mtime/size pre-check before reading/hashing the whole file.
    const QFileInfo info(path);
    const QDateTime mtime = info.lastModified();
    const qint64 size = info.size();
    if (mtime == m_lastJsonModified && size == m_lastJsonSize) return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return;
    const QByteArray bytes = file.readAll();
    const size_t hash = qHash(QByteArrayView(bytes));
    if (hash == m_lastWrittenDataHash) {
        m_lastJsonModified = mtime;
        m_lastJsonSize = size;
        return;
    }

    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(bytes, &error);
    if (doc.isNull()) return;

    EPanelData incoming = EPanelData::fromJsonDocument(doc);
    if (!hasDataChanged(incoming)) {
        m_lastJsonModified = mtime;
        m_lastJsonSize = size;
        return;
    }

    m_applyingExternalChange = true;
    if (hasUnsavedDataChanges()) {
        // Preserve local edits while absorbing remote additions.
        mergeData(incoming);
        deduplicate(m_data.rootFolder);
    } else {
        // No local pending changes: let the file win so deletions propagate.
        m_data = std::move(incoming);
        deduplicate(m_data.rootFolder);
    }
    rebuildIndex();
    m_lastJsonModified = mtime;
    m_lastJsonSize = size;
    m_lastSyncDate = QDateTime::currentDateTimeUtc();
    emit dataChanged();
    emit lastSyncDateChanged(m_lastSyncDate);
    m_applyingExternalChange = false;
}

void DataStore::handleExternalNotesChange()
{
    const QString path = notesFilePath();
    if (path.isEmpty() || !QFile::exists(path)) return;

    // Lightweight mtime/size pre-check before reading the file.
    const QFileInfo info(path);
    const QDateTime mtime = info.lastModified();
    const qint64 size = info.size();
    if (mtime == m_lastNotesModified && size == m_lastNotesSize) return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;
    const QString content = QString::fromUtf8(file.readAll());
    m_lastNotesModified = mtime;
    m_lastNotesSize = size;
    if (content == m_lastKnownNotesContent) return;

    m_lastKnownNotesContent = content;
    m_notes = content;
    emit notesChanged(m_notes);
}

void DataStore::createFolder(const QString &name, const QUuid &parentId)
{
    QUuid newFolderId;
    modifyFolder(parentId, [&](Folder &folder) {
        Folder newFolder(name);
        newFolderId = newFolder.id;
        folder.subfolders.prepend(newFolder);
    });
    if (!newFolderId.isNull()) {
        Folder *parent = findFolder(parentId);
        if (parent && !parent->subfolders.isEmpty() && parent->subfolders.first().id == newFolderId) {
            indexFolder(parent->subfolders.first(), parentId);
        }
    }
    scheduleSaveData();
    emit folderDataChanged(parentId);
}

void DataStore::renameFolder(const QUuid &folderId, const QString &newName)
{
    if (folderId == Folder::rootFolderId()) return;
    if (modifyFolder(folderId, [&](Folder &folder) { folder.name = newName; })) {
        scheduleSaveData();
        emit folderDataChanged(folderId);
    }
}

void DataStore::deleteFolder(const QUuid &folderId)
{
    if (folderId == Folder::rootFolderId()) return;

    Folder *folder = findFolder(folderId);
    if (!folder) return;

    // Capture parent id before unindexing the subtree.
    const QUuid parentId = m_folderParentIndex.value(folderId);

    // Capture entry count before removing from indexes.
    const int removedCount = folder->totalEntryCount();

    // Remove the folder and all descendants from the indexes.
    unindexFolderRecursively(*folder);

    Folder *parent = findFolder(parentId);
    if (!parent) return;

    for (int i = 0; i < parent->subfolders.size(); ++i) {
        if (parent->subfolders[i].id == folderId) {
            parent->subfolders.removeAt(i);
            adjustEntryCounts(parentId, -removedCount);
            scheduleSaveData();
            emit folderDataChanged(parentId);
            return;
        }
    }
}

void DataStore::toggleFolderCollapsed(const QUuid &folderId)
{
    if (folderId == Folder::rootFolderId()) return;
    if (modifyFolder(folderId, [&](Folder &folder) { folder.isCollapsed = !folder.isCollapsed; })) {
        scheduleSaveData();
        emit folderDataChanged(folderId);
    }
}

void DataStore::moveFolder(const QUuid &folderId, const QUuid &toParentId)
{
    if (folderId == Folder::rootFolderId()) return;
    if (folderId == toParentId) return;
    if (isDescendant(toParentId, folderId)) return;

    // Check current parent via index.
    const QUuid currentParent = m_folderParentIndex.value(folderId);
    if (currentParent == toParentId) return;

    Folder *sourceParent = findFolder(currentParent);
    if (!sourceParent) return;

    int index = -1;
    for (int i = 0; i < sourceParent->subfolders.size(); ++i) {
        if (sourceParent->subfolders[i].id == folderId) {
            index = i;
            break;
        }
    }
    if (index < 0) return;

    // Move the folder out to avoid a deep copy of its subtree.
    const int count = sourceParent->subfolders[index].totalEntryCount();
    Folder detached = std::move(sourceParent->subfolders[index]);
    sourceParent->subfolders.removeAt(index);

    // Update the index for the moved subtree.
    unindexFolderRecursively(detached);

    Folder *targetParent = findFolder(toParentId);
    if (!targetParent) {
        // Re-index in place if target is missing so the tree stays consistent.
        sourceParent->subfolders.insert(index, std::move(detached));
        indexFolder(sourceParent->subfolders[index], currentParent);
        return;
    }

    targetParent->subfolders.prepend(std::move(detached));
    indexFolder(targetParent->subfolders.first(), toParentId);

    adjustEntryCounts(currentParent, -count);
    adjustEntryCounts(toParentId, count);

    scheduleSaveData();
    emit folderDataChanged(currentParent);
    emit folderDataChanged(toParentId);
}

bool DataStore::isDescendant(const QUuid &folderId, const QUuid &ancestorId) const
{
    if (folderId == ancestorId) return false;

    // Walk up the parent chain from folderId.
    QUuid current = folderId;
    while (!current.isNull() && current != Folder::rootFolderId()) {
        auto it = m_folderParentIndex.find(current);
        if (it == m_folderParentIndex.end()) break;
        current = it.value();
        if (current == ancestorId) return true;
    }
    return false;
}

void DataStore::addEntry(const Entry &entry, const QUuid &folderId)
{
    modifyFolder(folderId, [&](Folder &folder) {
        folder.entries.append(entry);
    });
    if (!entry.id.isNull()) {
        m_entryParentIndex[entry.id] = folderId;
    }
    m_normalizedTexts.insert(entry.text.toLower().trimmed());
    adjustEntryCounts(folderId, 1);
    scheduleSaveData();
    emit folderDataChanged(folderId);
}

void DataStore::deleteEntry(const QUuid &entryId)
{
    auto parentIt = m_entryParentIndex.find(entryId);
    if (parentIt == m_entryParentIndex.end()) return;

    Folder *folder = findFolder(parentIt.value());
    if (!folder) return;

    for (int i = 0; i < folder->entries.size(); ++i) {
        if (folder->entries[i].id == entryId) {
            folder->entries.removeAt(i);
            m_entryParentIndex.remove(entryId);
            adjustEntryCounts(parentIt.value(), -1);
            scheduleSaveData();
            emit folderDataChanged(parentIt.value());
            return;
        }
    }
}

void DataStore::deleteEntries(const QSet<QUuid> &ids)
{
    if (ids.isEmpty()) return;

    // Group entries by parent folder so each folder is scanned once.
    QHash<QUuid, QSet<QUuid>> entriesByFolder;
    for (const QUuid &id : ids) {
        auto parentIt = m_entryParentIndex.find(id);
        if (parentIt != m_entryParentIndex.end()) {
            entriesByFolder[parentIt.value()].insert(id);
        }
    }

    bool changed = false;
    for (auto it = entriesByFolder.begin(); it != entriesByFolder.end(); ++it) {
        Folder *folder = findFolder(it.key());
        if (!folder) continue;
        const QSet<QUuid> &toRemove = it.value();
        QVector<Entry> kept;
        kept.reserve(folder->entries.size());
        int removed = 0;
        for (const Entry &entry : folder->entries) {
            if (!toRemove.contains(entry.id)) {
                kept.append(entry);
            } else {
                m_entryParentIndex.remove(entry.id);
                ++removed;
                changed = true;
            }
        }
        folder->entries = kept;
        if (removed > 0) {
            adjustEntryCounts(it.key(), -removed);
        }
    }

    if (changed) {
        for (auto it = entriesByFolder.begin(); it != entriesByFolder.end(); ++it) {
            emit folderDataChanged(it.key());
        }
        scheduleSaveData();
    }
}

void DataStore::moveEntry(const QUuid &entryId, const QUuid &toFolderId)
{
    auto parentIt = m_entryParentIndex.find(entryId);
    if (parentIt == m_entryParentIndex.end()) return;
    if (parentIt.value() == toFolderId) return;

    Folder *sourceFolder = findFolder(parentIt.value());
    if (!sourceFolder) return;

    Entry moved;
    int index = -1;
    for (int i = 0; i < sourceFolder->entries.size(); ++i) {
        if (sourceFolder->entries[i].id == entryId) {
            index = i;
            break;
        }
    }
    if (index < 0) return;

    moved = sourceFolder->entries.takeAt(index);
    m_entryParentIndex.remove(entryId);

    Folder *targetFolder = findFolder(toFolderId);
    if (!targetFolder) {
        // Roll back if target is missing.
        sourceFolder->entries.insert(index, moved);
        m_entryParentIndex[entryId] = parentIt.value();
        return;
    }

    targetFolder->entries.append(moved);
    m_entryParentIndex[entryId] = toFolderId;

    adjustEntryCounts(parentIt.value(), -1);
    adjustEntryCounts(toFolderId, 1);

    scheduleSaveData();
    emit folderDataChanged(parentIt.value());
    emit folderDataChanged(toFolderId);
}

void DataStore::moveEntries(const QVector<QUuid> &entryIds, const QUuid &toFolderId)
{
    if (entryIds.isEmpty()) return;

    // Group entries by source folder so each source folder is scanned once.
    QHash<QUuid, QVector<QUuid>> idsBySourceFolder;
    for (const QUuid &id : entryIds) {
        auto parentIt = m_entryParentIndex.find(id);
        if (parentIt != m_entryParentIndex.end() && parentIt.value() != toFolderId) {
            idsBySourceFolder[parentIt.value()].append(id);
        }
    }

    Folder *targetFolder = findFolder(toFolderId);
    if (!targetFolder) return;

    bool changed = false;
    for (auto it = idsBySourceFolder.begin(); it != idsBySourceFolder.end(); ++it) {
        Folder *sourceFolder = findFolder(it.key());
        if (!sourceFolder) continue;

        const QVector<QUuid> &toMove = it.value();

        // Sort for binary_search in the single-pass loop below;
        // drag-select sets are typically small so this is fast.
        QVector<QUuid> sorted(toMove);
        std::sort(sorted.begin(), sorted.end());

        QVector<Entry> kept;
        kept.reserve(sourceFolder->entries.size());
        int moved = 0;
        for (const Entry &entry : sourceFolder->entries) {
            if (std::binary_search(sorted.begin(), sorted.end(), entry.id)) {
                targetFolder->entries.append(entry);
                m_entryParentIndex[entry.id] = toFolderId;
                ++moved;
                changed = true;
            } else {
                kept.append(entry);
            }
        }
        sourceFolder->entries = kept;
        if (moved > 0) {
            adjustEntryCounts(it.key(), -moved);
        }
    }

    if (changed) {
        adjustEntryCounts(toFolderId, entryIds.size());
        scheduleSaveData();
        for (auto it = idsBySourceFolder.begin(); it != idsBySourceFolder.end(); ++it) {
            emit folderDataChanged(it.key());
        }
        emit folderDataChanged(toFolderId);
    }
}

Entry *DataStore::findEntry(const QUuid &entryId)
{
    auto parentIt = m_entryParentIndex.find(entryId);
    if (parentIt == m_entryParentIndex.end()) return nullptr;

    Folder *folder = findFolder(parentIt.value());
    if (!folder) return nullptr;

    auto it = std::find_if(folder->entries.begin(), folder->entries.end(),
                           [&](const Entry &entry) { return entry.id == entryId; });
    return it != folder->entries.end() ? &(*it) : nullptr;
}

QUuid DataStore::findParentFolderId(const QUuid &itemId) const
{
    if (itemId == Folder::rootFolderId() || itemId.isNull()) return Folder::rootFolderId();

    // Folders: return the folder's own id (so entries add to it)
    auto folderIt = m_folderIndex.find(itemId);
    if (folderIt != m_folderIndex.end()) return itemId;

    // Entries: return the parent folder id from the index
    auto entryIt = m_entryParentIndex.find(itemId);
    if (entryIt != m_entryParentIndex.end()) return entryIt.value();

    return Folder::rootFolderId();
}

void DataStore::importFile(const QString &path)
{
    if (path.endsWith(".json", Qt::CaseInsensitive)) {
        importJson(path);
    } else if (path.endsWith(".plist", Qt::CaseInsensitive)) {
        importSafariBookmarks(path);
    } else {
        importCsv(path);
    }
}

void DataStore::importJson(const QString &path)
{
    const int ret = QMessageBox::warning(nullptr, tr("Replace All Data?"),
                                         tr("Importing this JSON file will replace all your existing entries and folders. This cannot be undone."),
                                         QMessageBox::Yes | QMessageBox::Cancel);
    if (ret != QMessageBox::Yes) return;

    QString error;
    EPanelData loaded;
    if (!loaded.loadFromFile(path, &error)) {
        showAlert(tr("Failed to import JSON: %1").arg(error));
        return;
    }
    m_data = std::move(loaded);
    deduplicate(m_data.rootFolder);
    rebuildIndex();
    scheduleSaveData();
    emit dataChanged();
}

void DataStore::importCsv(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        showAlert(tr("Failed to read CSV file: %1").arg(file.errorString()));
        return;
    }
    QString csv = QString::fromUtf8(file.readAll());
    QVector<Entry> imported = parseCsv(csv);
    if (imported.isEmpty()) {
        showAlert(tr("No valid entries found in CSV file"));
        return;
    }

    QSet<QString> existingTexts;
    auto collect = [&](auto &self, const Folder &folder) -> void {
        for (const auto &e : folder.entries) existingTexts.insert(e.text);
        for (const auto &sub : folder.subfolders) self(self, sub);
    };
    collect(collect, m_data.rootFolder);

    QVector<Entry> unique;
    unique.reserve(imported.size());
    for (const auto &e : imported) {
        if (!existingTexts.contains(e.text)) unique.append(e);
    }
    int dupes = imported.size() - unique.size();
    if (unique.isEmpty()) {
        showAlert(tr("All %1 entries already exist. Nothing imported.").arg(imported.size()));
        return;
    }

    Folder importFolder(QString("Imported-%1").arg(QDateTime::currentDateTimeUtc().toString("yyyy-MM-dd")));
    importFolder.entries = unique;
    m_data.rootFolder.subfolders.append(importFolder);
    rebuildIndex();
    scheduleSaveData();
    emit dataChanged();

    QString msg = tr("Created '%1' with %2 entries.").arg(importFolder.name).arg(unique.size());
    if (dupes > 0) msg += tr(" %1 duplicates were skipped.").arg(dupes);
    showAlert(msg);
}

void DataStore::importSafariBookmarks(const QString &path)
{
#ifdef Q_OS_MACOS
    SafariSyncManager manager(this);
    auto result = manager.performFullImport(path);
    if (!result) {
        showAlert(tr("Invalid Safari bookmarks file format"));
        return;
    }

    QSet<QString> existingURLs = m_normalizedTexts;

    auto mergeFolderImpl = [&](const Folder &source, Folder &target, QSet<QString> &urls, int &entriesAdded, int &foldersAdded, int &dupes, auto &self) -> void {
        for (const auto &entry : source.entries) {
            QString normalized = entry.text.toLower().trimmed();
            if (!urls.contains(normalized)) {
                target.entries.append(entry);
                urls.insert(normalized);
                ++entriesAdded;
            } else {
                ++dupes;
            }
        }
        QHash<QString, int> targetSubfolderIndex;
        for (int i = 0; i < target.subfolders.size(); ++i) {
            targetSubfolderIndex[target.subfolders[i].name.toLower()] = i;
        }
        for (const auto &sourceSub : source.subfolders) {
            const QString key = sourceSub.name.toLower();
            auto it = targetSubfolderIndex.find(key);
            if (it != targetSubfolderIndex.end()) {
                self(sourceSub, target.subfolders[it.value()], urls, entriesAdded, foldersAdded, dupes, self);
            } else {
                Folder newSub(sourceSub.name);
                self(sourceSub, newSub, urls, entriesAdded, foldersAdded, dupes, self);
                target.subfolders.append(newSub);
                targetSubfolderIndex[newSub.name.toLower()] = target.subfolders.size() - 1;
                ++foldersAdded;
            }
        }
    };

    int existingIndex = -1;
    for (int i = 0; i < m_data.rootFolder.subfolders.size(); ++i) {
        if (m_data.rootFolder.subfolders[i].name == "Imported-Safari") {
            existingIndex = i;
            break;
        }
    }

    int entriesAdded = 0, foldersAdded = 0, dupes = 0;
    if (existingIndex >= 0) {
        for (const auto &sourceFolder : result->first) {
            mergeFolderImpl(sourceFolder, m_data.rootFolder.subfolders[existingIndex], existingURLs, entriesAdded, foldersAdded, dupes, mergeFolderImpl);
        }
        showAlert(tr("Merged into 'Imported-Safari': %1 new entries, %2 new folders. %3 duplicates skipped.")
                      .arg(entriesAdded).arg(foldersAdded).arg(dupes));
    } else {
        Folder newFolder("Imported-Safari");
        for (const auto &sourceFolder : result->first) {
            mergeFolderImpl(sourceFolder, newFolder, existingURLs, entriesAdded, foldersAdded, dupes, mergeFolderImpl);
        }
        m_data.rootFolder.subfolders.prepend(newFolder);
        showAlert(tr("Created 'Imported-Safari' with %1 entries and %2 folders. %3 duplicates skipped.")
                      .arg(entriesAdded).arg(foldersAdded).arg(dupes));
    }
    rebuildIndex();
    scheduleSaveData();
    emit dataChanged();
#else
    Q_UNUSED(path)
    showAlert(tr("Safari bookmark import is only available on macOS."));
#endif
}

void DataStore::exportJson(const QString &path)
{
    QString error;
    if (!m_data.saveToFile(path, &error)) {
        showAlert(tr("Export failed: %1").arg(error));
    }
}

void DataStore::exportCsv(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        showAlert(tr("Export failed: %1").arg(file.errorString()));
        return;
    }

    QTextStream stream(&file);
    auto writeFolder = [&](auto &self, const Folder &folder) -> void {
        for (const auto &e : folder.entries) {
            stream << e.text << ',' << e.date.toString("yyyy-MM-dd") << '\n';
        }
        for (const auto &sub : folder.subfolders) self(self, sub);
    };
    writeFolder(writeFolder, m_data.rootFolder);
}

QVector<Entry> DataStore::parseCsv(const QString &csv) const
{
    QVector<Entry> result;
    for (const auto line : QStringTokenizer{csv, u'\n'}) {
        QString trimmed = line.trimmed().toString();
        if (trimmed.isEmpty()) continue;
        QStringList parts = trimmed.split(',');
        if (parts.size() < 2) continue;
        QString dateStr = parts.takeLast();
        QDateTime date = QDateTime::fromString(dateStr, Qt::ISODate);
        if (!date.isValid()) {
            date = QDateTime::fromString(dateStr, "yyyy-MM-dd");
        }
        if (!date.isValid()) continue;
        QString text = parts.join(",");
        Entry entry;
        entry.text = text;
        entry.date = date;
        result.append(entry);
    }
    return result;
}

Folder *DataStore::findFolder(const QUuid &folderId)
{
    if (folderId == Folder::rootFolderId() || folderId.isNull()) return &m_data.rootFolder;
    auto it = m_folderIndex.find(folderId);
    return it != m_folderIndex.end() ? it.value() : nullptr;
}

bool DataStore::modifyFolder(const QUuid &folderId, const std::function<void(Folder &)> &modifier)
{
    Folder *folder = findFolder(folderId);
    if (!folder) return false;
    modifier(*folder);
    return true;
}

void DataStore::deduplicate(Folder &folder)
{
    QSet<QString> seen;
    QVector<Entry> unique;
    unique.reserve(folder.entries.size());
    for (const auto &entry : folder.entries) {
        QString normalized = entry.text.toLower().trimmed();
        if (!seen.contains(normalized)) {
            seen.insert(normalized);
            unique.append(entry);
        }
    }
    folder.entries = unique;
    for (auto &sub : folder.subfolders) {
        deduplicate(sub);
    }
}

bool DataStore::foldersEqual(const Folder &a, const Folder &b) const
{
    if (a.entries.size() != b.entries.size() || a.subfolders.size() != b.subfolders.size()) return false;
    QSet<QString> aEntries;
    for (const auto &e : a.entries) aEntries.insert(e.text.toLower().trimmed());
    QSet<QString> bEntries;
    for (const auto &e : b.entries) bEntries.insert(e.text.toLower().trimmed());
    if (aEntries != bEntries) return false;

    // Map each target subfolder name to its indices for O(1) lookup.
    QHash<QString, QVector<int>> bSubfolders;
    for (int i = 0; i < b.subfolders.size(); ++i) {
        bSubfolders[b.subfolders[i].name.toLower()].append(i);
    }

    for (const Folder &subA : a.subfolders) {
        auto it = bSubfolders.find(subA.name.toLower());
        if (it == bSubfolders.end() || it.value().isEmpty()) return false;

        bool matched = false;
        for (auto idxIt = it.value().begin(); idxIt != it.value().end(); ) {
            if (foldersEqual(subA, b.subfolders[*idxIt])) {
                idxIt = it.value().erase(idxIt);
                matched = true;
                break;
            }
            ++idxIt;
        }
        if (!matched) return false;
    }
    return true;
}

bool DataStore::hasDataChanged(const EPanelData &remote) const
{
    return !foldersEqual(m_data.rootFolder, remote.rootFolder);
}

bool DataStore::hasUnsavedDataChanges() const
{
    return m_saveDataTimer && m_saveDataTimer->isActive();
}

void DataStore::mergeData(const EPanelData &remote)
{
    mergeFolder(m_data.rootFolder, remote.rootFolder);
}

void DataStore::mergeFolder(Folder &local, const Folder &remote)
{
    // Merge entries by UUID first, then by text.
    QSet<QUuid> localEntryIds;
    QSet<QString> localEntryTexts;
    for (const auto &e : local.entries) {
        if (!e.id.isNull()) localEntryIds.insert(e.id);
        localEntryTexts.insert(e.text.toLower().trimmed());
    }

    for (const auto &re : remote.entries) {
        bool matched = false;
        if (!re.id.isNull() && localEntryIds.contains(re.id)) {
            matched = true;
        } else {
            const QString normalized = re.text.toLower().trimmed();
            if (localEntryTexts.contains(normalized)) {
                matched = true;
            } else {
                localEntryTexts.insert(normalized);
            }
        }
        if (!matched) {
            local.entries.append(re);
        }
    }

    // Merge subfolders by UUID first, then by name.
    QHash<QUuid, Folder *> foldersById;
    QHash<QString, Folder *> foldersByName;
    for (auto &lf : local.subfolders) {
        if (!lf.id.isNull()) foldersById[lf.id] = &lf;
        foldersByName[lf.name.toLower()] = &lf;
    }

    for (const auto &rf : remote.subfolders) {
        Folder *match = nullptr;
        if (!rf.id.isNull()) {
            auto it = foldersById.find(rf.id);
            if (it != foldersById.end()) match = it.value();
        }
        if (!match) {
            auto it = foldersByName.find(rf.name.toLower());
            if (it != foldersByName.end()) match = it.value();
        }

        if (match) {
            const bool wasCollapsed = match->isCollapsed;
            mergeFolder(*match, rf);
            match->isCollapsed = wasCollapsed;
        } else {
            local.subfolders.append(rf);
        }
    }
}

void DataStore::moveExistingContentToOriginalFolder()
{
    if (m_data.rootFolder.entries.isEmpty() && m_data.rootFolder.subfolders.isEmpty()) return;
    if (std::any_of(m_data.rootFolder.subfolders.begin(), m_data.rootFolder.subfolders.end(),
                    [&](const Folder &sub) { return sub.name == QStringLiteral("my_original_epanel"); })) {
        return;
    }
    Folder original("my_original_epanel");
    original.entries = m_data.rootFolder.entries;
    original.subfolders = m_data.rootFolder.subfolders;
    m_data.rootFolder.entries.clear();
    m_data.rootFolder.subfolders.clear();
    m_data.rootFolder.subfolders.append(original);
    rebuildIndex();
}

void DataStore::applyFullSafariImport(const QVector<Folder> &bookmarkFolders, const Folder &readingList)
{
    QSet<QString> existingURLs = m_normalizedTexts;

    auto mergeFolderImpl = [&](const Folder &source, Folder &target, QSet<QString> &urls, auto &self) -> void {
        for (const auto &entry : source.entries) {
            QString normalized = entry.text.toLower().trimmed();
            if (!urls.contains(normalized)) {
                target.entries.append(entry);
                urls.insert(normalized);
            }
        }
        QHash<QString, int> targetSubfolderIndex;
        for (int i = 0; i < target.subfolders.size(); ++i) {
            targetSubfolderIndex[target.subfolders[i].name.toLower()] = i;
        }
        for (const auto &sourceSub : source.subfolders) {
            const QString key = sourceSub.name.toLower();
            auto it = targetSubfolderIndex.find(key);
            if (it != targetSubfolderIndex.end()) {
                self(sourceSub, target.subfolders[it.value()], urls, self);
            } else {
                Folder newSub(sourceSub.name);
                self(sourceSub, newSub, urls, self);
                target.subfolders.append(newSub);
                targetSubfolderIndex[newSub.name.toLower()] = target.subfolders.size() - 1;
            }
        }
    };

    for (const auto &sourceFolder : bookmarkFolders) {
        Folder target(sourceFolder.name);
        mergeFolderImpl(sourceFolder, target, existingURLs, mergeFolderImpl);
        if (!target.entries.isEmpty() || !target.subfolders.isEmpty()) {
            m_data.rootFolder.subfolders.append(target);
        }
    }

    if (!readingList.entries.isEmpty() || !readingList.subfolders.isEmpty()) {
        Folder target("Reading List");
        mergeFolderImpl(const_cast<Folder &>(readingList), target, existingURLs, mergeFolderImpl);
        m_data.rootFolder.subfolders.prepend(target);
    }

    rebuildIndex();
    m_lastSyncDate = QDateTime::currentDateTimeUtc();
    scheduleSaveData();
    emit dataChanged();
    emit lastSyncDateChanged(m_lastSyncDate);
}

void DataStore::applySafariSync(const QVector<Folder> &bookmarkFolders, const Folder &readingList)
{
    m_syncingFromSafari = true;

    // Capture collapsed state
    QHash<QString, bool> collapsedState;
    auto capture = [&](auto &self, const Folder &folder) -> void {
        collapsedState[folder.id.toString(QUuid::WithoutBraces)] = folder.isCollapsed;
        for (const auto &sub : folder.subfolders) self(self, sub);
    };
    for (const auto &sub : m_data.rootFolder.subfolders) capture(capture, sub);

    auto restore = [&](auto &self, Folder &folder) -> void {
        if (collapsedState.contains(folder.id.toString(QUuid::WithoutBraces))) {
            folder.isCollapsed = collapsedState[folder.id.toString(QUuid::WithoutBraces)];
        }
        for (auto &sub : folder.subfolders) self(self, sub);
    };

    for (const auto &safariFolder : bookmarkFolders) {
        bool found = false;
        for (int i = 0; i < m_data.rootFolder.subfolders.size(); ++i) {
            if (m_data.rootFolder.subfolders[i].name == safariFolder.name) {
                m_data.rootFolder.subfolders[i] = safariFolder;
                restore(restore, m_data.rootFolder.subfolders[i]);
                found = true;
                break;
            }
        }
        if (!found && (!safariFolder.entries.isEmpty() || !safariFolder.subfolders.isEmpty())) {
            m_data.rootFolder.subfolders.append(safariFolder);
            restore(restore, m_data.rootFolder.subfolders.last());
        }
    }

    bool readingListFound = false;
    for (int i = 0; i < m_data.rootFolder.subfolders.size(); ++i) {
        if (m_data.rootFolder.subfolders[i].name == "Reading List") {
            m_data.rootFolder.subfolders[i] = readingList;
            m_data.rootFolder.subfolders[i].name = "Reading List";
            restore(restore, m_data.rootFolder.subfolders[i]);
            readingListFound = true;
            break;
        }
    }
    if (!readingListFound && !readingList.entries.isEmpty()) {
        m_data.rootFolder.subfolders.prepend(readingList);
        m_data.rootFolder.subfolders.first().name = "Reading List";
        restore(restore, m_data.rootFolder.subfolders.first());
    }

    rebuildIndex();
    m_lastSyncDate = QDateTime::currentDateTimeUtc();
    scheduleSaveData();
    emit dataChanged();
    emit lastSyncDateChanged(m_lastSyncDate);

    m_syncingFromSafari = false;
}

void DataStore::enableSafariSync(const QString &bookmarksPlistPath)
{
#ifdef Q_OS_MACOS
    auto manager = std::make_unique<SafariSyncManager>(this);
    if (!manager->saveBookmark(bookmarksPlistPath)) {
        showAlert(tr("Failed to save file access permission."));
        return;
    }

    moveExistingContentToOriginalFolder();

    auto result = manager->performFullImport(bookmarksPlistPath);
    if (result) {
        applyFullSafariImport(result->first, result->second);
    }

    m_safariSyncEnabled = true;
    QSettings().setValue(SafariSyncEnabledKey, true);
    m_syncManager = std::move(manager);
    m_syncManager->start(bookmarksPlistPath);
    emit safariSyncStateChanged(true);
#else
    Q_UNUSED(bookmarksPlistPath)
    showAlert(tr("Safari sync is only available on macOS."));
#endif
}

void DataStore::disableSafariSync()
{
#ifdef Q_OS_MACOS
    if (m_syncManager) {
        m_syncManager->stop();
        m_syncManager.reset();
    }
#endif
    m_safariSyncEnabled = false;
    QSettings().setValue(SafariSyncEnabledKey, false);
    emit safariSyncStateChanged(false);
}

void DataStore::showAlert(const QString &message)
{
    emit alertRequested(message);
}
