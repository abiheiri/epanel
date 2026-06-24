#pragma once

#include <QMainWindow>

class DataStore;
class QNetworkAccessManager;
class QTabWidget;

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(DataStore *store, QWidget *parent = nullptr);

private slots:
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

    DataStore *m_store = nullptr;
    QTabWidget *m_tabs = nullptr;
    QNetworkAccessManager *m_net = nullptr;
};
