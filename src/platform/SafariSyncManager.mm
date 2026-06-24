#include "SafariSyncManager.h"
#include "datastore/DataStore.h"
#include "models/Folder.h"
#include "models/Entry.h"

#include <QFileSystemWatcher>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QDateTime>
#include <QUuid>
#include <QtDebug>
#include <QLockFile>

#import <Foundation/Foundation.h>

static const QString SafariBookmarkPathKey = QStringLiteral("safariBookmarkPath");

static NSString *qStringToNSString(const QString &s)
{
    return s.toNSString();
}

static QString nsStringToQString(NSString *s)
{
    if (!s) return QString();
    return QString::fromNSString(s);
}

static id readPlist(const QString &path)
{
    NSURL *url = [NSURL fileURLWithPath:qStringToNSString(path)];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;

    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                           options:NSPropertyListImmutable
                                                            format:nil
                                                             error:&error];
    if (error) {
        qWarning() << "Failed to read plist:" << nsStringToQString(error.localizedDescription);
    }
    return plist;
}

static bool writePlist(id plist, const QString &path)
{
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (error) {
        qWarning() << "Failed to serialize plist:" << nsStringToQString(error.localizedDescription);
        return false;
    }
    NSURL *url = [NSURL fileURLWithPath:qStringToNSString(path)];
    return [data writeToURL:url atomically:YES];
}

static Folder convertSafariChildren(NSArray *children)
{
    Folder folder("");
    for (NSDictionary *child in children) {
        NSString *bookmarkType = child[@"WebBookmarkType"];
        NSString *title = child[@"Title"] ?: @"";

        if ([bookmarkType isEqualToString:@"WebBookmarkTypeLeaf"]) {
            NSString *urlString = child[@"URLString"] ?: child[@"URL"];
            if (urlString.length > 0) {
                Entry entry;
                entry.id = QUuid::createUuid();
                entry.text = nsStringToQString(urlString);
                entry.date = QDateTime::currentDateTimeUtc();
                folder.entries.append(entry);
            }
        } else if ([bookmarkType isEqualToString:@"WebBookmarkTypeList"]) {
            NSArray *subChildren = child[@"Children"];
            if (subChildren) {
                Folder sub = convertSafariChildren(subChildren);
                sub.name = nsStringToQString(title);
                if (sub.name.isEmpty()) sub.name = QObject::tr("Untitled Folder");
                folder.subfolders.append(sub);
            }
        }
    }
    return folder;
}

static std::optional<QPair<QVector<Folder>, Folder>> parseSafariPlist(const QString &path)
{
    id plist = readPlist(path);
    if (![plist isKindOfClass:[NSDictionary class]]) return std::nullopt;
    NSDictionary *dict = (NSDictionary *)plist;
    NSArray *children = dict[@"Children"];
    if (![children isKindOfClass:[NSArray class]]) return std::nullopt;

    QVector<Folder> bookmarkFolders;
    Folder readingList(QObject::tr("Reading List"));

    for (NSDictionary *child in children) {
        NSString *title = child[@"Title"] ?: @"";
        NSString *bookmarkType = child[@"WebBookmarkType"] ?: @"";

        if (![bookmarkType isEqualToString:@"WebBookmarkTypeList"]) continue;
        NSArray *subChildren = child[@"Children"];
        if (![subChildren isKindOfClass:[NSArray class]]) continue;

        if ([title isEqualToString:@"com.apple.ReadingList"]) {
            readingList = convertSafariChildren(subChildren);
            readingList.name = QObject::tr("Reading List");
        } else {
            Folder folder = convertSafariChildren(subChildren);
            if ([title isEqualToString:@"BookmarksBar"]) {
                folder.name = QObject::tr("Favorites");
            } else if ([title isEqualToString:@"BookmarksMenu"]) {
                folder.name = QObject::tr("Bookmarks Menu");
            } else {
                folder.name = nsStringToQString(title);
                if (folder.name.isEmpty()) folder.name = QObject::tr("Untitled Folder");
            }
            bookmarkFolders.append(folder);
        }
    }

    return qMakePair(bookmarkFolders, readingList);
}

SafariSyncManager::SafariSyncManager(DataStore *store, QObject *parent)
    : QObject(parent), m_store(store)
{
}

SafariSyncManager::~SafariSyncManager()
{
    stop();
}

bool SafariSyncManager::saveBookmark(const QString &plistPath)
{
    QSettings().setValue(SafariBookmarkPathKey, plistPath);
    return true;
}

QString SafariSyncManager::resolveBookmark()
{
    return QSettings().value(SafariBookmarkPathKey).toString();
}

void SafariSyncManager::start(const QString &plistPath)
{
    stop();
    m_plistPath = plistPath;

    m_watcher = new QFileSystemWatcher(this);
    connect(m_watcher, &QFileSystemWatcher::fileChanged, this, [this]() {
        syncFromSafari();
    });
    m_watcher->addPath(plistPath);

    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(30000);
    connect(m_pollTimer, &QTimer::timeout, this, &SafariSyncManager::syncFromSafari);
    m_pollTimer->start();

    connect(m_store, &DataStore::dataChanged, this, &SafariSyncManager::scheduleWriteback);

    syncFromSafari();
}

