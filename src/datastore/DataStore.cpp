#include "DataStore.h"
#include "models/EPanelData.h"
#include <QSettings>
#include <QFileDialog>
#include <QMessageBox>
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QRegularExpression>
#include <QCryptographicHash>
#include <QDesktopServices>
#include <QApplication>
#include <QPushButton>

#ifdef Q_OS_MACOS
#include "platform/SafariSyncManager.h"
#endif

static const QString DataFolderKey = "dataFolderPath";
static const QString SafariSyncEnabledKey = "safariSyncEnabled";

static QUuid s_rootFolderId("00000000-0000-0000-0000-000000000000");

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
    m_pollTimer->setInterval(5000);
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
    return s_rootFolderId;
}

QString DataStore::dataFolderPath() const
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

void DataStore::setNotes(const QString &notes)
{
    if (m_notes == notes) return;
    m_notes = notes;
    emit notesChanged(m_notes);
    scheduleSaveNotes();
}

void DataStore::promptForDataFile()
{
    QMessageBox box(QMessageBox::Question, tr("Welcome to ePanel"),
                    tr("Select the folder that contains your ePanel data (epanel.json + notes.txt), or create a new one."));
    QAbstractButton *openBtn = box.addButton(tr("Open Existing Folder…"), QMessageBox::AcceptRole);
    QAbstractButton *createBtn = box.addButton(tr("Create New…"), QMessageBox::AcceptRole);
    QAbstractButton *quitBtn = box.addButton(tr("Quit"), QMessageBox::RejectRole);
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
    m_data = loaded;
    emit dataChanged();
}

void DataStore::loadNotes()
{
    QString path = notesFilePath();
    if (path.isEmpty() || !QFile::exists(path)) return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;
    QString content = QString::fromUtf8(file.readAll());
    m_notes = content;
    m_lastKnownNotesContent = content;
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
    QJsonDocument doc = m_data.toJsonDocument();
    QByteArray jsonBytes = doc.toJson(QJsonDocument::Indented);
    m_lastWrittenDataHash = QCryptographicHash::hash(jsonBytes, QCryptographicHash::Sha256);

    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        showAlert(tr("Failed to save data: %1").arg(file.errorString()));
        return;
    }
    file.write(jsonBytes);
    if (!file.commit()) {
        showAlert(tr("Failed to save data: %1").arg(file.errorString()));
    }
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
    }
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

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return;
    QByteArray bytes = file.readAll();
    QByteArray hash = QCryptographicHash::hash(bytes, QCryptographicHash::Sha256);
    if (hash == m_lastWrittenDataHash) return;

    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(bytes, &error);
    if (doc.isNull()) return;

    EPanelData incoming = EPanelData::fromJsonDocument(doc);
    if (!hasDataChanged(incoming)) return;

    m_applyingExternalChange = true;
    m_data = incoming;
    deduplicate(m_data.rootFolder);
    m_lastSyncDate = QDateTime::currentDateTimeUtc();
    emit dataChanged();
    emit lastSyncDateChanged(m_lastSyncDate);
    m_applyingExternalChange = false;
}

void DataStore::handleExternalNotesChange()
{
    const QString path = notesFilePath();
    if (path.isEmpty() || !QFile::exists(path)) return;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;
    QString content = QString::fromUtf8(file.readAll());
    if (content == m_lastKnownNotesContent) return;

    m_lastKnownNotesContent = content;
    m_notes = content;
    emit notesChanged(m_notes);
}

void DataStore::createFolder(const QString &name, const QUuid &parentId)
{
    modifyFolder(parentId, [&](Folder &folder) {
        Folder newFolder(name);
        folder.subfolders.prepend(newFolder);
    });
    scheduleSaveData();
    emit dataChanged();
}

void DataStore::renameFolder(const QUuid &folderId, const QString &newName)
{
    if (folderId == s_rootFolderId) return;
    if (modifyFolder(folderId, [&](Folder &folder) { folder.name = newName; })) {
        scheduleSaveData();
        emit dataChanged();
    }
}

void DataStore::deleteFolder(const QUuid &folderId)
{
    if (folderId == s_rootFolderId) return;
    std::function<bool(QVector<Folder> &)> removeRecursively = [&](QVector<Folder> &folders) -> bool {
        for (int i = 0; i < folders.size(); ++i) {
            if (folders[i].id == folderId) {
                folders.removeAt(i);
                return true;
            }
            if (removeRecursively(folders[i].subfolders)) {
                return true;
            }
        }
        return false;
    };
    if (removeRecursively(m_data.rootFolder.subfolders)) {
        scheduleSaveData();
        emit dataChanged();
    }
}

