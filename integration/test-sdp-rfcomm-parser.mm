#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include "sdp-rfcomm-parser.h"
#include <cassert>

static IOBluetoothSDPDataElement *element(NSObject *v) { return [IOBluetoothSDPDataElement withElementValue:v]; }
static NSDictionary *unsignedValue(NSNumber *n) { return @{@"DataElementType":@1,@"DataElementSize":@1,@"DataElementValue":n}; }
static NSObject *uuid(uint16_t n) { return [IOBluetoothSDPUUID uuid16:n]; }
int main() {
    @autoreleasepool {
        unsigned cases=0;
        for (NSNumber *n in @[@3,@2,@9,@1,@30]) {
            auto list=element(@[@[uuid(0x0100)],@[uuid(3),unsignedValue(n)]]);
            auto p=PBParseRFCOMMProtocol(list); assert(p.ok && p.channel==n.unsignedIntValue); ++cases;
            p=PBParseRFCOMMProtocol(element(@[uuid(3),unsignedValue(n)])); assert(p.ok && p.channel==n.unsignedIntValue); ++cases;
        }
        for (NSObject *value in @[@[], @[uuid(3)], @[@[uuid(0x0100)]], @[@[uuid(3),@3,@4]],
              @[@[uuid(3),@3],@[uuid(3),@3]], @[@[uuid(3),@3],@[uuid(3),@9]],
              @[@[uuid(3),unsignedValue(@0)]], @[@[uuid(3),unsignedValue(@31)]],
              @[@[uuid(3),@{@"DataElementType":@2,@"DataElementSize":@1,@"DataElementValue":@3}]],
              @[@[uuid(3),@{@"DataElementType":@5,@"DataElementValue":@YES}]], @[@[@3,@3]], @"not-a-sequence"]) {
            assert(!PBParseRFCOMMProtocol(element(value)).ok); ++cases;
        }
        assert(!PBParseRFCOMMProtocol(nil).ok); ++cases;
        // Deliberately malformed local numeric objects: boolean disguised as uint,
        // negative, fractional, and a missing numeric payload must all be rejected.
        for (NSNumber *n in @[@YES,@(-1),@(1.5)]) {
            auto v=[IOBluetoothSDPDataElement withType:1 sizeDescriptor:0 size:1 value:n];
            auto u=element(uuid(3));
            auto row=[IOBluetoothSDPDataElement withType:6 sizeDescriptor:5 size:0 value:@[u,v]];
            assert(!PBParseRFCOMMProtocol(row).ok); ++cases;
        }
        auto target=[IOBluetoothSDPUUID uuid16:0x111f];
        assert(PBServiceClassMatches(element(target), target)); ++cases;
        assert(PBServiceClassMatches(element(@[target]), target)); ++cases;
        assert(PBServiceClassMatches(element([IOBluetoothSDPUUID uuid32:0x111f]), target)); ++cases;
        assert(!PBServiceClassMatches(element(uuid(0x1112)), target)); ++cases;
        // Construct an unpublished, device-less record. This exercises the actual
        // SDK getter mapping without any device query or SDP publication.
        auto record=[IOBluetoothSDPServiceRecord withServiceDictionary:@{
          @1:element(@[target]),
          @4:element(@[@[uuid(0x0100)],@[uuid(3),unsignedValue(@3)]])} device:nil];
        assert(record);
        auto parsed=PBParseRFCOMMProtocol([record getAttributeDataElement:4]); assert(parsed.ok && parsed.channel==3);
        BluetoothRFCOMMChannelID legacy=0; auto rc=[record getRFCOMMChannelID:&legacy]; assert(rc==0);
        // Do not require every OS to remap: selection must remain the real raw 3 either way.
        assert(parsed.channel==3); ++cases;
        printf("{\"passed\":true,\"cases\":%u,\"rawChannel\":3,\"getterChannel\":%u,\"getterDisagrees\":%s,\"deviceQueries\":false,\"servicePublished\":false}\n",cases,legacy,legacy!=3?"true":"false");
    }
}
