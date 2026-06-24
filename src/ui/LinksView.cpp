#include "LinksView.h"
#include "datastore/DataStore.h"
#include "models/Folder.h"
#include "models/Entry.h"
#include "dialogs/AddEntryDialog.h"
#include "dialogs/NewFolderDialog.h"
#include "dialogs/MoveItemDialog.h"

#include <QTreeView>
#include <QLineEdit>
#include <QPushButton>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QSortFilterProxyModel>
#include <QMenu>
#include <QMessageBox>
#include <QShortcut>
#include <QDesktopServices>
#include <QUrl>
#include <QFileInfo>
#include <QDir>
#include <QInputDialog>
#include <QRegularExpression>
#include <QItemSelectionModel>
#include <QApplication>

namespace {

bool looksLikeUrl(const QString &text)
{
    static const QRegularExpression re(QStringLiteral("^[a-zA-Z][a-zA-Z0-9+.-]*://"));
    return re.match(text.trimmed()).hasMatch();
}

} // namespace

LinksView::LinksView(DataStore *store, QWidget *parent)
    : QWidget(parent), m_store(store)
{
    buildUi();

    m_model->rebuild();

    connect(m_store, &DataStore::dataChanged, this, &LinksView::onDataChanged);
}

void LinksView::buildUi()
{
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->setSpacing(6);

    // Toolbar
    QHBoxLayout *toolbar = new QHBoxLayout();
    m_searchEdit = new QLineEdit(this);
    m_searchEdit->setPlaceholderText(tr("Search links and folders…"));
    m_searchEdit->setClearButtonEnabled(true);
    toolbar->addWidget(m_searchEdit, 1);

    QPushButton *addButton = new QPushButton(tr("Add"), this);
    addButton->setToolTip(tr("Add current text as an entry"));
    toolbar->addWidget(addButton);

    QPushButton *newFolderButton = new QPushButton(QIcon::fromTheme(QStringLiteral("folder-new")), tr("New Folder"), this);
    if (newFolderButton->icon().isNull()) {
        newFolderButton->setText(tr("New Folder"));
    }
    newFolderButton->setToolTip(tr("Create a new folder"));
    toolbar->addWidget(newFolderButton);

    layout->addLayout(toolbar);

    // Tree
    m_tree = new QTreeView(this);
    m_model = new TreeModel(m_store, this);
    m_filter = new QSortFilterProxyModel(this);
    m_filter->setRecursiveFilteringEnabled(true);
    m_filter->setFilterCaseSensitivity(Qt::CaseInsensitive);
    m_filter->setFilterRole(TreeModel::FilterRole);
    m_filter->setSourceModel(m_model);
    m_tree->setModel(m_filter);

    m_tree->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_tree->setUniformRowHeights(true);
    m_tree->setContextMenuPolicy(Qt::CustomContextMenu);
    m_tree->setDragEnabled(true);
    m_tree->setAcceptDrops(true);
    m_tree->setDropIndicatorShown(true);
    m_tree->setDragDropMode(QAbstractItemView::DragDrop);
    m_tree->setDefaultDropAction(Qt::MoveAction);
    m_tree->setEditTriggers(QAbstractItemView::EditKeyPressed);
    m_tree->setHeaderHidden(true);

    layout->addWidget(m_tree, 1);

    // Signals
    connect(m_searchEdit, &QLineEdit::textChanged, m_filter, &QSortFilterProxyModel::setFilterFixedString);
    connect(m_searchEdit, &QLineEdit::returnPressed, this, &LinksView::onAddEntry);
    connect(addButton, &QPushButton::clicked, this, &LinksView::onAddEntry);
    connect(newFolderButton, &QPushButton::clicked, this, &LinksView::onNewFolder);
    connect(m_tree, &QTreeView::doubleClicked, this, &LinksView::onOpenItem);
    connect(m_tree, &QTreeView::customContextMenuRequested, this, &LinksView::onCustomContextMenu);

    connect(m_model, &TreeModel::moveEntryRequested, m_store, &DataStore::moveEntry, Qt::QueuedConnection);
    connect(m_model, &TreeModel::moveEntriesRequested, m_store, &DataStore::moveEntries, Qt::QueuedConnection);
    connect(m_model, &TreeModel::moveFolderRequested, m_store, &DataStore::moveFolder, Qt::QueuedConnection);
    connect(m_model, &TreeModel::renameFolderRequested, m_store, &DataStore::renameFolder, Qt::QueuedConnection);

    QShortcut *deleteShortcut = new QShortcut(QKeySequence::Delete, this);
    connect(deleteShortcut, &QShortcut::activated, this, &LinksView::onDeleteKey);
}

