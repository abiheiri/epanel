cmake_minimum_required(VERSION 3.16)
project(epanel VERSION 6.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network)

set(SOURCES
    src/main.cpp
    src/models/Entry.cpp
    src/models/Folder.cpp
    src/models/EPanelData.cpp
    src/datastore/DataStore.cpp
    src/ui/MainWindow.cpp
    src/ui/LinksView.cpp
    src/ui/TreeModel.cpp
    src/ui/NotesView.cpp
    src/ui/SettingsView.cpp
    src/ui/dialogs/AddEntryDialog.cpp
    src/ui/dialogs/NewFolderDialog.cpp
    src/ui/dialogs/MoveItemDialog.cpp
    resources/epanel.qrc
)

set(HEADERS
    src/models/Entry.h
    src/models/Folder.h
    src/models/EPanelData.h
    src/datastore/DataStore.h
    src/ui/MainWindow.h
    src/ui/LinksView.h
    src/ui/TreeModel.h
    src/ui/NotesView.h
    src/ui/SettingsView.h
    src/ui/dialogs/AddEntryDialog.h
    src/ui/dialogs/NewFolderDialog.h
    src/ui/dialogs/MoveItemDialog.h
)

if(APPLE)
    list(APPEND SOURCES src/platform/SafariSyncManager.mm)
    list(APPEND HEADERS src/platform/SafariSyncManager.h)
    list(APPEND SOURCES resources/icons/icon.icns)
    set(MACOSX_BUNDLE_ICON_FILE icon.icns)
    set_source_files_properties(resources/icons/icon.icns PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
endif()

if(WIN32)
    configure_file(resources/windows_icon.rc.in ${CMAKE_CURRENT_BINARY_DIR}/windows_icon.rc @ONLY)
    list(APPEND SOURCES ${CMAKE_CURRENT_BINARY_DIR}/windows_icon.rc)
endif()

add_executable(epanel ${SOURCES} ${HEADERS})

target_include_directories(epanel PRIVATE src)

target_compile_definitions(epanel PRIVATE EPANEL_VERSION="${PROJECT_VERSION}")

target_link_libraries(epanel PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
)

if(APPLE)
    target_link_libraries(epanel PRIVATE "-framework Foundation")
    set_target_properties(epanel PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_SOURCE_DIR}/resources/Info.plist.in
        MACOSX_BUNDLE_ICON_FILE ${MACOSX_BUNDLE_ICON_FILE}
    )
endif()

set_target_properties(epanel PROPERTIES
    WIN32_EXECUTABLE TRUE
)
