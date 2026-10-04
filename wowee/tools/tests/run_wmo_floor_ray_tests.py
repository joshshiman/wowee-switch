#!/usr/bin/env python3
"""The downward floor ray must reach the geometry below the probe, and the
report about it must say what actually happened - once.

Compiles the real bodies out of wmo_renderer.cpp (gatherCandidates,
outsideCollisionFocus, withinWorldBounds, buildCollisionGrid,
gatherCellTriangles, getTrianglesInRange, rayAABBRange, rayIntersectsAABB,
trianglesAlongRay, transformAABB, rayReachesFloor, warnOncePerFloorMiss and
getFloorHeight itself) against a synthetic WMO, so the candidate selection and
the triangle test are exercised rather than described.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'src/rendering/wmo_renderer.cpp').read_text()


def slice_body(start_marker, end_marker, start_from=0):
    start = source.index(start_marker, start_from)
    end = source.index(end_marker, start + 1)
    return source[start:end]


def slice_signature(signature):
    """The whole definition that starts with `signature`.

    Some of these have a forward declaration as well as a definition, so the
    occurrence picked is the one whose parameter list is followed by a body -
    otherwise the slice runs from the declaration to the definition and takes
    half the file with it.
    """
    at = source.index(signature)
    while True:
        open_paren = source.index('(', at)
        depth = 0
        i = open_paren
        while True:
            if source[i] == '(':
                depth += 1
            elif source[i] == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        # Trailing `const`/`noexcept` sit between the parameter list and the
        # body, so look for whichever of ';' and '{' ends the declarator first:
        # a ';' is a declaration, a '{' is the definition being looked for.
        terminator = min(p for p in (source.find(';', i), source.find('{', i)) if p != -1)
        if source[terminator] == '{':
            depth = 0
            j = terminator
            while True:
                if source[j] == '{':
                    depth += 1
                elif source[j] == '}':
                    depth -= 1
                    if depth == 0:
                        return source[at:j + 1]
                j += 1
        at = source.index(signature, terminator)


def slice_const(name):
    """The production constant, by name, so the test cannot drift from it."""
    marker = f'constexpr float {name} ='
    start = source.index(marker)
    return source[start:source.index(';', start) + 1]


GATHER_CANDIDATES = slice_signature('void WMORenderer::gatherCandidates(')
OUTSIDE_FOCUS = slice_signature('bool WMORenderer::outsideCollisionFocus(')
WITHIN_BOUNDS = slice_signature('bool WMORenderer::withinWorldBounds(')
BUILD_GRID = slice_signature('void WMORenderer::GroupResources::buildCollisionGrid()')
GATHER_CELLS = slice_signature('void WMORenderer::GroupResources::gatherCellTriangles(')
TRI_IN_RANGE = slice_signature('void WMORenderer::GroupResources::getTrianglesInRange(')
RAY_AABB_RANGE = slice_signature('static bool rayAABBRange(')
RAY_AABB = slice_signature('static bool rayIntersectsAABB(')
TRI_ALONG_RAY = slice_signature('template <typename Group>\nstatic bool trianglesAlongRay(')
TRANSFORM_AABB = slice_signature('static void transformAABB(')
RAY_REACHES = slice_signature('static bool rayReachesFloor(')
WARN_ONCE = slice_signature('static void warnOncePerFloorMiss(')
FLOOR_HEIGHT = slice_signature('std::optional<float> WMORenderer::getFloorHeight(')

WALL_NORMAL_Z = slice_const('kWallMaxAbsNormalZ')
FLOOR_REACH_BELOW = slice_const('kFloorRayReachBelow')
FLOOR_REACH_ABOVE = slice_const('kFloorRayReachAbove')

FIXTURE = r'''
#include "rendering/collision_geometry.hpp"
#include "rendering/spatial_grid.hpp"
#include "rendering/triangle_cell_index.hpp"
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

using namespace wowee::rendering;

// The warning is the thing under test here, so it is counted rather than
// printed. Every other logger call is not reached from the extracted bodies.
static int g_floorMissWarnings = 0;
#define LOG_WARNING(...) (++g_floorMissWarnings)

struct QueryTimer {
    std::atomic<double>* totalMs;
    std::atomic<uint32_t>* callCount;
    QueryTimer(std::atomic<double>* t, std::atomic<uint32_t>* c) : totalMs(t), callCount(c) {}
    ~QueryTimer() {}
};

// File-scope scratch, exactly as the renderer keeps it.
static thread_local std::vector<size_t> tl_candidateScratch;
static thread_local std::vector<uint32_t> tl_triScratch;
static thread_local std::unordered_set<uint32_t> tl_candidateIdScratch;

namespace {
WALL_NORMAL_Z
FLOOR_REACH_BELOW
FLOOR_REACH_ABOVE
}  // namespace

struct WMORenderer {
    struct GroupResources {
        glm::vec3 boundingBoxMin, boundingBoxMax;
        wowee::platform::CpuGeometryVector<glm::vec3> collisionVertices;
        wowee::platform::CpuGeometryVector<uint16_t> collisionIndices;
        static constexpr float COLLISION_CELL_SIZE = 4.0f;
        int gridCellsX = 0, gridCellsY = 0;
        glm::vec2 gridOrigin;
        TriangleCellIndex cellTriangles, cellFloorTriangles, cellWallTriangles;
        struct TriBounds { float minZ, maxZ; };
        std::vector<TriBounds> triBounds;
        std::vector<glm::vec3> triNormals;
        mutable std::vector<uint8_t> triVisited;
        bool noBlockingTriangles = false;

        void buildCollisionGrid();
        void gatherCellTriangles(const TriangleCellIndex& cells, float minX, float minY,
                                 float maxX, float maxY, std::vector<uint32_t>& out) const;
        void getTrianglesInRange(float minX, float minY, float maxX, float maxY,
                                 std::vector<uint32_t>& out) const;
    };

    struct ModelData {
        uint32_t id = 0;
        std::vector<GroupResources> groups;
        glm::vec3 boundingBoxMin, boundingBoxMax;
        bool isLowPlatform = false;
    };

    struct WMOInstance {
        uint32_t id = 0, modelId = 0;
        glm::mat4 modelMatrix{1.0f}, invModelMatrix{1.0f};
        glm::vec3 worldBoundsMin, worldBoundsMax;
        std::vector<std::pair<glm::vec3, glm::vec3>> worldGroupBounds;
        bool isTransport = false;
    };

    struct ActiveGroupInfo {
        uint32_t instanceIdx = UINT32_MAX;
        uint32_t modelId = 0;
        int32_t groupIdx = -1;
        std::vector<uint32_t> neighborGroups;
        [[nodiscard]] bool isValid() const {
            return instanceIdx != UINT32_MAX && groupIdx >= 0;
        }
    };

    std::unordered_map<uint32_t, ModelData> loadedModels;
    std::vector<WMOInstance> instances;
    SpatialGrid spatialGrid;
    std::unordered_map<uint32_t, size_t> instanceIndexById;
    CollisionFocus collisionFocus;
    mutable ActiveGroupInfo activeGroup_;
    mutable std::atomic<double> queryTimeMs{0.0};
    mutable std::atomic<uint32_t> queryCallCount{0};

    void gatherCandidates(const glm::vec3&, const glm::vec3&, std::vector<size_t>&) const;
    bool outsideCollisionFocus(const WMOInstance&) const;
    bool withinWorldBounds(const WMOInstance&, float, float, float,
                           float = 0.0f, float = 0.0f) const;
    std::optional<float> getFloorHeight(float, float, float, float* = nullptr,
                                        float = std::numeric_limits<float>::quiet_NaN(),
                                        float = 0.0f) const;
};

GATHER_CANDIDATES
OUTSIDE_FOCUS
WITHIN_BOUNDS
BUILD_GRID
GATHER_CELLS
TRI_IN_RANGE
RAY_AABB_RANGE
RAY_AABB
TRI_ALONG_RAY
TRANSFORM_AABB
RAY_REACHES
WARN_ONCE
FLOOR_HEIGHT

// ---- synthetic world ------------------------------------------------------

// A flat horizontal quad, given by its four world-space corners, filed into
// whichever instance/model/group is current. Exactly the shape of the geometry
// a roof, a bridge deck or a paved square is.
static void addQuad(WMORenderer::GroupResources& group, const WMORenderer::WMOInstance& inst,
                    const glm::vec3& a, const glm::vec3& b, const glm::vec3& c,
                    const glm::vec3& d) {
    const uint16_t base = static_cast<uint16_t>(group.collisionVertices.size());
    for (const glm::vec3& w : {a, b, c, d}) {
        group.collisionVertices.push_back(
            glm::vec3(inst.invModelMatrix * glm::vec4(w, 1.0f)));
    }
    // Local-space winding: the grid sorts floors and walls by |normal.z|, and
    // getFloorHeight accepts the triangle either way round.
    for (uint16_t i : {0, 1, 2, 0, 2, 3}) {
        group.collisionIndices.push_back(static_cast<uint16_t>(base + i));
    }
    if (group.collisionVertices.size() == 4) {
        group.boundingBoxMin = glm::min(glm::min(a, b), glm::min(c, d));
        group.boundingBoxMax = glm::max(glm::max(a, b), glm::max(c, d));
        group.boundingBoxMin = glm::vec3(group.collisionVertices[0]);
        group.boundingBoxMax = group.boundingBoxMin;
        for (const glm::vec3& v : group.collisionVertices) {
            group.boundingBoxMin = glm::min(group.boundingBoxMin, v);
            group.boundingBoxMax = glm::max(group.boundingBoxMax, v);
        }
    } else {
        group.boundingBoxMin = glm::min(group.boundingBoxMin,
            glm::vec3(inst.invModelMatrix * glm::vec4(glm::min(glm::min(a, b), glm::min(c, d)), 1.0f)));
        group.boundingBoxMax = glm::max(group.boundingBoxMax,
            glm::vec3(inst.invModelMatrix * glm::vec4(glm::max(glm::max(a, b), glm::max(c, d)), 1.0f)));
    }
}

static size_t addInstance(WMORenderer& r, const glm::vec3& position,
                          const glm::vec3& rotationRadians = glm::vec3(0.0f)) {
    WMORenderer::WMOInstance inst;
    inst.id = static_cast<uint32_t>(r.instances.size());
    inst.modelId = 7;
    glm::mat4 m = glm::translate(glm::mat4(1.0f), position);
    if (rotationRadians.z != 0.0f) m *= glm::rotate(m, rotationRadians.z, glm::vec3(0, 0, 1));
    if (rotationRadians.y != 0.0f) m *= glm::rotate(m, rotationRadians.y, glm::vec3(0, 1, 0));
    if (rotationRadians.x != 0.0f) m *= glm::rotate(m, rotationRadians.x, glm::vec3(1, 0, 0));
    inst.modelMatrix = m;
    inst.invModelMatrix = glm::inverse(inst.modelMatrix);
    r.instances.push_back(inst);
    r.instanceIndexById.emplace(inst.id, r.instances.size() - 1);
    return r.instances.size() - 1;
}

// Publish the group the way createInstance/refreshInstanceBounds do: the world
// group bounds are the transformed local collision AABB, padded half a yard.
static void publishGroups(WMORenderer& r, size_t instanceIdx) {
    auto& inst = r.instances[instanceIdx];
    auto& model = r.loadedModels[inst.modelId];
    inst.worldGroupBounds.clear();
    glm::vec3 modelMin(1e30f), modelMax(-1e30f);
    for (auto& g : model.groups) {
        g.buildCollisionGrid();
        glm::vec3 lo, hi;
        transformAABB(inst.modelMatrix, g.boundingBoxMin, g.boundingBoxMax, lo, hi);
        lo -= glm::vec3(0.5f);
        hi += glm::vec3(0.5f);
        inst.worldGroupBounds.emplace_back(lo, hi);
        modelMin = glm::min(modelMin, lo);
        modelMax = glm::max(modelMax, hi);
    }
    inst.worldBoundsMin = modelMin;
    inst.worldBoundsMax = modelMax;
    model.boundingBoxMin = modelMin;
    model.boundingBoxMax = modelMax;
    insertBounds(r.spatialGrid, inst.worldBoundsMin, inst.worldBoundsMax, inst.id);
}

// A single square building whose deck spans [cx-half, cx+half] x [cy-half, ...]
// at `deckZ`, placed at (cx, cy, 0).
static void addFlatBuilding(WMORenderer& r, const glm::vec3& centre, float half,
                            float deckZ, const glm::vec3& rotation = glm::vec3(0.0f)) {
    const size_t idx = addInstance(r, glm::vec3(centre.x, centre.y, 0.0f), rotation);
    auto& inst = r.instances[idx];
    auto& model = r.loadedModels[inst.modelId];
    model.id = inst.modelId;
    WMORenderer::GroupResources group;
    // Only the deck: two triangles, both walkable.
    addQuad(group, inst,
            glm::vec3(centre.x - half, centre.y - half, deckZ),
            glm::vec3(centre.x + half, centre.y - half, deckZ),
            glm::vec3(centre.x + half, centre.y + half, deckZ),
            glm::vec3(centre.x - half, centre.y + half, deckZ));
    model.groups.push_back(std::move(group));
    publishGroups(r, idx);
}

static bool near(float a, float b) { return std::abs(a - b) < 0.01f; }

int main() {
    // ---- 1. A roof ten yards below the probe is still a floor. -----------
    // The log's second variant, verbatim: query z=96.0916, a building whose
    // bounds are z=[51.9749..86.0916]. The building does not contain the query
    // POINT, and it does contain the RAY - and its deck is a legal hit because
    // it is below the probe. The old point-inside-window test threw it away and
    // the answer was "no floor".
    {
        WMORenderer r;
        addFlatBuilding(r, glm::vec3(-9205.0f, -653.0f, 0.0f), 8.0f, 86.0916f);
        float nz = -1.0f;
        auto h = r.getFloorHeight(-9205.0f, -653.0f, 96.0916f, &nz);
        assert(h && "a deck ten yards below the probe is a floor");
        assert(near(*h, 86.0916f));
        assert(nz > 0.99f);
    }

    // ---- 2. Deck just below the probe, and deck level with it. -----------
    {
        WMORenderer r;
        addFlatBuilding(r, glm::vec3(100.0f, 200.0f, 0.0f), 6.0f, 90.0f);
        assert(near(*r.getFloorHeight(100.0f, 200.0f, 93.0f), 90.0f));
        assert(near(*r.getFloorHeight(100.0f, 200.0f, 92.0f), 90.0f));
    }

    // ---- 3. Another storey down is still not this floor. -----------------
    // The far-below guard the point window used to provide, now carried by the
    // ray's own reach: the query must not start answering with a deck well
    // under the character on a street with no floor of its own. The bound is
    // finite on purpose - "highest floor at or below the probe" only reaches
    // this far down when there is nothing nearer.
    {
        WMORenderer r;
        addFlatBuilding(r, glm::vec3(100.0f, 200.0f, 0.0f), 6.0f, 70.0f);
        assert(!r.getFloorHeight(100.0f, 200.0f, 96.0f));
        // ...and just inside it, it does answer, because the ray gets there.
        addFlatBuilding(r, glm::vec3(300.0f, 400.0f, 0.0f), 6.0f, 80.0f);
        assert(near(*r.getFloorHeight(300.0f, 400.0f, 96.0f), 80.0f));
    }

    // ---- 4. Outside the footprint in XY: no floor, and nothing said. -----
    // This is the stormwind case that produced 143 identical lines a run.
    // One WMO holds the whole city, so its header box - the only thing
    // overlappedInXY ever asked about - covers every street in it, while no
    // group of it has anything on this one. Nothing was ever considered, so
    // nothing is reported: the old message claimed a building "was considered"
    // and "no triangle was hit", which is a different bug from either.
    {
        WMORenderer r;
        addFlatBuilding(r, glm::vec3(400.0f, 400.0f, 0.0f), 6.0f, 90.0f);
        g_floorMissWarnings = 0;
        assert(!r.getFloorHeight(-8949.95f, -132.493f, 84.6308f));
        assert(g_floorMissWarnings == 0);
    }

    // ---- 5. Considered, tested, missed: said, and said once. ------------
    // A group whose world bounds do cover the spot, with no triangle under it.
    // That is a real fault worth a line - but the query is asked every frame
    // for as long as the character stands there, so it must not become one
    // line per second for the rest of the session.
    {
        WMORenderer r;
        const size_t idx = addInstance(r, glm::vec3(0.0f, 0.0f, 0.0f));
        auto& inst = r.instances[idx];
        auto& model = r.loadedModels[inst.modelId];
        model.id = inst.modelId;
        WMORenderer::GroupResources group;
        // A deck twenty yards away, inside a group box that spans the query.
        // The box is widened with vertices no triangle uses, which is how a
        // group comes to cover more ground than its floor does: createGroupResources
        // fits the box to the collision vertices, and a group with struts and
        // doorframes has vertices at its corners.
        addQuad(group, inst,
                glm::vec3(20.0f, 20.0f, 85.0f), glm::vec3(26.0f, 20.0f, 85.0f),
                glm::vec3(26.0f, 26.0f, 85.0f), glm::vec3(20.0f, 26.0f, 85.0f));
        for (float z : {80.0f, 100.0f}) {
            for (float x : {-40.0f, 40.0f}) {
                for (float y : {-40.0f, 40.0f}) {
                    group.collisionVertices.push_back(
                        glm::vec3(inst.invModelMatrix * glm::vec4(x, y, z, 1.0f)));
                }
            }
        }
        group.boundingBoxMin = glm::vec3(-40.0f, -40.0f, 80.0f);
        group.boundingBoxMax = glm::vec3(40.0f, 40.0f, 100.0f);
        model.groups.push_back(std::move(group));
        publishGroups(r, idx);

        g_floorMissWarnings = 0;
        for (int i = 0; i < 600; ++i) {
            assert(!r.getFloorHeight(0.0f, 0.0f, 90.0f));
        }
        assert(g_floorMissWarnings == 1);
        // A different height is a different question, and gets its own line.
        assert(!r.getFloorHeight(0.0f, 0.0f, 95.0f));
        assert(g_floorMissWarnings == 2);
        // ...and back to the first spot, which is already known.
        assert(!r.getFloorHeight(0.0f, 0.0f, 90.0f));
        assert(g_floorMissWarnings == 2);
    }

    // ---- 6. A pitched placement still finds its deck. -------------------
    // The leaning-local-ray case the per-group search along the ray exists for:
    // the ray starts five hundred units above and only a pitched model makes
    // that matter, so it is the one case a change to the culls must not break.
    {
        WMORenderer r;
        addFlatBuilding(r, glm::vec3(500.0f, 500.0f, 0.0f), 6.0f, 70.0f,
                        glm::vec3(glm::radians(9.0f), 0.0f, 0.0f));
        assert(near(*r.getFloorHeight(500.0f, 500.0f, 78.0f), 70.0f));
    }

    // ---- 7. WithinWorldBounds is untouched and still point-in-box. ------
    // Two call sites still want the containment question (transport riders,
    // isInsideWMOGroups), so it must keep meaning what it said.
    {
        WMORenderer r;
        const size_t idx = addInstance(r, glm::vec3(0.0f, 0.0f, 0.0f));
        auto& inst = r.instances[idx];
        inst.worldBoundsMin = glm::vec3(-10.0f, -10.0f, 100.0f);
        inst.worldBoundsMax = glm::vec3(10.0f, 10.0f, 110.0f);
        assert(r.withinWorldBounds(inst, 0.0f, 0.0f, 105.0f));
        assert(r.withinWorldBounds(inst, 0.0f, 0.0f, 114.0f, 0.0f, 4.0f));
        assert(!r.withinWorldBounds(inst, 0.0f, 0.0f, 96.0f));
        assert(!r.withinWorldBounds(inst, 0.0f, 0.0f, 120.0f));
    }

    std::cout << "PASS wmo floor ray: roof below the probe is a floor, "
                 "another storey down is not, an instance header box over a "
                 "city street is not evidence of anything, a considered miss "
                 "is said once per spot, pitched placements still find their "
                 "deck, containment queries unchanged\n";
    return 0;
}
'''.replace('WALL_NORMAL_Z', WALL_NORMAL_Z) \
   .replace('FLOOR_REACH_BELOW', FLOOR_REACH_BELOW) \
   .replace('FLOOR_REACH_ABOVE', FLOOR_REACH_ABOVE) \
   .replace('GATHER_CANDIDATES', GATHER_CANDIDATES) \
   .replace('OUTSIDE_FOCUS', OUTSIDE_FOCUS) \
   .replace('WITHIN_BOUNDS', WITHIN_BOUNDS) \
   .replace('BUILD_GRID', BUILD_GRID) \
   .replace('GATHER_CELLS', GATHER_CELLS) \
   .replace('TRI_IN_RANGE', TRI_IN_RANGE) \
   .replace('RAY_AABB_RANGE', RAY_AABB_RANGE) \
   .replace('RAY_AABB', RAY_AABB) \
   .replace('TRI_ALONG_RAY', TRI_ALONG_RAY) \
   .replace('TRANSFORM_AABB', TRANSFORM_AABB) \
   .replace('RAY_REACHES', RAY_REACHES) \
   .replace('WARN_ONCE', WARN_ONCE) \
   .replace('FLOOR_HEIGHT', FLOOR_HEIGHT)


def main():
    with tempfile.TemporaryDirectory(prefix='wowps-wmo-floor-ray-') as tmp:
        cpp = Path(tmp) / 'test.cpp'
        exe = Path(tmp) / 'test'
        cpp.write_text(FIXTURE)
        subprocess.run([
            os.environ.get('CXX', 'c++'), '-std=c++20', '-O1', '-g',
            '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
            '-DGLM_ENABLE_EXPERIMENTAL', '-DGLM_FORCE_DEPTH_ZERO_TO_ONE',
            '-I' + str(root / 'include'), '-I' + str(root / 'extern/glm'),
            str(cpp), '-o', str(exe),
        ], check=True)
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
        subprocess.run([str(exe)], check=True, env=env)


if __name__ == '__main__':
    main()