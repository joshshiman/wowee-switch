// audio_backend_switch.cpp - miniaudio custom backend on libnx audout.
//
// One playback device: the default audout output, 48 kHz stereo s16,
// 1024-frame grains (one 0x1000-aligned page, the granularity audout
// requires). miniaudio's default audio thread calls onDeviceWrite() with one
// period at a time; audoutPlayBuffer blocks until the grain has been
// consumed, which paces the thread.
#include "platform/switch/audio_backend_switch.hpp"
#include "platform/switch/switch_platform.hpp"

#include "core/logger.hpp"

#include <switch.h>   // the C-linkage master header; audout lives under it

#include <cstring>
#include <cstdio>

#include "miniaudio.h"   // declarations only (MINIAUDIO_IMPLEMENTATION lives in audio_engine.cpp)

namespace {

constexpr ma_uint32 kSampleRate = 48000;
constexpr ma_uint32 kChannels = 2;
constexpr ma_uint32 kGrainFrames = 1024;

struct PortState {
    bool opened = false;
    bool started = false;
    bool inFlight = false;
    alignas(0x1000) uint8_t grain[kGrainFrames * kChannels * sizeof(int16_t)];
};
PortState g_port;   // one device per process

constexpr size_t kGrainBytes = kGrainFrames * kChannels * sizeof(int16_t);

// audout reads a buffer when it is played, not when it is queued, so the grain
// cannot be rewritten until audout has released it. Waiting here also paces
// the audio thread: the wait returns as soon as the grain finishes.
bool waitForGrainRelease() {
    if (!g_port.inFlight) {
        return true;
    }
    AudioOutBuffer* released = nullptr;
    u32 releasedCount = 0;
    const Result rc = audoutWaitPlayFinish(&released, &releasedCount, 1000000000ULL);
    g_port.inFlight = false;
    return R_SUCCEEDED(rc) || releasedCount > 0;
}

ma_result ctxInit(ma_context* pContext, const ma_context_config*, ma_backend_callbacks* pCallbacks) {
    (void)pContext;
    // audoutInitialize opens the default "DeviceOut" (48 kHz, 2ch, Int16) and
    // registers the buffer-completion event; audoutGet* below reads back what
    // it negotiated.
    if (R_FAILED(audoutInitialize())) {
        LOG_ERROR("audoutInitialize failed");
        wowee::platform::switchport::reportBootStage("audio: audout context FAILED");
        return MA_FAILED_TO_INIT_BACKEND;
    }
    wowee::platform::switchport::miniaudioBackendCallbacks(*pCallbacks);
    wowee::platform::switchport::reportBootStage("audio: audout context open");
    return MA_SUCCESS;
}

ma_result ctxUninit(ma_context*) {
    audoutExit();
    return MA_SUCCESS;
}

ma_result ctxEnumerateDevices(ma_context* pContext, ma_enum_devices_callback_proc callback, void* pUserData) {
    ma_device_info info;
    std::memset(&info, 0, sizeof info);
    std::strncpy(info.name, "switch main audio output", sizeof(info.name) - 1);
    info.isDefault = MA_TRUE;
    callback(pContext, ma_device_type_playback, &info, pUserData);
    return MA_SUCCESS;
}

ma_result ctxGetDeviceInfo(ma_context*, ma_device_type deviceType, const ma_device_id*, ma_device_info* pDeviceInfo) {
    if (deviceType != ma_device_type_playback) return MA_NO_DEVICE;
    std::memset(pDeviceInfo, 0, sizeof *pDeviceInfo);
    std::strncpy(pDeviceInfo->name, "switch main audio output", sizeof(pDeviceInfo->name) - 1);
    pDeviceInfo->isDefault = MA_TRUE;
    pDeviceInfo->nativeDataFormatCount = 1;
    pDeviceInfo->nativeDataFormats[0].format = ma_format_s16;
    pDeviceInfo->nativeDataFormats[0].channels = kChannels;
    pDeviceInfo->nativeDataFormats[0].sampleRate = kSampleRate;
    pDeviceInfo->nativeDataFormats[0].flags = 0;
    return MA_SUCCESS;
}

ma_result devInit(ma_device* pDevice, const ma_device_config* pConfig, ma_device_descriptor* pDescriptorPlayback, ma_device_descriptor* pDescriptorCapture) {
    (void)pDevice;
    if (pConfig->deviceType != ma_device_type_playback || !pDescriptorPlayback) {
        LOG_ERROR("switch audio backend: only playback devices are supported");
        return MA_DEVICE_TYPE_NOT_SUPPORTED;
    }
    (void)pDescriptorCapture;
    if (g_port.opened) return MA_ALREADY_EXISTS;

    const u32 rate = audoutGetSampleRate();
    const u32 channels = audoutGetChannelCount();
    const PcmFormat format = audoutGetPcmFormat();
    if (rate != kSampleRate || channels != kChannels || format != PcmFormat_Int16) {
        LOG_ERROR("audout opened at ", rate, "Hz/", channels, "ch/format ", static_cast<int>(format),
                  "; expected ", kSampleRate, "Hz/", kChannels, "ch/Int16");
        wowee::platform::switchport::reportBootStage("audio: device init FAILED (format mismatch)");
        return MA_FAILED_TO_OPEN_BACKEND_DEVICE;
    }
    g_port.opened = true;

    pDescriptorPlayback->format = ma_format_s16;
    pDescriptorPlayback->channels = kChannels;
    pDescriptorPlayback->sampleRate = kSampleRate;
    ma_channel_map_init_standard(ma_standard_channel_map_default, pDescriptorPlayback->channelMap,
                                 (ma_uint32)(sizeof(pDescriptorPlayback->channelMap) / sizeof(pDescriptorPlayback->channelMap[0])), kChannels);
    pDescriptorPlayback->periodSizeInFrames = kGrainFrames;
    pDescriptorPlayback->periodSizeInMilliseconds = 0;
    pDescriptorPlayback->periodCount = 2;
    LOG_INFO("switch audio: audout open (48 kHz stereo s16, 1024-frame grains)");
    // Boot-stage crumbs bracket the whole device lifecycle because the client
    // log is pinned to WARNING and the engine can report audio=ok while the
    // device thread never reaches a write - exactly the silent-audio shape
    // seen on the console. "context open" + "device init" without "device
    // start" (or without "first device write" after a start) names the stage
    // that died without another run.
    wowee::platform::switchport::reportBootStage("audio: device init ok");
    return MA_SUCCESS;
}

ma_result devUninit(ma_device*) {
    if (g_port.opened) {
        waitForGrainRelease();
        audoutStopAudioOut();
        g_port.opened = false;
    }
    g_port.started = false;
    return MA_SUCCESS;
}

ma_result devStart(ma_device*) {
    if (R_FAILED(audoutStartAudioOut())) {
        LOG_ERROR("audoutStartAudioOut failed");
        wowee::platform::switchport::reportBootStage("audio: device start FAILED");
        return MA_ERROR;
    }
    g_port.started = true;
    wowee::platform::switchport::reportBootStage("audio: device start ok");
    return MA_SUCCESS;
}

ma_result devStop(ma_device*) {
    g_port.started = false;
    waitForGrainRelease();
    audoutStopAudioOut();
    return MA_SUCCESS;
}

ma_result devWrite(ma_device* pDevice, const void* pFrames, ma_uint32 frameCount, ma_uint32* pFramesWritten) {
    (void)pDevice;
    if (pFramesWritten) *pFramesWritten = 0;
    if (!g_port.opened) return MA_DEVICE_NOT_INITIALIZED;
    const char* src = static_cast<const char*>(pFrames);
    ma_uint32 done = 0;
    static bool firstWriteReported = false;
    if (!firstWriteReported) {
        firstWriteReported = true;
        wowee::platform::switchport::registerCrashReportingThread("audio device");
        wowee::platform::switchport::reportBootStage("audio: first device write");
    }
    while (done < frameCount) {
        ma_uint32 n = frameCount - done;
        if (n > kGrainFrames) n = kGrainFrames;
        std::memcpy(g_port.grain, src + (size_t)done * kChannels * sizeof(int16_t), (size_t)n * kChannels * sizeof(int16_t));
        if (n < kGrainFrames) {
            std::memset(g_port.grain + (size_t)n * kChannels * sizeof(int16_t), 0, (size_t)(kGrainFrames - n) * kChannels * sizeof(int16_t));
        }
        AudioOutBuffer buf{};
        buf.buffer = g_port.grain;
        buf.buffer_size = (u64)kGrainBytes;
        buf.data_size = (u64)kGrainBytes;
        AudioOutBuffer* released = nullptr;
        // No pre-wait here. libnx's audoutPlayBuffer is documented as
        // "Submits an audio sample data buffer for playing and waits for it to
        // finish playing", and it calls audoutAppendAudioOutBuffer then
        // audoutWaitPlayFinish internally, so it already blocks until the
        // hardware has consumed this buffer and already harvests the release
        // on the way out. Gating on our own in-flight flag double-waited: the
        // wait found the buffer already harvested, so it sat out its full
        // second and returned false, which made devWrite fail and miniaudio
        // close the device after a single grain of sound. The flag is kept for
        // devStop's drain only, and is cleared here because the buffer this
        // call submitted is finished by the time it returns.
        if (R_FAILED(audoutPlayBuffer(&buf, &released))) {
            LOG_ERROR("audoutPlayBuffer failed");
            if (pFramesWritten) *pFramesWritten = done;
            return MA_ERROR;
        }
        g_port.inFlight = false;
        done += n;
    }
    if (pFramesWritten) *pFramesWritten = done;
    return MA_SUCCESS;
}

}  // namespace

namespace wowee {
namespace platform {
namespace switchport {

void miniaudioBackendCallbacks(ma_backend_callbacks& out) {
    std::memset(&out, 0, sizeof out);
    out.onContextInit = ctxInit;
    out.onContextUninit = ctxUninit;
    out.onContextEnumerateDevices = ctxEnumerateDevices;
    out.onContextGetDeviceInfo = ctxGetDeviceInfo;
    out.onDeviceInit = devInit;
    out.onDeviceUninit = devUninit;
    out.onDeviceStart = devStart;
    out.onDeviceStop = devStop;
    out.onDeviceWrite = devWrite;
}

}  // namespace switchport
}  // namespace platform
}  // namespace wowee
