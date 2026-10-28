#pragma once
#include <array>
#include <atomic>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace phonebridge {
template <typename Value, size_t Capacity> class SPSCRing {
public:
    size_t available() const { return size_t(write_.load(std::memory_order_acquire) - read_.load(std::memory_order_acquire)); }
    size_t free() const { return Capacity - available(); }
    // Exactly one producer and one consumer. Each publishes only its own index.
    bool push(const Value *values, size_t count) {
        uint64_t w = write_.load(std::memory_order_relaxed), r = read_.load(std::memory_order_acquire);
        if (count > Capacity - size_t(w - r)) return false;
        for (size_t i = 0; i < count; ++i) storage_[(w + i) % Capacity] = values[i];
        write_.store(w + count, std::memory_order_release); return true;
    }
    bool peek(Value &value) const {
        uint64_t r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return false;
        value = storage_[r % Capacity]; return true;
    }
    bool pop(Value &value) {
        uint64_t r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return false;
        value = storage_[r % Capacity]; read_.store(r + 1, std::memory_order_release); return true;
    }
    size_t popMany(Value *values, size_t limit) {
        uint64_t r = read_.load(std::memory_order_relaxed), w = write_.load(std::memory_order_acquire);
        size_t count = std::min(limit, size_t(w - r));
        for (size_t i = 0; i < count; ++i) values[i] = storage_[(r + i) % Capacity];
        read_.store(r + count, std::memory_order_release); return count;
    }
private:
    std::array<Value, Capacity> storage_{};
    alignas(64) std::atomic<uint64_t> read_{0}, write_{0};
};
struct OutputFrame { float sample = 0; uint32_t generation = 0; uint32_t position8 = 0; uint16_t item = 0; };
struct ItemCounter { std::atomic<uint64_t> deviceFrames{0}; std::atomic<uint32_t> position8{0}; };
struct SharedAudio {
    static constexpr size_t itemLimit = 512;
    SPSCRing<float, 16000> input; // two seconds at 8 kHz; overflow fails closed
    SPSCRing<OutputFrame, 80000> output; // at most ten seconds at 8 kHz
    std::array<ItemCounter, itemLimit> counters;
    std::atomic<uint32_t> generation{0}, clearObserved{0};
    std::atomic<bool> stop{false};
    std::atomic<unsigned> fault{0};
    std::atomic<uint64_t> inputCallbacks{0}, outputCallbacks{0}, inputFrames{0};
    void render(float *destination, size_t count) {
        if (destination) std::memset(destination, 0, count * sizeof(float));
        if (!destination || !count || count > 8192) { fault.store(2); stop.store(true); return; }
        uint32_t active = generation.load(std::memory_order_acquire);
        std::array<uint32_t, itemLimit> contributed{}, positions{};
        if (!stop.load(std::memory_order_relaxed)) {
            for (size_t at = 0; at < count;) {
                if (generation.load(std::memory_order_acquire) != active || stop.load(std::memory_order_relaxed)) break;
                OutputFrame value;
                if (!output.peek(value)) break;
                if (value.generation > active) break;
                (void)output.pop(value);
                if (value.generation < active) continue;
                if (value.item >= itemLimit) { fault.store(3); stop.store(true); break; }
                destination[at++] = value.sample;
                ++contributed[value.item]; positions[value.item] = value.position8;
            }
        }
        uint32_t newest = generation.load(std::memory_order_acquire);
        if (newest != active || stop.load(std::memory_order_relaxed)) {
            std::memset(destination, 0, count * sizeof(float));
        } else for (size_t i = 0; i < itemLimit; ++i) if (contributed[i]) {
            counters[i].deviceFrames.fetch_add(contributed[i], std::memory_order_relaxed);
            counters[i].position8.store(positions[i], std::memory_order_release);
        }
        // Discard old-generation backlog even when the output buffer was empty.
        OutputFrame queued;
        while (output.peek(queued) && queued.generation < newest) (void)output.pop(queued);
        clearObserved.store(newest, std::memory_order_release);
    }
};
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<uint32_t>::is_always_lock_free && std::atomic<bool>::is_always_lock_free, "Realtime counters must be lock-free");
}
