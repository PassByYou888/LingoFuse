# =============================================================================
#  test - Build Script for the LingoFuse C++ Test Suite
# -----------------------------------------------------------------------------
#  Builds:
#    test_lingofuse : comprehensive test suite for the C++ RAII wrapper.
#
#  Output location:
#      ../../Binary/          (i.e. LingoFuse/Binary/, next to the DLLs)
#
#  Rationale for placing the test executable next to the DLLs:
#      The C wrapper's LF_LoadLibrary() first tries to load the dynamic
#      library from the directory containing the current executable. If
#      test_lingofuse were placed in a separate subdirectory, the loader
#      would fall back to the system PATH, requiring a manual PATH setup.
#      Keeping the executable in the same directory as the DLLs makes the
#      test suite runnable out of the box.
#
#  After building, the suite can be run either way:
#      ctest --output-on-failure              (from the build directory)
#      ../Binary/test_lingofuse               (direct execution)
# =============================================================================

# -----------------------------------------------------------------------------
#  Executable target
# -----------------------------------------------------------------------------
add_executable(test_lingofuse
    test_lingofuse.cpp
)

# std::thread is used by the concurrency test and the network-teardown helper.
# The top-level script does not call find_package(Threads) itself, so this
# subdirectory is responsible for requesting it. CMake caches the result,
# so repeated find_package calls across subdirectories are cheap.
find_package(Threads REQUIRED)

target_link_libraries(test_lingofuse
    PRIVATE
        lingofuse_c_wrapper
        Threads::Threads
)

# -----------------------------------------------------------------------------
#  Output directory
# -----------------------------------------------------------------------------
# The top-level CMakeLists.txt does NOT set a global CMAKE_RUNTIME_OUTPUT_DIRECTORY;
# each subdirectory is responsible for placing its own executables. We mirror
# the CrossDemo convention and put the test binary in LingoFuse/Binary/ next
# to the DLLs.
#
# Both the unsuffixed variable and the per-configuration variants are set,
# because CMake appends a per-configuration subdirectory (Debug/, Release/,
# ...) whenever only the unsuffixed variable is present.
set(LINGOFUSE_TEST_BINARY_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Binary")

message(STATUS "test: build output directory = ${LINGOFUSE_TEST_BINARY_DIR}")

set_target_properties(test_lingofuse PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY                "${LINGOFUSE_TEST_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG          "${LINGOFUSE_TEST_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE        "${LINGOFUSE_TEST_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     "${LINGOFUSE_TEST_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${LINGOFUSE_TEST_BINARY_DIR}"
)

# -----------------------------------------------------------------------------
#  Compiler warnings
# -----------------------------------------------------------------------------
# Matches the warning level used by the CrossDemo executables so that the
# test suite is held to the same standard.
if(MSVC)
    target_compile_options(test_lingofuse PRIVATE /W4 /permissive-)
else()
    target_compile_options(test_lingofuse PRIVATE -Wall -Wextra)
endif()

# -----------------------------------------------------------------------------
#  CTest registration
# -----------------------------------------------------------------------------
# Register the suite with CTest so that `ctest` (from the build directory)
# runs it together with any other tests in the project.
#
# The test runs with its working directory set to the output directory,
# so that the dynamic library sits next to the current working directory
# as a fallback, even if the executable-directory lookup inside
# LF_LoadLibrary() somehow fails.
add_test(
    NAME test_lingofuse
    COMMAND test_lingofuse
    WORKING_DIRECTORY "${LINGOFUSE_TEST_BINARY_DIR}"
)