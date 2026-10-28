#import "PBRFCOMMListener.h"

@interface PBRFCOMMListener ()
@property(nonatomic, strong, nullable) IOBluetoothUserNotification *notification;
@end

@implementation PBRFCOMMListener

- (BOOL)isListening {
    return self.notification != nil;
}

- (BOOL)startWithChannelID:(BluetoothRFCOMMChannelID)channelID {
    [self stop];
    // Register the exact local server channel. On macOS 26 the unfiltered
    // compatibility notification can miss a short-lived incoming HFP channel,
    // while the channel-specific incoming notification is delivered in time
    // for the app to answer the phone's AT handshake.
    self.notification = [IOBluetoothRFCOMMChannel
        registerForChannelOpenNotifications:self
        selector:@selector(rfcommChannelOpened:channel:)
        withChannelID:channelID
        direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    return self.notification != nil;
}

- (void)stop {
    [self.notification unregister];
    self.notification = nil;
}

- (void)rfcommChannelOpened:(IOBluetoothUserNotification *)notification
                    channel:(IOBluetoothRFCOMMChannel *)channel {
    if (notification != self.notification) {
        return;
    }
    [self.delegate rfcommListenerDidOpenChannel:channel];
}

- (void)dealloc {
    [self stop];
}

@end
