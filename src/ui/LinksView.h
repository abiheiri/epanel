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
class QTimer;

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
    void onFolderDataChanged(const QUuid &folderId);
    void onMoveItems();
    void onSearchTextChanged(const QString &text);
    void applySearchFilter();

private:
    void buildUi();
    void openEntryText(const QString &text);

    struct SelectedItem {
        TreeModel::ItemType type = TreeModel::EntryType;
        QUuid id;
    };
    QVector<SelectedItem> collectSelectedItems() const;
    void restoreSelection(const QVector<SelectedItem> &items);

    QSet<QUuid> collectExpandedFolderIds(const QModelIndex &proxyParent = QModelIndex()) const;
    void restoreExpandedFolders(const QSet<QUuid> &ids, const QModelIndex &proxyParent = QModelIndex());

    QUuid folderIdForProxyIndex(const QModelIndex &proxyIndex) const;
    QSet<QUuid> descendantFolderIds(const QUuid &folderId) const;

    DataStore *m_store = nullptr;
    QTreeView *m_tree = nullptr;
    QLineEdit *m_searchEdit = nullptr;
    TreeModel *m_model = nullptr;
    QSortFilterProxyModel *m_filter = nullptr;

    bool m_searchActive = false;
    QSet<QUuid> m_preSearchExpanded;
    QTimer *m_searchDebounceTimer = nullptr;
    QString m_pendingSearchText;
};
