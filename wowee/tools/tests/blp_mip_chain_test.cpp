// A BLP mip chain the 3.3.5a encoder cannot express, and the upload that
// refused it.
//
// 3.3.5a sizes each mip level from floor(w/4)*floor(h/4) blocks, clamped up to
// one block, instead of the ceil the format needs. A level whose extent is not a
// multiple of four in both axes therefore comes out short: an 8x2 level of a
// 128x32 DXT1 gets one block where two are needed, a 2x8 level of a 16x64 gets
// one as well. Both base dimensions are perfectly ordinary multiples of four -
// it is halving that produces the level with the odd extent, three to five
// levels down on the way to 1x1.
//
// The loader used to hand the whole chain over, and VkTexture::uploadMips
// rejected it in textureUploadLayout because a level was smaller than the
// region it would have been copied into, so the texture never uploaded and the
// model drew untextured. This checks that the loader now hands over the chain it
// can actually fill, and that the result is accepted by the same validator
// that rejected it.
//
// Every fixture below is a header read out of the vanilla 3.3.5a data - magic,
// compression, alpha fields, extent, mipOffsets and mipSizes, with the levels
// laid end to end from the end of the header exactly as the encoder wrote them.
// The payload is filler, which no assertion here looks at: it is the declared
// level sizes that the block upload turns on.
//
//   World\Generic\Orc\Passive Doodads\Bones\Bone02.blp   3924 B, DXT1 128x32
//     sizes 2048 512 128 32 8 8 8 8   -> short at level 4, 8x2, 8 B against 16
//   World\Generic\Human\Passive Doodads\CaveminePump\Lever3.blp 1876 B, DXT1 16x64
//     sizes  512 128  32 8 8 8 8      -> short at level 3, 2x8, 8 B against 16
//   Item\ObjectComponents\Weapon\Bow_1H_Blood_B_01Blue.blp 23060 B, DXT3 256x64
//     sizes 16384 4096 1024 256 64 16 16 16 16 -> short at level 5, 8x2
//   Environments\Stars\HellFireLightning01.blp 88596 B, DXT5 512x128
//     sizes 65536 16384 4096 1024 256 64 16 16 16 16 -> short at level 6, 8x2
//   Item\ObjectComponents\Weapon\Bow_1H_Blood_A_01Red.blp, DXT1 256x32
//     sizes 4096 1024 256 64 8 8 8 8 8  -> short at levels 4 and 5, 16x2 and 8x1
//   World\Generic\Human\Passive Doodads\Stormwind\StormwindBanner01 copy.blp,
//     DXT1 64x512
//     sizes 16384 4096 1024 256 64 8 8 8 8 8 -> short at levels 5 and 6, 2x16, 1x8
#include "pipeline/blp_loader.hpp"
#include "rendering/texture_upload_layout.hpp"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <vector>

using namespace wowee::pipeline;
using wowee::rendering::TextureUploadLevel;

