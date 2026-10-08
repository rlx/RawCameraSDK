# Builds the portable core (LibRaw and the C interface in Sources/RawShim) outside SwiftPM:
# as a static library for C and C++ hosts, and as WebAssembly under Emscripten.
#
#     cmake -S . -B .build/cmake && cmake --build .build/cmake && ctest --test-dir .build/cmake
#     emcmake cmake -S . -B .build/wasm && cmake --build .build/wasm
#
# The Swift package and the Rust crate compile the same sources through their own build
# systems; the list of sources and definitions here has to stay in step with Package.swift
# and Bindings/rust/build.rs. Docs/PORTING.md explains the layout.
cmake_minimum_required(VERSION 3.20)
project(rawinput_core LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

file(GLOB_RECURSE LIBRAW_SOURCES CONFIGURE_DEPENDS Vendor/LibRaw/src/*.cpp)
# Stand-ins LibRaw compiles only when the real stage is left out of a build.
list(FILTER LIBRAW_SOURCES EXCLUDE REGEX "_ph\\.cpp$")

add_library(rawinput_core STATIC ${LIBRAW_SOURCES} Sources/RawShim/RawShim.cpp)
target_include_directories(rawinput_core PUBLIC Sources/RawShim/include PRIVATE Vendor/LibRaw)
target_compile_definitions(rawinput_core PRIVATE USE_ZLIB USE_X3FTOOLS)
target_compile_options(rawinput_core PRIVATE -w)  # LibRaw's own warnings are not ours to fix

if(EMSCRIPTEN)
    # LibRaw reports errors by throwing and catching C++ exceptions internally.
    target_compile_options(rawinput_core PUBLIC -fexceptions -sUSE_ZLIB=1)

    add_executable(rawinput_core_wasm Bindings/web/glue.c)
    target_link_libraries(rawinput_core_wasm PRIVATE rawinput_core)
    set_target_properties(rawinput_core_wasm PROPERTIES
        OUTPUT_NAME rawinput_core SUFFIX .mjs
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/Bindings/web/dist)
    target_link_options(rawinput_core_wasm PRIVATE
        -fexceptions -sUSE_ZLIB=1
        -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,node
        # RAW frames are large: start small, grow as needed, up to wasm32's 4 GB ceiling.
        -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=4GB
        -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPU16,UTF8ToString
        "-sEXPORTED_FUNCTIONS=_malloc,_free,_rik_abi_version,_rik_libraw_version,_rik_strerror,_rik_open_buffer,_rik_close,_rik_set_memory_limit,_rik_unpack,_rik_get_develop_params,_rikw_info_json,_rikw_thumbnail,_rikw_mosaic,_rikw_develop,_rikw_result")
else()
    find_package(ZLIB REQUIRED)
    target_link_libraries(rawinput_core PUBLIC ZLIB::ZLIB)

    add_executable(core_smoke Bindings/c/smoke.c)
    target_link_libraries(core_smoke PRIVATE rawinput_core)

    # Decodes one of the demo's sample files, if they have been fetched.
    enable_testing()
    set(SAMPLE ${CMAKE_SOURCE_DIR}/Examples/RawInputDemo/Samples/files/samsung-nx300.srw)
    if(EXISTS ${SAMPLE})
        add_test(NAME core_smoke COMMAND core_smoke ${SAMPLE})
    endif()
endif()
