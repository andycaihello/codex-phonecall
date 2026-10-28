#pragma once
#import <Foundation/Foundation.h>

// Pure argument validation shared by the three native helpers. No Bluetooth,
// CoreAudio, permission or filesystem calls. The selected identity is immutable
// during one helper process; a display name alone never selects a device.
static inline NSString *PBPhoneIdentityError(NSString *address, NSString *name) {
    if (![address isKindOfClass:NSString.class] ||
        [address rangeOfString:@"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$" options:NSRegularExpressionSearch].length != 17 ||
        address.length != 17) return @"phone_address_must_be_canonical_uppercase_Bluetooth_address";
    if (![name isKindOfClass:NSString.class]) return @"phone_name_required";
    NSData *bytes = [name dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!bytes.length || bytes.length > 128 || [name hasPrefix:@"--"] ||
        ![name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return @"phone_name_must_be_nonempty_at_most_128_UTF8_bytes_without_control_characters";
    return nil;
}

static inline NSString *PBPhoneAudioUID(NSString *address, BOOL input) {
    return [[address stringByReplacingOccurrencesOfString:@":" withString:@"-"]
        stringByAppendingString:input ? @":input" : @":output"];
}
