#pragma once

#include <QWidget>

class DataStore;
class QLabel;

class SettingsView : public QWidget {
    Q_OBJECT

public:
    explicit SettingsView(DataStore *store, QWidget *parent = nullptr);

private:
    void updateLabels();
    void onChangeDataFile();
    void onRevealFile();
    void onRevealNotes();
    void onSafariSyncToggled(bool enabled);

    DataStore *m_store = nullptr;
    QLabel *m_dataFileLabel = nullptr;
    QLabel *m_notesFileLabel = nullptr;
    QLabel *m_lastSyncLabel = nullptr;
#ifdef Q_OS_MACOS
    class QCheckBox *m_syncCheck = nullptr;
#endif
};
