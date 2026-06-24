#pragma once

#include <QAbstractItemModel>
#include <QSet>
#include <QUuid>
#include <QVariantMap>
#include <QVector>

class DataStore;
class QMimeData;

class TreeModel : public QAbstractItemModel {
    Q_OBJECT

public:
    enum ItemType {
        FolderType,
        EntryType
    };
    Q_ENUM(ItemType)

    explicit TreeModel(DataStore *store, QObject *parent = nullptr);
    ~TreeModel() override;

    void rebuild();
    void updateFromData();

    // QAbstractItemModel
    QModelIndex index(int row, int column, const QModelIndex &parent = QModelIndex()) const override;
    QModelIndex parent(const QModelIndex &child) const override;
    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    int columnCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    bool setData(const QModelIndex &index, const QVariant &value, int role = Qt::EditRole) override;
    Qt::ItemFlags flags(const QModelIndex &index) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    // Drag / drop
    QStringList mimeTypes() const override;
    QMimeData *mimeData(const QModelIndexList &indexes) const override;
    Qt::DropActions supportedDragActions() const override;
    Qt::DropActions supportedDropActions() const override;
    bool canDropMimeData(const QMimeData *data, Qt::DropAction action,
                         int row, int column, const QModelIndex &parent) const override;
    bool dropMimeData(const QMimeData *data, Qt::DropAction action,
                      int row, int column, const QModelIndex &parent) override;

    // Helpers
    QUuid idForIndex(const QModelIndex &index) const;
    ItemType typeForIndex(const QModelIndex &index) const;
    QModelIndex indexForId(const QUuid &id, ItemType type) const;

    enum CustomRole {
        FilterRole = Qt::UserRole + 1
    };

signals:
    void moveEntryRequested(const QUuid &entryId, const QUuid &toFolderId);
    void moveEntriesRequested(const QVector<QUuid> &entryIds, const QUuid &toFolderId);
    void moveFolderRequested(const QUuid &folderId, const QUuid &toParentId);
    void renameFolderRequested(const QUuid &folderId, const QString &newName);

private:
    struct Node;

    DataStore *m_store = nullptr;
    Node *m_root = nullptr;

    static const QString s_mimeType;

    void clearNode(Node *node);
    Node *nodeForIndex(const QModelIndex &index) const;
    QModelIndex indexForNode(Node *node) const;
    void buildNode(Node *parentNode, const class Folder &folder);
    void updateFolderNode(Node *parentNode, const class Folder &folder);
    Node *findNode(Node *node, const QUuid &id, ItemType type) const;
    int folderEntryCount(Node *folderNode) const;
};
