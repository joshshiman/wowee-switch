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
//     vk_icdGetInstanceProcAddr with the live instance, which the
//     vkCreateInstance wrapper below records;
//   * device commands come from the driver's vkGetDeviceProcAddr for that
//     device.
//
// A name the driver declines is fatal rather than a jump through nullptr: a
// Vulkan call that cannot be resolved has no correct behaviour, and the crash
// screen says which one it was.
//
// The per-function stubs are generated from the real Vulkan headers by
// tools/switch/gen_nxvk_loader.py, so their signatures cannot drift.

#include <switch.h>

#include <stdlib.h>
#include <stdio.h>

#include <vulkan/vulkan.h>

extern "C" PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char* pName);

namespace {

// Set by the vkCreateInstance wrapper below; cleared by vkDestroyInstance.
VkInstance g_instance = VK_NULL_HANDLE;
PFN_vkGetDeviceProcAddr g_driverGetDeviceProcAddr = nullptr;

}  // namespace

extern "C" {

void vk_nxvkMissingEntryPoint(const char* name) {
    // Reached when the driver declines an entry point the client needs. Print
    // and halt: the alternative is a null function-pointer call, which on this
    // target reports nothing about the cause.
    std::fprintf(stderr, "[wowee/switch] nxvk: driver has no entry point '%s'\n", name);
    while (true) {
        svcSleepThread(1000000000LL);
    }
}

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

#ifndef WOWEE_NXVK_PROVIDES_LOADER
// The nxvk portlib exports only the ICD entry point, so the loader's own
// vkGetInstanceProcAddr lives here. The prebuilt drop-in archive provides one
// already (WOWEE_NXVK_PROVIDES_LOADER), and defining it twice would be a
// duplicate symbol.
PFN_vkVoidFunction VKAPI_PTR vkGetInstanceProcAddr(VkInstance instance, const char* pName) {
    return vk_icdGetInstanceProcAddr(instance, pName);
}
#endif

PFN_vkVoidFunction VKAPI_PTR vkGetDeviceProcAddr(VkDevice device, const char* pName) {
    return vk_nxvkLoadDeviceProc(device, pName);
}

#include "vk_nxvk_loader.inc"

}  // extern "C"

namespace {

PFN_vkCreateInstance g_driverCreateInstance = nullptr;
PFN_vkDestroyInstance g_driverDestroyInstance = nullptr;

}  // namespace

// vkCreateInstance/vkDestroyInstance are wrapped rather than forwarded: the
// instance has to be remembered, because every instance-, physical-device-,
// queue- and command-buffer-level lookup goes through it.
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
        g_driverGetDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
            vk_icdGetInstanceProcAddr(g_instance, "vkGetDeviceProcAddr"));
        g_driverDestroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(
            vk_icdGetInstanceProcAddr(g_instance, "vkDestroyInstance"));
    }
    return result;
}

extern "C" VKAPI_ATTR void VKAPI_CALL vkDestroyInstance(
    VkInstance instance,
    const VkAllocationCallbacks* pAllocator) {
    if (g_driverDestroyInstance) {
        g_driverDestroyInstance(instance, pAllocator);
    } else {
        vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance");
    }
    if (instance == g_instance) {
        g_instance = VK_NULL_HANDLE;
        g_driverGetDeviceProcAddr = nullptr;
    }
}

extern "C" void vk_nxvk_loader_init(void) {
    // NVK's own bring-up requirement, documented in the port's README: it
    // refuses to expose the console's Maxwell GPU without this set.
    setenv("NVK_I_WANT_A_BROKEN_VULKAN_DRIVER", "1", 1);
}