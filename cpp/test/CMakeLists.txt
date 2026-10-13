# =============================================================================
#  test - C++ / C test suites for the LingoFuse wrapper
# -----------------------------------------------------------------------------
#  Targets:
#    test_lingofuse       : comprehensive ABI/RAII/network test suite (C++)
#    test_lingofuse_json  : unified lf_io.hpp JSON/string I/O test suite (C++)
#    test_lingofuse_capi  : pure C ABI offline test suite (C)
#    test_lingofuse_uid   : UID identity-injection ABI verification (C)
#    test_uid_probe       : LF_Get_P2P_UID calling-convention probe (C, Windows)
#
#  Links:
#    lingofuse_headers   -> public headers via a single include path
#    lingofuse_c_wrapper -> C ABI forwarding layer + platform loader
#    Threads::Threads    -> std::thread for the C++ suites only
#
#  Output: ../../Binary/ (next to the DLLs, so LF_LoadLibrary finds them)
# =============================================================================

set(LINGOFUSE_TEST_BINARY_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Binary")

message(STATUS "test: build output directory = ${LINGOFUSE_TEST_BINARY_DIR}")

# Helper macro: standard output directory + warning level for C++ targets.
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

# Helper macro for pure C targets.
macro(test_configure_c_target target_name)
    set_target_properties(${target_name} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY                "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG          "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE        "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     "${LINGOFUSE_TEST_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${LINGOFUSE_TEST_BINARY_DIR}"
    )

    if(MSVC)
        target_compile_options(${target_name} PRIVATE /W4)
    else()
        target_compile_options(${target_name} PRIVATE -Wall -Wextra)
    endif()
endmacro()

# Threads is required by the C++ test suites only.
find_package(Threads REQUIRED)

# -----------------------------------------------------------------------------
#  test_lingofuse - ABI / RAII / network test suite (C++)
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
#  test_lingofuse_json - lf_io.hpp JSON / string I/O test suite (C++)
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

# -----------------------------------------------------------------------------
#  test_lingofuse_capi - pure C ABI offline test suite (C)
# -----------------------------------------------------------------------------
add_executable(test_lingofuse_capi
    test_lingofuse_capi.c
)

target_link_libraries(test_lingofuse_capi
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
)

test_configure_c_target(test_lingofuse_capi)

add_test(
    NAME test_lingofuse_capi
    COMMAND test_lingofuse_capi
    WORKING_DIRECTORY "${LINGOFUSE_TEST_BINARY_DIR}"
)

# -----------------------------------------------------------------------------
#  test_lingofuse_uid - UID identity-injection ABI verification (C)
# -----------------------------------------------------------------------------
add_executable(test_lingofuse_uid
    test_lingofuse_uid.c
)

target_link_libraries(test_lingofuse_uid
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
)

test_configure_c_target(test_lingofuse_uid)

add_test(
    NAME test_lingofuse_uid
    COMMAND test_lingofuse_uid
    WORKING_DIRECTORY "${LINGOFUSE_TEST_BINARY_DIR}"
)

# -----------------------------------------------------------------------------
#  test_uid_probe - LF_Get_P2P_UID calling-convention probe (C, Windows only)
# -----------------------------------------------------------------------------
#  A read-only diagnostic. It loads the DLL, locates LF_Get_P2P_UID via
#  GetProcAddress, and dumps the first 64 bytes of the function's machine
#  code so the calling convention can be determined without calling it.
#
#  Only built on Windows. On non-Windows platforms the file would not
#  compile (it includes <windows.h> unconditionally and uses
#  GetModuleHandleA / GetProcAddress).
# -----------------------------------------------------------------------------
if(WIN32)
    add_executable(test_uid_probe
        test_uid_probe.c
    )

    target_link_libraries(test_uid_probe
        PRIVATE
            lingofuse_headers
            lingofuse_c_wrapper
    )

    test_configure_c_target(test_uid_probe)
endif()