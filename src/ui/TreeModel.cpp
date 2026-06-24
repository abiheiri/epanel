#include "TreeModel.h"
#include "datastore/DataStore.h"
#include "models/Folder.h"
#include "models/Entry.h"
#include <QMimeData>
#include <QIcon>
#include <QUrl>

const QString TreeModel::s_mimeType = QStringLiteral("application/x-epanel-items");

struct TreeModel::Node {
    ItemType type = EntryType;
    QUuid id;
    QString text;
    int entryCount = 0; // for folders: total recursive entry count
    Node *parent = nullptr;
    QVector<Node *> children;
};

TreeModel::TreeModel(DataStore *store, QObject *parent)
    : QAbstractItemModel(parent), m_store(store)
{
    rebuild();
}

TreeModel::~TreeModel()
{
    clearNode(m_root);
}

void TreeModel::clearNode(Node *node)
{
    if (!node) return;
    for (Node *child : node->children) {
        clearNode(child);
    }
    delete node;
}

void TreeModel::rebuild()
{
    beginResetModel();
    clearNode(m_root);
    m_root = new Node;
    m_root->type = FolderType;
    m_root->id = DataStore::rootFolderId();
    m_root->text = QStringLiteral("/");

    if (m_store) {
        buildNode(m_root, m_store->data().rootFolder);
    }
    endResetModel();
}

void TreeModel::updateFromData()
{
    if (!m_store || !m_root) return;
    updateFolderNode(m_root, m_store->data().rootFolder);
}

void TreeModel::updateFolderNode(Node *parentNode, const Folder &folder)
{
    struct DesiredChild {
        enum Kind { FolderKind, EntryKind } kind;
        QUuid id;
        QString text;
        int entryCount = 0;
        const void *source = nullptr;
    };

    QVector<DesiredChild> desired;
    desired.reserve(folder.subfolders.size() + folder.entries.size());
    for (const Folder &sub : folder.subfolders) {
        desired.append({DesiredChild::FolderKind, sub.id, sub.name, sub.totalEntryCount(), &sub});
    }
    for (const Entry &entry : folder.entries) {
        desired.append({DesiredChild::EntryKind, entry.id, entry.text, 0, &entry});
    }

    int row = 0;
    const QModelIndex parentIndex = indexForNode(parentNode);

    while (row < desired.size()) {
        const DesiredChild &want = desired[row];
        const ItemType wantType = (want.kind == DesiredChild::FolderKind) ? FolderType : EntryType;

        // Find the best match among remaining current children.
        int matchIndex = -1;
        for (int i = row; i < parentNode->children.size(); ++i) {
            Node *n = parentNode->children[i];
            if (n->type != wantType) continue;
            if (!want.id.isNull() && n->id == want.id) {
                matchIndex = i;
                break; // UUID match is authoritative
            }
        }
        if (matchIndex < 0) {
            for (int i = row; i < parentNode->children.size(); ++i) {
                Node *n = parentNode->children[i];
                if (n->type != wantType) continue;
                const QString normalized = want.text.toLower().trimmed();
                if (n->text.toLower().trimmed() == normalized) {
                    matchIndex = i;
                    break;
                }
            }
        }

        if (matchIndex < 0) {
            // Insert a new node at the current row.
            Node *newNode = new Node;
            newNode->type = wantType;
            newNode->id = want.id;
            newNode->text = want.text;
            newNode->entryCount = want.entryCount;
            newNode->parent = parentNode;
            if (want.kind == DesiredChild::FolderKind) {
                buildNode(newNode, *static_cast<const Folder *>(want.source));
            }
            beginInsertRows(parentIndex, row, row);
            parentNode->children.insert(row, newNode);
            endInsertRows();
            ++row;
        } else {
            // Remove any stale children that stood between the current row and the match.
            if (matchIndex > row) {
                beginRemoveRows(parentIndex, row, matchIndex - 1);
                for (int i = matchIndex - 1; i >= row; --i) {
                    Node *n = parentNode->children.takeAt(i);
                    clearNode(n);
                }
                endRemoveRows();
            }

            Node *match = parentNode->children[row];
            bool displayChanged = false;
            if (match->text != want.text) {
                match->text = want.text;
                displayChanged = true;
            }
            if (want.kind == DesiredChild::FolderKind) {
                const int newCount = static_cast<const Folder *>(want.source)->totalEntryCount();
                if (match->entryCount != newCount) {
                    match->entryCount = newCount;
                    displayChanged = true;
                }
            }
            if (displayChanged) {
                const QModelIndex idx = indexForNode(match);
                emit dataChanged(idx, idx, {Qt::DisplayRole});
            }

            if (want.kind == DesiredChild::FolderKind) {
                updateFolderNode(match, *static_cast<const Folder *>(want.source));
            }
            ++row;
        }
    }

    // Remove any trailing children that are no longer present.
    if (row < parentNode->children.size()) {
        beginRemoveRows(parentIndex, row, parentNode->children.size() - 1);
        while (parentNode->children.size() > row) {
            Node *n = parentNode->children.takeLast();
            clearNode(n);
        }
        endRemoveRows();
    }
}

