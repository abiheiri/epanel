#include "EPanelData.h"
#include <QJsonObject>
#include <QJsonArray>
#include <QFile>

static const QUuid RootFolderID("00000000-0000-0000-0000-000000000000");

EPanelData EPanelData::empty()
{
    EPanelData data;
    data.rootFolder.id = RootFolderID;
    data.rootFolder.name = "/";
    return data;
}

QJsonDocument EPanelData::toJsonDocument() const
{
    QJsonObject obj;
    obj["rootFolder"] = rootFolder.toJson();
    return QJsonDocument(obj);
}

EPanelData EPanelData::fromJsonDocument(const QJsonDocument &doc)
{
    EPanelData data;
    const QJsonObject obj = doc.object();
    if (obj.contains("rootFolder")) {
        data.rootFolder = Folder::fromJson(obj["rootFolder"].toObject());
    } else {
        // Try legacy format
        data = fromLegacyJson(obj);
    }
    if (data.rootFolder.id != RootFolderID) {
        data.rootFolder.id = RootFolderID;
        data.rootFolder.name = "/";
    }
    return data;
}

bool EPanelData::loadFromFile(const QString &path, QString *error)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        if (error) *error = file.errorString();
        return false;
    }
    QJsonParseError parseError;
    QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (doc.isNull()) {
        if (error) *error = parseError.errorString();
        return false;
    }
    *this = fromJsonDocument(doc);
    return true;
}

bool EPanelData::saveToFile(const QString &path, QString *error) const
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        if (error) *error = file.errorString();
        return false;
    }
    file.write(toJsonDocument().toJson(QJsonDocument::Indented));
    return true;
}

EPanelData EPanelData::fromLegacyJson(const QJsonObject &obj)
{
    EPanelData data = empty();
    const QJsonArray foldersArr = obj["folders"].toArray();
    for (const auto &val : foldersArr) {
        data.rootFolder.subfolders.append(Folder::fromJson(val.toObject()));
    }
    const QJsonArray rootEntriesArr = obj["rootEntries"].toArray();
    for (const auto &val : rootEntriesArr) {
        data.rootFolder.entries.append(Entry::fromJson(val.toObject()));
    }
    // Notes are handled separately
    return data;
}
