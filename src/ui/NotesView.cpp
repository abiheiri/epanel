#include "NotesView.h"
#include "datastore/DataStore.h"
#include <QTextEdit>
#include <QVBoxLayout>

NotesView::NotesView(DataStore *store, QWidget *parent)
    : QWidget(parent), m_store(store)
{
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(12, 12, 12, 12);

    m_editor = new QTextEdit(this);
    m_editor->setPlainText(store->notes());
    layout->addWidget(m_editor);

    connect(m_editor, &QTextEdit::textChanged, this, &NotesView::onTextChanged);
    connect(store, &DataStore::notesChanged, this, [this](const QString &notes) {
        if (m_updating) return;
        if (m_editor->toPlainText() != notes) {
            m_updating = true;
            m_editor->setPlainText(notes);
            m_updating = false;
        }
    });
}

void NotesView::onTextChanged()
{
    m_updating = true;
    m_store->setNotes(m_editor->toPlainText());
    m_updating = false;
}
