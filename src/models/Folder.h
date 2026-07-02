#pragma once

#include "Entry.h"
#include <QVector>
#include <QUuid>
#include <QString>
#include <QJsonObject>

struct Folder {
    QUuid id;
    QString name;
    QVector<Entry> entries;
    QVector<Folder> subfolders;
    bool isCollapsed = false;
    int entryCount = 0; // cached recursive entry count

    Folder() = default;
    explicit Folder(const QString &name);

    static QUuid rootFolderId();

    bool isRoot() const;
    int totalEntryCount() const;
    void recomputeEntryCount();

    QJsonObject toJson() const;
    static Folder fromJson(const QJsonObject &obj);
};
