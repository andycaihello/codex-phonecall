#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#include "pcm-dsp.hpp"
#include "pcm-rings.hpp"
#include "private-ipc.hpp"
#include "../phone-identity-arguments.h"
#include <csignal>
#include <memory>
#include <thread>
#include <vector>

using namespace phonebridge;
static NSString *inputUID = nil;
static NSString *outputUID = nil;
static NSString *phoneName = nil;
static std::atomic<bool> interrupted{false};
static void onSignal(int) { interrupted.store(true, std::memory_order_relaxed); }
static void pump(double seconds = .005) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
struct Options {
    bool bridge = false, permissionStatus = false, permissionRequest = false, validate = false, help = false;
    unsigned maxSeconds = 0; // no fixed IO duration; parent/IPC/health checks remain
    NSString *socket = nil, *tokenFile = nil, *report = nil, *phoneAddress = nil, *phoneName = nil;
};
static NSString *parse(int argc, const char **argv, Options &o) {
    NSMutableSet *seen = [NSMutableSet set];
    for (int i = 1; i < argc; ++i) {
        NSString *arg = [NSString stringWithUTF8String:argv[i]];
        if (!arg || [seen containsObject:arg]) return @"Invalid or repeated option";
        [seen addObject:arg];
        if ([arg isEqualToString:@"--bridge"]) o.bridge = true;
        else if ([arg isEqualToString:@"--microphone-permission-status"]) o.permissionStatus = true;
        else if ([arg isEqualToString:@"--request-microphone-permission"]) o.permissionRequest = true;
        else if ([arg isEqualToString:@"--validate-args"]) o.validate = true;
        else if ([arg isEqualToString:@"--help"]) o.help = true;
        else if ([arg isEqualToString:@"--phone-address"] || [arg isEqualToString:@"--phone-name"]) {
            if (++i >= argc) return @"Option requires a value";
            NSString *value = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--phone-address"]) o.phoneAddress = value;
            else o.phoneName = value;
        }
        else if ([arg isEqualToString:@"--socket"] || [arg isEqualToString:@"--token-file"] ||
                 [arg isEqualToString:@"--report"] || [arg isEqualToString:@"--max-seconds"]) {
            if (++i >= argc) return @"Option requires a value";
            NSString *value = [NSString stringWithUTF8String:argv[i]];
            if (!value.length || [value hasPrefix:@"--"]) return @"Missing option value";
            if ([arg isEqualToString:@"--max-seconds"]) {
                const char *p = argv[i]; unsigned count = 0;
                for (; *p; ++p) {
                    if (*p < '0' || *p > '9') return @"--max-seconds must be an integer 0..2147483647; 0 means unlimited";
                    unsigned digit = unsigned(*p - '0');
                    if (count > (2147483647u - digit) / 10u) return @"--max-seconds exceeds integer range";
                    count = count * 10u + digit;
                }
                o.maxSeconds = count;
            } else {
                if (!value.isAbsolutePath || ![value isEqualToString:value.stringByStandardizingPath]) return @"Paths must be absolute and standardized";
                if ([arg isEqualToString:@"--socket"]) o.socket = value;
                else if ([arg isEqualToString:@"--token-file"]) o.tokenFile = value;
                else o.report = value;
            }
        } else return @"Unknown option";
    }
    if (o.help) return argc == 2 ? nil : @"Help must be used alone";
    if (unsigned(o.bridge) + unsigned(o.permissionStatus) + unsigned(o.permissionRequest) != 1) return @"Choose exactly one explicit action";
    if (o.bridge && (!o.socket || !o.tokenFile)) return @"Bridge requires --socket and --token-file";
    if (o.bridge) {
        NSString *identityError = PBPhoneIdentityError(o.phoneAddress, o.phoneName);
        if (identityError) return identityError;
    }
    if (!o.bridge && ([seen containsObject:@"--phone-address"] || [seen containsObject:@"--phone-name"])) return @"Permission actions cannot contain phone identity options";
    if (!o.bridge && (o.socket || o.tokenFile || [seen containsObject:@"--max-seconds"])) return @"Permission actions cannot contain bridge options";
    if (o.bridge && ([o.socket isEqualToString:o.tokenFile] || strlen(o.socket.fileSystemRepresentation) >= sizeof(sockaddr_un::sun_path))) return @"Socket path is invalid";
    if (o.report && ([o.report isEqualToString:o.socket] || [o.report isEqualToString:o.tokenFile])) return @"Report must be a separate new file";
    return nil;
}
static bool emit(NSDictionary *report, int fd = -1) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return false;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
    if (fd < 0) return true;
    const char *p = static_cast<const char *>(data.bytes); size_t left = data.length;
    while (left) { ssize_t n = write(fd, p, left); if (n < 0 && errno == EINTR) continue; if (n <= 0) return false; p += n; left -= size_t(n); }
    return fsync(fd) == 0;
}
static NSString *authorizationName(AVAuthorizationStatus status) {
    switch (status) {
        case AVAuthorizationStatusAuthorized: return @"authorized";
        case AVAuthorizationStatusDenied: return @"denied";
        case AVAuthorizationStatusRestricted: return @"restricted";
        default: return @"notDetermined";
    }
}
static bool property(AudioObjectID id, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, void *value, UInt32 *size) {
    AudioObjectPropertyAddress a{selector, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(id, &a, 0, nullptr, size, value) == noErr;
}
static NSString *stringProperty(AudioObjectID id, AudioObjectPropertySelector selector) {
    CFStringRef value = nullptr; UInt32 size = sizeof(value);
    if (!property(id, selector, kAudioObjectPropertyScopeGlobal, &value, &size) || !value) return @"";
    return CFBridgingRelease(value);
}
static bool scalar(AudioObjectID id, AudioObjectPropertySelector selector, UInt32 expected) {
    UInt32 value = 0, size = sizeof(value);
    return property(id, selector, kAudioObjectPropertyScopeGlobal, &value, &size) && size == sizeof(value) && value == expected;
}
static std::vector<UInt32> idsProperty(AudioObjectID id, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a{selector, scope, kAudioObjectPropertyElementMain}; UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size) || size > 65536 || size % 4) return {};
    std::vector<UInt32> ids(size / 4);
    if (size && AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, ids.data())) return {};
    ids.resize(size / 4); return ids;
}
static bool channels(AudioDeviceID id, AudioObjectPropertyScope scope, UInt32 expected) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain}; UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size) || size < offsetof(AudioBufferList, mBuffers) || size > 65536) return false;
    std::vector<uint8_t> buffer(size);
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, buffer.data())) return false;
    auto *list = reinterpret_cast<const AudioBufferList *>(buffer.data());
    if (offsetof(AudioBufferList, mBuffers) + size_t(list->mNumberBuffers) * sizeof(AudioBuffer) > size) return false;
    uint64_t total = 0; for (UInt32 i = 0; i < list->mNumberBuffers; ++i) total += list->mBuffers[i].mNumberChannels;
    return total == expected;
}
static bool formatMatches(AudioDeviceID id, bool input) {
    auto streams = idsProperty(id, kAudioDevicePropertyStreams, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput);
    if (streams.size() != 1) return false;
    AudioStreamBasicDescription f{}; UInt32 size = sizeof(f);
    if (!property(streams[0], kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &f, &size) || size != sizeof(f)) return false;
    UInt32 required = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, permitted = required | kAudioFormatFlagIsNonInterleaved;
    return f.mFormatID == kAudioFormatLinearPCM && f.mSampleRate == 8000 && f.mChannelsPerFrame == 1 &&
        f.mBitsPerChannel == 32 && f.mBytesPerFrame == 4 && f.mBytesPerPacket == 4 && f.mFramesPerPacket == 1 &&
        (f.mFormatFlags & required) == required && !(f.mFormatFlags & ~permitted);
}
static bool identityMatches(AudioDeviceID id, bool input) {
    return [stringProperty(id, kAudioDevicePropertyDeviceUID) isEqualToString:input ? inputUID : outputUID] &&
        [stringProperty(id, kAudioObjectPropertyName) isEqualToString:phoneName] &&
        scalar(id, kAudioDevicePropertyTransportType, kAudioDeviceTransportTypeBluetooth) && scalar(id, kAudioDevicePropertyDeviceIsAlive, 1) &&
        channels(id, kAudioObjectPropertyScopeInput, input ? 1 : 0) && channels(id, kAudioObjectPropertyScopeOutput, input ? 0 : 1) && formatMatches(id, input);
}
struct Endpoint {
    SharedAudio *shared = nullptr; bool input = false, started = false;
    AudioDeviceID id = 0; AudioDeviceIOProcID proc = nullptr;
    OSStatus create = -1, start = -1, stop = -1, destroy = -1;
};
static OSStatus ioProc(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *input,
                       const AudioTimeStamp *, AudioBufferList *output, const AudioTimeStamp *, void *context) {
    auto &e = *static_cast<Endpoint *>(context); SharedAudio &s = *e.shared;
    if (output) for (UInt32 i = 0; i < output->mNumberBuffers; ++i)
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    if (e.input) {
        s.inputCallbacks.fetch_add(1, std::memory_order_relaxed);
        if (s.stop.load(std::memory_order_relaxed) || interrupted.load(std::memory_order_relaxed)) return noErr;
        if (!input || input->mNumberBuffers != 1) { s.fault.store(1); s.stop.store(true); return noErr; }
        const AudioBuffer &b = input->mBuffers[0]; size_t count = b.mDataByteSize / sizeof(float);
        if (!b.mData || b.mNumberChannels != 1 || b.mDataByteSize % 4 || !count || count > 8192 ||
            !s.input.push(static_cast<const float *>(b.mData), count)) { s.fault.store(1); s.stop.store(true); return noErr; }
        s.inputFrames.fetch_add(count, std::memory_order_relaxed);
    } else {
        s.outputCallbacks.fetch_add(1, std::memory_order_relaxed);
        if (interrupted.load(std::memory_order_relaxed)) s.stop.store(true, std::memory_order_relaxed);
        if (!output || output->mNumberBuffers != 1 || !output->mBuffers[0].mData ||
            output->mBuffers[0].mNumberChannels != 1 || output->mBuffers[0].mDataByteSize % 4) {
            s.fault.store(2); s.stop.store(true); return noErr;
        }
        s.render(static_cast<float *>(output->mBuffers[0].mData), output->mBuffers[0].mDataByteSize / 4);
    }
    return noErr;
}
struct Deadline {
    std::atomic<bool> done{false};
    std::atomic<uint64_t> endMillis{0};
    std::thread thread;
    static uint64_t nowMillis() { return uint64_t(nowSeconds() * 1000); }
    void set(double seconds) { endMillis.store(nowMillis() + uint64_t(seconds * 1000), std::memory_order_release); }
    explicit Deadline(pid_t peer) : thread([this, peer] {
        uint64_t interruptionDeadline = 0;
        while (!done.load(std::memory_order_acquire)) {
            if (kill(peer, 0) && errno == ESRCH) interrupted.store(true, std::memory_order_relaxed);
            if (interrupted.load(std::memory_order_relaxed) && !interruptionDeadline) interruptionDeadline = nowMillis() + 3000;
            uint64_t end = endMillis.load(std::memory_order_acquire);
            if ((end && nowMillis() >= end) || (interruptionDeadline && nowMillis() >= interruptionDeadline)) {
                const char reason[] = "PhoneBridge native hard deadline; audio cleanup unverified\n";
                (void)write(STDERR_FILENO, reason, sizeof(reason) - 1); _Exit(124);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }) {}
    ~Deadline() { done.store(true, std::memory_order_release); thread.join(); }
};
static bool integer(id value, uint64_t maximum, uint64_t &result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    double n = [value doubleValue]; if (!std::isfinite(n) || n < 0 || n > maximum || std::floor(n) != n) return false;
    result = uint64_t(n); return true;
}
static bool validID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] < 1 || [value length] > 128) return false;
    static NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_:-"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}
