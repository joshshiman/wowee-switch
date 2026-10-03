// vk_nxvk_loader.cpp - forward the plain Vulkan API into nxvk.
//
// nxvk (Mesa's NVK Vulkan driver ported to the Switch) exports exactly one
// symbol: vk_icdGetInstanceProcAddr. The renderer, VMA, imgui_impl_vulkan
// and vk-bootstrap are written against the plain Vulkan API and call entry
// points directly, so this file provides those symbols as trampolines.
//
// Resolution follows what the driver actually supports:
//
//   * global commands (vkCreateInstance, vkEnumerateInstanceVersion, ...)
//     come from vk_icdGetInstanceProcAddr with a NULL instance;
//   * instance, physical-device, queue and command-buffer commands come from
//     vk_icdGetInstanceProcAddr with the live instance, which the generated
//     vkCreateInstance stub records;
//   * device commands come from the driver's vkGetDeviceProcAddr for that
//     device.
//
// The per-function stubs are generated from the real Vulkan headers by
// tools/switch/gen_nxvk_loader.py, so their signatures cannot drift.

#include <switch.h>

#include <vulkan/vulkan.h>

extern "C" PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char* pName);

namespace {

// Set by the generated vkCreateInstance stub below.
VkInstance g_instance = VK_NULL_HANDLE;
PFN_vkGetInstanceProcAddr g_driverGetInstanceProcAddr = nullptr;
PFN_vkGetDeviceProcAddr g_driverGetDeviceProcAddr = nullptr;

}  // namespace

extern "C" {

PFN_vkVoidFunction vk_nxvkLoadInstanceProc(const char* name) {
    if (g_instance == VK_NULL_HANDLE) return vk_icdGetInstanceProcAddr(VK_NULL_HANDLE, name);
    return vk_icdGetInstanceProcAddr(g_instance, name);
}

PFN_vkVoidFunction vk_nxvkLoadDeviceProc(VkDevice device, const char* name) {
    if (!g_driverGetDeviceProcAddr && g_instance != VK_NULL_HANDLE) {
        g_driverGetDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
            vk_icdGetInstanceProcAddr(g_instance, "vkGetDeviceProcAddr"));
    }
    if (!g_driverGetDeviceProcAddr) return nullptr;
    return g_driverGetDeviceProcAddr(device, name);
}

PFN_vkVoidFunction VKAPI_PTR vkGetInstanceProcAddr(VkInstance instance, const char* pName) {
    return vk_icdGetInstanceProcAddr(instance, pName);
}

PFN_vkVoidFunction VKAPI_PTR vkGetDeviceProcAddr(VkDevice device, const char* pName) {
    return vk_nxvkLoadDeviceProc(device, pName);
}

#include "vk_nxvk_loader.inc"

// The generated vkCreateInstance stub is a plain forward; wrap it so the
// instance is remembered for the entry points above.
}  // extern "C"

namespace {

PFN_vkCreateInstance g_driverCreateInstance = nullptr;

}  // namespace

extern "C" VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(
    const VkInstanceCreateInfo* pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkInstance* pInstance) {
    if (!g_driverCreateInstance) {
        g_driverCreateInstance = reinterpret_cast<PFN_vkCreateInstance>(
            vk_icdGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance"));
        if (!g_driverCreateInstance) return VK_ERROR_INITIALIZATION_FAILED;
    }
    const VkResult result = g_driverCreateInstance(pCreateInfo, pAllocator, pInstance);
    if (result == VK_SUCCESS && pInstance) {
        g_instance = *pInstance;
        g_driverGetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
            vk_icdGetInstanceProcAddr(g_instance, "vkGetInstanceProcAddr"));
    }
    return result;
}

extern "C" void vk_nxvk_loader_init(void) {
    // NVK's own bring-up requirement, documented in the port's README: it
    // refuses device creation without this set.
    setenv("NVK_I_WANT_A_BROKEN_VULKAN_DRIVER", "1", 1);
}