void DataStore::toggleFolderCollapsed(const QUuid &folderId)
{
    if (folderId == s_rootFolderId) return;
    if (modifyFolder(folderId, [&](Folder &folder) { folder.isCollapsed = !folder.isCollapsed; })) {
        scheduleSaveData();
        emit dataChanged();
    }
}

void DataStore::moveFolder(const QUuid &folderId, const QUuid &toParentId)
{
    if (folderId == s_rootFolderId) return;
    if (folderId == toParentId) return;
    if (isDescendant(toParentId, folderId)) return;

    // Check current parent
    QUuid currentParent = findParentFolderId(folderId);
    if (currentParent == toParentId) return;

    // Detach folder from current location
    std::function<bool(QVector<Folder> &, Folder &)> detach = [&](QVector<Folder> &folders, Folder &out) -> bool {
        for (int i = 0; i < folders.size(); ++i) {
            if (folders[i].id == folderId) {
                out = folders.takeAt(i);
                return true;
            }
            if (detach(folders[i].subfolders, out)) {
                return true;
            }
        }
        return false;
    };

    Folder detached;
    if (!detach(m_data.rootFolder.subfolders, detached)) return;

    modifyFolder(toParentId, [&](Folder &folder) {
        folder.subfolders.prepend(detached);
    });
    scheduleSaveData();
    emit dataChanged();
}

bool DataStore::isDescendant(const QUuid &folderId, const QUuid &ancestorId) const
{
    const Folder *ancestor = nullptr;
    std::function<bool(const Folder &)> findAncestor = [&](const Folder &folder) -> bool {
        if (folder.id == ancestorId) {
            ancestor = &folder;
            return true;
        }
        for (const auto &sub : folder.subfolders) {
            if (findAncestor(sub)) return true;
        }
        return false;
    };
    findAncestor(m_data.rootFolder);
    if (!ancestor) return false;

    std::function<bool(const QVector<Folder> &)> findDescendant = [&](const QVector<Folder> &folders) -> bool {
        for (const auto &folder : folders) {
            if (folder.id == folderId) return true;
            if (findDescendant(folder.subfolders)) return true;
        }
        return false;
    };
    return findDescendant(ancestor->subfolders);
}

void DataStore::addEntry(const Entry &entry, const QUuid &folderId)
{
    modifyFolder(folderId, [&](Folder &folder) {
        folder.entries.append(entry);
    });
    scheduleSaveData();
    emit dataChanged();
}

void DataStore::deleteEntry(const QUuid &entryId)
{
    std::function<bool(Folder &)> removeRecursively = [&](Folder &folder) -> bool {
        for (int i = 0; i < folder.entries.size(); ++i) {
            if (folder.entries[i].id == entryId) {
                folder.entries.removeAt(i);
                return true;
            }
        }
        for (auto &sub : folder.subfolders) {
            if (removeRecursively(sub)) return true;
        }
        return false;
    };
    if (removeRecursively(m_data.rootFolder)) {
        scheduleSaveData();
        emit dataChanged();
    }
}

void DataStore::deleteEntries(const QSet<QUuid> &ids)
{
    for (const auto &id : ids) {
        deleteEntry(id);
    }
}

void DataStore::moveEntry(const QUuid &entryId, const QUuid &toFolderId)
{
    if (findParentFolderId(entryId) == toFolderId) return;

    Entry moved;
    std::function<bool(Folder &)> removeRecursively = [&](Folder &folder) -> bool {
        for (int i = 0; i < folder.entries.size(); ++i) {
            if (folder.entries[i].id == entryId) {
                moved = folder.entries.takeAt(i);
                return true;
            }
        }
        for (auto &sub : folder.subfolders) {
            if (removeRecursively(sub)) return true;
        }
        return false;
    };
    if (!removeRecursively(m_data.rootFolder)) return;

    modifyFolder(toFolderId, [&](Folder &folder) {
        folder.entries.append(moved);
    });
    scheduleSaveData();
    emit dataChanged();
}

void DataStore::moveEntries(const QVector<QUuid> &entryIds, const QUuid &toFolderId)
{
    for (const auto &id : entryIds) {
        moveEntry(id, toFolderId);
    }
}

Entry *DataStore::findEntry(const QUuid &entryId)
{
    std::function<Entry*(Folder &)> findRecursively = [&](Folder &folder) -> Entry* {
        for (auto &entry : folder.entries) {
            if (entry.id == entryId) return &entry;
        }
        for (auto &sub : folder.subfolders) {
            if (Entry *found = findRecursively(sub)) return found;
        }
        return nullptr;
    };
    return findRecursively(m_data.rootFolder);
}

