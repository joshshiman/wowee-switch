# nxvk: Mesa's NVK Vulkan driver ported to the Switch, used as WoWee's Vulkan
# backend on WOWEE_SWITCH builds.
#
# Two supported layouts, both landing in $DEVKITPRO/portlibs/switch:
#
#   1. the nxvk devkitPro portlib (PalindromicBreadLoaf/nxvk, `make install`),
#      consumed through its own nxvk.pc;
#   2. the prebuilt drop-in archive from jhuz0/nvk-switch, which is one
#      self-contained libvulkan.a (Mesa + newlib gap fills + expat) beside the
#      Vulkan headers. It exports vkGetInstanceProcAddr itself, so
#      src/platform/switch/vk_nxvk_loader.cpp only supplies the plain API.
#
# Either way the driver exposes one real entry point, vk_icdGetInstanceProcAddr;
# the loader shim forwards the renderer's direct calls into it, and
# VK_NN_vi_surface presents through libnx's NWindow.

set(WOWEE_NXVK_PREFIX "${DEVKITPRO}/portlibs/switch")

add_library(nxvk_vulkan INTERFACE)
target_include_directories(nxvk_vulkan SYSTEM INTERFACE
    "${WOWEE_NXVK_PREFIX}/include")

# The Switch headers the driver needs: libnx's applet/window types and the
# platform surface extension.
target_compile_definitions(nxvk_vulkan INTERFACE __SWITCH__ VK_USE_PLATFORM_VI_NN)
target_compile_options(nxvk_vulkan INTERFACE -ffunction-sections -fdata-sections)

# Preferred: the portlib's pkg-config, which carries the driver's own flags.
find_package(PkgConfig QUIET)
set(WOWEE_NXVK_LAYOUT "")
if(PKG_CONFIG_FOUND)
    set(ENV{PKG_CONFIG_PATH} "${WOWEE_NXVK_PREFIX}/lib/pkgconfig")
    pkg_check_modules(NXVK QUIET IMPORTED_TARGET nxvk)
    if(TARGET PkgConfig::NXVK)
        set(WOWEE_NXVK_LAYOUT "portlib")
        target_link_libraries(nxvk_vulkan INTERFACE PkgConfig::NXVK)
    endif()
endif()

if(NOT WOWEE_NXVK_LAYOUT)
    # Prebuilt drop-in: one archive, walked whole so the driver's static
    # initialisers stay, forced in so the ICD entry point is never dropped.
    if(EXISTS "${WOWEE_NXVK_PREFIX}/lib/libvulkan.a")
        set(WOWEE_NXVK_LAYOUT "prebuilt")
        target_link_options(nxvk_vulkan INTERFACE
            -Wl,--whole-archive "${WOWEE_NXVK_PREFIX}/lib/libvulkan.a" -Wl,--no-whole-archive
            -Wl,-u,vk_icdGetInstanceProcAddr
            -Wl,--gc-sections)
        # This build already provides vkGetInstanceProcAddr and the newlib gap
        # fills, so the loader must not define them again.
        target_compile_definitions(nxvk_vulkan INTERFACE WOWEE_NXVK_PROVIDES_LOADER=1)
    else()
        message(FATAL_ERROR
            "No Vulkan driver for the Switch under ${WOWEE_NXVK_PREFIX}. Install one:\n"
            "  * the nxvk portlib: https://github.com/PalindromicBreadLoaf/nxvk "
            "(make image && make && sudo make install)\n"
            "  * or the prebuilt archive: https://github.com/jhuz0/nvk-switch (lib/libvulkan.a\n"
            "    plus include/vulkan/ into ${WOWEE_NXVK_PREFIX})")
    endif()
endif()

message(STATUS "Vulkan backend for Switch: nxvk (${WOWEE_NXVK_LAYOUT}) at ${WOWEE_NXVK_PREFIX}")
add_library(Vulkan::Vulkan ALIAS nxvk_vulkan)