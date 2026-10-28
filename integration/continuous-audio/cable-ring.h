#pragma once
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

// One HAL mixed-output writer, any number of input readers. Atomics prevent
// data races when input and output cycles overlap. No locks or allocations.
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit audio tags must be lock-free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "audio samples must be lock-free");
enum { PB_CABLE_CAPACITY = 32768, PB_CABLE_DELAY = 2048 };
typedef struct {
    atomic_ullong tag;
    atomic_ullong epoch;
    atomic_uint left, right;
} PBCableFrame;
typedef struct { atomic_ullong epoch; PBCableFrame frames[PB_CABLE_CAPACITY]; } PBCableRing;
static inline void PBCableReset(PBCableRing *r) {
    atomic_fetch_add_explicit(&r->epoch, 1, memory_order_seq_cst);
}
static inline void PBCableWrite(PBCableRing *r, int64_t start, unsigned n, const float *samples) {
    uint64_t epoch = atomic_load_explicit(&r->epoch, memory_order_seq_cst);
    for (unsigned i = 0; i < n; ++i) {
        int64_t frame = start + i;
        if (frame < 0) continue;
        PBCableFrame *f = &r->frames[(uint64_t)frame % PB_CABLE_CAPACITY];
        atomic_store_explicit(&f->tag, 0, memory_order_seq_cst);
        float l = isfinite(samples[2*i]) ? samples[2*i] : 0;
        float h = isfinite(samples[2*i+1]) ? samples[2*i+1] : 0;
        uint32_t lb, hb; memcpy(&lb, &l, 4); memcpy(&hb, &h, 4);
        atomic_store_explicit(&f->left, lb, memory_order_seq_cst);
        atomic_store_explicit(&f->right, hb, memory_order_seq_cst);
        atomic_store_explicit(&f->epoch, epoch, memory_order_seq_cst);
        atomic_store_explicit(&f->tag, (uint64_t)frame + 1, memory_order_seq_cst);
    }
}
static inline void PBCableRead(PBCableRing *r, int64_t start, unsigned n, float *samples) {
    uint64_t epoch = atomic_load_explicit(&r->epoch, memory_order_seq_cst);
    memset(samples, 0, n * 2 * sizeof(float));
    for (unsigned i = 0; i < n; ++i) {
        int64_t frame = start + i - PB_CABLE_DELAY;
        if (frame < 0) continue;
        PBCableFrame *f = &r->frames[(uint64_t)frame % PB_CABLE_CAPACITY];
        uint64_t wanted = (uint64_t)frame + 1;
        if (atomic_load_explicit(&f->epoch, memory_order_seq_cst) != epoch) continue;
        if (atomic_load_explicit(&f->tag, memory_order_seq_cst) != wanted) continue;
        if (atomic_load_explicit(&r->epoch, memory_order_seq_cst) != epoch ||
            atomic_load_explicit(&f->epoch, memory_order_seq_cst) != epoch) continue;
        uint32_t l = atomic_load_explicit(&f->left, memory_order_seq_cst);
        uint32_t h = atomic_load_explicit(&f->right, memory_order_seq_cst);
        if (atomic_load_explicit(&f->tag, memory_order_seq_cst) != wanted) continue;
        if (atomic_load_explicit(&r->epoch, memory_order_seq_cst) != epoch ||
            atomic_load_explicit(&f->epoch, memory_order_seq_cst) != epoch) continue;
        memcpy(&samples[2*i], &l, 4); memcpy(&samples[2*i+1], &h, 4);
    }
}
