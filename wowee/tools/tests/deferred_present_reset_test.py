#!/usr/bin/env python3
from pathlib import Path
root = Path(__file__).resolve().parents[2]
ctx = (root/'src/rendering/vk_context.cpp').read_text()
queue = (root/'switch/third_party/nxvk/source/vulkan-switch/src/vk_switch_queue.c').read_text()
start = ctx.index('void VkContext::resetFrameSyncState()')
end = ctx.index('VkCommandBuffer VkContext::beginFrame', start)
body = ctx[start:end]
wait = body.index('vkDeviceWaitIdle(device)')
flush = body.index('flushDeferredPresent()')
destroy = body.index('vkDestroySemaphore(device, sem, nullptr)')
reprime = body.index('deferredPresentPrimed_ = false')
assert wait < flush < destroy, 'deferred present must be consumed after idle and before semaphore destruction'
assert flush < reprime < destroy, 'deferred pipeline must be re-primed before semaphore handles are remade'
resolve = queue[queue.index('bool vk_switch_sync_resolve_semaphore'):queue.index('static bool vk_switch_queue_wait_semaphore')]
assert 'vk_switch_sync_validate_semaphore(sem)' in resolve
queue_all = queue
assert 'sem->label_mem.mapped != (void *)sem->label' in queue_all
assert '(uintptr_t)sem->label < 0x10000u' in queue_all
swap = (root/'switch/third_party/nxvk/source/vulkan-switch/src/vk_switch_swapchain.c').read_text()
present = swap[swap.index('vk_switch_QueuePresentKHR'): ]
assert present.index('vk_switch_sync_validate_semaphore(sem)') < present.index('sem->pending.slot_index')
print('PASS: deferred present is retired before sync-object rebuild and semaphore-label integrity is checked before dereference')