void LinksView::onAddEntry()
{
    QString text = m_searchEdit->text().trimmed();
    if (text.isEmpty()) return;

    AddEntryDialog dialog(m_store, text, this);
    if (dialog.exec() == QDialog::Accepted) {
        m_store->addEntry(Entry(text), dialog.selectedFolderId());
        m_searchEdit->clear();
    }
}

void LinksView::onNewFolder()
{
    NewFolderDialog dialog(m_store, this);
    if (dialog.exec() == QDialog::Accepted) {
        QString name = dialog.folderName();
        if (!name.isEmpty()) {
            m_store->createFolder(name, dialog.parentFolderId());
        }
    }
}

void LinksView::onOpenItem(const QModelIndex &proxyIndex)
{
    if (!proxyIndex.isValid()) return;

    QModelIndex sourceIndex = m_filter->mapToSource(proxyIndex);
    if (m_model->typeForIndex(sourceIndex) == TreeModel::FolderType) {
        m_tree->setExpanded(proxyIndex, !m_tree->isExpanded(proxyIndex));
        return;
    }

    QString text = sourceIndex.data(Qt::DisplayRole).toString();
    openEntryText(text);
}

void LinksView::openEntryText(const QString &text)
{
    QString t = text.trimmed();
    if (t.isEmpty()) return;

    if (looksLikeUrl(t)) {
        QDesktopServices::openUrl(QUrl(t, QUrl::TolerantMode));
        return;
    }

    QFileInfo info(t);
    if (info.exists()) {
        if (info.isDir()) {
            QDesktopServices::openUrl(QUrl::fromLocalFile(info.dir().absolutePath()));
        } else {
            QDesktopServices::openUrl(QUrl::fromLocalFile(info.absoluteFilePath()));
        }
    } else {
        QMessageBox::warning(this, tr("Cannot Open"),
                             tr("The file or URL does not exist or cannot be opened:\n%1").arg(t));
    }
}

void LinksView::onCustomContextMenu(const QPoint &pos)
{
    QModelIndex proxyIndex = m_tree->indexAt(pos);
    QVector<SelectedItem> selected = collectSelectedItems();

    QMenu menu(this);

    if (proxyIndex.isValid() && !selected.isEmpty()) {
        QModelIndex sourceIndex = m_filter->mapToSource(proxyIndex);
        TreeModel::ItemType type = m_model->typeForIndex(sourceIndex);

        if (selected.size() == 1 && type == TreeModel::EntryType) {
            QAction *goAction = menu.addAction(tr("Go"));
            connect(goAction, &QAction::triggered, this, [this, sourceIndex]() {
                openEntryText(sourceIndex.data(Qt::DisplayRole).toString());
            });

            menu.addSeparator();
        }

        if (selected.size() == 1 && type == TreeModel::FolderType) {
            QAction *renameAction = menu.addAction(tr("Rename"));
            connect(renameAction, &QAction::triggered, this, [this, proxyIndex]() {
                m_tree->edit(proxyIndex);
            });

            QAction *newSubAction = menu.addAction(tr("New Subfolder…"));
            connect(newSubAction, &QAction::triggered, this, [this, sourceIndex]() {
                QUuid parentId = m_model->idForIndex(sourceIndex);
                bool ok = false;
                QString name = QInputDialog::getText(this, tr("New Subfolder"),
                                                     tr("Folder name:"), QLineEdit::Normal,
                                                     tr("New Folder"), &ok);
                if (ok && !name.trimmed().isEmpty()) {
                    m_store->createFolder(name.trimmed(), parentId);
                }
            });

            menu.addSeparator();
        }

        QAction *moveAction = menu.addAction(selected.size() > 1 ? tr("Move %1 Items to…").arg(selected.size())
                                                                  : tr("Move to…"));
        connect(moveAction, &QAction::triggered, this, &LinksView::onMoveItems);

        QAction *deleteAction = menu.addAction(tr("Delete"));
        connect(deleteAction, &QAction::triggered, this, &LinksView::onDeleteKey);
    } else {
        QAction *newFolderAction = menu.addAction(tr("New Folder…"));
        connect(newFolderAction, &QAction::triggered, this, &LinksView::onNewFolder);
    }

    menu.exec(m_tree->viewport()->mapToGlobal(pos));
}

