#pragma once

#include <QDialog>
#include <QUuid>

class DataStore;
class QLineEdit;
class QTreeWidget;
class QTreeWidgetItem;

class NewFolderDialog : public QDialog {
    Q_OBJECT

public:
    explicit NewFolderDialog(DataStore *store, QWidget *parent = nullptr);

    QString folderName() const;
    QUuid parentFolderId() const;

private:
    void populateTree();
    void addFolderItems(const class Folder &folder, QTreeWidgetItem *parentItem);

    DataStore *m_store = nullptr;
    QLineEdit *m_nameEdit = nullptr;
    QTreeWidget *m_tree = nullptr;
};
