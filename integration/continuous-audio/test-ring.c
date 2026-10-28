#include "cable-ring.h"
#include <assert.h>
#include <stdio.h>
#include <pthread.h>
static PBCableRing ring;
static atomic_bool done;
static void *writer(void *unused) {
    for(int64_t f=0;f<200000;f++) {
        float x[2] = {(float)(f+1),-(float)(f+1)};
        PBCableWrite(&ring,f,1,x);
        if(f%1703==0) PBCableReset(&ring);
    }
    atomic_store(&done, true); return NULL;
}
int main(void) {
    float x[2] = {NAN,INFINITY}, out[2];
    PBCableWrite(&ring,0,1,x); PBCableRead(&ring,PB_CABLE_DELAY,1,out);
    assert(out[0]==0 && out[1]==0);
    x[0]=.5; x[1]=-.5;
    PBCableWrite(&ring,1,1,x); PBCableRead(&ring,PB_CABLE_DELAY+1,1,out);
    assert(out[0]==.5 && out[1]==-.5);
    PBCableReset(&ring); PBCableRead(&ring,PB_CABLE_DELAY+1,1,out);
    assert(out[0]==0 && out[1]==0);
    pthread_t thread; assert(pthread_create(&thread,NULL,writer,NULL)==0);
    unsigned reads=0;
    while(!atomic_load(&done)) for(int64_t i=0;i<200000;i+=97) {
        PBCableRead(&ring,i+PB_CABLE_DELAY,1,out);
        assert(out[0]==-out[1]); assert(out[0]==0 || out[0]==i+1); reads++;
    }
    pthread_join(thread,NULL);
    printf("PASS: nonfinite sanitization, epoch flush, 200000 writes with concurrent reads and recipient resets (%u reads).\n",reads);
}
