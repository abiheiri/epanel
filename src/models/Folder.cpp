#include "Folder.h"
#include <QJsonArray>
#include <numeric>

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
    return entries.size() + std::accumulate(subfolders.begin(), subfolders.end(), 0,
                                            [](int sum, const Folder &sub) {
                                                return sum + sub.totalEntryCount();
                                            });
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