QUuid DataStore::findParentFolderId(const QUuid &itemId) const
{
    // If item is a folder, return its own id (so entries add to it)
    std::function<QUuid(const Folder &)> findFolder = [&](const Folder &folder) -> QUuid {
        if (folder.id == itemId) return folder.id;
        for (const auto &sub : folder.subfolders) {
            QUuid found = findFolder(sub);
            if (!found.isNull()) return found;
        }
        return QUuid();
    };
    QUuid folderFound = findFolder(m_data.rootFolder);
    if (!folderFound.isNull()) return folderFound;

    std::function<QUuid(const Folder &)> findEntryParent = [&](const Folder &folder) -> QUuid {
        for (const auto &entry : folder.entries) {
            if (entry.id == itemId) return folder.id;
        }
        for (const auto &sub : folder.subfolders) {
            QUuid found = findEntryParent(sub);
            if (!found.isNull()) return found;
        }
        return QUuid();
    };
    QUuid entryParent = findEntryParent(m_data.rootFolder);
    if (!entryParent.isNull()) return entryParent;

    return s_rootFolderId;
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
    m_data = loaded;
    deduplicate(m_data.rootFolder);
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
    std::function<void(const Folder &)> collect = [&](const Folder &folder) {
        for (const auto &e : folder.entries) existingTexts.insert(e.text);
        for (const auto &sub : folder.subfolders) collect(sub);
    };
    collect(m_data.rootFolder);

    QVector<Entry> unique;
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

    QSet<QString> existingURLs;
    std::function<void(const Folder &)> collect = [&](const Folder &folder) {
        for (const auto &e : folder.entries) existingURLs.insert(e.text.toLower().trimmed());
        for (const auto &sub : folder.subfolders) collect(sub);
    };
    collect(m_data.rootFolder);

    auto mergeFolder = [&](const Folder &source, Folder &target, QSet<QString> &urls, int &entriesAdded, int &foldersAdded, int &dupes, auto &self) -> void {
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
        for (const auto &sourceSub : source.subfolders) {
            int existingIndex = -1;
            for (int i = 0; i < target.subfolders.size(); ++i) {
                if (target.subfolders[i].name.toLower() == sourceSub.name.toLower()) {
                    existingIndex = i;
                    break;
                }
            }
            if (existingIndex >= 0) {
                self(sourceSub, target.subfolders[existingIndex], urls, entriesAdded, foldersAdded, dupes, self);
            } else {
                Folder newSub(sourceSub.name);
                self(sourceSub, newSub, urls, entriesAdded, foldersAdded, dupes, self);
                target.subfolders.append(newSub);
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
            mergeFolder(sourceFolder, m_data.rootFolder.subfolders[existingIndex], existingURLs, entriesAdded, foldersAdded, dupes, mergeFolder);
        }
        showAlert(tr("Merged into 'Imported-Safari': %1 new entries, %2 new folders. %3 duplicates skipped.")
                      .arg(entriesAdded).arg(foldersAdded).arg(dupes));
    } else {
        Folder newFolder("Imported-Safari");
        for (const auto &sourceFolder : result->first) {
            mergeFolder(sourceFolder, newFolder, existingURLs, entriesAdded, foldersAdded, dupes, mergeFolder);
        }
        m_data.rootFolder.subfolders.prepend(newFolder);
        showAlert(tr("Created 'Imported-Safari' with %1 entries and %2 folders. %3 duplicates skipped.")
                      .arg(entriesAdded).arg(foldersAdded).arg(dupes));
    }
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
    file.write(formatCsv().toUtf8());
}

QVector<Entry> DataStore::parseCsv(const QString &csv) const
{
    QVector<Entry> result;
    const QStringList lines = csv.split('\n');
    for (QString line : lines) {
        line = line.trimmed();
        if (line.isEmpty()) continue;
        QStringList parts = line.split(',');
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

QString DataStore::formatCsv() const
{
    QStringList lines;
    std::function<void(const Folder &)> collect = [&](const Folder &folder) {
        for (const auto &e : folder.entries) {
            lines.append(QString("%1,%2").arg(e.text, e.date.toString("yyyy-MM-dd")));
        }
        for (const auto &sub : folder.subfolders) collect(sub);
    };
    collect(m_data.rootFolder);
    return lines.join('\n');
}

Folder *DataStore::findFolder(const QUuid &folderId)
{
    if (folderId == s_rootFolderId || folderId.isNull()) return &m_data.rootFolder;
    std::function<Folder*(Folder &)> findRecursively = [&](Folder &folder) -> Folder* {
        if (folder.id == folderId) return &folder;
        for (auto &sub : folder.subfolders) {
            if (Folder *found = findRecursively(sub)) return found;
        }
        return nullptr;
    };
    return findRecursively(m_data.rootFolder);
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
    for (auto &entry : folder.entries) {
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

    for (const auto &subA : a.subfolders) {
        bool found = false;
        for (const auto &subB : b.subfolders) {
            if (subA.name.toLower() == subB.name.toLower() && foldersEqual(subA, subB)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

bool DataStore::hasDataChanged(const EPanelData &remote) const
{
    return !foldersEqual(m_data.rootFolder, remote.rootFolder);
}

void DataStore::moveExistingContentToOriginalFolder()
{
    if (m_data.rootFolder.entries.isEmpty() && m_data.rootFolder.subfolders.isEmpty()) return;
    for (const auto &sub : m_data.rootFolder.subfolders) {
        if (sub.name == "my_original_epanel") return;
    }
    Folder original("my_original_epanel");
    original.entries = m_data.rootFolder.entries;
    original.subfolders = m_data.rootFolder.subfolders;
    m_data.rootFolder.entries.clear();
    m_data.rootFolder.subfolders.clear();
    m_data.rootFolder.subfolders.append(original);
}

void DataStore::applyFullSafariImport(const QVector<Folder> &bookmarkFolders, const Folder &readingList)
{
    QSet<QString> existingURLs;
    std::function<void(const Folder &)> collect = [&](const Folder &folder) {
        for (const auto &e : folder.entries) existingURLs.insert(e.text.toLower().trimmed());
        for (const auto &sub : folder.subfolders) collect(sub);
    };
    collect(m_data.rootFolder);

    auto mergeFolder = [&](const Folder &source, Folder &target, QSet<QString> &urls, auto &self) -> void {
        for (const auto &entry : source.entries) {
            QString normalized = entry.text.toLower().trimmed();
            if (!urls.contains(normalized)) {
                target.entries.append(entry);
                urls.insert(normalized);
            }
        }
        for (const auto &sourceSub : source.subfolders) {
            int existingIndex = -1;
            for (int i = 0; i < target.subfolders.size(); ++i) {
                if (target.subfolders[i].name.toLower() == sourceSub.name.toLower()) {
                    existingIndex = i;
                    break;
                }
            }
            if (existingIndex >= 0) {
                self(sourceSub, target.subfolders[existingIndex], urls, self);
            } else {
                Folder newSub(sourceSub.name);
                self(sourceSub, newSub, urls, self);
                target.subfolders.append(newSub);
            }
        }
    };

    for (const auto &sourceFolder : bookmarkFolders) {
        Folder target(sourceFolder.name);
        mergeFolder(sourceFolder, target, existingURLs, mergeFolder);
        if (!target.entries.isEmpty() || !target.subfolders.isEmpty()) {
            m_data.rootFolder.subfolders.append(target);
        }
    }

    if (!readingList.entries.isEmpty() || !readingList.subfolders.isEmpty()) {
        Folder target("Reading List");
        mergeFolder(const_cast<Folder &>(readingList), target, existingURLs, mergeFolder);
        m_data.rootFolder.subfolders.prepend(target);
    }

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
    std::function<void(const Folder &)> capture = [&](const Folder &folder) {
        collapsedState[folder.id.toString(QUuid::WithoutBraces)] = folder.isCollapsed;
        for (const auto &sub : folder.subfolders) capture(sub);
    };
    for (const auto &sub : m_data.rootFolder.subfolders) capture(sub);

    std::function<void(Folder &)> restore = [&](Folder &folder) {
        if (collapsedState.contains(folder.id.toString(QUuid::WithoutBraces))) {
            folder.isCollapsed = collapsedState[folder.id.toString(QUuid::WithoutBraces)];
        }
        for (auto &sub : folder.subfolders) restore(sub);
    };

    for (auto safariFolder : bookmarkFolders) {
        restore(safariFolder);
        bool found = false;
        for (int i = 0; i < m_data.rootFolder.subfolders.size(); ++i) {
            if (m_data.rootFolder.subfolders[i].name == safariFolder.name) {
                m_data.rootFolder.subfolders[i] = safariFolder;
                found = true;
                break;
            }
        }
        if (!found && (!safariFolder.entries.isEmpty() || !safariFolder.subfolders.isEmpty())) {
            m_data.rootFolder.subfolders.append(safariFolder);
        }
    }

    Folder rl = readingList;
    rl.name = "Reading List";
    restore(rl);
    bool found = false;
    for (int i = 0; i < m_data.rootFolder.subfolders.size(); ++i) {
        if (m_data.rootFolder.subfolders[i].name == "Reading List") {
            m_data.rootFolder.subfolders[i] = rl;
            found = true;
            break;
        }
    }
    if (!found && !rl.entries.isEmpty()) {
        m_data.rootFolder.subfolders.prepend(rl);
    }

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
