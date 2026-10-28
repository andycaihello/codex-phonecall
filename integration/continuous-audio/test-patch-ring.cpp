#include "PBVoicePatchRing.h"
#include <cassert>
#include <atomic>
#include <thread>
#include <cstdio>
#include <cmath>
int main() {
    assert(PBVoicePatchCreate(511)==nullptr);
    auto *ring=PBVoicePatchCreate(512); assert(ring);
    float stereo[8]={1,0,.5f,-.5f,NAN,1,INFINITY,0}, output[6]={};
    AudioBufferList input={1,{{2,sizeof(stereo),stereo}}}, out={1,{{1,sizeof(output),output}}};
    assert(PBVoicePatchCapture(ring,&input,4)==4);
    assert(PBVoicePatchRender(ring,&out,6)==4);
    assert(output[0]==.5f && output[1]==0 && output[2]==.5f && output[3]==0 && output[4]==0 && output[5]==0);
    auto s=PBVoicePatchGetStats(ring); assert(s.queuedFrames==0 && s.missingFrames==2);
    input.mBuffers[0].mDataByteSize=1; assert(PBVoicePatchCapture(ring,&input,4)==0);
    s=PBVoicePatchGetStats(ring); assert(s.captureCallbacks==2 && s.offeredFrames==8 && s.rejectedFrames==4 && s.lastRejectCode==4);
    PBVoicePatchDestroy(ring);
    ring=PBVoicePatchCreate(512); std::atomic<bool> done{false};
    std::thread producer([&]{
        for(unsigned i=1;i<=200000;i++) {
            float value=float(i);AudioBufferList buffer={1,{{1,sizeof(value),&value}}};
            while(!PBVoicePatchCapture(ring,&buffer,1)) std::this_thread::yield();
        }
        done=true;
    });
    unsigned expected=1;
    while(!done || PBVoicePatchGetStats(ring).queuedFrames) {
        float samples[31];AudioBufferList buffer={1,{{1,sizeof(samples),samples}}};
        auto n=PBVoicePatchRender(ring,&buffer,31);
        for(unsigned i=0;i<n;i++) assert(samples[i]==float(expected++));
        for(unsigned i=n;i<31;i++) assert(samples[i]==0);
    }
    producer.join(); assert(expected==200001);
    PBVoicePatchDestroy(ring);
    puts("PASS: bounded allocation, stereo downmix, nonfinite sanitization, underrun silence, invalid buffers, 200000 ordered concurrent frames. No audio devices opened.");
}
