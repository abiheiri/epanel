#include "MainWindow.h"
#include "LinksView.h"
#include "NotesView.h"
#include "SettingsView.h"
#include "datastore/DataStore.h"

#include <QStackedWidget>
#include <QPushButton>
#include <QButtonGroup>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QWidget>
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

    setupCentralWidget();

    m_net = new QNetworkAccessManager(this);

    setupMenu();

    connect(m_store, &DataStore::alertRequested,
            this, [](const QString &message) {
                QMessageBox::information(nullptr, QCoreApplication::applicationName(), message);
            });
}

void MainWindow::setupCentralWidget()
{
    QWidget *central = new QWidget(this);
    QVBoxLayout *mainLayout = new QVBoxLayout(central);
    mainLayout->setContentsMargins(0, 4, 0, 0);
    mainLayout->setSpacing(0);

    // Navigation row
    QWidget *navWidget = new QWidget(central);
    QHBoxLayout *navLayout = new QHBoxLayout(navWidget);
    navLayout->setContentsMargins(0, 0, 0, 4);
    navLayout->setSpacing(2);
    navLayout->addStretch();

    m_navGroup = new QButtonGroup(this);
    m_navGroup->setExclusive(true);

    const QStringList labels = { tr("Links"), tr("Notes"), tr("Settings") };
    for (int i = 0; i < labels.size(); ++i) {
        QPushButton *btn = new QPushButton(labels.at(i), navWidget);
        btn->setCheckable(true);
        btn->setFlat(true);
        btn->setCursor(Qt::PointingHandCursor);
        btn->setStyleSheet(QStringLiteral(
            "QPushButton {"
            "  border: none;"
            "  border-bottom: 2px solid transparent;"
            "  background: transparent;"
            "  color: #858585;"
            "  padding: 4px 8px;"
            "  font-size: 13px;"
            "}"
            "QPushButton:hover:!checked {"
            "  color: #cccccc;"
            "}"
            "QPushButton:checked {"
            "  color: #ffffff;"
            "  border-bottom-color: #0a84ff;"
            "}"
        ));
        m_navGroup->addButton(btn, i);
        navLayout->addWidget(btn);
    }
    navLayout->addStretch();

    // Stacked content
    m_stack = new QStackedWidget(central);
    m_stack->addWidget(new LinksView(m_store, m_stack));
    m_stack->addWidget(new NotesView(m_store, m_stack));
    m_stack->addWidget(new SettingsView(m_store, m_stack));

    connect(m_navGroup, QOverload<int>::of(&QButtonGroup::idClicked),
            this, &MainWindow::onNavClicked);

    mainLayout->addWidget(navWidget);
    mainLayout->addWidget(m_stack, 1);

    setCentralWidget(central);

    // Default to Links
    setActiveNav(0);
}

void MainWindow::onNavClicked(int index)
{
    setActiveNav(index);
}

void MainWindow::setActiveNav(int index)
{
    if (index < 0 || index >= m_stack->count()) return;

    QAbstractButton *btn = m_navGroup->button(index);
    if (btn && !btn->isChecked()) {
        btn->setChecked(true);
    }
    m_stack->setCurrentIndex(index);
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
