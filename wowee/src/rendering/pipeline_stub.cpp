#include "rendering/pipeline_stub.hpp"
#include "rendering/vk_shader.hpp"
#include "core/logger.hpp"

#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace wowee::rendering {
namespace {

std::once_flag g_skipFlag;
std::vector<std::string> g_skipEntries;

void loadSkipList() {
    std::call_once(g_skipFlag, [] {
        const std::string path = "sdmc:/switch/wowee/skip-shaders.txt";
        std::FILE* file = std::fopen(path.c_str(), "r");
        if (!file) return;   // absent is the normal case, not worth a warning
        char line[256];
        while (std::fgets(line, sizeof line, file)) {
            std::string entry(line);
            const size_t hash = entry.find('#');
            if (hash != std::string::npos) entry.erase(hash);
            while (!entry.empty() && (entry.back() == '\r' || entry.back() == '\n' ||
                                      entry.back() == ' ' || entry.back() == '\t')) {
                entry.pop_back();
            }
            size_t start = 0;
            while (start < entry.size() && (entry[start] == ' ' || entry[start] == '\t')) ++start;
            entry.erase(0, start);
            if (entry.empty()) continue;
            g_skipEntries.push_back(entry);
        }
        std::fclose(file);
        LOG_WARNING("Pipeline skip list: ", g_skipEntries.size(), " entr",
                    g_skipEntries.size() == 1 ? "y" : "ies", " from ", path);
    });
}

}  // namespace

::VkShaderModule StubVertexModule(VkDevice device) {
    // Loaded through the normal shader path, so the stub is a checked-in,
    // validated SPIR-V module like every other shader. The obvious alternative -
    // a hand-assembled empty module - is accepted by vkCreateShaderModule and
    // then rejected at pipeline creation with an opaque error, which is a poor
    // thing to have to debug.
    static ::VkShaderModule module = VK_NULL_HANDLE;
    static bool attempted = false;
    if (!attempted) {
        attempted = true;
        static VkShaderModule vertexStub;
        if (vertexStub.loadFromFile(device, "assets/shaders/stub.vert.spv")) {
            module = vertexStub.getModule();
            LOG_WARNING("Stub vertex shader loaded (stub.vert.spv) - stubbed pipelines draw nothing");
        }
    }
    return module;
}

::VkShaderModule StubFragmentModule(VkDevice device) {
    static ::VkShaderModule module = VK_NULL_HANDLE;
    static bool attempted = false;
    if (!attempted) {
        attempted = true;
        static VkShaderModule fragmentStub;
        if (fragmentStub.loadFromFile(device, "assets/shaders/stub.frag.spv")) {
            module = fragmentStub.getModule();
            LOG_WARNING("Stub fragment shader loaded (stub.frag.spv) - stubbed pipelines draw nothing");
        }
    }
    return module;
}

bool PipelineSkipList::Matches(const char* stageList) {
    loadSkipList();
    if (g_skipEntries.empty() || stageList == nullptr) return false;
    for (const std::string& entry : g_skipEntries) {
        if (std::strstr(stageList, entry.c_str()) != nullptr) return true;
    }
    return false;
}

uint32_t PipelineSkipList::Count() {
    loadSkipList();
    return static_cast<uint32_t>(g_skipEntries.size());
}

}  // namespace wowee::rendering