# =============================================================================
#  CrossDemo - Build Script for the LingoFuse C++ Demo Executables
# -----------------------------------------------------------------------------
#  Builds three executables that demonstrate the C++ RAII wrapper:
#
#    CrossService  : Coordinator process. Creates the IPC service endpoint
#                    "ipc:cross" and does nothing else.
#
#    CrossNode     : Worker node. Registers the "add" and "inv_seri" APIs
#                    under application "demo", then attaches itself to the
#                    IPC endpoint. Multiple instances may be launched to
#                    exercise the automatic load balancer.
#
#    CrossCall     : Client. Connects to "ipc:cross" as a pure consumer and
#                    runs a 10-second concurrent load test against the
#                    worker nodes.
#
#  Output location:
#      ../../Binary/          (i.e. LingoFuse/Binary/, next to the DLLs)
#
#  All three link against lingofuse_c_wrapper, which provides:
#    - the C ABI forwarding layer (LingoFuse.c)
#    - the include path for LingoFuse.h and LingoFuse.hpp
#    - the platform-specific dynamic loading library
#      (kernel32 on Windows, ${CMAKE_DL_LIBS} on Linux / macOS)
# =============================================================================

# -----------------------------------------------------------------------------
#  Output directory - keep all executables next to the runtime DLLs / SOs.
# -----------------------------------------------------------------------------
#
#  Rationale for setting this locally (in addition to the parent scope):
#
#    - The top-level CMakeLists.txt already sets CMAKE_RUNTIME_OUTPUT_DIRECTORY
#      and its per-configuration variants. In the normal case those are
#      inherited by this subdirectory, and no explicit setting is required.
#
#    - However, if this CMakeLists.txt is ever consumed standalone (e.g. as a
#      snippet, via add_subdirectory from a different parent, or when a future
#      CMake version changes inheritance rules), the inherited value may be
#      missing. Setting the target property explicitly guarantees that the
#      executables always land in the intended directory.
#
#    - Both the unsuffixed variable and the per-configuration variants are set,
#      because CMake appends a per-configuration subdirectory (Debug/, Release/,
#      ...) whenever only the unsuffixed variable is present.
# -----------------------------------------------------------------------------

set(LINGOFUSE_CROSS_BINARY_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Binary")

message(STATUS "CrossDemo: build output directory = "
               "${LINGOFUSE_CROSS_BINARY_DIR}")

# Helper macro to apply the output directory to a target.
#
# We use a macro rather than a function to avoid an extra variable scope,
# and because the macro body is short enough that inlining is clearer.
macro(cross_set_output_dir target_name)
    set_target_properties(${target_name} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY           "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG     "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE   "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${LINGOFUSE_CROSS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${LINGOFUSE_CROSS_BINARY_DIR}"
    )
endmacro()

# -----------------------------------------------------------------------------
#  CrossService - pure coordinator, no API registration
# -----------------------------------------------------------------------------
add_executable(CrossService
    CrossService.cpp
)

target_link_libraries(CrossService
    PRIVATE
        lingofuse_c_wrapper
)

cross_set_output_dir(CrossService)

# -----------------------------------------------------------------------------
#  CrossNode - worker node registering "add" and "inv_seri"
# -----------------------------------------------------------------------------
add_executable(CrossNode
    CrossNode.cpp
)

target_link_libraries(CrossNode
    PRIVATE
        lingofuse_c_wrapper
)

cross_set_output_dir(CrossNode)

# -----------------------------------------------------------------------------
#  CrossCall - concurrent client / load tester
#  Uses std::thread, so we link the platform thread library as well.
# -----------------------------------------------------------------------------
add_executable(CrossCall
    CrossCall.cpp
)

find_package(Threads REQUIRED)

target_link_libraries(CrossCall
    PRIVATE
        lingofuse_c_wrapper
        Threads::Threads
)

cross_set_output_dir(CrossCall)

# -----------------------------------------------------------------------------
#  Compiler warnings (applied to all three targets)
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