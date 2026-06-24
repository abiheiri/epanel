#pragma once

#include "TreeModel.h"

#include <QWidget>
#include <QModelIndex>
#include <QSet>
#include <QSortFilterProxyModel>
#include <QUuid>
#include <QVector>

class DataStore;
class QTreeView;
class QLineEdit;

class LinksView : public QWidget {
    Q_OBJECT

public:
    explicit LinksView(DataStore *store, QWidget *parent = nullptr);

private slots:
    void onAddEntry();
    void onNewFolder();
    void onOpenItem(const QModelIndex &proxyIndex);
    void onCustomContextMenu(const QPoint &pos);
    void onDeleteKey();
    void onDataChanged();
    void onMoveItems();

private:
    void buildUi();
    void openEntryText(const QString &text);

    QSet<QUuid> collectExpandedFolders() const;
    void restoreExpandedFolders(const QSet<QUuid> &ids);

    struct SelectedItem {
        TreeModel::ItemType type;
        QUuid id;
    };
    QVector<SelectedItem> collectSelectedItems() const;
    void restoreSelection(const QVector<SelectedItem> &items);

    QUuid folderIdForProxyIndex(const QModelIndex &proxyIndex) const;
    QSet<QUuid> descendantFolderIds(const QUuid &folderId) const;

    DataStore *m_store = nullptr;
    QTreeView *m_tree = nullptr;
    QLineEdit *m_searchEdit = nullptr;
    TreeModel *m_model = nullptr;
    QSortFilterProxyModel *m_filter = nullptr;
};
