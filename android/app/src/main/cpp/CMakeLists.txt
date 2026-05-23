cmake_minimum_required(VERSION 3.22)
project(lmt)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Source files
set(SOURCES
    main.cpp
    renderer/renderer.cpp
    ui/window_manager.cpp
)

# Headers
set(HEADERS
    renderer/renderer.h
    ui/window_manager.h
    data/song.h
    data/chain.h
    data/phrase.h
    data/instrument.h
    data/sample.h
)

# Create the executable (for desktop testing) or shared library (for Android JNI)
if(ANDROID)
    add_library(lmt_native SHARED ${SOURCES})
    target_link_libraries(lmt_native SDL2 SDL2_ttf android log)
else()
    add_executable(lmt ${SOURCES})
    target_link_libraries(lmt SDL2 SDL2_ttf)
endif()

# Include directories
target_include_directories(lmt_native PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_include_directories(lmt PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# Find SDL2 and SDL2_ttf
find_package(SDL2 REQUIRED)
find_package(SDL2_ttf REQUIRED)
include_directories(${SDL2_INCLUDE_DIRS} ${SDL2_TTF_INCLUDE_DIRS})
