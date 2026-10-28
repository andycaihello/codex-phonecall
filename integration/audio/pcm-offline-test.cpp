#include "pcm-dsp.hpp"
#include "pcm-rings.hpp"
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <thread>
#include <chrono>
using namespace phonebridge;
static unsigned checks = 0;
static void check(bool condition, const char *label) {
    ++checks; if (!condition) { std::fprintf(stderr, "FAIL: %s\n", label); std::exit(1); }
}
static std::vector<float> tone(double frequency, unsigned rate, size_t frames) {
    std::vector<float> out(frames);
    for (size_t i = 0; i < frames; ++i) out[i] = float(.5 * std::sin(2 * 3.141592653589793 * frequency * double(i) / rate));
    return out;
}
static double rms(const std::vector<float> &samples, size_t skip = 1000) {
    double sum = 0; for (size_t i = skip; i < samples.size(); ++i) sum += double(samples[i]) * samples[i];
    return std::sqrt(sum / double(samples.size() - skip));
}
static double amplitude(const std::vector<float> &samples, double frequency, unsigned rate) {
    double cosine = 0, sine = 0; size_t skip = 2000;
    for (size_t i = skip; i < samples.size(); ++i) {
        double phase = 2 * 3.141592653589793 * frequency * double(i) / rate;
        cosine += samples[i] * std::cos(phase); sine += samples[i] * std::sin(phase);
    }
    return 2 * std::hypot(cosine, sine) / double(samples.size() - skip);
}
int main() {
    auto samples = tone(1000, 24000, 24007); std::vector<float> all, chunks;
    Down24To8 a, b; a.process(samples.data(), samples.size(), all);
    size_t at = 0; const size_t sizes[] = {1, 19, 137, 2, 2400, 7}; unsigned block = 0;
    while (at < samples.size()) { size_t n = std::min(sizes[block++ % 6], samples.size() - at); b.process(samples.data() + at, n, chunks); at += n; }
    check(all == chunks && all.size() == samples.size() / 3, "downsample arbitrary chunk boundaries");
    a.finish(all); b.finish(chunks); check(all == chunks && all.size() == 8088, "bounded FIR tail and chunk invariance");
    auto low = tone(1000, 24000, 48000), high = tone(6000, 24000, 48000), high2 = tone(10000, 24000, 48000);
    std::vector<float> low8, high8, high28; Down24To8 c, d, e;
    c.process(low.data(), low.size(), low8); d.process(high.data(), high.size(), high8); e.process(high2.data(), high2.size(), high28);
    double passRMS = rms(low8), rejectedRMS = rms(high8), rejected2RMS = rms(high28);
    check(passRMS > .35 && passRMS < .357, "one-kHz passband gain");
    check(rejectedRMS < passRMS * .001 && rejected2RMS < passRMS * .001, "six and ten kHz anti-alias attenuation exceeds sixty dB");
    auto eight = tone(1000, 8000, 16001); Up8To24 upA, upB; std::vector<float> up, upChunks;
    upA.process(eight.data(), eight.size(), up); at = 0; block = 0;
    while (at < eight.size()) { size_t n = std::min(sizes[block++ % 6], eight.size() - at); upB.process(eight.data() + at, n, upChunks); at += n; }
    check(up == upChunks && up.size() == eight.size() * 3, "upsample arbitrary chunk boundaries and count");
    double fundamental = amplitude(up, 1000, 24000), image = amplitude(up, 7000, 24000);
    check(fundamental > .495 && fundamental < .505 && image < .001, "upsample gain and image rejection");
    a.reset(); upA.reset(); std::vector<float> zeros(99), downZero, upZero;
    a.process(zeros.data(), zeros.size(), downZero); upA.process(zeros.data(), zeros.size(), upZero);
    check(rms(downZero, 0) == 0 && rms(upZero, 0) == 0, "reset clears filter history");
    SPSCRing<uint32_t, 17> ring; uint32_t small[18]{}; check(!ring.push(small, 18) && ring.available() == 0, "overflow is atomic with no partial write");
    check(ring.push(small, 17) && ring.free() == 0, "exact ring capacity");
    uint32_t popped[17]; check(ring.popMany(popped, 17) == 17 && ring.available() == 0, "ring drain");
    auto concurrent = std::make_unique<SPSCRing<uint32_t, 127>>(); std::atomic<bool> bad{false};
    std::thread producer([&] { for (uint32_t i = 0; i < 200000; ++i) while (!concurrent->push(&i, 1)) std::this_thread::yield(); });
    std::thread consumer([&] { for (uint32_t i = 0; i < 200000; ++i) { uint32_t v; while (!concurrent->pop(v)) std::this_thread::yield(); if (v != i) bad.store(true); } });
    producer.join(); consumer.join(); check(!bad.load() && concurrent->available() == 0, "concurrent SPSC immutable publication over repeated wraps");
    auto audio = std::make_unique<SharedAudio>(); OutputFrame queued[4] = {{.25f, 0, 1, 0}, {.5f, 0, 2, 0}, {.75f, 0, 3, 0}, {1, 0, 4, 0}};
    float buffer[4]{}; check(audio->output.push(queued, 4), "enqueue synthetic output"); audio->render(buffer, 2);
    check(buffer[0] == .25f && buffer[1] == .5f && audio->counters[0].position8.load() == 2, "playback position counts only submitted callback frames");
    audio->generation.store(1, std::memory_order_release); audio->render(buffer, 4);
    check(buffer[0] == 0 && buffer[3] == 0 && audio->output.available() == 0 && audio->clearObserved.load() == 1 && audio->counters[0].position8.load() == 2, "generation flush produces silence without advancing old item");
    OutputFrame fresh[2] = {{.5f, 1, 1, 1}, {.75f, 1, 2, 1}}; check(audio->output.push(fresh, 2), "enqueue acknowledged new generation"); audio->render(buffer, 4);
    check(buffer[0] == .5f && buffer[1] == .75f && buffer[2] == 0 && audio->counters[1].deviceFrames.load() == 2, "new generation playback and EOF zero fill");
    check(audio->output.push(fresh, 2), "enqueue before stop"); audio->stop.store(true); audio->render(buffer, 4);
    check(buffer[0] == 0 && buffer[1] == 0 && audio->counters[1].deviceFrames.load() == 2, "stop renders silence and never advances position");
    std::printf("{\"passed\":true,\"checks\":%u,\"deviceIO\":false,\"inputPassRMS\":%.9g,\"alias6kRMS\":%.9g,\"alias10kRMS\":%.9g,\"upsampled1kAmplitude\":%.9g,\"upsampled7kImage\":%.9g}\n", checks, passRMS, rejectedRMS, rejected2RMS, fundamental, image);
}
