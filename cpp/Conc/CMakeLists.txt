# =============================================================================
#  Conc/CMakeLists.txt
# -----------------------------------------------------------------------------
#  Concurrent-notify demo for the LingoFuse C++ interface.
#
#  This is a SUBDIRECTORY of the parent LingoFuse C++ project. The parent
#  (cpp/CMakeLists.txt) defines the imported targets:
#
#      lingofuse_headers    (INTERFACE, public headers)
#      lingofuse_c_wrapper  (STATIC, C ABI forwarding + loader)
#
#  Targets produced here:
#      ConcService  -- service side: tick counter + wait_complete barrier
#      ConcClient   -- client side: multi-threaded notify dispatcher
#
#  Build output: ../../Binary/ (next to the LingoFuse runtime library)
# =============================================================================

set(LINGOFUSE_CONC_BINARY_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Binary")

message(STATUS "Conc: build output directory = ${LINGOFUSE_CONC_BINARY_DIR}")

macro(conc_set_output_dir target_name)
    set_target_properties(${target_name} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY                "${LINGOFUSE_CONC_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG          "${LINGOFUSE_CONC_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE        "${LINGOFUSE_CONC_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     "${LINGOFUSE_CONC_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${LINGOFUSE_CONC_BINARY_DIR}"
    )
endmacro()

if(NOT TARGET Threads::Threads)
    find_package(Threads REQUIRED)
endif()

# -----------------------------------------------------------------------------
#  ConcService
# -----------------------------------------------------------------------------
add_executable(ConcService
    ConcService.cpp
    ConcCommon.hpp
)

target_link_libraries(ConcService
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
        Threads::Threads
)

conc_set_output_dir(ConcService)

# -----------------------------------------------------------------------------
#  ConcClient
# -----------------------------------------------------------------------------
add_executable(ConcClient
    ConcClient.cpp
    ConcCommon.hpp
)

target_link_libraries(ConcClient
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
        Threads::Threads
)

conc_set_output_dir(ConcClient)

# -----------------------------------------------------------------------------
#  Compiler flags
# -----------------------------------------------------------------------------
if(MSVC)
    target_compile_options(ConcService PRIVATE /W4 /permissive- /utf-8)
    target_compile_options(ConcClient  PRIVATE /W4 /permissive- /utf-8)
else()
    target_compile_options(ConcService PRIVATE -Wall -Wextra)
    target_compile_options(ConcClient  PRIVATE -Wall -Wextra)
endif()