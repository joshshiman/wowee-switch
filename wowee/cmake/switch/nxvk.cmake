# nxvk: Mesa's NVK Vulkan driver (Vulkan 1.4) ported to the Switch, used as
# WoWee's Vulkan backend on WOWEE_SWITCH builds. See
# references/nxvk/switch/README.md.
#
# Provides the Vulkan::Vulkan target the renderer already compiles against
# (vk_context.cpp, vk_shader.cpp, vk_utils.cpp, imgui_impl_vulkan, VMA,
# vk-bootstrap), backed by the prebuilt NVK archives from the nxvk devkitPro
# portlib (installed under $DEVKITPRO/portlibs/switch). Entry points resolve
# through the single exported symbol vk_icdGetInstanceProcAddr; the loader shim
# (src/platform/switch/vk_nxvk_loader.cpp) forwards the direct-call entry
# points the client's renderer code uses to it.

set(WOWEE_NXVK_PREFIX "${DEVKITPRO}/portlibs/switch")

# Preferred path: the portlib's own pkg-config, which carries exactly the flags
# the port documents (--whole-archive around libnvk.a, -u
# vk_icdGetInstanceProcAddr, --gc-sections, -I include, -D__SWITCH__,
# -DVK_USE_PLATFORM_VI_NN).
find_package(PkgConfig QUIET)
set(WOWEE_NXVK_VIA_PKGCONFIG FALSE)
if(PKG_CONFIG_FOUND)
    set(ENV{PKG_CONFIG_PATH} "${WOWEE_NXVK_PREFIX}/lib/pkgconfig")
    pkg_check_modules(NXVK QUIET IMPORTED_TARGET nxvk)
    if(TARGET PkgConfig::NXVK)
        set(WOWEE_NXVK_VIA_PKGCONFIG TRUE)
    endif()
endif()

add_library(nxvk_vulkan INTERFACE)
if(WOWEE_NXVK_VIA_PKGCONFIG)
    message(STATUS "nxvk: using ${WOWEE_NXVK_PREFIX}/lib/pkgconfig/nxvk.pc")
    target_link_libraries(nxvk_vulkan INTERFACE PkgConfig::NXVK)
else()
    # Fallback for an installation whose .pc is missing or unreadable: the
    # driver archives are all that is needed, because the loader shim supplies
    # the entry points.
    message(WARNING
        "nxvk: no usable nxvk.pc under ${WOWEE_NXVK_PREFIX}/lib/pkgconfig; "
        "falling back to linking the archives directly. Expect a link error if "
        "the driver was not installed there (tools/switch/fetch-nxvk.sh).")
    target_include_directories(nxvk_vulkan INTERFACE
        "${WOWEE_NXVK_PREFIX}/include"
        "${WOWEE_NXVK_PREFIX}/include/vulkan")
    target_compile_definitions(nxvk_vulkan INTERFACE __SWITCH__ VK_USE_PLATFORM_VI_NN)
    target_compile_options(nxvk_vulkan INTERFACE -ffunction-sections -fdata-sections)
    target_link_libraries(nxvk_vulkan INTERFACE
        -Wl,--whole-archive
        "${WOWEE_NXVK_PREFIX}/lib/libnvk.a"
        "${WOWEE_NXVK_PREFIX}/lib/libnvk_support.a"
        -Wl,--no-whole-archive
        -Wl,-u,vk_icdGetInstanceProcAddr
        -Wl,--gc-sections
        "${WOWEE_NXVK_PREFIX}/lib/libz.a"
        "${WOWEE_NXVK_PREFIX}/lib/libexpat.a")
endif()
add_library(Vulkan::Vulkan ALIAS nxvk_vulkan)