void LinksView::onDeleteKey()
{
    QVector<SelectedItem> selected = collectSelectedItems();
    if (selected.isEmpty()) return;

    QSet<QUuid> entryIds;
    QSet<QUuid> folderIds;
    for (const SelectedItem &item : selected) {
        if (item.type == TreeModel::EntryType) entryIds.insert(item.id);
        else folderIds.insert(item.id);
    }

    if (!folderIds.isEmpty()) {
        int ret = QMessageBox::warning(this, tr("Delete Folders"),
                                       tr("Deleting folders will also delete their contents. This cannot be undone.\n\nAre you sure?"),
                                       QMessageBox::Yes | QMessageBox::Cancel,
                                       QMessageBox::Cancel);
        if (ret != QMessageBox::Yes) return;
    }

    if (!entryIds.isEmpty()) {
        m_store->deleteEntries(entryIds);
    }
    for (const QUuid &id : folderIds) {
        m_store->deleteFolder(id);
    }
}

void LinksView::onMoveItems()
{
    QVector<SelectedItem> selected = collectSelectedItems();
    if (selected.isEmpty()) return;

    QSet<QUuid> excludedIds;
    for (const SelectedItem &item : selected) {
        if (item.type == TreeModel::FolderType) {
            excludedIds.insert(item.id);
            excludedIds.unite(descendantFolderIds(item.id));
        }
    }

    MoveItemDialog dialog(m_store, tr("Move Items"), excludedIds, this);
    if (dialog.exec() != QDialog::Accepted) return;

    QUuid dest = dialog.selectedFolderId();

    QVector<QUuid> entryIds;
    QVector<QUuid> folderIds;
    for (const SelectedItem &item : selected) {
        if (item.type == TreeModel::EntryType) entryIds.append(item.id);
        else folderIds.append(item.id);
    }

    if (!entryIds.isEmpty()) {
        if (entryIds.size() == 1) {
            m_store->moveEntry(entryIds.first(), dest);
        } else {
            m_store->moveEntries(entryIds, dest);
        }
    }

    for (const QUuid &folderId : folderIds) {
        m_store->moveFolder(folderId, dest);
    }
}

void LinksView::onDataChanged()
{
    QSet<QUuid> expanded = collectExpandedFolders();
    QVector<SelectedItem> selected = collectSelectedItems();

    m_model->rebuild();

    restoreExpandedFolders(expanded);
    restoreSelection(selected);
}

