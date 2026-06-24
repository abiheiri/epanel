#pragma once

#include <QWidget>

class DataStore;
class QTextEdit;
class QTimer;

class NotesView : public QWidget {
    Q_OBJECT

public:
    explicit NotesView(DataStore *store, QWidget *parent = nullptr);

private slots:
    void onTextChanged();
    void commitNotes();

private:
    DataStore *m_store = nullptr;
    QTextEdit *m_editor = nullptr;
    QTimer *m_commitTimer = nullptr;
    bool m_updating = false;
};
