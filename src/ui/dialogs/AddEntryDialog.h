#pragma once

#include <QDialog>
#include <QUuid>
#include "models/Entry.h"

class DataStore;
class QTreeWidget;
class QTreeWidgetItem;
class QLabel;

class AddEntryDialog : public QDialog {
    Q_OBJECT

public:
    AddEntryDialog(DataStore *store, const QString &entryText, QWidget *parent = nullptr);

    QUuid selectedFolderId() const;

private:
    void populateTree();
    void addFolderItems(QTreeWidget *tree, const class Folder &folder, QTreeWidgetItem *parentItem, int depth);

    DataStore *m_store = nullptr;
    QTreeWidget *m_tree = nullptr;
    QLabel *m_textLabel = nullptr;
};
