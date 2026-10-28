#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include "PBVoicePatchRing.h"

NS_ASSUME_NONNULL_BEGIN

@protocol PBRFCOMMListenerDelegate <NSObject>
- (void)rfcommListenerDidOpenChannel:(IOBluetoothRFCOMMChannel *)channel;
@end

/// Thin Objective-C adapter around IOBluetooth's Objective-C notification API.
/// Keeping the selector in Objective-C avoids Swift selector/import ambiguity in
/// the legacy framework on current macOS releases.
@interface PBRFCOMMListener : NSObject
@property(nonatomic, weak, nullable) id<PBRFCOMMListenerDelegate> delegate;
@property(nonatomic, readonly, getter=isListening) BOOL listening;
- (BOOL)startWithChannelID:(BluetoothRFCOMMChannelID)channelID;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
