#pragma once

#include <QUuid>
#include <QString>
#include <QDateTime>
#include <QJsonObject>

struct Entry {
    QUuid id;
    QString text;
    QDateTime date;

    Entry() = default;
    explicit Entry(const QString &text);

    QJsonObject toJson() const;
    static Entry fromJson(const QJsonObject &obj);

    bool operator==(const Entry &other) const;
};
