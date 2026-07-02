#include "Folder.h"
#include <QJsonArray>

static const QUuid RootFolderId("00000000-0000-0000-0000-000000000000");

Folder::Folder(const QString &name)
    : id(QUuid::createUuid()), name(name)
{
}

QUuid Folder::rootFolderId()
{
    return RootFolderId;
}

bool Folder::isRoot() const
{
    return id == RootFolderId;
}

int Folder::totalEntryCount() const
{
    return entryCount;
}

void Folder::recomputeEntryCount()
{
    entryCount = static_cast<int>(entries.size());
    for (auto &sub : subfolders) {
        sub.recomputeEntryCount();
        entryCount += sub.entryCount;
    }
}

QJsonObject Folder::toJson() const
{
    QJsonObject obj;
    obj["id"] = id.toString(QUuid::WithoutBraces);
    obj["name"] = name;

    QJsonArray entriesArr;
    for (const auto &entry : entries) {
        entriesArr.append(entry.toJson());
    }
    obj["entries"] = entriesArr;

    QJsonArray foldersArr;
    for (const auto &sub : subfolders) {
        foldersArr.append(sub.toJson());
    }
    obj["subfolders"] = foldersArr;

    obj["isCollapsed"] = isCollapsed;
    return obj;
}

Folder Folder::fromJson(const QJsonObject &obj)
{
    Folder folder;
    folder.id = QUuid::fromString(obj["id"].toString());
    folder.name = obj["name"].toString();
    folder.isCollapsed = obj["isCollapsed"].toBool(false);

    const QJsonArray entriesArr = obj["entries"].toArray();
    for (const auto &val : entriesArr) {
        folder.entries.append(Entry::fromJson(val.toObject()));
    }

    const QJsonArray foldersArr = obj["subfolders"].toArray();
    for (const auto &val : foldersArr) {
        folder.subfolders.append(Folder::fromJson(val.toObject()));
    }

    return folder;
}