namespace {

constexpr uint32_t kHeaderBytes = 1172;  // BLP2 header, through the 256-entry palette

void put32(uint8_t* at, uint32_t value) {
    at[0] = static_cast<uint8_t>(value);
    at[1] = static_cast<uint8_t>(value >> 8);
    at[2] = static_cast<uint8_t>(value >> 16);
    at[3] = static_cast<uint8_t>(value >> 24);
}

/// Rebuild a BLP2 the way the 3.3.5a encoder writes one: levels laid end to end
/// from the end of the header, in the order and with the sizes given.
std::vector<uint8_t> blp2(uint8_t compression, uint8_t alphaDepth, uint8_t alphaEncoding,
                          uint32_t width, uint32_t height,
                          const std::vector<uint32_t>& levelSizes) {
    std::vector<uint8_t> bytes(kHeaderBytes, 0);
    std::copy_n(reinterpret_cast<const char*>("BLP2"), 4,
                reinterpret_cast<char*>(bytes.data()));
    put32(bytes.data() + 4, 1);                          // version
    bytes[8] = compression;
    bytes[9] = alphaDepth;
    bytes[10] = alphaEncoding;
    bytes[11] = 1;                                       // hasMips
    put32(bytes.data() + 12, width);
    put32(bytes.data() + 16, height);
    uint32_t offset = kHeaderBytes;
    for (size_t level = 0; level < levelSizes.size(); ++level) {
        put32(bytes.data() + 20 + level * 4, offset);
        put32(bytes.data() + 84 + level * 4, levelSizes[level]);
        for (uint32_t i = 0; i < levelSizes[level]; ++i)
            bytes.push_back(static_cast<uint8_t>((level * 37 + i * 11) & 0xFF));
        offset += levelSizes[level];
    }
    return bytes;
}

/// Whether VkTexture::uploadMips would accept this chain: the same call, with
/// the same block geometry, that logged "invalid dimensions or truncated mip
/// chain" for every one of these textures.
bool uploadAccepts(uint32_t width, uint32_t height, uint32_t blockBytes,
                   const std::vector<const uint8_t*>& data,
                   const std::vector<uint32_t>& sizes) {
    std::vector<TextureUploadLevel> layout;
    uint64_t total = 0;
    return wowee::rendering::textureUploadLayout(width, height, 4, 4, blockBytes,
                                                 data.data(), sizes.data(),
                                                 static_cast<uint32_t>(sizes.size()),
                                                 layout, total);
}

unsigned cases = 0;

void checkChain(const char* what, const std::vector<uint8_t>& file, uint32_t expectedWidth,
                uint32_t expectedHeight, uint32_t blockBytes, size_t expectedLevels,
                uint32_t expectedBaseBytes) {
    // Kept compressed, so the level pointers stay inside `file` for this whole
    // function - a BLPImage built from a temporary would outlive nothing.
    const BLPImage image = BLPLoader::load(file, /*keepCompressed=*/true);
    assert(image.isValid());
    assert(image.isBlockCompressed());
    assert(image.width == static_cast<int>(expectedWidth));
    assert(image.height == static_cast<int>(expectedHeight));
    assert(image.mipLevels == static_cast<int>(expectedLevels));
    assert(image.mipmaps.size() == expectedLevels);
    assert(static_cast<uint32_t>(image.mipmaps[0].size()) == expectedBaseBytes);

    // Every kept level holds what its own extent needs, and the chain is a
    // prefix of the halving chain, so the upload cannot be refused.
    std::vector<const uint8_t*> data;
    std::vector<uint32_t> sizes;
    uint32_t w = expectedWidth, h = expectedHeight;
    for (size_t level = 0; level < image.mipmaps.size(); ++level) {
        assert(image.mipmaps[level].size() >= size_t((w + 3) / 4) * ((h + 3) / 4) * blockBytes);
        data.push_back(image.mipmaps[level].data());
        sizes.push_back(static_cast<uint32_t>(image.mipmaps[level].size()));
        w = std::max(1u, w / 2);
        h = std::max(1u, h / 2);
    }
    assert(uploadAccepts(expectedWidth, expectedHeight, blockBytes, data, sizes));
    ++cases;
    std::printf("  %-24s %4ux%-4u %s: %zu level(s), base %zu B, upload accepted\n",
                what, expectedWidth, expectedHeight,
                BLPLoader::getCompressionName(image.compression),
                image.mipmaps.size(), image.mipmaps[0].size());
}

/// Every level the file holds, as uploadMips would have been handed them before
/// the loader checked any of them.
bool uploadAcceptsWholeChain(uint32_t width, uint32_t height, uint32_t blockBytes,
                             const std::vector<uint32_t>& levelSizes) {
    std::vector<const uint8_t*> data;
    std::vector<uint32_t> sizes;
    for (uint32_t size : levelSizes) {
        data.push_back(reinterpret_cast<const uint8_t*>("x"));
        sizes.push_back(size);
    }
    return uploadAccepts(width, height, blockBytes, data, sizes);
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    // --- The two textures the desktop log named. Both keep every level above the
    // short one, at full resolution: nothing is lost but the tail.
    const auto bone = blp2(2, 0, 0, 128, 32, {2048, 512, 128, 32, 8, 8, 8, 8});
    checkChain("Bone02.blp", bone, 128, 32, 8, 4, 2048);
    const auto lever = blp2(2, 0, 0, 16, 64, {512, 128, 32, 8, 8, 8, 8});
    checkChain("Lever3.BLP", lever, 16, 64, 8, 3, 512);

    // Proof the rejection was real and not a theory: handing uploadMips the
    // whole chain, unpruned, is exactly what it refused before.
    assert(!uploadAcceptsWholeChain(128, 32, 8, {2048, 512, 128, 32, 8, 8, 8, 8}));
    assert(!uploadAcceptsWholeChain(16, 64, 8, {512, 128, 32, 8, 8, 8, 8}));

    // --- The same shape at the other block sizes.
    {
        const auto dxt3 = blp2(2, 8, 1, 256, 64, {16384, 4096, 1024, 256, 64, 16, 16, 16, 16});
        checkChain("Bow_1H_Blood_B_01Blue", dxt3, 256, 64, 16, 5, 16384);
        assert(BLPLoader::load(dxt3, true).compression == BLPCompression::DXT3);
    }
    {
        const auto dxt5 = blp2(2, 8, 7, 512, 128,
                               {65536, 16384, 4096, 1024, 256, 64, 16, 16, 16, 16});
        checkChain("HellFireLightning01", dxt5, 512, 128, 16, 6, 65536);
        assert(BLPLoader::load(dxt5, true).compression == BLPCompression::DXT5);
    }
    // Two short levels in a row, so the chain has to stop at the first and not
    // resume: a prefix, never a gap.
    {
        const auto bow = blp2(2, 0, 0, 256, 32, {4096, 1024, 256, 64, 8, 8, 8, 8, 8});
        checkChain("Bow_1H_Blood_A_01Red", bow, 256, 32, 8, 4, 4096);
    }
    {
        const auto banner = blp2(2, 0, 0, 64, 512,
                                 {16384, 4096, 1024, 256, 64, 8, 8, 8, 8, 8});
        checkChain("StormwindBanner01 copy", banner, 64, 512, 8, 5, 16384);
    }

    // --- Nothing above is allowed to cost a healthy chain a level, square or not.
    {
        const auto square = blp2(2, 0, 0, 256, 256,
                                 {32768, 8192, 2048, 512, 128, 32, 8, 8, 8});
        checkChain("256x256 complete", square, 256, 256, 8, 9, 32768);
    }
    {
        // 64x16 halves to 32x8, 16x4, 8x2, 4x1, 2x1, 1x1 - and 8x2 here is
        // complete, because 16-byte-per-block files store it as two blocks. The
        // aspect ratio is not what makes a chain short; a stored level size
        // below the extent is.
        const auto wide = blp2(2, 0, 0, 64, 16, {512, 128, 32, 16, 8, 8, 8});
        checkChain("64x16 complete", wide, 64, 16, 8, 7, 512);
    }

    // --- The base level is never silently short. Decoders read through a bounds
    // check of their own, so a clipped mip 0 used to become a texture whose
    // lower half was whatever followed it in the file.
    assert(!BLPLoader::load(blp2(2, 0, 0, 64, 64, {2048 - 1}), true).isValid());
    assert(!BLPLoader::load(blp2(1, 8, 0, 64, 64, {4096}), false).isValid());
    assert(!BLPLoader::load(blp2(3, 8, 0, 64, 64, {4096}), false).isValid());
    // A whole missing mip 0 is the same failure one step earlier.
    assert(!BLPLoader::load(blp2(2, 0, 0, 64, 64, {}), true).isValid());
    // Palette at 8-bit alpha wants an index plane and an alpha plane; half of
    // that is not a palette image, and all of it is.
    assert(!BLPLoader::load(blp2(1, 8, 0, 64, 64, {4096 + 4096 - 1}), false).isValid());
    assert(BLPLoader::load(blp2(1, 8, 0, 64, 64, {4096 + 4096}), false).isValid());
    // ... and with no alpha channel at all it wants the index plane alone.
    assert(!BLPLoader::load(blp2(1, 0, 0, 64, 64, {4096 - 1}), false).isValid());
    assert(BLPLoader::load(blp2(1, 0, 0, 64, 64, {4096}), false).isValid());

    // --- And the decode path is unchanged by any of this: the same 128x32 file
    // decoded gives the same full-resolution pixels the blocks decode to.
    {
        const BLPImage decoded = BLPLoader::load(bone, /*keepCompressed=*/false);
        assert(decoded.isValid());
        assert(!decoded.isBlockCompressed());
        assert(decoded.width == 128 && decoded.height == 32);
        assert(decoded.data.size() == 128u * 32u * 4u);
        const std::vector<uint8_t> fromBlocks =
            BLPLoader::decodeBaseLevel(BLPLoader::load(bone, true));
        assert(fromBlocks == decoded.data);
    }

    std::printf("PASS %u BLP mip chains: 3.3.5a's floor-product level sizes no longer refuse "
                "the block upload; mip 0 is checked for every format, a complete chain keeps "
                "every level, and the decode path is unchanged\n", cases);
    return 0;
}
