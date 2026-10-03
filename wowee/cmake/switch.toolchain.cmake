# CMake toolchain file for building WoWee/WoWPS for the Nintendo Switch with
# the devkitPro toolchain (devkitA64 + libnx + portlibs).
#
# Usage:
#   export DEVKITPRO=/opt/devkitpro
#   cmake -S . -B build-switch -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/switch.toolchain.cmake
#   cmake --build build-switch
#
# Requires:
#   - $DEVKITPRO/devkitA64 (aarch64-none-elf-gcc/g++)
#   - $DEVKITPRO/libnx
#   - $DEVKITPRO/portlibs/switch with: zlib, and the nxvk (NVK Vulkan) package
#     (PalindromicBreadLoaf/nxvk, installed as a devkitPro portlib).

set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_CROSSCOMPILING TRUE)
set(WOWEE_SWITCH ON CACHE BOOL "Building for the Nintendo Switch" FORCE)

if(NOT DEFINED DEVKITPRO)
    if(DEFINED ENV{DEVKITPRO})
        set(DEVKITPRO "$ENV{DEVKITPRO}")
    else()
        message(FATAL_ERROR "DEVKITPRO is not set. Install devkitPro and point it at the install root.")
    endif()
endif()
set(DEVKITPRO "${DEVKITPRO}" CACHE PATH "devkitPro root")

if(NOT EXISTS "${DEVKITPRO}/devkitA64/bin")
    message(FATAL_ERROR "DEVKITPRO=${DEVKITPRO} does not look like a devkitPro install (missing devkitA64/bin)")
endif()

set(DEVKITA64 "${DEVKITPRO}/devkitA64/bin")
set(CMAKE_C_COMPILER   "${DEVKITA64}/aarch64-none-elf-gcc")
set(CMAKE_CXX_COMPILER "${DEVKITA64}/aarch64-none-elf-g++")
set(CMAKE_AR           "${DEVKITA64}/aarch64-none-elf-ar")
set(CMAKE_RANLIB       "${DEVKITA64}/aarch64-none-elf-ranlib")

# try_compile must not attempt to link the host drivers against switch.specs.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Tegra X1 CPU: A57 quad, Cortex-A53 quad. Tuning flags for the renderer's
# CPU culling/animation sampling/asset bookkeeping.
set(WOWEE_SWITCH_COMMON_FLAGS
    "-fPIC -ffunction-sections -fdata-sections -fexceptions -march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIE -D_GNU_SOURCE -D__SWITCH__ -DWOWEE_SWITCH=1")
set(CMAKE_C_FLAGS_INIT   "${WOWEE_SWITCH_COMMON_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${WOWEE_SWITCH_COMMON_FLAGS} -fcxx-exceptions")

set(CMAKE_EXE_LINKER_FLAGS_INIT
    "-specs=${DEVKITPRO}/libnx/switch.specs -Wl,--gc-sections -L${DEVKITPRO}/portlibs/switch/lib")

set(BUILD_SHARED_LIBS OFF)
set(CMAKE_FIND_ROOT_PATH "${DEVKITPRO}/portlibs/switch;${DEVKITPRO}/libnx")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Cross pkg-config for the portlibs (nxvk, zlib). devkitPro ships one per
# target triple; cmake/switch/nxvk.cmake uses it through pkg_check_modules.
set(PKG_CONFIG_EXECUTABLE "${DEVKITPRO}/portlibs/switch/bin/aarch64-none-elf-pkg-config"
    CACHE FILEPATH "devkitA64 pkg-config")

# Output plain ELF; CMakeLists.txt runs elf2nro after link.
