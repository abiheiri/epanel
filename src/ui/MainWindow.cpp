#include "MainWindow.h"
#include "LinksView.h"
#include "NotesView.h"
#include "SettingsView.h"
#include "datastore/DataStore.h"

#include <QTabWidget>
#include <QMenuBar>
#include <QMenu>
#include <QAction>
#include <QMessageBox>
#include <QFileDialog>
#include <QDesktopServices>
#include <QUrl>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QApplication>
#include <QKeySequence>
#include <algorithm>

MainWindow::MainWindow(DataStore *store, QWidget *parent)
    : QMainWindow(parent), m_store(store)
{
    setWindowTitle(tr("ePanel"));
    setMinimumSize(600, 450);

    m_tabs = new QTabWidget(this);
    m_tabs->addTab(new LinksView(m_store, this), tr("Links"));
    m_tabs->addTab(new NotesView(m_store, this), tr("Notes"));
    m_tabs->addTab(new SettingsView(m_store, this), tr("Settings"));
    setCentralWidget(m_tabs);

    m_net = new QNetworkAccessManager(this);

    setupMenu();

    connect(m_store, &DataStore::alertRequested,
            this, [](const QString &message) {
                QMessageBox::information(nullptr, QCoreApplication::applicationName(), message);
            });
}

void MainWindow::setupMenu()
{
    QMenu *fileMenu = menuBar()->addMenu(tr("&File"));

    QAction *importAct = fileMenu->addAction(tr("&Import…"), this, &MainWindow::onImportFile);
    importAct->setShortcut(QKeySequence::Open);

#ifdef Q_OS_MACOS
    QAction *importSafariAct = fileMenu->addAction(tr("Import from Safari…"), this, &MainWindow::onImportSafari);
    Q_UNUSED(importSafariAct)
#endif

    fileMenu->addSeparator();

    QAction *exportJsonAct = fileMenu->addAction(tr("Export JSON…"), this, &MainWindow::onExportJson);
    QAction *exportCsvAct = fileMenu->addAction(tr("Export CSV…"), this, &MainWindow::onExportCsv);
    Q_UNUSED(exportJsonAct)
    Q_UNUSED(exportCsvAct)

    QAction *changeFolderAct = fileMenu->addAction(tr("Change Data Folder…"), this, &MainWindow::onChangeDataFolder);
    Q_UNUSED(changeFolderAct)

    fileMenu->addSeparator();

    QAction *quitAct = fileMenu->addAction(tr("&Quit"), qApp, &QApplication::quit);
    quitAct->setShortcut(QKeySequence::Quit);

    QMenu *helpMenu = menuBar()->addMenu(tr("&Help"));
    helpMenu->addAction(tr("ePanel Help"), this, &MainWindow::onHelp);
    helpMenu->addAction(tr("Check for Updates"), this, &MainWindow::onCheckUpdates);
    helpMenu->addSeparator();
    helpMenu->addAction(tr("About ePanel"), this, &MainWindow::onAbout);
}

void MainWindow::onImportFile()
{
    QString filter = tr("JSON/CSV Files (*.json *.csv)");
#ifdef Q_OS_MACOS
    filter += tr(";;Property Lists (*.plist)");
#endif
    QString path = QFileDialog::getOpenFileName(this, tr("Import File"),
                                                QDir::homePath(),
                                                filter);
    if (!path.isEmpty()) {
        m_store->importFile(path);
    }
}

void MainWindow::onChangeDataFolder()
{
    m_store->changeDataFile();
}

void MainWindow::onImportSafari()
{
#ifdef Q_OS_MACOS
    QString path = QFileDialog::getOpenFileName(this, tr("Select Safari Bookmarks.plist"),
                                                QDir::home().filePath("Library/Safari"),
                                                tr("Property Lists (*.plist)"));
    if (!path.isEmpty()) {
        m_store->importFile(path);
    }
#else
    QMessageBox::information(this, tr("Import Safari"),
                             tr("Safari bookmark import is only available on macOS."));
#endif
}

void MainWindow::onExportJson()
{
    QString path = QFileDialog::getSaveFileName(this, tr("Export JSON"),
                                                QDir::home().filePath("epanel.json"),
                                                tr("JSON Files (*.json)"));
    if (!path.isEmpty()) {
        m_store->exportJson(path);
    }
}

void MainWindow::onExportCsv()
{
    QString path = QFileDialog::getSaveFileName(this, tr("Export CSV"),
                                                QDir::home().filePath("epanel.csv"),
                                                tr("CSV Files (*.csv)"));
    if (!path.isEmpty()) {
        m_store->exportCsv(path);
    }
}

void MainWindow::onHelp()
{
    QDesktopServices::openUrl(QUrl(QStringLiteral("https://github.com/abiheiri/epanel/blob/main/README.md")));
}

void MainWindow::onCheckUpdates()
{
    QNetworkRequest request(QUrl(QStringLiteral("https://api.github.com/repos/abiheiri/epanel/releases/latest")));
    request.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("ePanel/%1").arg(QCoreApplication::applicationVersion()));
    QNetworkReply *reply = m_net->get(request);

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            QMessageBox::warning(this, tr("Check for Updates"),
                                 tr("Unable to check for updates:\n%1").arg(reply->errorString()));
            return;
        }

        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        QJsonObject obj = doc.object();
        QString tag = obj.value(QStringLiteral("tag_name")).toString();
        QString htmlUrl = obj.value(QStringLiteral("html_url")).toString();

        if (tag.isEmpty()) {
            QMessageBox::information(this, tr("Check for Updates"),
                                     tr("Could not determine the latest release."));
            return;
        }

        QString current = QCoreApplication::applicationVersion();
        QString latest = tag;
        if (latest.startsWith('v') || latest.startsWith('V')) {
            latest.remove(0, 1);
        }

        // Simple numeric version comparison
        QStringList curParts = current.split('.');
        QStringList latParts = latest.split('.');
        bool newer = false;
        for (int i = 0; i < std::max(curParts.size(), latParts.size()); ++i) {
            int cur = (i < curParts.size()) ? curParts[i].toInt() : 0;
            int lat = (i < latParts.size()) ? latParts[i].toInt() : 0;
            if (lat > cur) { newer = true; break; }
            if (lat < cur) { break; }
        }

        if (newer) {
            int ret = QMessageBox::information(this, tr("Update Available"),
                                               tr("ePanel %1 is available. You are running %2.").arg(latest, current),
                                               QMessageBox::Open | QMessageBox::Close, QMessageBox::Open);
            if (ret == QMessageBox::Open && !htmlUrl.isEmpty()) {
                QDesktopServices::openUrl(QUrl(htmlUrl));
            }
        } else {
            QMessageBox::information(this, tr("You're Up to Date"),
                                     tr("ePanel %1 is the latest version.").arg(current));
        }
    });
}

void MainWindow::onAbout()
{
    QMessageBox::about(this, tr("About ePanel"),
                       tr("<h2>ePanel %1</h2>"
                          "<p>A cross-platform link and note manager.</p>"
                          "<p><a href=\"https://github.com/abiheiri/epanel\">github.com/abiheiri/epanel</a></p>")
                           .arg(QCoreApplication::applicationVersion()));
}
