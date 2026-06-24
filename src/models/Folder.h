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

    Folder() = default;
    explicit Folder(const QString &name);

    bool isRoot() const;
    int totalEntryCount() const;

    QJsonObject toJson() const;
    static Folder fromJson(const QJsonObject &obj);
};
