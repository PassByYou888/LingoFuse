# =============================================================================
#  Stress/CMakeLists.txt
# -----------------------------------------------------------------------------
#  Stress and stability test demo for the LingoFuse C++ interface.
#
#  This is a SUBDIRECTORY of the parent LingoFuse C++ project. The parent
#  (cpp/CMakeLists.txt) defines the imported targets:
#
#      lingofuse_headers    (INTERFACE, public headers)
#      lingofuse_c_wrapper  (STATIC, C ABI forwarding + loader)
#
#  Targets produced here:
#      StressService  -- beacon + API executor
#      StressClient   -- multi-threaded caller, reports via LF_Notify
#      StressMonitor  -- mesh observer, samples clients by PID
#
#  Build output: ../../Binary/ (next to the LingoFuse runtime library)
# =============================================================================

set(LINGOFUSE_STRESS_BINARY_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../Binary")

message(STATUS "Stress: build output directory = ${LINGOFUSE_STRESS_BINARY_DIR}")

macro(stress_set_output_dir target_name)
    set_target_properties(${target_name} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY                "${LINGOFUSE_STRESS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG          "${LINGOFUSE_STRESS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE        "${LINGOFUSE_STRESS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL     "${LINGOFUSE_STRESS_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${LINGOFUSE_STRESS_BINARY_DIR}"
    )
endmacro()

if(NOT TARGET Threads::Threads)
    find_package(Threads REQUIRED)
endif()

# -----------------------------------------------------------------------------
#  StressService
# -----------------------------------------------------------------------------
add_executable(StressService
    StressService.cpp
)

target_link_libraries(StressService
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
)

stress_set_output_dir(StressService)

# -----------------------------------------------------------------------------
#  StressClient
# -----------------------------------------------------------------------------
add_executable(StressClient
    StressClient.cpp
    StressCommon.hpp
)

target_link_libraries(StressClient
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
        Threads::Threads
)

stress_set_output_dir(StressClient)

# -----------------------------------------------------------------------------
#  StressMonitor
# -----------------------------------------------------------------------------
#  The monitor is now a LingoFuse App itself (StressMon / report), so it
#  links the same interface and wrapper as the other targets, plus the
#  platform-specific libraries for process sampling.
# -----------------------------------------------------------------------------
add_executable(StressMonitor
    StressMonitor.cpp
    StressCommon.hpp
)

target_link_libraries(StressMonitor
    PRIVATE
        lingofuse_headers
        lingofuse_c_wrapper
        Threads::Threads
)

if(WIN32)
    target_link_libraries(StressMonitor PRIVATE psapi)
endif()

stress_set_output_dir(StressMonitor)

# -----------------------------------------------------------------------------
#  Compiler flags
# -----------------------------------------------------------------------------
if(MSVC)
    target_compile_options(StressService PRIVATE /W4 /permissive- /utf-8)
    target_compile_options(StressClient  PRIVATE /W4 /permissive- /utf-8)
    target_compile_options(StressMonitor PRIVATE /W4 /permissive- /utf-8)
else()
    target_compile_options(StressService PRIVATE -Wall -Wextra)
    target_compile_options(StressClient  PRIVATE -Wall -Wextra)
    target_compile_options(StressMonitor PRIVATE -Wall -Wextra)
endif()