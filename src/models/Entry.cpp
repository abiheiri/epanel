#include "Entry.h"

Entry::Entry(const QString &text)
    : id(QUuid::createUuid()), text(text), date(QDateTime::currentDateTimeUtc())
{
}

QJsonObject Entry::toJson() const
{
    QJsonObject obj;
    obj["id"] = id.toString(QUuid::WithoutBraces);
    obj["text"] = text;
    obj["date"] = date.toString(Qt::ISODate);
    return obj;
}

Entry Entry::fromJson(const QJsonObject &obj)
{
    Entry entry;
    entry.id = QUuid::fromString(obj["id"].toString());
    entry.text = obj["text"].toString();
    entry.date = QDateTime::fromString(obj["date"].toString(), Qt::ISODate);
    if (!entry.date.isValid()) {
        entry.date = QDateTime::currentDateTimeUtc();
    }
    return entry;
}

bool Entry::operator==(const Entry &other) const
{
    return id == other.id && text == other.text && date == other.date;
}
