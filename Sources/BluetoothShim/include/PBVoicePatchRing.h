#pragma once
#include <AudioToolbox/AudioToolbox.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PBVoicePatchRing PBVoicePatchRing;
typedef struct {
    uint64_t capturedFrames, renderedFrames, droppedFrames, missingFrames, queuedFrames;
    uint64_t captureCallbacks, offeredFrames, rejectedFrames;
    uint32_t lastBufferCount, lastChannels, lastBytes, lastFrames, lastRejectCode;
} PBVoicePatchStats;
PBVoicePatchRing *PBVoicePatchCreate(uint32_t capacity);
void PBVoicePatchDestroy(PBVoicePatchRing *ring);
uint32_t PBVoicePatchCapture(PBVoicePatchRing *ring, const AudioBufferList *input, uint32_t frames);
uint32_t PBVoicePatchRender(PBVoicePatchRing *ring, AudioBufferList *output, uint32_t frames);
PBVoicePatchStats PBVoicePatchGetStats(PBVoicePatchRing *ring);
#ifdef __cplusplus
}
#endif
