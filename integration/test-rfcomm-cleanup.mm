#define main phonebridge_production_main
#include "bluetooth-call-control.mm"
#undef main
#include <cassert>
@interface TestOwnedChannel : NSObject
@property uint8_t channelID;
@end
@implementation TestOwnedChannel
@end
@interface TestClosePeer : NSObject
@property NSMutableArray *requests;
@property id RFCOMMChannels;
- (void)closeRFCOMMChannel:(uint8_t)n;
@end
@implementation TestClosePeer
- (instancetype)init { if ((self = [super init])) { _requests = [NSMutableArray array]; _RFCOMMChannels = [NSMutableArray array]; } return self; }
- (void)closeRFCOMMChannel:(uint8_t)n { [self.requests addObject:@(n)]; }
@end
static BTController *fixture() {
    BTController *c = [BTController new]; TestClosePeer *p = [TestClosePeer new]; c.peer = p;
    for (NSString *name in @[@"helper", @"hfp"]) {
        TestOwnedChannel *ch = [TestOwnedChannel new]; ch.channelID = [name isEqual:@"helper"] ? 9 : 3;
        BTSlot *slot = [BTSlot new]; slot.name = name; slot.channelID = ch.channelID; slot.channel = ch; slot.fd = 99;
        c.slots[name] = slot; [p.RFCOMMChannels addObject:ch];
    }
    c->hfp.ready = c->hfp.idleVerified = true; c->hfp.call = c->hfp.setup = c->hfp.held = 0;
    c.helperStateKnown = c.helperCleanupSucceeded = YES;
    return c;
}
static void completeFirstMatchingPeerChannel(BTController *c) {
    TestClosePeer *p = c.peer;
    id first = [p.RFCOMMChannels firstObject];
    [p.RFCOMMChannels removeObjectAtIndex:0];
    [c closed:first error:0];
}
int main() { @autoreleasepool {
    BTController *c = [BTController new]; TestClosePeer *peer = [TestClosePeer new]; c.peer = peer;
    TestOwnedChannel *hf = [TestOwnedChannel new]; hf.channelID = 3;
    TestOwnedChannel *helper = [TestOwnedChannel new]; helper.channelID = 9;
    for (NSString *name in @[@"hfp", @"helper"]) {
        BTSlot *s = [BTSlot new]; s.name = name; s.channel = [name isEqual:@"hfp"] ? hf : helper;
        s.channelID = [name isEqual:@"hfp"] ? 3 : 9; s.fd = 99; c.slots[name] = s;
    }
    [c closeSlot:c.slots[@"hfp"]]; [c closeSlot:c.slots[@"hfp"]];
    assert([peer.requests isEqual:@[@3]]); assert(!c.slots[@"hfp"].closed);
    [c closed:helper error:0]; assert(c.slots[@"helper"].closed); assert(!c.slots[@"hfp"].closed);
    TestOwnedChannel *replacement = [TestOwnedChannel new]; replacement.channelID = 3;
    [c closed:replacement error:0]; assert(!c.slots[@"hfp"].closed);
    [c closed:nil error:0]; assert(!c.slots[@"hfp"].closed);
    [c closed:hf error:0]; assert(c.slots[@"hfp"].closed); assert(c.slots[@"hfp"].fd == -1);
    assert([c.slots[@"hfp"].closeEvidence isEqual:@"retained_object_disconnect_callback"]);
    [c closeSlot:c.slots[@"hfp"]]; assert(peer.requests.count == 1);
    assert(closeCallbackGraceSeconds == 3.0);
    // Model daemon selecting the first same-peer entry (helper9) for close3.
    BTController *flow = fixture(); TestClosePeer *fp = flow.peer;
    [flow closeSlot:flow.slots[@"hfp"]]; completeFirstMatchingPeerChannel(flow);
    assert(flow.helperCloseProgressObserved && !flow.shutdown);
    [flow progressOwnedCloseAfterCallback]; assert(fp.requests.count == 1);
    flow.shutdown = flow.closesStarted = YES; flow.closeAt = now();
    [flow progressOwnedCloseAfterCallback]; assert(([fp.requests isEqual:@[@3, @3]]));
    assert(!flow.slots[@"hfp"].closed && flow.slots[@"hfp"].closeProgressRetryUsed);
    [flow progressOwnedCloseAfterCallback]; assert(fp.requests.count == 2);
    completeFirstMatchingPeerChannel(flow);
    assert(flow.slots[@"helper"].closed && flow.slots[@"hfp"].closed);
    [flow progressOwnedCloseAfterCallback]; assert(fp.requests.count == 2);
    // Each missing guard rejects the second request, without touching devices.
    for (int scenario = 0; scenario < 16; ++scenario) {
        BTController *guarded = fixture(); TestClosePeer *gp = guarded.peer;
        [guarded closeSlot:guarded.slots[@"hfp"]]; completeFirstMatchingPeerChannel(guarded);
        guarded.shutdown = guarded.closesStarted = YES; guarded.closeAt = now();
        switch (scenario) {
            case 0: guarded.shutdown = NO; break;
            case 1: guarded.closesStarted = NO; break;
            case 2: guarded.opening = @{@"id":@"pending"}; break;
            case 3: guarded->hfp.idleVerified = false; break;
            case 4: guarded->hfp.call = 1; break;
            case 5: guarded->hfp.setup = 1; break;
            case 6: guarded->hfp.held = 1; break;
            case 7: guarded->hfp.ownDial = true; break;
            case 8: guarded.helperStateKnown = NO; break;
            case 9: guarded.helperActive = YES; break;
            case 10: guarded.helperPendingConnect = YES; break;
            case 11: guarded.helperCleanupSucceeded = NO; break;
            case 12: [gp.RFCOMMChannels addObject:[TestOwnedChannel new]]; break;
            case 13: guarded.closeAt = now() - 3.1; break;
            case 14: guarded.helperCloseProgressObserved = NO; break;
            case 15: guarded->hfp.enqueue("refresh", "pending"); break;
        }
        [guarded progressOwnedCloseAfterCallback]; assert(gp.requests.count == 1);
    }
    // Actual framework metadata uses a weak NSHashTable, not NSArray.
    for (int scenario = 0; scenario < 5; ++scenario) {
        BTController *hc = fixture(); TestClosePeer *hp = hc.peer;
        [hc closeSlot:hc.slots[@"hfp"]]; completeFirstMatchingPeerChannel(hc);
        hc.shutdown = hc.closesStarted = YES; hc.closeAt = now();
        NSHashTable *table = [NSHashTable weakObjectsHashTable];
        TestOwnedChannel *other = [TestOwnedChannel new]; other.channelID = 3;
        if (scenario != 2 && scenario != 3) [table addObject:hc.slots[@"hfp"].channel];
        if (scenario == 1 || scenario == 3) [table addObject:other];
        if (scenario == 4) [table addObject:hc.slots[@"helper"].channel];
        hp.RFCOMMChannels = table;
        [hc progressOwnedCloseAfterCallback];
        assert(hp.requests.count == (scenario == 0 ? 2u : 1u));
        assert([hc.closeProgressBlockReason isEqual:scenario == 0 ? @"none" :
            scenario == 2 ? @"retained_HFP_missing_from_peer_cache" : @"unowned_or_ambiguous_cached_channel"]);
    }
    emit(@{@"event":@"offline_cleanup_test", @"passed":@YES, @"cases":@44, @"deviceQueries":@NO,
        @"realTransportUsed":@NO, @"fakePeerCloseRequests":peer.requests});
} return 0; }