void SafariSyncManager::stop()
{
    if (m_watcher) {
        delete m_watcher;
        m_watcher = nullptr;
    }
    if (m_pollTimer) {
        m_pollTimer->stop();
        delete m_pollTimer;
        m_pollTimer = nullptr;
    }
    if (m_writebackTimer) {
        m_writebackTimer->stop();
        delete m_writebackTimer;
        m_writebackTimer = nullptr;
    }
    m_plistPath.clear();
}

std::optional<QPair<QVector<Folder>, Folder>> SafariSyncManager::performFullImport(const QString &plistPath)
{
    return parseSafariPlist(plistPath);
}

void SafariSyncManager::syncFromSafari()
{
    if (m_plistPath.isEmpty()) return;
    if (m_writebackInProgress) return;

    QFileInfo info(m_plistPath);
    QDateTime mod = info.lastModified();
    if (m_lastModificationDate.isValid() && mod <= m_lastModificationDate) return;
    m_lastModificationDate = mod;

    auto result = parseSafariPlist(m_plistPath);
    if (!result) return;

    m_applyingSync = true;
    m_store->applySafariSync(result->first, result->second);
    m_applyingSync = false;
}

void SafariSyncManager::scheduleWriteback()
{
    if (m_plistPath.isEmpty()) return;
    if (m_applyingSync) return;
    if (m_store && m_store->isSyncingFromSafari()) return;
    if (!m_writebackTimer) {
        m_writebackTimer = new QTimer(this);
        m_writebackTimer->setSingleShot(true);
        connect(m_writebackTimer, &QTimer::timeout, this, &SafariSyncManager::writebackToSafari);
    }
    m_writebackTimer->start(2000);
}

static void collectLeaves(NSArray *children, NSMutableDictionary *urlToLeaf)
{
    for (NSDictionary *child in children) {
        NSString *type = child[@"WebBookmarkType"];
        if ([type isEqualToString:@"WebBookmarkTypeLeaf"]) {
            NSString *url = child[@"URLString"];
            if (url) {
                urlToLeaf[[url lowercaseString]] = child;
            }
        } else if ([type isEqualToString:@"WebBookmarkTypeList"]) {
            NSArray *sub = child[@"Children"];
            if (sub) collectLeaves(sub, urlToLeaf);
        }
    }
}

static void collectFolders(NSArray *children, NSMutableDictionary *titleToFolder)
{
    for (NSDictionary *child in children) {
        if ([child[@"WebBookmarkType"] isEqualToString:@"WebBookmarkTypeList"]) {
            NSString *title = child[@"Title"];
            if (title) titleToFolder[title] = child;
            NSArray *sub = child[@"Children"];
            if (sub) collectFolders(sub, titleToFolder);
        }
    }
}

static NSDictionary *buildSafariLeaf(const Entry &entry, NSDictionary *urlToLeaf)
{
    NSString *url = qStringToNSString(entry.text);
    NSString *normalized = [url lowercaseString];
    NSDictionary *existing = urlToLeaf[normalized];
    if (existing) return existing;

    return @{
        @"WebBookmarkType": @"WebBookmarkTypeLeaf",
        @"WebBookmarkUUID": qStringToNSString(QUuid::createUuid().toString(QUuid::WithoutBraces)),
        @"URLString": url,
        @"URIDictionary": @{@"title": url}
    };
}

static NSDictionary *buildSafariFolder(const Folder &folder, NSString *safariTitle,
                                       NSDictionary *urlToLeaf, NSDictionary *titleToFolder)
{
    NSDictionary *existing = titleToFolder[safariTitle];
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"WebBookmarkType"] = @"WebBookmarkTypeList";
    dict[@"Title"] = safariTitle;
    dict[@"WebBookmarkUUID"] = existing[@"WebBookmarkUUID"] ?: qStringToNSString(QUuid::createUuid().toString(QUuid::WithoutBraces));

    // Preserve other metadata
    if (existing) {
        for (NSString *key in existing) {
            if (![key isEqualToString:@"Children"] && !dict[key]) {
                dict[key] = existing[key];
            }
        }
    }

    NSMutableArray *children = [NSMutableArray array];
    for (const auto &sub : folder.subfolders) {
        [children addObject:buildSafariFolder(sub, qStringToNSString(sub.name), urlToLeaf, titleToFolder)];
    }
    for (const auto &entry : folder.entries) {
        [children addObject:buildSafariLeaf(entry, urlToLeaf)];
    }
    if (children.count > 0) {
        dict[@"Children"] = children;
    }
    return dict;
}

