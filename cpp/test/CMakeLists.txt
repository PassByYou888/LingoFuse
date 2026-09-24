# =============================================================================
#  test - C++ test suites for the LingoFuse wrapper
# -----------------------------------------------------------------------------
#  Targets:
#    test_lingofuse       : comprehensive ABI/RAII test suite
#    test_lingofuse_json  : unified lf_io.hpp JSON/string I/O test suite
#
#  Links (both targets):
#    lingofuse_headers   -> public headers (json.hpp, LingoFuse.h,
#                           LingoFuse.hpp, lf_io.hpp) via a single
#                           include path
#    lingofuse_c_wrapper -> C ABI forwarding layer + platform loader
#    Threads::Threads    -> std::thread for concurrency tests
#
#  Output: ../../Binary/ (next to the DLLs, so LF_LoadLibrary finds them)
#
#  Run:
#    ctest --output-on-failure              (from the build directory)
#    ../Binary/test_lingofuse               (direct execution)
#    ../Binary/test_lingofuse_json          (direct execution)
# =============================================================================

# -----------------------------------------------------------------------------
#  Output directory (shared by both test executables)
# -----------------------------------------------------------------------------
set(LINGOFUSE_TEST_BINARY_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Binary")

message(STATUS "test: build output directory = ${LINGOFUSE_TEST_BINARY_DIR}")

# Helper macro: apply the standard output directory and warning level
# to a test target. Keeps the two targets below identical in shape.
macro(test_configure_target target_name)
    set_target_properties(${target_name} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY                "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG          "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE        "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${LINGOFUSE_TEST_BINARY_DIR}"
    )

    if(MSVC)
        target_compile_options(${target_name} PRIVATE /W4 /permissive-)
    else()
        target_compile_options(${target_name} PRIVATE -Wall -Wextra)
    endif()
endmacro()

# Threads is required by both test suites (concurrency and stress tests).
find_package(Threads REQUIRED)

# -----------------------------------------------------------------------------
#  test_lingofuse - ABI / RAII / network test suite
# -----------------------------------------------------------------------------
add_executable(test_lingofuse
    test_lingofuse.cpp
)

target_link_libraries(test_lingofuse
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
        Threads::Threads
)

test_configure_target(test_lingofuse)

add_test(
    NAME test_lingofuse
    COMMAND test_lingofuse
    WORKING_DIRECTORY "${LINGOFUSE_TEST_BINARY_DIR}"
)

# -----------------------------------------------------------------------------
#  test_lingofuse_json - lf_io.hpp JSON / string I/O test suite
# -----------------------------------------------------------------------------
#  Offline test suite: exercises the unified payload layer (lf_io.hpp)
#  without touching the network. It still links lingofuse_c_wrapper
#  because LibraryLoader is used to load the dynamic library once at
#  the start of the suite.
# -----------------------------------------------------------------------------
add_executable(test_lingofuse_json
    test_lingofuse_json.cpp
)

target_link_libraries(test_lingofuse_json
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
        Threads::Threads
)

test_configure_target(test_lingofuse_json)

add_test(
    NAME test_lingofuse_json
    COMMAND test_lingofuse_json
    WORKING_DIRECTORY "${LINGOFUSE_TEST_BINARY_DIR}"
)