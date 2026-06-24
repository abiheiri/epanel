#include "NotesView.h"
#include "datastore/DataStore.h"
#include <QTextEdit>
#include <QVBoxLayout>
#include <QTimer>

NotesView::NotesView(DataStore *store, QWidget *parent)
    : QWidget(parent), m_store(store)
{
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(12, 12, 12, 12);

    m_editor = new QTextEdit(this);
    m_editor->setPlainText(store->notes());
    layout->addWidget(m_editor);

    m_commitTimer = new QTimer(this);
    m_commitTimer->setSingleShot(true);
    m_commitTimer->setInterval(300);
    connect(m_commitTimer, &QTimer::timeout, this, &NotesView::commitNotes);

    connect(m_editor, &QTextEdit::textChanged, this, &NotesView::onTextChanged);
    connect(store, &DataStore::notesChanged, this, [this](const QString &notes) {
        if (m_updating) return;
        m_commitTimer->stop();
        if (m_editor->toPlainText() != notes) {
            m_updating = true;
            m_editor->setPlainText(notes);
            m_updating = false;
        }
    });
}

void NotesView::onTextChanged()
{
    m_commitTimer->start();
}

void NotesView::commitNotes()
{
    m_updating = true;
    m_store->setNotes(m_editor->toPlainText());
    m_updating = false;
}
