#pragma once

#include <QDialog>
#include <QUuid>
#include <QSet>

class DataStore;
class QTreeWidget;
class QTreeWidgetItem;

class MoveItemDialog : public QDialog {
    Q_OBJECT

public:
    MoveItemDialog(DataStore *store, const QString &title, const QSet<QUuid> &excludedIds, QWidget *parent = nullptr);

    QUuid selectedFolderId() const;

private:
    void populateTree();
    void addFolderItems(const class Folder &folder, QTreeWidgetItem *parentItem);

    DataStore *m_store = nullptr;
    QTreeWidget *m_tree = nullptr;
    QSet<QUuid> m_excludedIds;
};
