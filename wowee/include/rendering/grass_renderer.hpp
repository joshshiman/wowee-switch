#pragma once

#include <cstdint>
#include <vector>

#include <glm/glm.hpp>
#include <vulkan/vulkan.h>
#include <vk_mem_alloc.h>

#include "pipeline/grass_population.hpp"
#include "rendering/grass_blade.hpp"
#include "rendering/vk_context.hpp"

namespace wowee {

namespace rendering {

class Camera;

/// GPU-driven grass.
///
/// Phase 1 of `docs/plan-grass.md`: the whole path - source buffer, compute
/// cull with atomic compaction, indirect draw - running on a fixed test
/// population at a hardcoded origin. No terrain input, no wind, no curvature.
/// Those arrive in later phases; this one exists so that when they do, the
/// Vulkan plumbing underneath them is already known to work.
///
/// The counter is never read on the CPU. `instanceCount` in the indirect
/// command is both the compaction cursor the compute shader atomically
/// advances and the field the draw consumes, so no readback and no host
/// synchronisation is involved.
class GrassRenderer {
public:
    GrassRenderer() = default;
    ~GrassRenderer();

    GrassRenderer(const GrassRenderer&) = delete;
    GrassRenderer& operator=(const GrassRenderer&) = delete;

    /// `bladeCapacity` is how many blades the source buffer is allocated for,
    /// from capacityFor below. Grass is optional, so nothing in here may throw:
    /// a failed allocation comes back as false and grass is skipped.
    bool initialize(VkContext* ctx, VkDescriptorSetLayout perFrameLayout,
                    uint32_t bladeCapacity);
    void shutdown();

    /// Rebuild the graphics pipeline against the current render pass. Called
    /// when MSAA or the swapchain changes, like every other renderer.
    void recreatePipelines();

    /// Record the cull dispatch. Must run outside a render pass, before
    /// `render()` for the same frame.
    ///
    /// `rangeCenter` is the point the draw distance is measured from - the
    /// player, matching the generation window. Never the camera: it orbits.
    void dispatchCull(VkCommandBuffer cmd, uint32_t frameIndex, const Camera& camera,
                      const glm::vec3& rangeCenter);

    /// Record the indirect draw. Must run inside the render pass.
    void render(VkCommandBuffer cmd, uint32_t frameIndex, VkDescriptorSet perFrameSet);

    /// Replace the live population. Blades carry world positions, so this is
    /// the whole of what the renderer knows about where grass is.
    ///
    /// Stages into a buffer allocated once at its full capacity: the set of
    /// blades changes every time the player leaves the generated window, and
    /// reallocating a device-local buffer on that cadence would mean either
    /// stalling the queue or deferring destruction on every rebuild.
    /// Blades beyond the source buffer's capacity are dropped, and the caller
    /// is told.
    bool setPopulation(const pipeline::GrassBladeSample* blades, size_t count);

    /// Replace the vegetation profile table the shaders index by blade.
    /// Uploaded whole; there are a few dozen at most.
    bool setProfiles(const std::vector<pipeline::GrassProfile>& profiles);

    /// Profiles the table can hold. Ground effects number in the hundreds but
    /// distinct profiles do not, because they are a blend of five categories -
    /// crossed now with the biome the effect was met in, so the table is
    /// sized for a session that wanders several zones.
    static constexpr uint32_t kMaxProfiles = 128;

    /// Log how many blades the cull kept, once. Diagnostic only.
    void reportCullResult();

    [[nodiscard]] bool isReady() const { return pipeline_ != VK_NULL_HANDLE; }
    [[nodiscard]] uint32_t bladeCount() const { return bladeCount_; }

    /// Blades the source buffer holds, from the capacity initialize() was
    /// given, and the most setPopulation will take.
    [[nodiscard]] uint32_t capacity() const { return capacity_; }

    /// How many blades one configuration wants, before any memory budget is
    /// applied: what the generator would produce over a whole window of
    /// uniformly suitable ground.
    ///
    /// Mirrors the generator's own octave arithmetic. Each ring past the first
    /// holds about as many lattice cells as the one inside it, so a window's
    /// total grows with the log of its radius and not with its area - 387,182
    /// candidates at the default 150 yards, 794,245 at the 2000 the slider
    /// allows. Times the density setting, which is the share of candidates a
    /// cell has to beat to survive.
    static uint32_t bladesFor(float densityScale, float cullDistanceYards);

