#include "AddEntryDialog.h"
#include "datastore/DataStore.h"
#include "models/Folder.h"
#include <QDialogButtonBox>
#include <QLabel>
#include <QLineEdit>
#include <QTreeWidget>
#include <QVBoxLayout>
#include <QHeaderView>

AddEntryDialog::AddEntryDialog(DataStore *store, const QString &entryText, QWidget *parent)
    : QDialog(parent), m_store(store)
{
    setWindowTitle(tr("Add Entry To"));
    setMinimumWidth(360);

    QVBoxLayout *layout = new QVBoxLayout(this);

    m_textLabel = new QLabel(entryText, this);
    m_textLabel->setWordWrap(true);
    m_textLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
    layout->addWidget(m_textLabel);

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

QUuid AddEntryDialog::selectedFolderId() const
{
    QTreeWidgetItem *item = m_tree->currentItem();
    if (!item) return DataStore::rootFolderId();
    return item->data(0, Qt::UserRole).toUuid();
}

void AddEntryDialog::populateTree()
{
    QTreeWidgetItem *rootItem = new QTreeWidgetItem(m_tree);
    rootItem->setText(0, tr("<root folder>"));
    rootItem->setData(0, Qt::UserRole, QVariant(DataStore::rootFolderId()));
    rootItem->setSelected(true);

    const Folder &root = m_store->data().rootFolder;
    for (const auto &folder : root.subfolders) {
        addFolderItems(m_tree, folder, rootItem, 1);
    }

    m_tree->expandAll();
}

void AddEntryDialog::addFolderItems(QTreeWidget *tree, const Folder &folder, QTreeWidgetItem *parentItem, int depth)
{
    Q_UNUSED(tree)
    Q_UNUSED(depth)
    QTreeWidgetItem *item = new QTreeWidgetItem(parentItem);
    item->setText(0, folder.name);
    item->setData(0, Qt::UserRole, QVariant(folder.id));
    item->setIcon(0, QIcon::fromTheme("folder"));
    for (const auto &sub : folder.subfolders) {
        addFolderItems(tree, sub, item, depth + 1);
    }
}
