// audio_backend_switch.cpp - miniaudio custom backend on libnx audout.
//
// One playback device: the system main audio output, 48 kHz stereo s16,
// 256-frame grains. miniaudio's default audio thread calls onDeviceWrite()
// with one period at a time; audoutPlayBuffer blocks until the grain has
// been consumed, which paces the thread. Buffers for audout must be
// 0x1000-aligned in address and size, hence the aligned staging.
#include "platform/switch/audio_backend_switch.hpp"
#include "platform/switch/switch_platform.hpp"

#include "core/logger.hpp"

#include <switch/services/audout.h>

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
    alignas(0x1000) uint8_t grain[kGrainFrames * kChannels * sizeof(int16_t)];
};
PortState g_port;   // one device per process

constexpr size_t kGrainBytes = kGrainFrames * kChannels * sizeof(int16_t);

ma_result ctxInit(ma_context* pContext, const ma_context_config*, ma_backend_callbacks* pCallbacks) {
    (void)pContext;
    if (R_FAILED(audoutInitialize())) {
        LOG_ERROR("audoutInitialize failed");
        return MA_FAILED_TO_INIT_BACKEND;
    }
    wowee::platform::switchport::miniaudioBackendCallbacks(*pCallbacks);
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

    u32 rateOut = 0, channelsOut = 0;
    PcmFormat format = PcmFormat_Invalid;
    AudioOutState state = AudioOutState_Stopped;
    if (R_FAILED(audoutOpenAudioOut(nullptr, nullptr, kSampleRate, kChannels, &rateOut, &channelsOut, &format, &state))) {
        LOG_ERROR("audoutOpenAudioOut failed");
        return MA_FAILED_TO_OPEN_BACKEND_DEVICE;
    }
    if (format != PcmFormat_Int16) {
        LOG_ERROR("audoutOpenAudioOut returned unexpected format");
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
    LOG_INFO("switch audio: audout opened (48 kHz stereo s16, 256-frame grains)");
    return MA_SUCCESS;
}

ma_result devUninit(ma_device*) {
    if (g_port.opened) {
        audoutStopAudioOut();
        g_port.opened = false;
    }
    g_port.started = false;
    return MA_SUCCESS;
}

ma_result devStart(ma_device*) {
    if (R_FAILED(audoutStartAudioOut())) return MA_ERROR;
    g_port.started = true;
    return MA_SUCCESS;
}

ma_result devStop(ma_device*) {
    g_port.started = false;
    AudioOutBuffer* released = nullptr;
    u32 releasedCount = 0;
    audoutWaitPlayFinish(&released, &releasedCount, 1000000000ULL);
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
        if (R_FAILED(audoutPlayBuffer(&buf, &released))) {
            LOG_ERROR("audoutPlayBuffer failed");
            return MA_ERROR;
        }
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
