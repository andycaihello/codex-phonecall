#pragma once
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <cmath>

// Local SDP object inspection only. No query, publication, device or transport API.
static inline bool PBServiceClassMatches(IOBluetoothSDPDataElement *element, IOBluetoothSDPUUID *wanted) {
    if (![element isKindOfClass:IOBluetoothSDPDataElement.class] || !wanted) return false;
    if (element.getUUIDValue) return [element.getUUIDValue isEqualToUUID:wanted];
    NSArray *values = element.getArrayValue;
    if (![values isKindOfClass:NSArray.class] || values.count > 32) return false;
    for (id value in values) {
        if ([value isKindOfClass:IOBluetoothSDPDataElement.class] && [[value getUUIDValue] isEqualToUUID:wanted]) return true;
    }
    return false;
}
struct PBRFCOMMParseResult {
    bool ok = false;
    uint8_t channel = 0;
    unsigned matches = 0;
    const char *error = "missing_protocol_descriptor";
};
static inline PBRFCOMMParseResult PBParseRFCOMMProtocol(IOBluetoothSDPDataElement *protocols) {
    PBRFCOMMParseResult result;
    if (![protocols isKindOfClass:IOBluetoothSDPDataElement.class]) return result;
    NSArray *outer = protocols.getArrayValue;
    if (![outer isKindOfClass:NSArray.class] || outer.count == 0 || outer.count > 32) return result;
    // A ProtocolDescriptorList usually contains descriptor sequences. Also
    // accept a single RFCOMM descriptor sequence when the SDK presents it directly.
    id first = outer.firstObject;
    bool directDescriptor = [first isKindOfClass:IOBluetoothSDPDataElement.class] && [first getUUIDValue] != nil;
    NSArray *rows = directDescriptor ? @[protocols] : outer;
    IOBluetoothSDPUUID *rfcomm = [IOBluetoothSDPUUID uuid16:0x0003];
    for (id row in rows) {
        if (![row isKindOfClass:IOBluetoothSDPDataElement.class]) { result.error="invalid_protocol_row"; return result; }
        NSArray *fields = [row getArrayValue];
        if (![fields isKindOfClass:NSArray.class] || fields.count == 0 || fields.count > 16 ||
            ![fields.firstObject isKindOfClass:IOBluetoothSDPDataElement.class]) { result.error="invalid_protocol_fields"; return result; }
        IOBluetoothSDPUUID *uuid = [fields.firstObject getUUIDValue];
        if (!uuid) { result.error="missing_protocol_UUID"; return result; }
        if (![uuid isEqualToUUID:rfcomm]) continue;
        ++result.matches;
        if (result.matches != 1) { result.error="ambiguous_RFCOMM_descriptors"; return result; }
        if (fields.count != 2 || ![fields[1] isKindOfClass:IOBluetoothSDPDataElement.class]) { result.error="RFCOMM_requires_exactly_one_channel"; return result; }
        IOBluetoothSDPDataElement *value = fields[1];
        NSNumber *number = value.getNumberValue;
        // SDP numeric types 1/2/5 all return NSNumber. Require unsigned integer
        // type 1 explicitly; a boolean or signed channel is never accepted.
        if (value.getTypeDescriptor != 1 || ![number isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) { result.error="RFCOMM_channel_must_be_unsigned_integer"; return result; }
        double numeric = number.doubleValue;
        if (!std::isfinite(numeric) || std::floor(numeric) != numeric || numeric < 1 || numeric > 30) {
            result.error="RFCOMM_channel_out_of_range"; return result;
        }
        result.channel = uint8_t(number.unsignedIntValue);
    }
    if (result.matches != 1) { result.error="RFCOMM_descriptor_missing"; return result; }
    result.ok = true; result.error = ""; return result;
}