void TreeModel::buildNode(Node *parentNode, const Folder &folder)
{
    // Folders come first, matching the model order used elsewhere.
    for (const Folder &sub : folder.subfolders) {
        Node *folderNode = new Node;
        folderNode->type = FolderType;
        folderNode->id = sub.id;
        folderNode->text = sub.name;
        folderNode->entryCount = sub.totalEntryCount();
        folderNode->parent = parentNode;
        parentNode->children.append(folderNode);
        buildNode(folderNode, sub);
    }

    for (const Entry &entry : folder.entries) {
        Node *entryNode = new Node;
        entryNode->type = EntryType;
        entryNode->id = entry.id;
        entryNode->text = entry.text;
        entryNode->parent = parentNode;
        parentNode->children.append(entryNode);
    }
}

TreeModel::Node *TreeModel::nodeForIndex(const QModelIndex &index) const
{
    if (!index.isValid()) return m_root;
    return static_cast<Node *>(index.internalPointer());
}

QModelIndex TreeModel::indexForNode(Node *node) const
{
    if (!node || node == m_root) return QModelIndex();
    int row = node->parent ? node->parent->children.indexOf(node) : -1;
    if (row < 0) return QModelIndex();
    return createIndex(row, 0, node);
}

QModelIndex TreeModel::index(int row, int column, const QModelIndex &parent) const
{
    if (column != 0 || row < 0) return QModelIndex();
    Node *parentNode = nodeForIndex(parent);
    if (!parentNode || row >= parentNode->children.size()) return QModelIndex();
    return createIndex(row, column, parentNode->children.at(row));
}

QModelIndex TreeModel::parent(const QModelIndex &child) const
{
    Node *node = nodeForIndex(child);
    if (!node || node == m_root) return QModelIndex();
    return indexForNode(node->parent);
}

int TreeModel::rowCount(const QModelIndex &parent) const
{
    Node *parentNode = nodeForIndex(parent);
    return parentNode ? parentNode->children.size() : 0;
}

int TreeModel::columnCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return 1;
}

QVariant TreeModel::data(const QModelIndex &index, int role) const
{
    Node *node = nodeForIndex(index);
    if (!node || node == m_root) return QVariant();

    switch (role) {
    case Qt::DisplayRole:
        if (node->type == FolderType) {
            return QStringLiteral("%1 (%2)").arg(node->text).arg(node->entryCount);
        }
        return node->text;

    case Qt::DecorationRole: {
        if (node->type == FolderType) {
            QIcon icon = QIcon::fromTheme(QStringLiteral("folder"));
            if (icon.isNull()) icon = QIcon::fromTheme(QStringLiteral("folder-open"));
            return icon;
        }
        QIcon icon = QIcon::fromTheme(QStringLiteral("text-html"));
        if (icon.isNull()) icon = QIcon::fromTheme(QStringLiteral("document-open"));
        if (icon.isNull()) icon = QIcon::fromTheme(QStringLiteral("text-plain"));
        return icon;
    }

    case Qt::UserRole: {
        QVariantMap map;
        map[QStringLiteral("type")] = node->type == FolderType ? QStringLiteral("folder") : QStringLiteral("entry");
        map[QStringLiteral("id")] = QVariant(node->id);
        return map;
    }

    case Qt::ToolTipRole:
        if (node->type == EntryType) return node->text;
        return QVariant();

    case FilterRole:
        return node->text;

    default:
        return QVariant();
    }
}

bool TreeModel::setData(const QModelIndex &index, const QVariant &value, int role)
{
    Node *node = nodeForIndex(index);
    if (!node || node->type != FolderType || role != Qt::EditRole) return false;

    QString newName = value.toString().trimmed();
    if (newName.isEmpty() || newName == node->text) return false;

    node->text = newName;
    emit dataChanged(index, index, {Qt::DisplayRole});
    emit renameFolderRequested(node->id, newName);
    return true;
}

Qt::ItemFlags TreeModel::flags(const QModelIndex &index) const
{
    if (!index.isValid()) return Qt::NoItemFlags;

    Qt::ItemFlags f = Qt::ItemIsEnabled | Qt::ItemIsSelectable | Qt::ItemIsDragEnabled | Qt::ItemIsDropEnabled;
    Node *node = nodeForIndex(index);
    if (node && node->type == FolderType) {
        f |= Qt::ItemIsEditable;
    }
    return f;
}

QVariant TreeModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if (orientation == Qt::Horizontal && role == Qt::DisplayRole && section == 0) {
        return tr("Name");
    }
    return QVariant();
}

QStringList TreeModel::mimeTypes() const
{
    return QStringList() << s_mimeType;
}