    /// How many blades to allocate: bladesFor, clamped to kMaxSourceBytes and
    /// kMaxBlades.
    ///
    /// Sized from the grass sliders rather than at the largest field the
    /// generator could ever be asked for. The fixed 1,000,000 this replaced was
    /// 64 MB of source buffer, allocated once at start-up whether grass was on
    /// or not, and it was far more than the widest field can hold: both figures
    /// above are under a million, so the number was never the binding
    /// constraint, the memory it stood for was.
    ///
    /// Clamped to kMaxSourceBytes, because the size it used to ask for is one
    /// the console has already refused: 64 MB was the last thing a Switch boot
    /// did before it died, on a driver that reports a single 2.25 GB
    /// host-visible heap and no device-local memory at all.
    static uint32_t capacityFor(float densityScale, float cullDistanceYards);

    /// Ceiling on the source buffer, in blades, whatever the sliders ask for.
    /// A bound and not a target: the widest window the slider reaches is under
    /// it, and the byte budget below is what normally binds first.
    static constexpr uint32_t kMaxBlades = 1000000;

    /// Ceiling on the source buffer's size, and so on its capacity: 16 MiB is a
    /// quarter of the 64 MB that was refused, and 0.7% of the one heap the
    /// console reports. A field thinned to fit this is whole and evenly sparse,
    /// because the generator's own cap thins every candidate by the same
    /// factor rather than cutting one side of the window off.
    #ifdef WOWEE_SWITCH
    static constexpr uint32_t kMaxSourceBytes = 4u * 1024u * 1024u;
#else
    static constexpr uint32_t kMaxSourceBytes = 16u * 1024u * 1024u;
#endif

    /// Default draw distance, and the radius inside which density never
    /// thins. The grass distance setting replaces the former at runtime via
    /// setCullDistance; the fade band and generation window are derived from
    /// it, so nothing else changes by hand.
    static constexpr float kCullDistance = 45.0f;

    /// Where the height fade begins, as a fraction of the cull distance.
    /// 0.71 of 45 is the 32 the fade always started at.
    static constexpr float kFadeStartFraction = 32.0f / 45.0f;

    /// The grass distance setting. Blades past this never draw, and the
    /// height fade tracks it so the field still thins away rather than
    /// ending on a cut line.
    void setCullDistance(float yards) { cullDistance_ = yards; }
    [[nodiscard]] float cullDistance() const { return cullDistance_; }

private:
    bool createSourceBuffer();
    bool createPerFrameBuffers();
    bool createCullPipeline();
    bool createDrawPipeline(VkDescriptorSetLayout perFrameLayout);
    bool buildDrawPipeline();

    VkContext* vkCtx_ = nullptr;
    VkDescriptorSetLayout perFrameLayout_ = VK_NULL_HANDLE;
    uint32_t bladeCount_ = 0;
    uint32_t capacity_ = 0;
    float cullDistance_ = kCullDistance;
    bool cullReported_ = false;
    uint32_t framesSincePopulated_ = 0;
    bool drawReported_ = false;


    // Shared, written once at load.
    VkBuffer sourceBuffer_ = VK_NULL_HANDLE;
    VmaAllocation sourceAlloc_ = VK_NULL_HANDLE;
    VkBuffer profileBuffer_ = VK_NULL_HANDLE;
    VmaAllocation profileAlloc_ = VK_NULL_HANDLE;
    VkBuffer indexBuffer_ = VK_NULL_HANDLE;
    VmaAllocation indexAlloc_ = VK_NULL_HANDLE;

    // Per frame in flight: the compute shader writes these while the previous
    // frame's copies are still being drawn from.
    static constexpr uint32_t kFrames = MAX_FRAMES_IN_FLIGHT;
    VkBuffer cullUniform_[kFrames]{};
    VmaAllocation cullUniformAlloc_[kFrames]{};
    void* cullUniformMapped_[kFrames]{};
    VkBuffer visibleBuffer_[kFrames]{};
    VmaAllocation visibleAlloc_[kFrames]{};
    VkBuffer indirectBuffer_[kFrames]{};
    VmaAllocation indirectAlloc_[kFrames]{};

    VkDescriptorPool descPool_ = VK_NULL_HANDLE;
    VkDescriptorSetLayout cullSetLayout_ = VK_NULL_HANDLE;
    VkDescriptorSet cullSet_[kFrames]{};
    VkPipelineLayout cullPipelineLayout_ = VK_NULL_HANDLE;
    VkPipeline cullPipeline_ = VK_NULL_HANDLE;

    VkDescriptorSetLayout drawSetLayout_ = VK_NULL_HANDLE;
    VkDescriptorSet drawSet_[kFrames]{};
    VkPipelineLayout pipelineLayout_ = VK_NULL_HANDLE;
    VkPipeline pipeline_ = VK_NULL_HANDLE;
};

} // namespace rendering
} // namespace wowee
