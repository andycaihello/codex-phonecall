#pragma once
#include <array>
#include <cmath>
#include <cstddef>
#include <vector>

// Non-realtime converters. 257-tap normalized Blackman-windowed sinc at 24 kHz,
// 3.5 kHz cutoff, 128/24000 s linear-phase delay. No spectral folding by naive
// decimation: downsampling filters before taking every third sample; upsampling
// filters the zero-inserted stream with gain three to suppress images.
namespace phonebridge {
class FIR24 {
public:
    static constexpr size_t taps = 257, delayFrames24 = 128;
    FIR24() {
        constexpr double pi = 3.14159265358979323846, fc = 3500.0 / 24000.0;
        double sum = 0;
        for (size_t i = 0; i < taps; ++i) {
            double x = double(i) - double(delayFrames24);
            double ideal = x == 0 ? 2 * fc : std::sin(2 * pi * fc * x) / (pi * x);
            double window = .42 - .5 * std::cos(2 * pi * double(i) / (taps - 1)) + .08 * std::cos(4 * pi * double(i) / (taps - 1));
            kernel_[i] = ideal * window; sum += kernel_[i];
        }
        for (double &v : kernel_) v /= sum;
    }
    void reset() { history_.fill(0); cursor_ = 0; }
    void push(float value) { history_[cursor_] = value; cursor_ = (cursor_ + 1) % taps; }
    float output() const {
        double value = 0; size_t at = cursor_;
        for (size_t i = 0; i < taps; ++i) { at = at ? at - 1 : taps - 1; value += kernel_[i] * history_[at]; }
        return float(value);
    }
private:
    std::array<double, taps> kernel_{};
    std::array<float, taps> history_{};
    size_t cursor_ = 0;
};
class Down24To8 {
public:
    void reset() { filter_.reset(); phase_ = 0; }
    void process(const float *input, size_t count, std::vector<float> &out) {
        for (size_t i = 0; i < count; ++i) {
            filter_.push(input[i]);
            if (++phase_ == 3) { phase_ = 0; out.push_back(filter_.output()); }
        }
    }
    void finish(std::vector<float> &out) {
        size_t zeros = FIR24::taps - 1;
        zeros += (3 - (phase_ + zeros) % 3) % 3;
        const float zero = 0;
        for (size_t i = 0; i < zeros; ++i) process(&zero, 1, out);
    }
private:
    FIR24 filter_;
    size_t phase_ = 0;
};
class Up8To24 {
public:
    void reset() { filter_.reset(); }
    void process(const float *input, size_t count, std::vector<float> &out) {
        for (size_t i = 0; i < count; ++i) for (unsigned phase = 0; phase < 3; ++phase) {
            filter_.push(phase == 0 ? input[i] : 0);
            out.push_back(3 * filter_.output());
        }
    }
private:
    FIR24 filter_;
};
}