QMimeData *TreeModel::mimeData(const QModelIndexList &indexes) const
{
    QSet<QUuid> seen;
    QStringList items;

    for (const QModelIndex &idx : indexes) {
        if (!idx.isValid() || idx.column() != 0) continue;
        Node *node = nodeForIndex(idx);
        if (!node || node == m_root) continue;
        if (seen.contains(node->id)) continue;
        seen.insert(node->id);

        QString prefix = node->type == FolderType ? QStringLiteral("folder:") : QStringLiteral("entry:");
        items.append(prefix + node->id.toString(QUuid::WithoutBraces));
    }

    if (items.isEmpty()) return nullptr;

    QMimeData *mime = new QMimeData();
    mime->setData(s_mimeType, items.join(',').toUtf8());
    return mime;
}

Qt::DropActions TreeModel::supportedDragActions() const
{
    return Qt::MoveAction;
}

Qt::DropActions TreeModel::supportedDropActions() const
{
    return Qt::MoveAction;
}

bool TreeModel::canDropMimeData(const QMimeData *data, Qt::DropAction action,
                                int row, int column, const QModelIndex &parent) const
{
    Q_UNUSED(row)
    Q_UNUSED(column)
    if (action != Qt::MoveAction) return false;
    if (!data || !data->hasFormat(s_mimeType)) return false;

    // Determine target folder id
    QUuid targetFolderId = DataStore::rootFolderId();
    if (parent.isValid()) {
        Node *target = nodeForIndex(parent);
        if (target) {
            targetFolderId = (target->type == FolderType) ? target->id : target->parent->id;
        }
    }

    // Refuse dropping a folder onto itself or onto one of its descendants.
    const QByteArray encoded = data->data(s_mimeType);
    const QStringList items = QString::fromUtf8(encoded).split(',', Qt::SkipEmptyParts);
    for (const QString &item : items) {
        if (!item.startsWith(QStringLiteral("folder:"))) continue;
        QUuid sourceId = QUuid::fromString(item.mid(7));
        if (sourceId == targetFolderId) return false;
        if (m_store && m_store->isDescendant(targetFolderId, sourceId)) return false;
    }

    return true;
}

bool TreeModel::dropMimeData(const QMimeData *data, Qt::DropAction action,
                             int row, int column, const QModelIndex &parent)
{
    Q_UNUSED(row)
    Q_UNUSED(column)
    if (action != Qt::MoveAction) return false;
    if (!data || !data->hasFormat(s_mimeType)) return false;

    QUuid targetFolderId = DataStore::rootFolderId();
    if (parent.isValid()) {
        Node *target = nodeForIndex(parent);
        if (target) {
            targetFolderId = (target->type == FolderType) ? target->id : target->parent->id;
        }
    }

    const QByteArray encoded = data->data(s_mimeType);
    const QStringList items = QString::fromUtf8(encoded).split(',', Qt::SkipEmptyParts);

    QVector<QUuid> entryIds;
    QVector<QUuid> folderIds;

    for (const QString &item : items) {
        if (item.startsWith(QStringLiteral("entry:"))) {
            QUuid id = QUuid::fromString(item.mid(6));
            if (!id.isNull()) entryIds.append(id);
        } else if (item.startsWith(QStringLiteral("folder:"))) {
            QUuid id = QUuid::fromString(item.mid(7));
            if (!id.isNull()) folderIds.append(id);
        }
    }

    if (entryIds.isEmpty() && folderIds.isEmpty()) return false;

    if (!entryIds.isEmpty()) {
        if (entryIds.size() == 1) {
            emit moveEntryRequested(entryIds.first(), targetFolderId);
        } else {
            emit moveEntriesRequested(entryIds, targetFolderId);
        }
    }

    for (const QUuid &folderId : folderIds) {
        emit moveFolderRequested(folderId, targetFolderId);
    }

    return true;
}

QUuid TreeModel::idForIndex(const QModelIndex &index) const
{
    Node *node = nodeForIndex(index);
    return node ? node->id : QUuid();
}

TreeModel::ItemType TreeModel::typeForIndex(const QModelIndex &index) const
{
    Node *node = nodeForIndex(index);
    return node ? node->type : EntryType;
}

QModelIndex TreeModel::indexForId(const QUuid &id, ItemType type) const
{
    Node *found = findNode(m_root, id, type);
    return found ? indexForNode(found) : QModelIndex();
}

TreeModel::Node *TreeModel::findNode(Node *node, const QUuid &id, ItemType type) const
{
    if (!node) return nullptr;
    if (node != m_root && node->type == type && node->id == id) return node;
    for (Node *child : node->children) {
        Node *found = findNode(child, id, type);
        if (found) return found;
    }
    return nullptr;
}

int TreeModel::folderEntryCount(Node *folderNode) const
{
    if (!folderNode || folderNode->type != FolderType) return 0;
    return folderNode->entryCount;
}