struct OutputItem {
    NSString *response = nil, *item = nil; unsigned content = 0; uint32_t generation = 0;
    uint64_t sourceFrames24 = 0, queuedFrames8 = 0, reportedFrames = 0;
    bool ended = false;
};
class OutputCommands {
public:
    SharedAudio &shared; PrivateIPC &ipc; NSString *error = nil;
    std::vector<OutputItem> items; int current = -1;
    bool waitingClear = false; uint32_t generation = 0;
    explicit OutputCommands(SharedAudio &s, PrivateIPC &p) : shared(s), ipc(p) { items.reserve(SharedAudio::itemLimit); }
    bool command(NSDictionary *c) {
        NSString *op = c[@"op"]; uint64_t gen = 0;
        if (!integer(c[@"generation"], INT32_MAX, gen)) return fail(@"Audio command requires a nonnegative integer generation");
        if ([op isEqualToString:@"clear_output"]) {
            if (gen <= generation) return reject(@"Clear generation must increase");
            generation = uint32_t(gen); waitingClear = true; current = -1; converter.reset();
            shared.generation.store(generation, std::memory_order_release); return true;
        }
        if (gen != generation || waitingClear) return reject(@"Stale, future, or not-yet-acknowledged generation");
        uint64_t index = 0;
        if (!validID(c[@"response_id"]) || !validID(c[@"item_id"]) || !integer(c[@"content_index"], 1024, index))
            return fail(@"Audio item identity is invalid");
        bool end = [op isEqualToString:@"output_end"];
        if (!end && ![op isEqualToString:@"output_audio"]) return fail(@"Unknown audio command");
        if (current >= 0) {
            const OutputItem &item = items[size_t(current)];
            if (![item.response isEqualToString:c[@"response_id"]] || ![item.item isEqualToString:c[@"item_id"]] || item.content != index)
                return fail(@"Finish or clear the current item before another item");
        } else {
            if (end) return fail(@"No open output item to finish");
            for (const auto &item : items) if (item.generation == generation && item.content == index &&
                [item.response isEqualToString:c[@"response_id"]] && [item.item isEqualToString:c[@"item_id"]])
                return fail(@"A finished item cannot be reopened in the same generation");
            if (items.size() == SharedAudio::itemLimit) return fail(@"Output item limit reached");
            OutputItem item; item.response = c[@"response_id"]; item.item = c[@"item_id"]; item.content = unsigned(index); item.generation = generation;
            items.push_back(item); current = int(items.size()) - 1; converter.reset();
        }
        auto &item = items[size_t(current)]; std::vector<float> converted;
        if (end) {
            if (shared.output.free() < 87) return fail(@"Ten-second playback queue is full");
            converter.finish(converted); item.ended = true;
        } else {
            id audio = c[@"audio"];
            if (![audio isKindOfClass:NSString.class] || [audio length] > 64000) return fail(@"PCM chunk is too large or invalid");
            NSData *bytes = [[NSData alloc] initWithBase64EncodedString:audio options:0];
            if (!bytes.length || bytes.length % 2 || bytes.length > 48000) return fail(@"Require 1..24000 PCM16 mono 24000 Hz frames");
            size_t count = bytes.length / 2;
            if (item.sourceFrames24 + count > 7200000 || shared.output.free() < (count + 2) / 3 + 87) return fail(@"Output duration or ten-second queue bound exceeded");
            const auto *p = static_cast<const uint8_t *>(bytes.bytes); std::vector<float> samples(count);
            for (size_t i = 0; i < count; ++i) { uint16_t raw = uint16_t(p[i * 2]) | uint16_t(p[i * 2 + 1]) << 8; samples[i] = float(raw < 32768 ? int32_t(raw) : int32_t(raw) - 65536) / 32768; }
            item.sourceFrames24 += count; converted.reserve((count + 2) / 3 + 87); converter.process(samples.data(), count, converted);
        }
        std::vector<OutputFrame> frames(converted.size());
        for (size_t i = 0; i < frames.size(); ++i) {
            float sample = std::max(-1.0f, std::min(1.0f, converted[i]));
            uint64_t submitted24 = (item.queuedFrames8 + i + 1) * 3;
            uint64_t content8 = submitted24 > FIR24::delayFrames24 ? (submitted24 - FIR24::delayFrames24) / 3 : 0;
            frames[i] = {sample, generation, uint32_t(std::min(item.sourceFrames24 / 3, content8)), uint16_t(current)};
        }
        if (!shared.output.push(frames.data(), frames.size())) return fail(@"Playback queue lost capacity");
        item.queuedFrames8 += frames.size();
        if (end) current = -1;
        return true;
    }
    bool progress(bool force = false) {
        for (size_t i = 0; i < items.size(); ++i) {
            auto &item = items[i]; uint64_t frames = shared.counters[i].deviceFrames.load(std::memory_order_acquire);
            if (!force && frames == item.reportedFrames) continue;
            uint32_t position = shared.counters[i].position8.load(std::memory_order_acquire);
            if (!ipc.enqueue(@{@"type": @"playback", @"generation": @(item.generation), @"response_id": item.response,
                @"item_id": item.item, @"content_index": @(item.content), @"played_frames8000": @(position),
                @"audio_end_ms": @(position / 8), @"device_frames_submitted": @(frames),
                @"queued_frames8000": @(item.queuedFrames8), @"item_end_received": @(item.ended),
                @"scope": @"HAL-submitted-not-audible-confirmed"}, false)) return false;
            item.reportedFrames = frames;
        }
        if (waitingClear && shared.clearObserved.load(std::memory_order_acquire) == generation) {
            waitingClear = false;
            return ipc.enqueue(@{@"type": @"clear_ack", @"generation": @(generation),
                @"scope": @"Older queued frames discarded; previously submitted HAL buffers cannot be recalled"}, false);
        }
        return true;
    }
private:
    Down24To8 converter;
    bool fail(NSString *message) { error = message; return false; }
    bool reject(NSString *message) { return ipc.enqueue(@{@"type": @"output_rejected", @"generation": @(generation), @"reason": message}, false); }
};
static NSDictionary *endpointReport(const Endpoint &e) {
    return @{@"deviceID": @(e.id), @"createStatus": @(e.create), @"startStatus": @(e.start),
        @"stopStatus": e.started ? @(e.stop) : NSNull.null, @"destroyStatus": e.proc ? @(e.destroy) : NSNull.null};
}
static int runBridge(const Options &o, NSMutableDictionary *r, int reportFD) {
    PrivateIPC ipc;
    if (!ipc.connectTo(o.socket, o.tokenFile)) { r[@"error"] = ipc.error; return 3; }
    r[@"peerVerified"] = @YES; r[@"coordinatorPID"] = @(ipc.peerPID);
    Deadline deadline(ipc.peerPID); deadline.set(93);
    double waitStart = nowSeconds(); bool start = false, stop = false;
    while (!start && !stop && !interrupted.load() && nowSeconds() - waitStart < 90) {
        @autoreleasepool {
            NSMutableArray *commands = [NSMutableArray array];
            if (!ipc.flush() || !ipc.receive(commands)) { r[@"error"] = ipc.error; return 3; }
            for (NSDictionary *command in commands) {
                if ([command[@"op"] isEqual:@"stop"]) stop = true;
                else if ([command[@"op"] isEqual:@"start"] && !start) start = true;
                else { r[@"error"] = @"Only start or stop is accepted before IO"; return 3; }
            }
            if (!start && !stop) pump();
        }
    }
    if (stop || interrupted.load()) { r[@"stage"] = @"bridge-stopped-before-io"; r[@"cleanupVerified"] = @YES; return 0; }
    if (!start) { r[@"error"] = @"Start command timed out"; return 3; }
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
        r[@"error"] = @"This helper requires normal microphone authorization before start; it will not request it during a call"; return 4;
    }
    deadline.set(15); r[@"deviceQueries"] = @YES;
    auto shared = std::make_unique<SharedAudio>();
    Endpoint input{shared.get(), true}, output{shared.get(), false}; unsigned inputMatches = 0, outputMatches = 0;
    for (AudioDeviceID id : idsProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)) {
        NSString *uid = stringProperty(id, kAudioDevicePropertyDeviceUID);
        if ([uid isEqualToString:inputUID]) { input.id = id; ++inputMatches; }
        if ([uid isEqualToString:outputUID]) { output.id = id; ++outputMatches; }
    }
    if (inputMatches != 1 || outputMatches != 1 || input.id == output.id || !identityMatches(input.id, true) || !identityMatches(output.id, false)) {
        r[@"error"] = @"The unique fixed Bluetooth split input/output route or exact mono-float32 8000 Hz format is unavailable"; return 5;
    }
    bool identityStable = true, clean = true, success = true; double ioStart = 0;
    input.create = AudioDeviceCreateIOProcID(input.id, ioProc, &input, &input.proc);
    if (!input.create && input.proc) output.create = AudioDeviceCreateIOProcID(output.id, ioProc, &output, &output.proc);
    if (!input.create && !output.create && input.proc && output.proc && !interrupted.load()) {
        output.start = AudioDeviceStart(output.id, output.proc); output.started = output.start == noErr;
        if (output.started) { ioStart = nowSeconds(); deadline.set(o.maxSeconds ? double(o.maxSeconds) + 3 : 10); }
        if (output.started && !interrupted.load()) { input.start = AudioDeviceStart(input.id, input.proc); input.started = input.start == noErr; }
    }
    if (!ioStart) ioStart = nowSeconds();
    bool started = input.started && output.started;
    r[@"ioStarted"] = @(input.started || output.started); r[@"fullDuplexStarted"] = @(started);
    if (!started) { r[@"error"] = @"Could not start both owned CoreAudio IOProcs"; success = false; }
    if (!started) deadline.set(3);
    OutputCommands outputCommands(*shared, ipc); Up8To24 inputConverter;
    uint64_t sequence = 0, inputDelivered8 = 0, inputSanitized = 0;
    double nextRoute = ioStart + .25, nextProgress = ioStart + .1;
    NSString *stopReason = started ? @"duration-limit" : @"start-failed";
    if (started && !ipc.enqueue(@{@"type": @"ready", @"generation": @0, @"input_sample_rate": @24000,
        @"output_sample_rate": @24000, @"device_sample_rate": @8000, @"channels": @1,
        @"format": @"pcm16-little-endian", @"max_seconds": @(o.maxSeconds),
        @"input_uid": inputUID, @"output_uid": outputUID, @"device_name": phoneName,
        @"resampler_delay_ms": @(1000.0 * FIR24::delayFrames24 / 24000)}, false)) success = false;
    while (started && success && !stop && !interrupted.load() && !shared->stop.load() &&
           (!o.maxSeconds || nowSeconds() - ioStart < o.maxSeconds)) {
        @autoreleasepool {
            // In unlimited mode a stalled main loop is still terminated; this
            // moving health watchdog is not a limit on total call duration.
            if (!o.maxSeconds) deadline.set(10);
            NSMutableArray *commands = [NSMutableArray array];
            if (!ipc.flush() || !ipc.receive(commands)) { r[@"error"] = ipc.error; success = false; break; }
            for (NSDictionary *c in commands) {
                if (![c[@"op"] isKindOfClass:NSString.class]) { r[@"error"] = @"Command requires an op string"; success = false; break; }
                if ([c[@"op"] isEqual:@"stop"]) { stop = true; stopReason = @"stop-command"; break; }
                if (!outputCommands.command(c)) { r[@"error"] = outputCommands.error ?: ipc.error; success = false; break; }
            }
            if (!success || stop) break;
            if (shared->input.available() >= 800) {
                float block[800]; size_t count = shared->input.popMany(block, 800);
                for (size_t i = 0; i < count; ++i) if (!std::isfinite(block[i])) { block[i] = 0; ++inputSanitized; }
                std::vector<float> converted; converted.reserve(count * 3); inputConverter.process(block, count, converted);
                NSMutableData *pcm = [NSMutableData dataWithLength:converted.size() * 2]; auto *p = static_cast<uint8_t *>(pcm.mutableBytes);
                for (size_t i = 0; i < converted.size(); ++i) {
                    double value = std::max(-1.0, std::min(32767.0 / 32768, double(converted[i])));
                    int32_t sample = int32_t(std::lrint(value * 32768)); uint16_t bits = uint16_t(sample & 65535);
                    p[i * 2] = uint8_t(bits); p[i * 2 + 1] = uint8_t(bits >> 8);
                }
                inputDelivered8 += count;
                if (!ipc.enqueue(@{@"type": @"input_audio", @"audio": [pcm base64EncodedStringWithOptions:0],
                    @"frames": @(converted.size()), @"sample_rate": @24000, @"channels": @1,
                    @"sequence": @(sequence++), @"elapsed_seconds": @(nowSeconds() - ioStart)}, true)) {
                    r[@"error"] = ipc.error; success = false; break;
                }
            }
            double now = nowSeconds();
            if (now >= nextProgress) { if (!outputCommands.progress()) { r[@"error"] = ipc.error; success = false; break; } nextProgress = now + .1; }
            if (now >= nextRoute) {
                identityStable = identityMatches(input.id, true) && identityMatches(output.id, false);
                if (!identityStable) { r[@"error"] = @"Fixed phone route identity or stream format changed"; success = false; break; }
                nextRoute = now + .25;
            }
            pump();
        }
    }
    if (interrupted.load()) stopReason = @"signal-or-coordinator-exit";
    if (shared->fault.load()) { success = false; r[@"error"] = @"Realtime buffer shape or bounded input queue failed"; stopReason = @"realtime-fault"; }
    shared->stop.store(true, std::memory_order_release); deadline.set(3);
    // Stop only successfully started owned procedures; destroy every returned ID.
    for (Endpoint *e : {&input, &output}) if (e->started) { e->stop = AudioDeviceStop(e->id, e->proc); if (e->stop) clean = false; }
    for (Endpoint *e : {&input, &output}) if (e->proc) { e->destroy = AudioDeviceDestroyIOProcID(e->id, e->proc); if (e->destroy) clean = false; }
    r[@"stage"] = @"bridge-finished"; r[@"stopReason"] = stopReason; r[@"cleanupVerified"] = @(clean);
    r[@"success"] = @(success && clean); r[@"interrupted"] = @(interrupted.load());
    r[@"identityStable"] = @(identityStable); r[@"elapsedIOSeconds"] = @(nowSeconds() - ioStart);
    r[@"input"] = endpointReport(input); r[@"output"] = endpointReport(output);
    r[@"inputFrames8000"] = @(shared->inputFrames.load()); r[@"inputFramesQueuedToIPC8000"] = @(inputDelivered8);
    r[@"inputNonfiniteSanitized"] = @(inputSanitized); r[@"inputCallbacks"] = @(shared->inputCallbacks.load());
    r[@"outputCallbacks"] = @(shared->outputCallbacks.load()); r[@"realtimeFault"] = @(shared->fault.load());
    r[@"generation"] = @(outputCommands.generation); r[@"outputItems"] = @(outputCommands.items.size());
    // On stop, unsent PCM is deliberately dropped with socket close. Metadata is
    // returned through the private report; do not delay cleanup to upload audio.
    if (clean && ipc.discardUnsentAudio()) {
        (void)outputCommands.progress();
        (void)ipc.enqueue(@{@"type": @"stopped", @"cleanupVerified": @YES, @"stop_reason": stopReason,
            @"success": @(success), @"generation": @(outputCommands.generation), @"error": r[@"error"] ?: NSNull.null}, false);
        (void)ipc.flush();
    }
    // Endpoint context as well as its buffers must stay alive until exit if HAL
    // failed to destroy a callback. Do not return through these stack frames.
    if (!clean) { r[@"liveCallbackContextRetainedUntilProcessExit"] = @YES; (void)emit(r, reportFD); _Exit(7); }
    return success && clean ? 0 : 6;
}
static int runAction(const Options &o) {
    int reportFD = -1;
    if (o.report) { reportFD = createPrivateReport(o.report); if (reportFD < 0) { emit(@{@"stage": @"report-error", @"ioStarted": @NO, @"error": @"Report must be a new file in a private owner-only directory"}); return 2; } }
    NSMutableDictionary *r = [@{@"bundleIdentifier": @"local.phonebridge.PCMBridge", @"version": @"0.1.0",
        @"stage": @"bridge-rejected", @"ioStarted": @NO, @"deviceQueries": @NO, @"permissionRequested": @NO,
        @"cleanupVerified": @YES, @"audioRecorded": @NO, @"nativeNetworkAccess": @NO,
        @"playbackScope": @"HAL-submitted-not-audible-confirmed"} mutableCopy];
    AVAuthorizationStatus before = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    r[@"authorizationBefore"] = authorizationName(before);
    int code = 0;
    if (o.permissionStatus || o.permissionRequest) {
        r[@"permissionKind"] = @"microphone";
        r[@"stage"] = o.permissionRequest ? @"permission-only" : @"permission-status-only";
        __block BOOL completed = NO;
        if (o.permissionRequest && before == AVAuthorizationStatusNotDetermined) {
            r[@"permissionRequested"] = @YES;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                (void)granted; dispatch_async(dispatch_get_main_queue(), ^{ completed = YES; });
            }];
            double start = nowSeconds(); while (!completed && !interrupted.load() && nowSeconds() - start < 45) pump(.02);
            r[@"permissionCallbackReceived"] = @(completed);
        }
        AVAuthorizationStatus after = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        r[@"authorizationAfter"] = authorizationName(after);
        if (o.permissionRequest && after != AVAuthorizationStatusAuthorized) code = 4;
    } else code = runBridge(o, r, reportFD);
    bool written = emit(r, reportFD); if (reportFD >= 0) close(reportFD);
    if (![r[@"cleanupVerified"] boolValue]) _Exit(7);
    return written ? code : 8;
}
@interface PCMApplicationDelegate : NSObject <NSApplicationDelegate> {
@public Options options; int resultCode; BOOL scheduled;
}
- (void)runRequestedAction;
@end
@implementation PCMApplicationDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification; if (scheduled) return; scheduled = YES;
    [self performSelector:@selector(runRequestedAction) withObject:nil afterDelay:0];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender; interrupted.store(true); return NSTerminateCancel;
}
- (void)runRequestedAction {
    resultCode = runAction(options); [NSApp stop:nil];
    NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    if (wake) [NSApp postEvent:wake atStart:YES];
}
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        Options o; NSString *error = parse(argc, argv, o);
        if (error) { emit(@{@"stage": @"argument-error", @"error": error, @"ioStarted": @NO, @"deviceQueries": @NO}); return 2; }
        if (o.help) {
            puts("--bridge --phone-address AA:BB:CC:DD:EE:FF --phone-name NAME --socket /absolute/private/coordinator.sock --token-file /absolute/private/token [--max-seconds 0..2147483647; 0=unlimited] [--report /absolute/private/new.json]\n"
                 "--microphone-permission-status | --request-microphone-permission [--report /absolute/private/new.json]\n"
                 "--validate-args with one action parses only: no AppKit, permission, file, socket or device work.\n"
                 "Bridge waits for authenticated local coordinator start; exact selected Bluetooth endpoints only. No recording, cloud, ASR, default fallback or device-format changes."); return 0;
        }
        if (o.bridge) { inputUID = PBPhoneAudioUID(o.phoneAddress, YES); outputUID = PBPhoneAudioUID(o.phoneAddress, NO); phoneName = o.phoneName; }
        if (o.validate) { emit(@{@"stage": @"arguments-valid", @"ioStarted": @NO, @"deviceQueries": @NO, @"permissionRequested": @NO, @"socketConnected": @NO,
            @"input_uid": inputUID ?: NSNull.null, @"output_uid": outputUID ?: NSNull.null, @"device_name": phoneName ?: NSNull.null}); return 0; }
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGPIPE, SIG_IGN);
        NSApplication *app = NSApplication.sharedApplication; PCMApplicationDelegate *delegate = [PCMApplicationDelegate new];
        delegate->options = o; delegate->resultCode = 9; app.delegate = delegate; [app run]; app.delegate = nil; return delegate->resultCode;
    }
}
