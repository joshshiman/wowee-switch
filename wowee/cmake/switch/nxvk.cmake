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

find_package(PkgConfig REQUIRED)
set(ENV{PKG_CONFIG_PATH} "${DEVKITPRO}/portlibs/switch/lib/pkgconfig")
pkg_check_modules(NXVK REQUIRED IMPORTED_TARGET nxvk)

# PkgConfig::NXVK already carries the Mesalike flags (--whole-archive for
# libnvk.a, -u vk_icdGetInstanceProcAddr, -I include, -D__SWITCH__,
# -DVK_USE_PLATFORM_VI_NN) via nxvk.pc, so it is the whole backend.
add_library(nxvk_vulkan INTERFACE)
target_link_libraries(nxvk_vulkan INTERFACE PkgConfig::NXVK)
add_library(Vulkan::Vulkan ALIAS nxvk_vulkan)
