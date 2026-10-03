#pragma once
#include <vulkan/vulkan.h>

namespace wowee::rendering {

/// Pipeline skip list: switch individual shaders off without a rebuild.
///
/// `sdmc:/switch/wowee/skip-shaders.txt`, one shader-name substring per line;
/// blank lines and `#` comments ignored. A pipeline built from a matching
/// shader pair is created from `assets/shaders/stub.*.spv` instead, so it stays
/// a valid pipeline - every draw call and null check downstream keeps working -
/// and simply contributes nothing to the frame.
///
/// This exists because a driver that cannot compile one shader fails in ways
/// that look like unrelated hangs, and because "turn this effect off" should be
/// a question you can ask a shipped build.
class PipelineSkipList {
public:
    /// True when any entry is a substring of `stageList`.
    static bool Matches(const char* stageList);
    /// Entries loaded, for logging.
    static uint32_t Count();
};

/// The stub modules, created on first use. VK_NULL_HANDLE if unavailable, in
/// which case a skipped pipeline is left alone rather than half-substituted.
/// Deliberately never destroyed: they live as long as the device, and a
/// shutdown path for two modules is not worth the ordering constraints.
::VkShaderModule StubVertexModule(VkDevice device);
::VkShaderModule StubFragmentModule(VkDevice device);

}  // namespace wowee::rendering