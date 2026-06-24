#include "NewFolderDialog.h"
#include "datastore/DataStore.h"
#include "models/Folder.h"
#include <QDialogButtonBox>
#include <QLabel>
#include <QLineEdit>
#include <QTreeWidget>
#include <QVBoxLayout>

NewFolderDialog::NewFolderDialog(DataStore *store, QWidget *parent)
    : QDialog(parent), m_store(store)
{
    setWindowTitle(tr("Create New Folder"));
    setMinimumWidth(320);

    QVBoxLayout *layout = new QVBoxLayout(this);

    layout->addWidget(new QLabel(tr("Folder Name:"), this));
    m_nameEdit = new QLineEdit(this);
    m_nameEdit->setText(tr("New Folder"));
    layout->addWidget(m_nameEdit);

    layout->addWidget(new QLabel(tr("Location:"), this));
    m_tree = new QTreeWidget(this);
    m_tree->setHeaderHidden(true);
    m_tree->setColumnCount(1);
    populateTree();
    layout->addWidget(m_tree, 1);

    QDialogButtonBox *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, this);
    connect(buttons, &QDialogButtonBox::accepted, this, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    layout->addWidget(buttons);

    m_nameEdit->setFocus();
    m_nameEdit->selectAll();
}

QString NewFolderDialog::folderName() const
{
    return m_nameEdit->text().trimmed();
}

QUuid NewFolderDialog::parentFolderId() const
{
    QTreeWidgetItem *item = m_tree->currentItem();
    if (!item) return DataStore::rootFolderId();
    return item->data(0, Qt::UserRole).toUuid();
}

void NewFolderDialog::populateTree()
{
    QTreeWidgetItem *rootItem = new QTreeWidgetItem(m_tree);
    rootItem->setText(0, "/");
    rootItem->setData(0, Qt::UserRole, QVariant(DataStore::rootFolderId()));
    rootItem->setSelected(true);

    const Folder &root = m_store->data().rootFolder;
    for (const auto &folder : root.subfolders) {
        addFolderItems(folder, rootItem);
    }
    m_tree->expandAll();
}

void NewFolderDialog::addFolderItems(const Folder &folder, QTreeWidgetItem *parentItem)
{
    QTreeWidgetItem *item = new QTreeWidgetItem(parentItem);
    item->setText(0, folder.name);
    item->setData(0, Qt::UserRole, QVariant(folder.id));
    item->setIcon(0, QIcon::fromTheme("folder"));
    for (const auto &sub : folder.subfolders) {
        addFolderItems(sub, item);
    }
}
