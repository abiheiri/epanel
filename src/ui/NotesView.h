#pragma once

#include <QWidget>

class DataStore;
class QTextEdit;

class NotesView : public QWidget {
    Q_OBJECT

public:
    explicit NotesView(DataStore *store, QWidget *parent = nullptr);

private:
    void onTextChanged();

    DataStore *m_store = nullptr;
    QTextEdit *m_editor = nullptr;
    bool m_updating = false;
};
