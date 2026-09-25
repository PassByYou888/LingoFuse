# =============================================================================
#  LingoFuse C/C++ Wrapper - Top-Level Build Script
# -----------------------------------------------------------------------------
#  Targets:
#    lingofuse_headers   : INTERFACE library for the public headers
#    lingofuse_c_wrapper : STATIC library wrapping LingoFuse.c
#    CrossDemo/*         : demo executables (service / node / call)
#    test/test_lingofuse : C++ test suite
#
#  Layout:
#    cpp/
#      CMakeLists.txt          <-- this file
#      json.hpp                <-- nlohmann/json single header
#      LingoFuse.h             <-- C ABI declarations
#      LingoFuse.c             <-- C ABI forwarding layer
#      LingoFuse.hpp           <-- C++17 RAII wrapper (header-only)
#      lf_io.hpp               <-- unified JSON/string I/O (header-only)
#      CrossDemo/CMakeLists.txt
#      test/CMakeLists.txt
#
#  Output: executables land in cpp/../Binary/ next to the DLLs.
#
#  Usage:
#    mkdir build && cd build
#    cmake .. -DCMAKE_BUILD_TYPE=Release
#    cmake --build . --config Release
#    ctest --output-on-failure
#
#  Requirements: CMake 3.14+, C99, C++17.
# =============================================================================

cmake_minimum_required(VERSION 3.14)

project(LingoFuseCppWrapper
        VERSION 1.0.0
        DESCRIPTION "C/C++ explicit-linking wrapper for the LingoFuse RPC framework"
        LANGUAGES C CXX)

# -----------------------------------------------------------------------------
#  Language standards
# -----------------------------------------------------------------------------
set(CMAKE_C_STANDARD          99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS        OFF)

set(CMAKE_CXX_STANDARD          17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS        OFF)

# -----------------------------------------------------------------------------
#  lingofuse_headers - INTERFACE library for the public headers
# -----------------------------------------------------------------------------
#  Single authoritative home for all public headers:
#
#    json.hpp         nlohmann/json single-header edition
#    LingoFuse.h      C ABI declarations
#    LingoFuse.hpp    C++17 RAII wrapper (header-only)
#    lf_io.hpp        Unified JSON/string I/O (header-only)
#
#  Every target links this INTERFACE library, so all four headers are
#  reachable via `#include` without per-target include paths, and all
#  four show up in IDE project views for every consuming target.
# -----------------------------------------------------------------------------

add_library(lingofuse_headers INTERFACE)

target_include_directories(lingofuse_headers INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_sources(lingofuse_headers INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/json.hpp
    ${CMAKE_CURRENT_SOURCE_DIR}/LingoFuse.h
    ${CMAKE_CURRENT_SOURCE_DIR}/LingoFuse.hpp
    ${CMAKE_CURRENT_SOURCE_DIR}/lf_io.hpp
	${CMAKE_CURRENT_SOURCE_DIR}/lf_http_bridge_client.hpp
)

# -----------------------------------------------------------------------------
#  lingofuse_c_wrapper - STATIC library wrapping LingoFuse.c
# -----------------------------------------------------------------------------

add_library(lingofuse_c_wrapper STATIC
    LingoFuse.c
)

target_link_libraries(lingofuse_c_wrapper
    PUBLIC
        lingofuse_headers
)

set_target_properties(lingofuse_c_wrapper PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# -----------------------------------------------------------------------------
#  Platform-specific link dependencies
# -----------------------------------------------------------------------------
if(WIN32)
    target_link_libraries(lingofuse_c_wrapper PUBLIC kernel32)
else()
    target_link_libraries(lingofuse_c_wrapper PUBLIC ${CMAKE_DL_LIBS})
endif()

# -----------------------------------------------------------------------------
#  Testing
# -----------------------------------------------------------------------------
enable_testing()

# -----------------------------------------------------------------------------
#  Subdirectories
# -----------------------------------------------------------------------------
add_subdirectory(CrossDemo)
add_subdirectory(test)