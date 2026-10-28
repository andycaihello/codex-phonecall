#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static OSStatus changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) { return 0; }
static OSStatus readStorage(AudioServerPlugInHostRef h, CFStringRef key, CFPropertyListRef *out) { *out = NULL; return 0; }
static OSStatus writeStorage(AudioServerPlugInHostRef h, CFStringRef key, CFPropertyListRef data) { return 0; }
static OSStatus deleteStorage(AudioServerPlugInHostRef h, CFStringRef key) { return 0; }
static OSStatus configuration(AudioServerPlugInHostRef h, AudioObjectID o, UInt64 change, void *data) { return 0; }
static AudioServerPlugInHostInterface host = {changed, readStorage, writeStorage, deleteStorage, configuration};
typedef void *(*Factory)(CFAllocatorRef, CFUUIDRef);
static AudioServerPlugInDriverRef load(const char *path, const char *expectedUID) {
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL); assert(lib && "driver must load without installing");
    Factory factory = (Factory)dlsym(lib, "NullAudio_Create"); assert(factory);
    AudioServerPlugInDriverRef d = factory(NULL, kAudioServerPlugInTypeUUID); assert(d);
    assert((*d)->Initialize(d, &host) == 0);
    AudioObjectPropertyAddress uid = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, 0};
    CFStringRef value = NULL; UInt32 size = 0;
    assert((*d)->GetPropertyData(d, 3, 0, &uid, 0, NULL, sizeof(value), &size, &value) == 0);
    char text[256]; assert(CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8)); CFRelease(value);
    assert(strcmp(text, expectedUID) == 0);
    AudioObjectPropertyAddress info = {kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal, 0};
    AudioServerPlugInCustomPropertyInfo custom;
    assert((*d)->GetPropertyData(d, 3, 0, &info, 0, NULL, sizeof(custom), &size, &custom) == 0);
    assert(custom.mSelector == 0x5042666C && custom.mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    AudioObjectPropertyAddress allInfo = {kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal, 0};
    AudioServerPlugInCustomPropertyInfo entries[2];
    assert((*d)->GetPropertyData(d, kAudioObjectPlugInObject, 0, &allInfo, 0, NULL, sizeof(entries), &size, entries) == 0);
    assert(size == sizeof(entries) && entries[1].mSelector == 0x5042666C && entries[1].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert((*d)->StartIO(d, 3, 100) == 0);
    return d;
}
static void io(AudioServerPlugInDriverRef d, bool output, double frame, float *samples) {
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mSampleTime = cycle.mOutputTime.mSampleTime = frame;
    assert((*d)->DoIOOperation(d, 3, output ? 8 : 4, 100,
        output ? kAudioServerPlugInIOOperationWriteMix : kAudioServerPlugInIOOperationReadInput,
        4, &cycle, samples, NULL) == 0);
}
int main(int argc, const char **argv) {
    assert(argc == 3);
    AudioServerPlugInDriverRef a = load(argv[1], "cn.andy.phonebridge.audio.input.device");
    AudioServerPlugInDriverRef b = load(argv[2], "cn.andy.phonebridge.audio.output.device");
    float written[8] = {.25f,-.25f,.5f,-.5f,.75f,-.75f,1,-1}, read[8];
    io(a, true, 100, written); io(a, false, 100 + 2048, read);
    assert(memcmp(written, read, sizeof(read)) == 0);
    io(b, false, 100 + 2048, read);
    for(int i=0;i<8;i++) assert(read[i] == 0); // no AI self-loop across cables
    assert((*a)->StartIO(a, 3, 101) == 0);
    assert((*a)->StopIO(a, 3, 100) == 0);
    io(a, false, 100 + 2048, read);
    assert(memcmp(written, read, sizeof(read)) == 0); // other client keeps clock/data
    AudioObjectPropertyAddress flush = {0x5042666C, kAudioObjectPropertyScopeGlobal, 0}; SInt32 command = 1;
    CFNumberRef payload = CFNumberCreate(NULL,kCFNumberSInt32Type,&command);
    assert((*a)->SetPropertyData(a, 3, 0, &flush, 0, NULL, sizeof(payload), &payload) == 0);
    CFRelease(payload);
    io(a, false, 100 + 2048, read);
    for(int i=0;i<8;i++) assert(read[i] == 0); // previous recipient's buffered audio discarded
    command = 2; payload = CFNumberCreate(NULL,kCFNumberSInt32Type,&command);
    assert((*a)->SetPropertyData(a, 3, 0, &flush, 0, NULL, sizeof(payload), &payload) != 0); CFRelease(payload);
    io(a, true, 104, written); io(a, false, 104 + 2048, read);
    assert(memcmp(written, read, sizeof(read)) == 0);
    assert((*a)->StopIO(a, 3, 101) == 0);
    assert((*a)->StartIO(a, 3, 102) == 0);
    io(a, false, 104 + 2048, read);
    for(int i=0;i<8;i++) assert(read[i] == 0); // fresh lifecycle cannot replay old samples
    assert((*a)->StopIO(a, 3, 102) == 0); assert((*b)->StopIO(b, 3, 100) == 0);
    puts("PASS: both driver interfaces, distinct identities, loopback, directional isolation, multiple-client lifetime, flush, malformed flush rejection, no replay after restart. No HAL installation, microphone, audio output or telephone call.");
}
