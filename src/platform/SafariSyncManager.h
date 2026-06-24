#pragma once

#include <QObject>
#include <QPair>
#include <QVector>
#include <QSet>
#include <QDateTime>
#include <optional>

class DataStore;
class Folder;
class QFileSystemWatcher;
class QTimer;

class SafariSyncManager : public QObject {
    Q_OBJECT

public:
    explicit SafariSyncManager(DataStore *store, QObject *parent = nullptr);
    ~SafariSyncManager();

    bool saveBookmark(const QString &plistPath);
    QString resolveBookmark();

    void start(const QString &plistPath);
    void stop();

    std::optional<QPair<QVector<Folder>, Folder>> performFullImport(const QString &plistPath);

private slots:
    void syncFromSafari();
    void scheduleWriteback();
    void writebackToSafari();

private:
    DataStore *m_store = nullptr;
    QString m_plistPath;
    QFileSystemWatcher *m_watcher = nullptr;
    QTimer *m_pollTimer = nullptr;
    QTimer *m_writebackTimer = nullptr;
    QDateTime m_lastModificationDate;
    bool m_applyingSync = false;
    bool m_writebackInProgress = false;
};
