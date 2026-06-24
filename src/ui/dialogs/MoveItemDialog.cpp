#include "MoveItemDialog.h"
#include "datastore/DataStore.h"
#include "models/Folder.h"
#include <QDialogButtonBox>
#include <QLabel>
#include <QTreeWidget>
#include <QVBoxLayout>

MoveItemDialog::MoveItemDialog(DataStore *store, const QString &title, const QSet<QUuid> &excludedIds, QWidget *parent)
    : QDialog(parent), m_store(store), m_excludedIds(excludedIds)
{
    setWindowTitle(title);
    setMinimumWidth(320);

    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->addWidget(new QLabel(tr("Select destination folder:"), this));

    m_tree = new QTreeWidget(this);
    m_tree->setHeaderHidden(true);
    m_tree->setColumnCount(1);
    populateTree();
    layout->addWidget(m_tree, 1);

    QDialogButtonBox *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, this);
    connect(buttons, &QDialogButtonBox::accepted, this, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    layout->addWidget(buttons);
}

QUuid MoveItemDialog::selectedFolderId() const
{
    QTreeWidgetItem *item = m_tree->currentItem();
    if (!item) return DataStore::rootFolderId();
    return item->data(0, Qt::UserRole).toUuid();
}

void MoveItemDialog::populateTree()
{
    QTreeWidgetItem *rootItem = new QTreeWidgetItem(m_tree);
    rootItem->setText(0, tr("<root folder>"));
    rootItem->setData(0, Qt::UserRole, QVariant(DataStore::rootFolderId()));
    rootItem->setSelected(true);

    const Folder &root = m_store->data().rootFolder;
    for (const auto &folder : root.subfolders) {
        addFolderItems(folder, rootItem);
    }
    m_tree->expandAll();
}

void MoveItemDialog::addFolderItems(const Folder &folder, QTreeWidgetItem *parentItem)
{
    if (m_excludedIds.contains(folder.id)) return;

    QTreeWidgetItem *item = new QTreeWidgetItem(parentItem);
    item->setText(0, folder.name);
    item->setData(0, Qt::UserRole, QVariant(folder.id));
    item->setIcon(0, QIcon::fromTheme("folder"));

    for (const auto &sub : folder.subfolders) {
        addFolderItems(sub, item);
    }
}
