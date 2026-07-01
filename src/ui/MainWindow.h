#pragma once

#include <QMainWindow>

class DataStore;
class QNetworkAccessManager;
class QStackedWidget;
class QButtonGroup;

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(DataStore *store, QWidget *parent = nullptr);

private slots:
    void onNavClicked(int index);
    void onImportFile();
    void onImportSafari();
    void onChangeDataFolder();
    void onExportJson();
    void onExportCsv();
    void onHelp();
    void onCheckUpdates();
    void onAbout();

private:
    void setupMenu();
    void setupCentralWidget();
    void setActiveNav(int index);

    DataStore *m_store = nullptr;
    QStackedWidget *m_stack = nullptr;
    QButtonGroup *m_navGroup = nullptr;
    QNetworkAccessManager *m_net = nullptr;
};
