#include "PBVoicePatchRing.h"
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

struct PBVoicePatchRing {
    explicit PBVoicePatchRing(uint32_t count): capacity(count), samples(new float[count]()) {}
    const uint32_t capacity;
    float *samples;
    alignas(64) std::atomic<uint64_t> write{0};
    alignas(64) std::atomic<uint64_t> read{0};
    std::atomic<uint64_t> captured{0}, rendered{0}, dropped{0}, missing{0};
    std::atomic<uint64_t> callbacks{0}, offered{0}, rejected{0};
    std::atomic<uint32_t> lastBuffers{0}, lastChannels{0}, lastBytes{0}, lastFrames{0}, lastReject{0};
    ~PBVoicePatchRing() { delete[] samples; }
};
static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "audio counters must be lock-free");
PBVoicePatchRing *PBVoicePatchCreate(uint32_t capacity) {
    if (capacity < 512 || capacity > 192000) return nullptr;
    try { return new PBVoicePatchRing(capacity); } catch (...) { return nullptr; }
}
void PBVoicePatchDestroy(PBVoicePatchRing *ring) { delete ring; }
uint32_t PBVoicePatchCapture(PBVoicePatchRing *r, const AudioBufferList *in, uint32_t frames) {
    if (!r) return 0;
    r->callbacks.fetch_add(1, std::memory_order_relaxed); r->offered.fetch_add(frames, std::memory_order_relaxed);
    r->lastFrames.store(frames, std::memory_order_relaxed);
    r->lastBuffers.store(in ? in->mNumberBuffers : 0, std::memory_order_relaxed);
    auto reject = [r, frames](uint32_t reason) {r->rejected.fetch_add(frames, std::memory_order_relaxed);r->lastReject.store(reason,std::memory_order_relaxed);return uint32_t(0);};
    if (!in || !frames || frames > 192000 || in->mNumberBuffers == 0 || in->mNumberBuffers > 8) return reject(1);
    r->lastChannels.store(in->mBuffers[0].mNumberChannels, std::memory_order_relaxed);
    r->lastBytes.store(in->mBuffers[0].mDataByteSize, std::memory_order_relaxed);
    unsigned channels = 0;
    for (unsigned b = 0; b < in->mNumberBuffers; ++b) {
        const auto &buffer = in->mBuffers[b];
        if (!buffer.mData) return reject(2);
        if (!buffer.mNumberChannels || buffer.mNumberChannels > 8) return reject(3);
        if (uint64_t(buffer.mDataByteSize) < uint64_t(frames)*buffer.mNumberChannels*sizeof(float)) return reject(4);
        channels += buffer.mNumberChannels;
    }
    if (!channels || channels > 8) return reject(5);
    r->lastReject.store(0, std::memory_order_relaxed);
    uint64_t w = r->write.load(std::memory_order_relaxed), q = r->read.load(std::memory_order_acquire);
    uint32_t accepted = uint32_t(std::min<uint64_t>(frames, r->capacity - (w - q)));
    for (unsigned f = 0; f < accepted; ++f) {
        float sample = 0;
        for (unsigned b = 0; b < in->mNumberBuffers; ++b) {
            const auto &buffer = in->mBuffers[b]; const float *data = static_cast<const float *>(buffer.mData);
            for (unsigned c = 0; c < buffer.mNumberChannels; ++c) {
                float value = data[f*buffer.mNumberChannels+c];
                if (std::isfinite(value)) sample += value / channels;
            }
        }
        r->samples[(w+f)%r->capacity] = sample;
    }
    r->write.store(w+accepted, std::memory_order_release);
    r->captured.fetch_add(accepted, std::memory_order_relaxed);
    r->dropped.fetch_add(frames-accepted, std::memory_order_relaxed);
    return accepted;
}
uint32_t PBVoicePatchRender(PBVoicePatchRing *r, AudioBufferList *out, uint32_t frames) {
    if (!r || !out || !frames || frames > 192000 || out->mNumberBuffers == 0 || out->mNumberBuffers > 8) return 0;
    for (unsigned b = 0; b < out->mNumberBuffers; ++b) {
        auto &buffer = out->mBuffers[b];
        if (!buffer.mData || !buffer.mNumberChannels || buffer.mNumberChannels > 8 ||
            uint64_t(buffer.mDataByteSize) < uint64_t(frames)*buffer.mNumberChannels*sizeof(float)) return 0;
    }
    uint64_t q = r->read.load(std::memory_order_relaxed), w = r->write.load(std::memory_order_acquire);
    uint32_t available = uint32_t(std::min<uint64_t>(frames, w-q));
    for (unsigned b = 0; b < out->mNumberBuffers; ++b) {
        auto &buffer = out->mBuffers[b]; float *data = static_cast<float *>(buffer.mData);
        for (unsigned f = 0; f < frames; ++f) {
            float sample = f < available ? r->samples[(q+f)%r->capacity] : 0;
            for (unsigned c = 0; c < buffer.mNumberChannels; ++c) data[f*buffer.mNumberChannels+c] = sample;
        }
    }
    r->read.store(q+available, std::memory_order_release);
    r->rendered.fetch_add(available, std::memory_order_relaxed);
    r->missing.fetch_add(frames-available, std::memory_order_relaxed);
    return available;
}
PBVoicePatchStats PBVoicePatchGetStats(PBVoicePatchRing *r) {
    if (!r) return {};
    auto q=r->read.load(std::memory_order_acquire), w=r->write.load(std::memory_order_acquire);
    return {r->captured.load(),r->rendered.load(),r->dropped.load(),r->missing.load(),w>=q?w-q:0,
            r->callbacks.load(),r->offered.load(),r->rejected.load(),
            r->lastBuffers.load(),r->lastChannels.load(),r->lastBytes.load(),r->lastFrames.load(),r->lastReject.load()};
}
