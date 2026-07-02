#include "SettingsView.h"
#include "datastore/DataStore.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QCheckBox>
#include <QFileDialog>
#include <QMessageBox>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QGroupBox>

SettingsView::SettingsView(DataStore *store, QWidget *parent)
    : QWidget(parent), m_store(store)
{
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setAlignment(Qt::AlignTop);
    layout->setSpacing(16);

    // Data File group
    QGroupBox *dataGroup = new QGroupBox(tr("Data File"), this);
    QVBoxLayout *dataLayout = new QVBoxLayout(dataGroup);
    m_dataFileLabel = new QLabel(tr("No file selected"), this);
    m_dataFileLabel->setWordWrap(true);
    m_dataFileLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
    dataLayout->addWidget(m_dataFileLabel);

    QHBoxLayout *dataBtnLayout = new QHBoxLayout();
    QPushButton *changeBtn = new QPushButton(tr("Change Data File…"), this);
    connect(changeBtn, &QPushButton::clicked, this, &SettingsView::onChangeDataFile);
    dataBtnLayout->addWidget(changeBtn);

    QPushButton *revealBtn = new QPushButton(tr("Reveal in Finder"), this);
#ifdef Q_OS_WIN
    revealBtn->setText(tr("Show in Explorer"));
#endif
    connect(revealBtn, &QPushButton::clicked, this, &SettingsView::onRevealFile);
    dataBtnLayout->addWidget(revealBtn);
    dataBtnLayout->addStretch();
    dataLayout->addLayout(dataBtnLayout);

    m_lastSyncLabel = new QLabel(this);
    dataLayout->addWidget(m_lastSyncLabel);

    QLabel *dataInfo = new QLabel(tr("ePanel reads and writes directly to this JSON file. Multiple instances can safely share the same file. Notes are stored in a companion notes.txt file."), this);
    dataInfo->setWordWrap(true);
    dataInfo->setStyleSheet("color: gray;");
    dataLayout->addWidget(dataInfo);
    layout->addWidget(dataGroup);

    // Notes File group
    QGroupBox *notesGroup = new QGroupBox(tr("Notes File"), this);
    QVBoxLayout *notesLayout = new QVBoxLayout(notesGroup);
    m_notesFileLabel = new QLabel(this);
    m_notesFileLabel->setWordWrap(true);
    m_notesFileLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
    notesLayout->addWidget(m_notesFileLabel);

    QPushButton *revealNotesBtn = new QPushButton(tr("Reveal in Finder"), this);
#ifdef Q_OS_WIN
    revealNotesBtn->setText(tr("Show in Explorer"));
#endif
    connect(revealNotesBtn, &QPushButton::clicked, this, &SettingsView::onRevealNotes);
    notesLayout->addWidget(revealNotesBtn);

    QLabel *notesInfo = new QLabel(tr("Notes are stored separately from the JSON data."), this);
    notesInfo->setWordWrap(true);
    notesInfo->setStyleSheet("color: gray;");
    notesLayout->addWidget(notesInfo);
    layout->addWidget(notesGroup);

    // Safari Sync group (macOS only)
#ifdef Q_OS_MACOS
    QGroupBox *syncGroup = new QGroupBox(tr("Safari Sync"), this);
    QVBoxLayout *syncLayout = new QVBoxLayout(syncGroup);
    m_syncCheck = new QCheckBox(tr("Sync with Safari"), this);
    m_syncCheck->setChecked(store->safariSyncEnabled());
    connect(m_syncCheck, &QCheckBox::toggled, this, &SettingsView::onSafariSyncToggled);
    syncLayout->addWidget(m_syncCheck);

    QLabel *syncInfo = new QLabel(tr("When enabled, your existing ePanel content will be moved to a 'my_original_epanel' folder. Safari bookmarks and reading list will be imported and kept in sync."), this);
    syncInfo->setWordWrap(true);
    syncInfo->setStyleSheet("color: gray;");
    syncLayout->addWidget(syncInfo);
    layout->addWidget(syncGroup);
#else
    Q_UNUSED(store)
#endif

    layout->addStretch();
    updateLabels();

    connect(store, &DataStore::dataFileChanged, this, &SettingsView::updateLabels);
    connect(store, &DataStore::lastSyncDateChanged, this, &SettingsView::updateLabels);
    connect(store, &DataStore::safariSyncStateChanged, this, &SettingsView::updateLabels);
}

void SettingsView::updateLabels()
{
    QString jsonPath = m_store->jsonFilePath();
    if (jsonPath.isEmpty()) {
        if (m_dataFileLabel->text() != tr("No file selected"))
            m_dataFileLabel->setText(tr("No file selected"));
    } else {
        if (m_dataFileLabel->text() != jsonPath)
            m_dataFileLabel->setText(jsonPath);
    }

    QString notesPath = m_store->notesFilePath();
    if (notesPath.isEmpty()) {
        if (m_notesFileLabel->text() != tr("No file selected"))
            m_notesFileLabel->setText(tr("No file selected"));
    } else {
        if (m_notesFileLabel->text() != notesPath)
            m_notesFileLabel->setText(notesPath);
    }

    if (m_store->lastSyncDate().isValid()) {
        QString text = tr("Last synced: %1").arg(m_store->lastSyncDate().toLocalTime().toString());
        if (m_lastSyncLabel->text() != text)
            m_lastSyncLabel->setText(text);
    } else {
        if (!m_lastSyncLabel->text().isEmpty())
            m_lastSyncLabel->clear();
    }

#ifdef Q_OS_MACOS
    const bool blocked = m_syncCheck->blockSignals(true);
    m_syncCheck->setChecked(m_store->safariSyncEnabled());
    m_syncCheck->blockSignals(blocked);
#endif
}

void SettingsView::onChangeDataFile()
{
    m_store->changeDataFile();
}

void SettingsView::onRevealFile()
{
    QString path = m_store->jsonFilePath();
    if (!path.isEmpty()) {
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(path).dir().absolutePath()));
    }
}

void SettingsView::onRevealNotes()
{
    QString path = m_store->notesFilePath();
    if (!path.isEmpty()) {
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(path).dir().absolutePath()));
    }
}

void SettingsView::onSafariSyncToggled(bool enabled)
{
#ifdef Q_OS_MACOS
    if (enabled) {
        QString path = QFileDialog::getOpenFileName(this, tr("Select Safari Bookmarks.plist"),
                                                    QDir::home().filePath("Library/Safari"),
                                                    tr("Property Lists (*.plist)"));
        if (path.isEmpty()) {
            m_syncCheck->blockSignals(true);
            m_syncCheck->setChecked(false);
            m_syncCheck->blockSignals(false);
            return;
        }
        int ret = QMessageBox::question(this, tr("Enable Safari Sync?"),
                                        tr("Your existing ePanel content will be moved to a 'my_original_epanel' folder. Safari bookmarks and reading list will be imported and kept in sync."));
        if (ret == QMessageBox::Yes) {
            m_store->enableSafariSync(path);
        } else {
            m_syncCheck->blockSignals(true);
            m_syncCheck->setChecked(false);
            m_syncCheck->blockSignals(false);
        }
    } else {
        m_store->disableSafariSync();
    }
#else
    Q_UNUSED(enabled)
#endif
}
