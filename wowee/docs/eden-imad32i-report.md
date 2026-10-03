# Eden cannot translate NVK's `IMAD32I`, and reports success while doing it

## Summary

A homebrew NRO built against the `nvk-switch` (Mesa NVK) portlib cannot get past
its first frame under Eden. NVK compiles SPIR-V to Maxwell SM5, and one of the
instructions it emits — `IMAD32I` — is not implemented by Eden's Maxwell
decompiler. The pipeline call still returns `VK_SUCCESS`, the broken pipeline is
executed, and the emulator wedges or dies.

This is not specific to any one shader: it is a gap in the instruction set the
recompiler accepts, and NVK emits that instruction readily.

## Environment

| | |
|---|---|
| Emulator | Eden nightly (`v0.2.1` dev build, and a newer 2026 nightly), Windows 11 25H2 |
| Host GPU | Intel Arc A770, Vulkan 1.4.356 |
| Guest | devkitA64 GCC 15.2.0, libnx 4.12.0, statically linked `libvulkan.a` from `nvk-switch-mesa-25.0.7-r1` |
| Title | plain homebrew `.nro` (title id 0), no romfs, launched from the games directory |

## Reproduction

1. Build any Vulkan NRO against the `nvk-switch` portlib.
2. Create a graphics pipeline from a SPIR-V shader containing 32-bit integer
   arithmetic (an `a * b + c` on integers is enough).
3. Run it.

Eden reports:

```
Render.Vulkan <Error> video_core/renderer_vulkan/vk_pipeline_cache.cpp:905:
CreateGraphicsPipeline: Instruction IMAD32I is not implemented is not implemented
```

and then, once the broken pipeline runs:

```
HW.GPU  <Critical> video_core/macro.cpp:1229: MacroJIT_ErrorThunk:
    Macro JIT: invalid parameter access 0x33ddf5f15a4 (0x33ddf5f1510 is the last parameter)
Debug   <Critical> video_core/engines/maxwell_3d.cpp:616: assert buffer_address != 0
```

followed by an endless stream of `maxwell_3d.cpp` assertions. The process
either becomes unresponsive or exits, depending on the async/emulation
settings.

## Impact

1. **The failure is not reported to the guest.** `vkCreateGraphicsPipelines`
   returns `VK_SUCCESS` even though the recompile failed. A guest has no way to
   detect it: the application sees a valid `VkPipeline` handle. Our client's
   logs contain no error of any kind for the failing pipeline.
2. **The consequence is a hang, not a failure.** With asynchronous shader
   compilation the queue stops completing, so `vkQueuePresentKHR` never returns
   and Windows reports the emulator as not responding. There is no timeout to
   trip and no diagnostic for the user beyond that.

Point 1 is the reason this is hard to work around from the guest side, and
seems worth addressing regardless of whether `IMAD32I` gets implemented: a
pipeline that cannot be recompiled should fail `vkCreateGraphicsPipelines`
rather than hand back a handle that executes garbage.

## Two related observations

**No device-local memory.** The same build reports:

```
vkGetPhysicalDeviceMemoryProperties:
  1 type(s) in 1 heap(s)
  type 0 heap=0 flags=14 (0xe) deviceLocal=0 hostVisible=1 hostCoherent=1 hostCached=1
```

i.e. a single host-visible heap with no `VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT`
type, which is expected for guest VRAM mapped to host memory. Not a blocker on
its own, but worth knowing when a guest asks for a device-local allocation.

**Image allocation crashed Eden 0.2.1.** In the older `v0.2.1` build, the first
guest image allocation reproducibly killed the process with an access violation
inside `eden.exe` (`0xc0000005`, fault offset `0x78f91d`) during `nvhost` GPU
setup — with an explicit host-visible type mask and with an unrestricted one.
The nightly does not crash, so this appears fixed, but it is the same shape of
guest-memory path and may be worth a regression test.

## What would fix it

Implementing `IMAD32I` in `src/shader_recompiler/frontend/maxwell/`. It is an
SM5-only instruction: a 32-bit integer multiply-add with a carry-out, distinct
from the `IMAD` used by Turing and later. Retail titles evidently do not need
it, which is why it has gone unnoticed — but NVK emits it, so anything built
with Mesa's NVK path hits it.

## Notes for reproduction

Getting a *minimal* repro is harder than it looks: the client that found this
has ~95 SPIR-V shaders, and the `[PIPELINE]` breadcrumbs needed to attribute
the failure were client-side. A purpose-built NRO that creates one pipeline from
a small SPIR-V with integer `mad` would be the clean test case.
