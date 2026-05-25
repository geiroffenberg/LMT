cmake_minimum_required(VERSION 3.22.1)
project(lmt_audio VERSION 1.0.0)

# Oboe is provided via Prefab (AAR dependency in build.gradle.kts)
find_package(oboe REQUIRED CONFIG)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Audio engine library
add_library(lmt_audio SHARED
    audio/audio_engine.cpp
    audio/jni_bridge.cpp
    freeverb.cpp
)

target_include_directories(lmt_audio PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(lmt_audio
    android
    log
    oboe::oboe
)

target_compile_features(lmt_audio PRIVATE cxx_std_17)