static NSDictionary *buildSafariReadingList(const Folder &folder, NSDictionary *urlToLeaf, NSDictionary *existingRL)
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"WebBookmarkType"] = @"WebBookmarkTypeList";
    dict[@"Title"] = @"com.apple.ReadingList";
    dict[@"WebBookmarkUUID"] = existingRL[@"WebBookmarkUUID"] ?: qStringToNSString(QUuid::createUuid().toString(QUuid::WithoutBraces));

    if (existingRL) {
        for (NSString *key in existingRL) {
            if (![key isEqualToString:@"Children"] && !dict[key]) {
                dict[key] = existingRL[key];
            }
        }
    }

    NSMutableArray *children = [NSMutableArray array];
    for (const auto &entry : folder.entries) {
        NSString *url = qStringToNSString(entry.text);
        NSString *normalized = [url lowercaseString];
        NSDictionary *existing = urlToLeaf[normalized];
        if (existing) {
            [children addObject:existing];
        } else {
            NSDate *dateAdded = [NSDate dateWithTimeIntervalSince1970:entry.date.toSecsSinceEpoch()];
            [children addObject:@{
                @"WebBookmarkType": @"WebBookmarkTypeLeaf",
                @"WebBookmarkUUID": qStringToNSString(QUuid::createUuid().toString(QUuid::WithoutBraces)),
                @"URLString": url,
                @"URIDictionary": @{@"title": url},
                @"ReadingList": @{@"DateAdded": dateAdded, @"PreviewText": @""},
                @"ReadingListNonSync": @{@"neverFetchMetadata": @NO}
            }];
        }
    }
    if (children.count > 0) {
        dict[@"Children"] = children;
    }
    return dict;
}

void SafariSyncManager::writebackToSafari()
{
    if (m_plistPath.isEmpty()) return;
    if (m_writebackInProgress) return;
    m_writebackInProgress = true;

    // Coordinate with other running ePanel instances. Only one instance writes
    // back to Safari at a time; the others rely on the shared data file to
    // propagate their changes to the lock holder.
    QLockFile lock(m_store->dataFolderPath() + QStringLiteral("/epanel-safari.lock"));
    lock.setStaleLockTime(5000);
    if (!lock.tryLock(2000)) {
        m_writebackInProgress = false;
        return;
    }

    id plist = readPlist(m_plistPath);
    if (![plist isKindOfClass:[NSDictionary class]]) {
        m_writebackInProgress = false;
        return;
    }
    NSMutableDictionary *root = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)plist];
    NSArray *existingChildren = root[@"Children"];
    if (![existingChildren isKindOfClass:[NSArray class]]) {
        m_writebackInProgress = false;
        return;
    }

    NSMutableDictionary *urlToLeaf = [NSMutableDictionary dictionary];
    collectLeaves(existingChildren, urlToLeaf);
    NSMutableDictionary *titleToFolder = [NSMutableDictionary dictionary];
    collectFolders(existingChildren, titleToFolder);

    const Folder &rootFolder = m_store->data().rootFolder;

    const Folder *favorites = nullptr;
    const Folder *bookmarksMenu = nullptr;
    const Folder *readingList = nullptr;
    QVector<const Folder *> otherFolders;

    for (const auto &sub : rootFolder.subfolders) {
        if (sub.name == QObject::tr("Favorites")) favorites = &sub;
        else if (sub.name == QObject::tr("Bookmarks Menu")) bookmarksMenu = &sub;
        else if (sub.name == QObject::tr("Reading List")) readingList = &sub;
        else if (sub.name == "my_original_epanel") continue;
        else otherFolders.append(&sub);
    }

    NSMutableArray *newChildren = [NSMutableArray array];
    // Preserve proxy entries
    for (NSDictionary *child in existingChildren) {
        if ([child[@"WebBookmarkType"] isEqualToString:@"WebBookmarkTypeProxy"]) {
            [newChildren addObject:child];
        }
    }

    // BookmarksBar (Favorites)
    if (favorites) {
        [newChildren addObject:buildSafariFolder(*favorites, @"BookmarksBar", urlToLeaf, titleToFolder)];
    } else {
        NSDictionary *existing = titleToFolder[@"BookmarksBar"];
        if (existing) [newChildren addObject:existing];
    }

    // BookmarksMenu + other folders + root entries
    Folder mergedMenu(bookmarksMenu ? bookmarksMenu->name : QObject::tr("Bookmarks Menu"));
    if (bookmarksMenu) {
        mergedMenu.entries = bookmarksMenu->entries;
        mergedMenu.subfolders = bookmarksMenu->subfolders;
    }
    mergedMenu.entries.append(rootFolder.entries);
    for (const auto *other : otherFolders) {
        mergedMenu.subfolders.append(*other);
    }
    [newChildren addObject:buildSafariFolder(mergedMenu, @"BookmarksMenu", urlToLeaf, titleToFolder)];

    // Reading List
    NSDictionary *existingRL = titleToFolder[@"com.apple.ReadingList"];
    if (readingList) {
        [newChildren addObject:buildSafariReadingList(*readingList, urlToLeaf, existingRL)];
    } else if (existingRL) {
        [newChildren addObject:existingRL];
    }

    root[@"Children"] = newChildren;

    if (writePlist(root, m_plistPath)) {
        QFileInfo info(m_plistPath);
        m_lastModificationDate = info.lastModified();
    }
    m_writebackInProgress = false;
}
