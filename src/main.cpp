#include "ui/MainWindow.h"
#include "datastore/DataStore.h"

#include <QApplication>
#include <QCoreApplication>
#include <QCommandLineParser>
#include <QDir>
#include <QFile>
#include <QIcon>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setWindowIcon(QIcon(QStringLiteral(":/icons/icon.png")));

    QCoreApplication::setOrganizationName(QStringLiteral("abiheiri"));
    QCoreApplication::setApplicationName(QStringLiteral("ePanel"));
    QCoreApplication::setApplicationVersion(QStringLiteral(EPANEL_VERSION));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("ePanel - cross-platform link and note manager"));
    parser.addHelpOption();
    parser.addVersionOption();

    QCommandLineOption dataDirOption(QStringList{QStringLiteral("d"), QStringLiteral("data-dir")},
                                     QStringLiteral("Path to the folder containing epanel.json and notes.txt"),
                                     QStringLiteral("directory"));
    parser.addOption(dataDirOption);
    parser.process(app);

    DataStore store;

    if (parser.isSet(dataDirOption)) {
        QString dir = parser.value(dataDirOption);
        QString jsonPath = QDir(dir).filePath(QStringLiteral("epanel.json"));
        if (!QFile::exists(jsonPath)) {
            EPanelData::empty().saveToFile(jsonPath);
            QFile notesFile(QDir(dir).filePath(QStringLiteral("notes.txt")));
            if (!notesFile.exists()) { (void)notesFile.open(QIODevice::WriteOnly); }
        }
        store.setDataFolderPath(dir);
    } else if (store.needsFileSelection()) {
        store.promptForDataFile();
    }

    MainWindow window(&store);
    window.show();

    return app.exec();
}
