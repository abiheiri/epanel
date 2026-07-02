#pragma once

#include "models/EPanelData.h"
#include <QObject>
#include <QTimer>
#include <QFileSystemWatcher>
#include <QDateTime>
#include <QUuid>
#include <QHash>
#include <QLockFile>
#include <memory>
#include <functional>

#ifdef Q_OS_MACOS
class SafariSyncManager;
#endif

class DataStore : public QObject {
    Q_OBJECT

public:
    explicit DataStore(QObject *parent = nullptr);
    ~DataStore();

    static QUuid rootFolderId();

    const EPanelData &data() const { return m_data; }
    const QString &notes() const { return m_notes; }
    const QString &dataFolderPath() const;
    QString jsonFilePath() const;
    QString notesFilePath() const;
    bool needsFileSelection() const { return m_needsFileSelection; }

    bool safariSyncEnabled() const { return m_safariSyncEnabled; }
    bool isSyncingFromSafari() const { return m_syncingFromSafari; }
    QDateTime lastSyncDate() const { return m_lastSyncDate; }

    void setNotes(const QString &notes);

    // Folder operations
    void createFolder(const QString &name, const QUuid &parentId = rootFolderId());
    void renameFolder(const QUuid &folderId, const QString &newName);
    void deleteFolder(const QUuid &folderId);
    void toggleFolderCollapsed(const QUuid &folderId);
    void moveFolder(const QUuid &folderId, const QUuid &toParentId);
    bool isDescendant(const QUuid &folderId, const QUuid &ancestorId) const;

    // Entry operations
    void addEntry(const Entry &entry, const QUuid &folderId = rootFolderId());
    void deleteEntry(const QUuid &entryId);
    void deleteEntries(const QSet<QUuid> &ids);
    void moveEntry(const QUuid &entryId, const QUuid &toFolderId);
    void moveEntries(const QVector<QUuid> &entryIds, const QUuid &toFolderId);
    Entry *findEntry(const QUuid &entryId);
    QUuid findParentFolderId(const QUuid &itemId) const;

    // Import / Export
    void importFile(const QString &path);
    void exportJson(const QString &path);
    void exportCsv(const QString &path);

    // Data file management
    void promptForDataFile();
    void changeDataFile();
    void setDataFolderPath(const QString &folderPath);

    // Safari sync (macOS only)
    void enableSafariSync(const QString &bookmarksPlistPath);
    void disableSafariSync();
    void applySafariSync(const QVector<Folder> &bookmarkFolders, const Folder &readingList);

    // Helpers
    void showAlert(const QString &message);
    Folder *findFolder(const QUuid &folderId);

signals:
    void dataChanged();
    void folderDataChanged(const QUuid &folderId);
    void notesChanged(const QString &notes);
    void alertRequested(const QString &message);
    void dataFileChanged();
    void safariSyncStateChanged(bool enabled);
    void lastSyncDateChanged(const QDateTime &date);

private:
    void setDataFolder(const QString &folderPath);
    void loadAllData();
    void loadData();
    void loadNotes();

    void scheduleSaveData();
    void saveData();
    void saveDataNow();

    void scheduleSaveNotes();
    void saveNotes();
    void saveNotesNow();

    void startFileMonitoring();
    void stopFileMonitoring();

    void handleExternalDataChange();
    void handleExternalNotesChange();

    void mergeData(const EPanelData &remote);
    void mergeFolder(Folder &local, const Folder &remote);
    bool hasUnsavedDataChanges() const;

    void importJson(const QString &path);
    void importCsv(const QString &path);
    void importSafariBookmarks(const QString &path);

    QVector<Entry> parseCsv(const QString &csv) const;

    bool modifyFolder(const QUuid &folderId, const std::function<void(Folder &)> &modifier);

    void deduplicate(Folder &folder);
    bool foldersEqual(const Folder &a, const Folder &b) const;
    bool hasDataChanged(const EPanelData &remote) const;

    // UUID indexes to avoid O(n) recursive tree walks.
    void rebuildIndex();
    void indexFolder(Folder &folder, const QUuid &parentId);
    void unindexFolderRecursively(Folder &folder);
    void unindexEntry(const QUuid &entryId);

    void recomputeAllEntryCounts(Folder &folder);
    void adjustEntryCounts(const QUuid &folderId, int delta);

    void moveExistingContentToOriginalFolder();
    void applyFullSafariImport(const QVector<Folder> &bookmarkFolders, const Folder &readingList);

    EPanelData m_data = EPanelData::empty();
    QString m_notes;
    QString m_dataFolderPath;
    bool m_needsFileSelection = true;

    QTimer *m_saveDataTimer = nullptr;
    QTimer *m_saveNotesTimer = nullptr;
    QTimer *m_pollTimer = nullptr;
    QFileSystemWatcher *m_fileWatcher = nullptr;

    bool m_applyingExternalChange = false;
    bool m_syncingFromSafari = false;
    size_t m_lastWrittenDataHash = 0;
    QDateTime m_lastJsonModified;
    qint64 m_lastJsonSize = 0;
    QString m_lastKnownNotesContent;
    QDateTime m_lastNotesModified;
    qint64 m_lastNotesSize = 0;

    // folder id -> Folder* (live pointer into m_data tree)
    QHash<QUuid, Folder *> m_folderIndex;
    // entry id -> parent folder id
    QHash<QUuid, QUuid> m_entryParentIndex;
    // folder id -> parent folder id (root maps to null)
    QHash<QUuid, QUuid> m_folderParentIndex;
    // normalized entry text set for O(1) dedup during sync/import
    QSet<QString> m_normalizedTexts;

    void rebuildTextIndex();

    bool m_safariSyncEnabled = false;
    QDateTime m_lastSyncDate;
#ifdef Q_OS_MACOS
    std::unique_ptr<SafariSyncManager> m_syncManager;
#endif

    friend class SafariSyncManager;
};
