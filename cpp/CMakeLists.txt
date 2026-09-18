# =============================================================================
#  LingoFuse C/C++ Wrapper - Top-Level Build Script
# -----------------------------------------------------------------------------
#  Builds:
#    - lingofuse_c_wrapper   : static library wrapping LingoFuse.c
#    - CrossDemo/*           : demonstration executables (service / node / call)
#    - test/test_lingofuse   : comprehensive C++ test suite
#
#  Layout assumed by this script:
#      cpp/
#          CMakeLists.txt      <-- this file
#          LingoFuse.h
#          LingoFuse.c
#          LingoFuse.hpp
#          CrossDemo/
#              CMakeLists.txt
#              CrossService.cpp
#              CrossNode.cpp
#              CrossCall.cpp
#          test/
#              CMakeLists.txt
#              test_lingofuse.cpp
#
#  Output layout:
#      cpp/../Binary/          <-- all built executables are placed here.
#                                 (i.e. LingoFuse/Binary/, next to the DLLs)
#
#  Usage:
#      mkdir build && cd build
#      cmake .. -DCMAKE_BUILD_TYPE=Release
#      cmake --build . --config Release
#
#  Run the test suite (from the build directory):
#      ctest --output-on-failure
#  or execute the binary directly:
#      ../Binary/test_lingofuse
#
#  Requirements:
#      - CMake 3.14 or later
#      - C99-compatible C compiler
#      - C++17-compatible C++ compiler
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
#  Core static library: lingofuse_c_wrapper
# -----------------------------------------------------------------------------
add_library(lingofuse_c_wrapper STATIC
    LingoFuse.h
    LingoFuse.c
    LingoFuse.hpp
)

# The include directory is PUBLIC so that every downstream target
# (CrossDemo executables, the test suite, user projects) can find
# LingoFuse.h / LingoFuse.hpp without repeating target_include_directories.
target_include_directories(lingofuse_c_wrapper
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
)

# Position-independent code so the wrapper can also be linked into a shared
# library if a downstream project needs it.
set_target_properties(lingofuse_c_wrapper PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# -----------------------------------------------------------------------------
#  Platform-specific link dependencies
# -----------------------------------------------------------------------------
if(WIN32)
    # LoadLibraryA / GetProcAddress / FreeLibrary live in kernel32.
    target_link_libraries(lingofuse_c_wrapper PUBLIC kernel32)
else()
    # On Linux / BSD, dlopen / dlsym / dlclose live in libdl.
    # On macOS, CMAKE_DL_LIBS expands to an empty string, since the same
    # symbols are part of libSystem.
    target_link_libraries(lingofuse_c_wrapper PUBLIC ${CMAKE_DL_LIBS})
endif()

# -----------------------------------------------------------------------------
#  Testing (CTest)
# -----------------------------------------------------------------------------
# Enables CTest at the top level. Individual add_test() calls are made by the
# subdirectories that own the corresponding executables (currently: test/).
#
# After building, run the suite from the build directory:
#     ctest --output-on-failure
enable_testing()

# -----------------------------------------------------------------------------
#  Subdirectories
# -----------------------------------------------------------------------------
add_subdirectory(CrossDemo)
add_subdirectory(test)