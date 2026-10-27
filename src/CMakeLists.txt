cmake_minimum_required(VERSION 3.21)
project(FreeTubeLight VERSION 0.1.0 LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Quick QuickControls2 Network)
qt_standard_project_setup(REQUIRES 6.5)

set(MPV_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../tools/mpv)

qt_add_executable(FreeTubeLight WIN32
    main.cpp
    helperclient.cpp helperclient.h
    mpvitem.cpp mpvitem.h
    store.cpp store.h
    windowtools.cpp windowtools.h
    keynames.cpp keynames.h
    sleeptimer.cpp sleeptimer.h
    gpus.cpp gpus.h
    paths.h
)
set_target_properties(FreeTubeLight PROPERTIES OUTPUT_NAME "FTL Player")

# Icon and version info. Compiled on its own because windres breaks on include paths containing spaces.
set(ICON_PATH ${CMAKE_CURRENT_SOURCE_DIR}/assets/icon.ico)
configure_file(app.rc.in ${CMAKE_CURRENT_BINARY_DIR}/app.rc @ONLY)
add_library(FreeTubeLightResources OBJECT ${CMAKE_CURRENT_BINARY_DIR}/app.rc)
# (windres doesn't tell the build about the icon it embeds: a new icon.ico alone didn't recompile app.rc)
set_source_files_properties(${CMAKE_CURRENT_BINARY_DIR}/app.rc PROPERTIES OBJECT_DEPENDS ${ICON_PATH})
set_target_properties(FreeTubeLightResources PROPERTIES AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
target_sources(FreeTubeLight PRIVATE $<TARGET_OBJECTS:FreeTubeLightResources>)

set_source_files_properties(AppState.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(FreeTubeLight
    URI FreeTubeLight
    VERSION 1.0
    QML_FILES
        Main.qml AppState.qml PlayerView.qml PlaylistList.qml Comments.qml SmoothScroll.qml TimerButton.qml
        VideoCard.qml VideoGrid.qml PlaylistCard.qml Avatar.qml
        SubscriptionsPage.qml ChannelsPage.qml ChannelPage.qml HistoryPage.qml SettingsPage.qml SearchPage.qml PlaylistsPage.qml SavePopup.qml
    RESOURCES assets/icon.png assets/icon_dark.png assets/icon_light.png assets/thumb_up.svg assets/thumb_up_dark.svg   # thumb_up: Material Symbols (Apache 2.0)
)

target_include_directories(FreeTubeLight PRIVATE ${MPV_DIR}/include)
target_link_libraries(FreeTubeLight PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Network ${MPV_DIR}/libmpv.dll.a)
if(WIN32)
    target_link_libraries(FreeTubeLight PRIVATE dxgi)   # the GPU setting (gpus.cpp)
endif()
