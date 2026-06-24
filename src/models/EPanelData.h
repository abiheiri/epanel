#pragma once

#include "Folder.h"
#include <QJsonDocument>
#include <QString>

struct EPanelData {
    Folder rootFolder;

    static EPanelData empty();

    QJsonDocument toJsonDocument() const;
    static EPanelData fromJsonDocument(const QJsonDocument &doc);

    bool loadFromFile(const QString &path, QString *error = nullptr);
    bool saveToFile(const QString &path, QString *error = nullptr) const;

    // Legacy import for the old JSON format used by earlier versions
    static EPanelData fromLegacyJson(const QJsonObject &obj);
};
