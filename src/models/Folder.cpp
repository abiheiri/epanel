#include "Folder.h"
#include <QJsonArray>

Folder::Folder(const QString &name)
    : id(QUuid::createUuid()), name(name)
{
}

bool Folder::isRoot() const
{
    return id.isNull();
}

int Folder::totalEntryCount() const
{
    int count = entries.size();
    for (const auto &sub : subfolders) {
        count += sub.totalEntryCount();
    }
    return count;
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
