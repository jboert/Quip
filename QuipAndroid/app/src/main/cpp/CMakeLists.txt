cmake_minimum_required(VERSION 3.22.1)
project(whisper_jni)

include(FetchContent)

# Download whisper.cpp source at configure time
FetchContent_Declare(
    whisper
    URL https://github.com/ggerganov/whisper.cpp/archive/refs/tags/v1.7.2.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP ON
)

set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(whisper)

add_library(whisper_jni SHARED whisper_jni.cpp)

target_link_libraries(whisper_jni
    whisper
    log
)

target_include_directories(whisper_jni PRIVATE
    ${whisper_SOURCE_DIR}/include
    ${whisper_SOURCE_DIR}
)
