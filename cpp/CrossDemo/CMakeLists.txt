# =============================================================================
#  CrossDemo - demo executables for the LingoFuse C++ wrapper
# -----------------------------------------------------------------------------
#  Targets:
#    CrossService : coordinator (creates ipc:cross)
#    CrossNode    : worker node registering add / inv_seri
#    CrossCall    : concurrent load-test client
#
#  Each target links:
#    lingofuse_headers   -> public headers (json.hpp, LingoFuse.h,
#                           LingoFuse.hpp, lf_io.hpp) via a single
#                           include path
#    lingofuse_c_wrapper -> C ABI forwarding layer + platform loader
#    Threads::Threads    -> CrossCall only
#
#  Output: ../../Binary/ (next to the DLLs)
# =============================================================================

set(LINGOFUSE_CROSS_BINARY_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Binary")

message(STATUS "CrossDemo: build output directory = ${LINGOFUSE_CROSS_BINARY_DIR}")

macro(cross_set_output_dir target_name)
    set_target_properties(${target_name} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY                "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG          "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE        "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${LINGOFUSE_CROSS_BINARY_DIR}"
    )
endmacro()

# -----------------------------------------------------------------------------
#  CrossService
# -----------------------------------------------------------------------------
add_executable(CrossService
    CrossService.cpp
)

target_link_libraries(CrossService
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
)

cross_set_output_dir(CrossService)

# -----------------------------------------------------------------------------
#  CrossNode
# -----------------------------------------------------------------------------
add_executable(CrossNode
    CrossNode.cpp
)

target_link_libraries(CrossNode
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
)

cross_set_output_dir(CrossNode)

# -----------------------------------------------------------------------------
#  CrossCall
# -----------------------------------------------------------------------------
add_executable(CrossCall
    CrossCall.cpp
)

find_package(Threads REQUIRED)

target_link_libraries(CrossCall
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
        Threads::Threads
)

cross_set_output_dir(CrossCall)

# -----------------------------------------------------------------------------
#  Compiler warnings
# -----------------------------------------------------------------------------
if(MSVC)
    target_compile_options(CrossService PRIVATE /W4 /permissive-)
    target_compile_options(CrossNode    PRIVATE /W4 /permissive-)
    target_compile_options(CrossCall    PRIVATE /W4 /permissive-)
else()
    target_compile_options(CrossService PRIVATE -Wall -Wextra)
    target_compile_options(CrossNode    PRIVATE -Wall -Wextra)
    target_compile_options(CrossCall    PRIVATE -Wall -Wextra)
endif()