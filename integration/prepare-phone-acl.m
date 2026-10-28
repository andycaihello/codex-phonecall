// Public, single-purpose ACL preparation. No SDP, RFCOMM, profile, audio, dial,
// or callback replacement. A previously connected selected phone is explicitly
// disconnected and reopened so its newly published companion services are not
// hidden by a stale macOS SDP cache. The fresh ACL is left to the controller.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "phone-identity-arguments.h"

static NSString *PhoneAddress = nil;
static NSString *PhoneName = nil;
static volatile sig_atomic_t ReceivedSignal = 0;
static atomic_bool ParentExited = false, AcceptCallback = false, CallbackSeen = false;
static atomic_bool FreshRequested = false, SubmitSeen = false, ConnectedBeforeKnown = false, ConnectedBefore = false;
static atomic_bool ConnectedObservedKnown = false, ConnectedObserved = false, ReportClaimed = false;
static atomic_bool CloseRequested = false, DisconnectedObserved = false;
static atomic_int CallbackStatus = 0, SubmitStatus = 0, CloseStatus = 0;
static double Started = 0;
static pid_t OwnerPID = 0;

static double Now(void) {
    struct timespec value = {}; clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}
static void OnSignal(int value) { if (!ReceivedSignal) ReceivedSignal = value; }
static BOOL Stopping(void) { return ReceivedSignal || atomic_load(&ParentExited) || Now() - Started >= 11.5; }
static NSString *Normalized(NSString *address) {
    return [address.uppercaseString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
}
static void WriteOnce(const void *bytes, size_t count) {
    if (atomic_exchange_explicit(&ReportClaimed, true, memory_order_acq_rel)) return;
    // One small JSON record, below PIPE_BUF. A closed owner pipe is not retried.
    ssize_t written; do { written = write(STDOUT_FILENO, bytes, count); } while (written < 0 && errno == EINTR);
}
static void Emit(NSDictionary *report) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy]; const char newline = '\n'; [line appendBytes:&newline length:1];
    WriteOnce(line.bytes, line.length);
}
static void *Watch(void *unused) {
    (void)unused; double stoppedAt = 0;
    for (;;) {
        if (getppid() != OwnerPID) atomic_store(&ParentExited, true);
        double now = Now();
        if ((ReceivedSignal || atomic_load(&ParentExited)) && !stoppedAt) stoppedAt = now;
        if (now - Started >= 12 || (stoppedAt && now - stoppedAt >= .25)) {
            atomic_store_explicit(&AcceptCallback, false, memory_order_release);
            char record[1800];
            BOOL callback = atomic_load_explicit(&CallbackSeen, memory_order_acquire);
            BOOL fresh = atomic_load(&FreshRequested);
            int status = callback ? atomic_load(&CallbackStatus) : atomic_load(&SubmitStatus);
            char statusValue[32] = "null";
            if (callback || atomic_load_explicit(&SubmitSeen, memory_order_acquire)) snprintf(statusValue, sizeof(statusValue), "%d", status);
            int count = snprintf(record, sizeof(record),
                "{\"ok\":false,\"stage\":\"%s\",\"connectedBefore\":%s,\"freshACLRequested\":%s,"
                "\"callbackSeen\":%s,\"status\":%s,\"connectedObserved\":%s,\"connectionPreserved\":true,"
                "\"cleanupClaimed\":false,\"connectionCloseRequested\":%s,\"disconnectedObserved\":%s,\"sdpRequested\":false,"
                "\"rfcommRequested\":false,\"audioRequested\":false,\"dialed\":false,\"elapsedSeconds\":%.6f,"
                "\"nativePendingMayRemain\":%s,\"connectionPreservedMeaning\":\"The refreshed selected-phone ACL is handed to the controller; post-exit retention is not guaranteed\"}\n",
                stoppedAt ? "interrupted-during-public-operation" : "hard-deadline",
                atomic_load(&ConnectedBeforeKnown) ? (atomic_load(&ConnectedBefore) ? "true" : "false") : "null",
                fresh ? "true" : "false", callback ? "true" : "false", statusValue,
                atomic_load(&ConnectedObservedKnown) ? (atomic_load(&ConnectedObserved) ? "true" : "false") : "null",
                atomic_load(&CloseRequested) ? "true" : "false", atomic_load(&DisconnectedObserved) ? "true" : "false",
                now - Started, fresh && !callback ? "true" : "false");
            if (count > 0 && (size_t)count < sizeof(record)) WriteOnce(record, (size_t)count);
            _Exit(ReceivedSignal ? 128 + ReceivedSignal : atomic_load(&ParentExited) ? 125 : 124);
        }
        struct timespec pause = {0, 5000000}; nanosleep(&pause, NULL);
    }
    return NULL;
}
@interface ACLPreparationObserver : NSObject
@end
@implementation ACLPreparationObserver
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (!atomic_load_explicit(&AcceptCallback, memory_order_acquire)) return;
    if (![Normalized(device.addressString) isEqualToString:PhoneAddress]) return;
    // This callback records only the result of our request. It never opens a
    // profile/channel, changes a callback owner, dials, or follows up on a late event.
    if (!atomic_load_explicit(&AcceptCallback, memory_order_acquire)) return;
    atomic_store_explicit(&CallbackStatus, status, memory_order_relaxed);
    atomic_store_explicit(&CallbackSeen, true, memory_order_release);
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL prepare = NO, validate = NO, continuedAfterReset = NO, bad = NO;
        NSMutableSet *seen = [NSMutableSet set];
        for (int i = 1; i < argc; ++i) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (!arg || [seen containsObject:arg]) { bad = YES; break; }
            [seen addObject:arg];
            if (!strcmp(argv[i], "--prepare-paired-phone") && !prepare) prepare = YES;
            else if (!strcmp(argv[i], "--validate-args") && !validate) validate = YES;
            else if (!strcmp(argv[i], "--continued-after-stale-reset") && !continuedAfterReset) continuedAfterReset = YES;
            else if (([arg isEqualToString:@"--phone-address"] || [arg isEqualToString:@"--phone-name"]) && ++i < argc) {
                NSString *value = [NSString stringWithUTF8String:argv[i]];
                if ([arg isEqualToString:@"--phone-address"]) PhoneAddress = value;
                else PhoneName = value;
            }
            else bad = YES;
        }
        if (bad || !prepare || PBPhoneIdentityError(PhoneAddress, PhoneName)) {
            Emit(@{@"ok": @NO, @"stage": @"argument-error", @"error": @"Use --prepare-paired-phone --phone-address AA:BB:CC:DD:EE:FF --phone-name NAME [--validate-args]; valid explicit identity required",
                @"deviceQueries": @NO, @"freshACLRequested": @NO, @"connectionPreserved": @YES}); return 2;
        }
        if (validate) {
            Emit(@{@"ok": @YES, @"stage": @"arguments-valid", @"deviceQueries": @NO,
                @"freshACLRequested": @NO, @"callbackSeen": @NO, @"connectionPreserved": @YES,
                @"cleanupClaimed": @NO, @"maxSeconds": @12}); return 0;
        }
        signal(SIGTERM, OnSignal); signal(SIGINT, OnSignal); signal(SIGPIPE, SIG_IGN);
        OwnerPID = getppid(); Started = Now(); pthread_t watchdog;
        if (pthread_create(&watchdog, NULL, Watch, NULL)) {
            Emit(@{@"ok": @NO, @"stage": @"watchdog-start-failed", @"deviceQueries": @NO,
                @"freshACLRequested": @NO, @"callbackSeen": @NO, @"connectionPreserved": @YES}); return 3;
        }
        pthread_detach(watchdog);
        NSMutableDictionary *report = [@{@"ok": @NO, @"connectedBefore": NSNull.null, @"freshACLRequested": @NO,
            @"callbackSeen": @NO, @"status": NSNull.null, @"connectedObserved": NSNull.null,
            @"connectionPreserved": @YES, @"connectionCloseRequested": @NO, @"disconnectedObserved": @NO,
            @"cleanupClaimed": @NO,
            @"sdpRequested": @NO, @"rfcommRequested": @NO, @"audioRequested": @NO, @"dialed": @NO,
            @"deviceQueries": @NO, @"maxSeconds": @12, @"stage": @"not-prepared",
            @"connectionPreservedMeaning": @"A fresh selected-phone ACL is left to the subsequent control process; post-exit retention is not guaranteed"} mutableCopy];
        IOBluetoothDevice *device = nil; ACLPreparationObserver *observer = [ACLPreparationObserver new];
        BOOL verified = NO; int exitCode = 1;
        if (!Stopping()) {
            report[@"deviceQueries"] = @YES;
            // IOBluetooth's first CoreBluetooth coordinator initialization can
            // synchronously wait for a callback delivered on the main queue.
            // Resolve identity on a worker while keeping the main run loop live.
            // The semaphore publishes the retained object and identity result;
            // the watchdog still bounds a framework call that never returns.
            __block IOBluetoothDevice *resolvedDevice = nil;
            __block BOOL resolvedIdentity = NO;
            dispatch_semaphore_t lookup = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    resolvedDevice = [IOBluetoothDevice deviceWithAddressString:PhoneAddress];
                    resolvedIdentity = resolvedDevice && resolvedDevice.isPaired &&
                        [Normalized(resolvedDevice.addressString) isEqualToString:PhoneAddress] &&
                        [resolvedDevice.name isEqualToString:PhoneName];
                    dispatch_semaphore_signal(lookup);
                }
            });
            BOOL lookupReady = NO;
            while (!Stopping()) {
                if (dispatch_semaphore_wait(lookup, DISPATCH_TIME_NOW) == 0) { lookupReady = YES; break; }
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                        beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            }
            if (lookupReady) { device = resolvedDevice; verified = resolvedIdentity; }
            report[@"pairedIdentityVerified"] = @(verified);
        }
        if (!verified) report[@"stage"] = @"fixed-paired-phone-not-verified";
        else if (!Stopping()) {
            if (continuedAfterReset) {
                double resetSettleMinimum = Now() + 3.0;
                double resetSettleDeadline = Now() + 5.0;
                while (!Stopping() && Now() < resetSettleDeadline &&
                       (device.isConnected || Now() < resetSettleMinimum)) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:.025]];
                }
            }
            BOOL actualBefore = device.isConnected;
            BOOL before = actualBefore || continuedAfterReset;
            atomic_store(&ConnectedBefore, before); atomic_store(&ConnectedBeforeKnown, true);
            report[@"connectedBefore"] = @(before);
            if (continuedAfterReset) report[@"continuedAfterStaleReset"] = @YES;
            if (actualBefore && continuedAfterReset) {
                // The previous process observed the selected ACL go down. If
                // the fresh process now sees it connected after the settle
                // window, this is a new ACL even when the system initiated the
                // reconnect before our explicit page request.
                atomic_store(&DisconnectedObserved, true); report[@"disconnectedObserved"] = @YES;
                atomic_store(&ConnectedObserved, true); atomic_store(&ConnectedObservedKnown, true);
                report[@"connectedObserved"] = @YES;
                report[@"postResetConnectionObserved"] = @YES;
                report[@"status"] = @0;
                report[@"ok"] = @YES;
                report[@"stage"] = @"stale-acl-reset-and-system-reconnect-ready";
                exitCode = 0;
            } else if (actualBefore) {
                atomic_store(&CloseRequested, true); report[@"connectionCloseRequested"] = @YES;
                IOReturn closeStatus = [device closeConnection];
                atomic_store(&CloseStatus, closeStatus); report[@"closeStatus"] = @(closeStatus);
                double closeDeadline = Now() + 3.0;
                while (closeStatus == kIOReturnSuccess && device.isConnected && !Stopping() && Now() < closeDeadline) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.025]];
                }
                BOOL disconnected = !device.isConnected;
                atomic_store(&DisconnectedObserved, disconnected); report[@"disconnectedObserved"] = @(disconnected);
                if (closeStatus != kIOReturnSuccess || !disconnected) {
                    report[@"stage"] = @"stale-acl-reset-not-verified";
                } else if (!Stopping()) {
                    // Re-exec the tiny helper after the confirmed close. On
                    // macOS the process that issued closeConnection can receive
                    // a success callback for an immediate reopen while the ACL
                    // remains down. A fresh process reliably starts a new page
                    // transaction and keeps this reset invisible to the app.
                    execl(argv[0], argv[0], "--prepare-paired-phone",
                          "--phone-address", PhoneAddress.UTF8String,
                          "--phone-name", PhoneName.UTF8String,
                          "--continued-after-stale-reset", (char *)NULL);
                    report[@"stage"] = @"stale-acl-reset-reexec-failed";
                    report[@"execErrno"] = @(errno);
                }
            } else {
                atomic_store(&DisconnectedObserved, true); report[@"disconnectedObserved"] = @YES;
            }
            if (!actualBefore && atomic_load(&DisconnectedObserved) && !Stopping()) {
                  atomic_store_explicit(&AcceptCallback, true, memory_order_release);
                  atomic_store(&FreshRequested, true); report[@"freshACLRequested"] = @YES;
                // Public asynchronous baseband request. 0x2000 slots = 5.12 s.
                IOReturn submitted = [device openConnection:observer withPageTimeout:0x2000 authenticationRequired:YES];
                atomic_store(&SubmitStatus, submitted); atomic_store_explicit(&SubmitSeen, true, memory_order_release);
                report[@"submitStatus"] = @(submitted);
                while (submitted == kIOReturnSuccess && !atomic_load_explicit(&CallbackSeen, memory_order_acquire) && !Stopping()) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.025]];
                }
                atomic_store_explicit(&AcceptCallback, false, memory_order_release);
                BOOL seen = atomic_load_explicit(&CallbackSeen, memory_order_acquire);
                IOReturn completion = atomic_load(&CallbackStatus);
                report[@"callbackSeen"] = @(seen); report[@"status"] = seen ? @(completion) : @(submitted);
                report[@"statusSource"] = seen ? @"connectionComplete-callback" : @"openConnection-submission-only";
                report[@"callbackStatus"] = seen ? @(completion) : NSNull.null;
                if (!Stopping()) {
                    // IOBluetooth can deliver a successful completion callback
                    // slightly before isConnected reflects the new baseband
                    // state. Give that public state a short, bounded settle
                    // window instead of treating the race as a failed refresh.
                    double observedDeadline = Now() + 2.5;
                    while (seen && completion == kIOReturnSuccess && !device.isConnected &&
                           !Stopping() && Now() < observedDeadline) {
                        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:.025]];
                    }
                    BOOL connected = device.isConnected;
                    atomic_store(&ConnectedObserved, connected); atomic_store(&ConnectedObservedKnown, true);
                    report[@"connectedObserved"] = @(connected);
                    BOOL ready = submitted == kIOReturnSuccess && seen && completion == kIOReturnSuccess && connected;
                    report[@"ok"] = @(ready); report[@"stage"] = ready ?
                        (before ? @"stale-acl-reset-and-fresh-ready" : @"fresh-acl-ready") : @"fresh-acl-not-verified";
                    if (ready) exitCode = 0;
                }
                  report[@"nativePendingMayRemain"] = @(submitted == kIOReturnSuccess && !seen);
            }
        }
        atomic_store_explicit(&AcceptCallback, false, memory_order_release);
        if (Stopping()) {
            report[@"ok"] = @NO;
            report[@"stage"] = ReceivedSignal ? @"signal" : atomic_load(&ParentExited) ? @"owner-exited" : @"deadline";
            exitCode = ReceivedSignal ? 128 + ReceivedSignal : atomic_load(&ParentExited) ? 125 : 124;
        }
        report[@"elapsedSeconds"] = @(Now() - Started); Emit(report);
        // Keep the observer/device alive through process exit if the public
        // request is still pending. There is intentionally no disconnect/cancel.
        _Exit(exitCode);
    }
}