QSet<QUuid> LinksView::collectExpandedFolders() const
{
    QSet<QUuid> ids;
    std::function<void(const QModelIndex &)> traverse = [&](const QModelIndex &parent) {
        int rows = m_filter->rowCount(parent);
        for (int row = 0; row < rows; ++row) {
            QModelIndex proxyIndex = m_filter->index(row, 0, parent);
            QModelIndex sourceIndex = m_filter->mapToSource(proxyIndex);
            if (m_model->typeForIndex(sourceIndex) != TreeModel::FolderType) continue;

            QUuid id = m_model->idForIndex(sourceIndex);
            if (m_tree->isExpanded(proxyIndex)) {
                ids.insert(id);
            }
            traverse(proxyIndex);
        }
    };
    traverse(QModelIndex());
    return ids;
}

void LinksView::restoreExpandedFolders(const QSet<QUuid> &ids)
{
    std::function<void(const QModelIndex &)> traverse = [&](const QModelIndex &parent) {
        int rows = m_filter->rowCount(parent);
        for (int row = 0; row < rows; ++row) {
            QModelIndex proxyIndex = m_filter->index(row, 0, parent);
            QModelIndex sourceIndex = m_filter->mapToSource(proxyIndex);
            if (m_model->typeForIndex(sourceIndex) != TreeModel::FolderType) continue;

            QUuid id = m_model->idForIndex(sourceIndex);
            if (ids.contains(id)) {
                m_tree->expand(proxyIndex);
                traverse(proxyIndex);
            }
        }
    };
    traverse(QModelIndex());
}

QVector<LinksView::SelectedItem> LinksView::collectSelectedItems() const
{
    QVector<SelectedItem> items;
    QModelIndexList proxyIndexes = m_tree->selectionModel()->selectedRows(0);
    for (const QModelIndex &proxyIndex : proxyIndexes) {
        QModelIndex sourceIndex = m_filter->mapToSource(proxyIndex);
        SelectedItem item;
        item.type = m_model->typeForIndex(sourceIndex);
        item.id = m_model->idForIndex(sourceIndex);
        if (!item.id.isNull()) items.append(item);
    }
    return items;
}

void LinksView::restoreSelection(const QVector<SelectedItem> &items)
{
    QItemSelectionModel *sel = m_tree->selectionModel();
    sel->clearSelection();

    QModelIndex firstProxy;
    for (const SelectedItem &item : items) {
        QModelIndex sourceIndex = m_model->indexForId(item.id, item.type);
        if (!sourceIndex.isValid()) continue;
        QModelIndex proxyIndex = m_filter->mapFromSource(sourceIndex);
        if (!proxyIndex.isValid()) continue;

        sel->select(proxyIndex, QItemSelectionModel::Select | QItemSelectionModel::Rows);
        if (!firstProxy.isValid()) firstProxy = proxyIndex;
    }

    if (firstProxy.isValid()) {
        sel->setCurrentIndex(firstProxy, QItemSelectionModel::Current | QItemSelectionModel::Rows);
        m_tree->scrollTo(firstProxy, QAbstractItemView::EnsureVisible);
    }
}

QUuid LinksView::folderIdForProxyIndex(const QModelIndex &proxyIndex) const
{
    if (!proxyIndex.isValid()) return DataStore::rootFolderId();
    QModelIndex sourceIndex = m_filter->mapToSource(proxyIndex);
    if (m_model->typeForIndex(sourceIndex) == TreeModel::FolderType) {
        return m_model->idForIndex(sourceIndex);
    }
    // Entry: return its parent folder id via the model parent
    QModelIndex sourceParent = m_model->parent(sourceIndex);
    if (!sourceParent.isValid()) return DataStore::rootFolderId();
    return m_model->idForIndex(sourceParent);
}

QSet<QUuid> LinksView::descendantFolderIds(const QUuid &folderId) const
{
    QSet<QUuid> result;
    if (!m_store) return result;

    std::function<void(const Folder &)> walk = [&](const Folder &folder) {
        for (const Folder &sub : folder.subfolders) {
            if (m_store->isDescendant(sub.id, folderId)) {
                result.insert(sub.id);
                walk(sub);
            } else {
                walk(sub);
            }
        }
    };

    walk(m_store->data().rootFolder);
    return result;
}


