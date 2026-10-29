#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <objc/message.h>
#include "hfp-control-machine.hpp"
#include "sdp-rfcomm-parser.h"
#include "phone-identity-arguments.h"
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static NSString *phoneAddress = nil;
static NSString *phoneName = nil;
static NSString *const helperUUID = @"9d8b4c21-742e-4e0c-9c6f-4a1fa5c3a701";
static volatile sig_atomic_t interrupted = 0;
static bool outputFailed = false;
static std::string permittedDialNumber;
static bool incomingOnly = false;
static constexpr double closeCallbackGraceSeconds = 3.0;
static void onSignal(int s) { interrupted = s; }
static double now() { timespec t{}; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static id invoke(id target, NSString *name) {
    SEL s = NSSelectorFromString(name); return target && [target respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(target, s) : nil;
}
static id value(id object, NSString *key) { @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; } }
static NSString *normalizedAddress(NSString *s) { return [s.uppercaseString stringByReplacingOccurrencesOfString:@"-" withString:@":"]; }
static bool matches(NSString *s, NSString *pattern) {
    if (![s isKindOfClass:NSString.class]) return false;
    NSRange range = [s rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == s.length;
}
static NSString *validateRequest(id object) {
    if (![object isKindOfClass:NSDictionary.class]) return @"object_required";
    NSDictionary *r = object;
    if (!matches(r[@"id"], @"^[A-Za-z0-9_-]{1,64}$")) return @"invalid_id";
    if ([r[@"id"] hasPrefix:@"cleanup-"]) return @"reserved_id_prefix";
    NSString *op = r[@"op"];
    NSArray *ops = @[@"helper_connect", @"helper_status", @"helper_exchange", @"helper_audio", @"helper_dial_ui", @"helper_stop", @"open_hsp", @"hsp_audio", @"close_hsp",
        @"connect", @"connect_hfp_anchor", @"status", @"refresh", @"dial", @"answer", @"hangup", @"disconnect", @"stop"];
    if (![op isKindOfClass:NSString.class] || ![ops containsObject:op]) return @"invalid_operation";
    NSSet *keys = [NSSet setWithArray:r.allKeys];
    BOOL numberedOperation = [op isEqualToString:@"dial"] || [op isEqualToString:@"helper_dial_ui"];
    BOOL answering = [op isEqualToString:@"answer"];
    if (incomingOnly && numberedOperation) return @"incoming_only; dial_not_allowed";
    if (answering && !incomingOnly) return @"answer_requires_incoming_mode";
    if (answering && !matches(r[@"incoming_id"], @"^[1-9][0-9]{0,14}$")) return @"invalid_incoming_id";
    NSSet *expected = [NSSet setWithArray:numberedOperation ? @[@"id", @"op", @"number"] : answering ? @[@"id", @"op", @"incoming_id"] : @[@"id", @"op"]];
    if (![keys isEqualToSet:expected]) return @"unexpected_or_missing_fields";
    if (numberedOperation) {
        NSString *n = r[@"number"];
        if (![n isKindOfClass:NSString.class] || !phonebridge::validDialNumber(n.UTF8String ?: "") || permittedDialNumber != (n.UTF8String ?: "")) return @"number_not_allowlisted";
    }
    return nil;
}
static bool emit(NSDictionary *source) {
    NSMutableDictionary *r = [source mutableCopy]; r[@"schema"] = @1; r[@"monotonicSeconds"] = @(now());
    BOOL result = [r[@"event"] isEqual:@"result"];
    r[@"type"] = result ? @"result" : @"state";
    if (result && ![r[@"ok"] boolValue] && r[@"detail"]) r[@"error"] = r[@"detail"];
    r[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    NSData *d = [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingSortedKeys error:nil];
    if (!d) return false;
    const uint8_t *p = static_cast<const uint8_t *>(d.bytes); size_t left = d.length;
    while (left) { ssize_t n = write(STDOUT_FILENO, p, left); if (n <= 0) { interrupted = SIGPIPE; outputFailed = true; return false; } p += n; left -= size_t(n); }
    bool ok = write(STDOUT_FILENO, "\n", 1) == 1;
    if (!ok) { outputFailed = true; interrupted = SIGPIPE; } return ok;
}
static NSData *uuidData(NSString *string) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:string]; if (!uuid) return nil;
    uuid_t bytes; [uuid getUUIDBytes:bytes]; return [NSData dataWithBytes:bytes length:16];
}
static NSData *uuid16(uint16_t n) { uint8_t b[] = {uint8_t(n >> 8), uint8_t(n)}; return [NSData dataWithBytes:b length:2]; }
static NSDictionary *uintElement(int n, int bytes) { return @{@"DataElementType": @1, @"DataElementSize": @(bytes), @"DataElementValue": @(n)}; }

@interface BTSlot : NSObject
@property NSString *name;
@property uint8_t channelID;
@property id channel;
@property int fd;
@property BOOL closed;
@property BOOL closeRequested;
@property NSString *closeEvidence;
@property BOOL closeProgressRetryUsed;
@property NSMutableData *tx;
@property NSMutableData *rx;
@property BOOL txStarted;
@property NSUInteger receivedBytes;
@property NSUInteger sentBytes;
@property NSUInteger sendWouldBlockCount;
@property double lastReceivedAt;
@property double lastSentAt;
@end
@implementation BTSlot
- (instancetype)init { if ((self = [super init])) { _fd = -1; _tx = [NSMutableData data]; _rx = [NSMutableData data]; } return self; }
@end

@interface BTController : NSObject {
@public phonebridge::HFP hfp;
}
@property IOBluetoothDevice *device;
@property id peer;
@property IOBluetoothSDPServiceRecord *localHSP;
@property NSMutableDictionary<NSString *, BTSlot *> *slots;
@property NSMutableSet<NSString *> *seenIDs;
@property NSDictionary *opening;
@property NSString *openingStage;
@property uint8_t openingChannel;
@property double openingDeadline;
@property double warmUntil;
@property NSUInteger generation;
@property NSMutableArray<NSDictionary *> *helperQueue;
@property NSDictionary *helperPending;
@property double helperDeadline;
@property BOOL helperSLC;
@property BOOL helperPeerVerified;
@property BOOL helperStatusOK;
@property double helperStatusAt;
@property NSString *helperStageState;
@property BOOL hfpAnchorSelected;
@property BOOL helperActive;
@property BOOL helperStateKnown;
@property BOOL helperCleanupSucceeded;
@property BOOL helperPendingConnect;
@property BOOL helperStopAcknowledged;
@property BOOL helperAudioRequested;
@property BOOL helperAudioActive;
@property NSString *helperAudioError;
@property NSInteger helperCallState;
@property NSDictionary *hspAudioPending;
@property double hspAudioDeadline;
@property BOOL hspAudioCommandWritten;
@property BOOL shutdown;
@property BOOL finished;
@property BOOL cleanupHangupQueued;
@property BOOL cleanupHelperQueued;
@property BOOL closesStarted;
@property double shutdownAt;
@property double closeAt;
@property BOOL helperCloseProgressObserved;
@property NSString *closeProgressBlockReason;
@property NSString *closeProgressCollectionClass;
@property NSString *stopID;
@property int exitCode;
- (void)request:(NSDictionary *)r;
- (void)tick;
- (void)beginShutdown:(NSString *)reason requestID:(NSString *)requestID;
@end

@implementation BTController
- (instancetype)init {
    if ((self = [super init])) { _slots = [NSMutableDictionary dictionary]; _seenIDs = [NSMutableSet set]; _helperQueue = [NSMutableArray array]; _openingStage = @"idle"; _helperStageState = @"unknown"; _helperCallState = -1; }
    return self;
}
- (NSDictionary *)state {
    NSMutableDictionary *s = [@{@"hfpStage": @(hfp.stage.c_str()), @"hfpReady": @(hfp.ready), @"slcReady": @(hfp.ready), @"protocolFailed": @(hfp.failed),
        @"call": @(hfp.call), @"callsetup": @(hfp.setup), @"callheld": @(hfp.held), @"ownDial": @(hfp.ownDial),
        @"setup": @(hfp.setup), @"held": @(hfp.held),
        @"incomingOnly": @(hfp.incomingOnly), @"ownIncoming": @(hfp.ownIncoming),
        @"incomingAvailable": @(hfp.incomingAvailable()), @"incomingID": [NSString stringWithFormat:@"%llu", (unsigned long long)hfp.incomingToken],
        @"idleVerified": @(hfp.idleVerified), @"helperSlcControlComplete": @(self.helperSLC), @"helperActive": @(self.helperActive),
        @"helperStateKnown": @(self.helperStateKnown), @"helperPeerVerified": @(self.helperPeerVerified),
        @"helperStageState": self.helperStageState, @"helperStatusAgeSeconds": @(self.helperStatusAt > 0 ? now() - self.helperStatusAt : -1),
        @"hfpAnchorMode": @(self.hfpAnchorSelected), @"helperCleanupSucceeded": @(self.helperCleanupSucceeded), @"helperPendingConnect": @(self.helperPendingConnect),
        @"helperStopAcknowledged": @(self.helperStopAcknowledged),
        @"helperAudioRequested": @(self.helperAudioRequested), @"helperAudioActive": @(self.helperAudioActive),
        @"helperAudioError": self.helperAudioError ?: @"",
        @"helperCallState": @(self.helperCallState),
        @"audioRequestedByCLI": @(self.hspAudioCommandWritten), @"dialAllowlistLast4": [NSString stringWithUTF8String:permittedDialNumber.substr(permittedDialNumber.size() > 4 ? permittedDialNumber.size() - 4 : 0).c_str()], @"openingStage": self.openingStage,
        @"shutdown": @(self.shutdown), @"queueDepth": @(hfp.queued())} mutableCopy];
    s[@"helperCloseProgressObserved"] = @(self.helperCloseProgressObserved);
    s[@"closeProgressBlockReason"] = self.closeProgressBlockReason ?: @"not_evaluated";
    s[@"closeProgressCollectionClass"] = self.closeProgressCollectionClass ?: @"not_read";
    s[@"hfpCommandPending"] = @(hfp.hasPending());
    s[@"hfpPendingKind"] = @(hfp.pendingKind().c_str());
    s[@"hfpBufferedBytes"] = @(hfp.bufferedBytes());
    s[@"hfpPendingResponseSeen"] = @(hfp.pendingResponseSeen());
    s[@"helperCommandPending"] = @(self.helperPending != nil || self.helperQueue.count != 0);
    NSMutableDictionary *slots = [NSMutableDictionary dictionary];
    for (NSString *name in self.slots) { BTSlot *v = self.slots[name]; slots[name] = @{@"channelID": @(v.channelID), @"open": @(!v.closed && v.fd >= 0), @"closeRequested": @(v.closeRequested), @"closeEvidence": v.closeEvidence ?: @"none", @"closeProgressRetryUsed": @(v.closeProgressRetryUsed), @"receivedBytes": @(v.receivedBytes), @"sentBytes": @(v.sentBytes), @"txPendingBytes": @(v.tx.length), @"sendWouldBlockCount": @(v.sendWouldBlockCount), @"lastReceivedAt": @(v.lastReceivedAt), @"lastSentAt": @(v.lastSentAt)}; }
    s[@"channels"] = slots; return s;
}
- (void)result:(NSString *)requestID ok:(BOOL)ok detail:(NSString *)detail {
    emit(@{@"event": @"result", @"id": requestID ?: @"", @"ok": @(ok), @"detail": detail, @"state": self.state});
}
- (BTSlot *)live:(NSString *)name { BTSlot *s = self.slots[name]; return s && !s.closed && !s.closeRequested && s.fd >= 0 ? s : nil; }
- (void)request:(NSDictionary *)r {
    NSString *err = validateRequest(r); NSString *rid = [r[@"id"] isKindOfClass:NSString.class] ? r[@"id"] : @"";
    if (err) { [self result:rid ok:NO detail:err]; return; }
    if ([self.seenIDs containsObject:rid]) { [self result:rid ok:NO detail:@"duplicate_id_refused"]; return; }
    if (self.seenIDs.count >= 4096) { [self result:rid ok:NO detail:@"session_request_limit"]; [self beginShutdown:@"request_limit" requestID:nil]; return; }
    [self.seenIDs addObject:rid]; NSString *op = r[@"op"];
    if ([op isEqualToString:@"status"]) { [self result:rid ok:YES detail:@"cached_status; no_BT_query"]; return; }
    if ([op isEqualToString:@"stop"]) { [self beginShutdown:@"explicit_stop" requestID:rid]; return; }
    if (self.shutdown) { [self result:rid ok:NO detail:@"shutdown_in_progress"]; return; }
    if ([@[@"helper_connect", @"open_hsp", @"connect", @"connect_hfp_anchor"] containsObject:op]) { [self open:r]; return; }
    if ([op hasPrefix:@"helper_"]) {
        if (![self live:@"helper"]) { [self result:rid ok:NO detail:@"helper_channel_not_open"]; return; }
        if (self.helperQueue.count >= 16) { [self result:rid ok:NO detail:@"helper_queue_full"]; return; }
        if ([op isEqualToString:@"helper_exchange"] && !phonebridge::allowedHelperExchange([self live:@"hsp"] != nil, [self live:@"hfp"] != nil, self.hfpAnchorSelected && hfp.ready && !hfp.failed)) {
            [self result:rid ok:NO detail:@"exclusive_HSP_or_verified_explicit_HFP_anchor_required_before_exchange"]; return;
        }
        if ([op isEqualToString:@"helper_stop"] && hfp.hasOwnedDialIntent()) { [self result:rid ok:NO detail:@"hangup_owned_call_before_helper_stop"]; return; }
        NSMutableDictionary *command = [@{@"id": rid, @"op": [op substringFromIndex:7]} mutableCopy];
        if ([op isEqualToString:@"helper_dial_ui"]) command[@"number"] = r[@"number"];
        [self.helperQueue addObject:command]; return;
    }
    if ([op isEqualToString:@"close_hsp"] || [op isEqualToString:@"disconnect"]) {
        if (hfp.hasOwnedDialIntent()) { [self result:rid ok:NO detail:@"hangup_owned_call_before_control_close"]; return; }
        NSString *name = [op isEqualToString:@"close_hsp"] ? @"hsp" : @"hfp";
        [self closeSlot:self.slots[name]]; [self result:rid ok:YES detail:@"channel_close_requested; watch_channel_closed"]; return;
    }
    if ([op isEqualToString:@"hsp_audio"]) {
        BTSlot *headset = [self live:@"hsp"];
        if (!headset || ![self live:@"hfp"]) { [self result:rid ok:NO detail:@"HSP_and_HFP_channels_required"]; return; }
        if (self.hspAudioPending || headset.tx.length) { [self result:rid ok:NO detail:@"HSP_audio_command_busy"]; return; }
        if (!hfp.canRequestHSPAudio()) { [self result:rid ok:NO detail:@"owned_active_call_required_for_HSP_audio"]; return; }
        const char *command = "AT+CKPD=200\r";
        headset.txStarted = NO;
        [headset.tx appendBytes:command length:strlen(command)];
        self.hspAudioPending = @{ @"id": rid };
        self.hspAudioDeadline = now() + 4;
        emit(@{@"event": @"HSP_audio_transfer_queued", @"id": rid, @"state": self.state});
        return;
    }
    if (![self live:@"hfp"]) { [self result:rid ok:NO detail:@"HFP_channel_not_open"]; return; }
    BTSlot *control = [self live:@"hfp"];
    if ([op isEqualToString:@"hangup"] && control.tx.length && !control.txStarted && (hfp.pendingKind() == "dial" || hfp.pendingKind() == "answer")) {
        [control.tx setLength:0]; hfp.cancelUnwrittenControl();
    }
    hfp.enqueue(op.UTF8String, rid.UTF8String, [r[@"number"] UTF8String] ?: "", [r[@"incoming_id"] longLongValue]);
}
- (BOOL)verifyPhone {
    return self.device && self.device.isPaired && [normalizedAddress(self.device.addressString) isEqualToString:phoneAddress] && [self.device.name isEqualToString:phoneName];
}
- (void)open:(NSDictionary *)r {
    if (self.opening) { [self result:r[@"id"] ok:NO detail:@"connection_operation_busy"]; return; }
    NSString *op = r[@"op"], *name = [op isEqualToString:@"helper_connect"] ? @"helper" : [op isEqualToString:@"open_hsp"] ? @"hsp" : @"hfp";
    BOOL experimentalAnchor = [op isEqualToString:@"connect_hfp_anchor"];
    if (!experimentalAnchor && [self live:name]) { [self result:r[@"id"] ok:YES detail:@"channel_already_open; no_new_connection"]; return; }
    if ([name isEqualToString:@"hsp"] && (self.hfpAnchorSelected || [self live:@"hfp"])) {
        [self result:r[@"id"] ok:NO detail:@"HSP_and_explicit_HFP_anchors_are_mutually_exclusive"]; return;
    }
    if ([name isEqualToString:@"hfp"] && !experimentalAnchor && (![self live:@"hsp"] || !self.helperSLC)) { [self result:r[@"id"] ok:NO detail:@"HSP_anchor_and_helper_SLC_required_before_HFP"]; return; }
    if (experimentalAnchor) {
        BTSlot *hs = self.slots[@"hsp"], *hf = self.slots[@"hfp"];
        phonebridge::HFPAnchorPrerequisites prerequisites;
        prerequisites.paired = [self verifyPhone]; prerequisites.helperOpen = [self live:@"helper"] != nil;
        prerequisites.statusOK = self.helperStatusOK; prerequisites.peerVerified = self.helperPeerVerified;
        prerequisites.active = self.helperActive; prerequisites.slcComplete = self.helperSLC;
        prerequisites.awaitingHandshake = [self.helperStageState isEqualToString:@"hf-awaiting-handshake"];
        prerequisites.pendingConnect = self.helperPendingConnect;
        prerequisites.anyOwnedPhoneControl = (hs && !hs.closed) || (hf && !hf.closed) || self.localHSP != nil;
        prerequisites.statusAge = self.helperStatusAt > 0 ? now() - self.helperStatusAt : -1;
        if (!phonebridge::allowedHFPAnchor(prerequisites)) {
            [self result:r[@"id"] ok:NO detail:@"HFP_anchor_requires_fresh_verified_gated_helper_status_and_no_owned_HSP_HFP"]; return;
        }
    }
    if (!self.device) self.device = [IOBluetoothDevice deviceWithAddressString:phoneAddress];
    if (![self verifyPhone]) { [self result:r[@"id"] ok:NO detail:@"fixed_paired_phone_identity_rejected"]; return; }
    self.opening = @{@"id": r[@"id"], @"name": name, @"experimentalHFPAnchor": @(experimentalAnchor)}; self.openingDeadline = now() + 15;
    BOOL wasConnected = self.device.isConnected;
    emit(@{@"event": @"connection_preflight", @"id": r[@"id"], @"role": name, @"operation": op,
        @"paired": @YES, @"connectedBefore": @(wasConnected), @"freshACLRequested": @(!wasConnected), @"state": self.state});
    if (!wasConnected) {
        self.openingStage = @"opening_acl";
        IOReturn rc = [self.device openConnection:self withPageTimeout:0x2000 authenticationRequired:YES];
        emit(@{@"event": @"acl_open_submitted", @"status": @(rc)});
        if (rc) [self openingFailed:@"ACL_open_submission_failed"];
    } else [self querySDP];
}
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (device != self.device || !self.opening || ![self.openingStage isEqualToString:@"opening_acl"]) return;
        emit(@{@"event": @"acl_open_callback", @"status": @(status), @"connectedObserved": @(device.isConnected), @"role": self.opening[@"name"]});
        if (status || ![self verifyPhone] || !device.isConnected) { [self openingFailed:@"ACL_completion_failed"]; return; }
        if (self.shutdown) { [self openingFailed:@"shutdown_after_ACL_completion"]; return; }
        [self querySDP];
    });
}
- (void)querySDP {
    self.openingStage = @"querying_sdp_metadata";
    IOReturn rc = [self.device performSDPQuery:self];
    emit(@{@"event": @"sdp_query_submitted", @"status": @(rc), @"overTheAirRefreshVerified": @NO});
    if (rc) [self openingFailed:@"SDP_submission_failed"];
}
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (device != self.device || !self.opening || ![self.openingStage isEqualToString:@"querying_sdp_metadata"]) return;
        if (self.shutdown) { [self openingFailed:@"shutdown_after_SDP_completion"]; return; }
        if (status || ![self verifyPhone]) { [self openingFailed:@"SDP_callback_or_identity_failed"]; return; }
        NSString *name = self.opening[@"name"];
        NSData *wantedData = [name isEqualToString:@"helper"] ? uuidData(helperUUID) : uuid16([name isEqualToString:@"hsp"] ? 0x1112 : 0x111f);
        IOBluetoothSDPUUID *wanted = [IOBluetoothSDPUUID uuidWithBytes:wantedData.bytes length:(unsigned)wantedData.length];
        NSMutableSet *channels = [NSMutableSet set]; NSUInteger matchingRecords = 0; BOOL malformedMatch = NO;
        for (IOBluetoothSDPServiceRecord *record in self.device.services) {
            IOBluetoothSDPDataElement *classes = [record getAttributeDataElement:0x0001];
            if (!PBServiceClassMatches(classes, wanted)) continue;
            ++matchingRecords;
            IOBluetoothSDPDataElement *protocols = [record getAttributeDataElement:0x0004];
            PBRFCOMMParseResult parsed = PBParseRFCOMMProtocol(protocols);
            BluetoothRFCOMMChannelID getterChannel = 0; IOReturn getterStatus = kIOReturnError;
            NSString *getterError = @"";
            @try { getterStatus = [record getRFCOMMChannelID:&getterChannel]; }
            @catch (__unused NSException *exception) { getterError = @"getter_exception"; }
            NSString *serviceName = record.getServiceName ?: @"";
            NSString *raw = protocols.description ?: @"missing";
            NSString *classRaw = classes.description ?: @"missing";
            emit(@{@"event": @"SDP_matching_service_record", @"role": name,
                @"serviceName": [serviceName substringToIndex:MIN(serviceName.length, 160)],
                @"serviceClassRaw": [classRaw substringToIndex:MIN(classRaw.length, 1024)],
                @"protocolDescriptorRaw": [raw substringToIndex:MIN(raw.length, 2048)],
                @"rawParseOK": @(parsed.ok), @"rawParsedChannelID": parsed.ok ? @(parsed.channel) : [NSNull null],
                @"rawParseError": @(parsed.error), @"RFCOMMDescriptorCount": @(parsed.matches),
                @"getterStatus": @(getterStatus), @"getterChannelID": getterStatus == 0 ? @(getterChannel) : [NSNull null],
                @"getterError": getterError, @"getterDisagreesWithRaw": @(parsed.ok && getterStatus == 0 && parsed.channel != getterChannel),
                @"getterUsedForSelection": @NO});
            if (!parsed.ok) malformedMatch = YES;
            else [channels addObject:@(parsed.channel)];
        }
        if (matchingRecords != 1 || channels.count != 1 || malformedMatch) {
            [self openingFailed:@"expected_service_or_raw_RFCOMM_missing_or_ambiguous; no_channel_guess"]; return;
        }
        self.openingChannel = [channels.anyObject unsignedCharValue];
        for (BTSlot *slot in self.slots.allValues) if (!slot.closed && slot.channelID == self.openingChannel) { [self openingFailed:@"channel_already_owned_by_another_role"]; return; }
        emit(@{@"event": @"service_channel_selected", @"role": name, @"channelID": @(self.openingChannel), @"source": @"raw_SDP_ProtocolDescriptorList_after_success_callback", @"serviceUUID": [name isEqualToString:@"helper"] ? helperUUID : [name isEqualToString:@"hsp"] ? @"1112" : @"111f", @"overTheAirRefreshVerified": @NO});
        if ([name isEqualToString:@"hsp"] && !self.localHSP) {
            NSDictionary *service = @{@"0001 - ServiceClassIDList": @[uuidData(@"00001108-0000-1000-8000-00805f9b34fb"), uuid16(0x1108), uuid16(0x1131), uuid16(0x1203)],
                @"0003 - ServiceID": uuidData(@"00004408-0000-1000-8000-00805f9b34fb"),
                @"0004 - ProtocolDescriptorList": @[@[uuid16(0x0100)], @[uuid16(0x0003), uintElement(4, 1)]],
                @"0005 - BrowseGroupList": @[uuid16(0x1002)], @"0009 - BluetoothProfileDescriptorList": @[@[uuidData(@"00001108-0000-1000-8000-00805f9b34fb"), uintElement(0x0102, 2)]],
                @"0100 - ServiceName": @"PhoneBridge Headset", @"LocalAttributes": @{@"Persistent": @NO}};
            self.localHSP = [IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:service];
            if (!self.localHSP) { [self openingFailed:@"local_HSP_record_publish_failed"]; return; }
        }
        if (![self ensurePeer]) { [self openingFailed:@"classic_peer_API_or_callback_ownership_unavailable"]; return; }
        self.openingStage = @"peer_warmup"; self.warmUntil = now() + .75;
    });
}
- (BOOL)ensurePeer {
    if (self.peer) return YES;
    id peer = invoke(self.device, @"classicPeer");
    for (NSString *s in @[@"openRFCOMMChannel:", @"closeRFCOMMChannel:", @"setConnectRFCOMMCallback:", @"setDisconnectRFCOMMCallback:"])
        if (![peer respondsToSelector:NSSelectorFromString(s)]) return NO;
    if (invoke(peer, @"connectRFCOMMCallback") || invoke(peer, @"disconnectRFCOMMCallback")) return NO;
    self.peer = peer; self.generation++; NSUInteger generation = self.generation;
    __weak BTController *weak = self;
    void (^opened)(id, NSInteger) = ^(id channel, NSInteger error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BTController *s = weak; if (!s || generation != s.generation) return;
            [s opened:channel error:error];
        });
    };
    void (^closed)(id, NSInteger) = ^(id channel, NSInteger error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BTController *s = weak; if (!s || generation != s.generation) return;
            [s closed:channel error:error];
        });
    };
    ((void (*)(id, SEL, id))objc_msgSend)(peer, NSSelectorFromString(@"setConnectRFCOMMCallback:"), opened);
    ((void (*)(id, SEL, id))objc_msgSend)(peer, NSSelectorFromString(@"setDisconnectRFCOMMCallback:"), closed);
    return YES;
}
- (void)closed:(id)channel error:(NSInteger)error {
    id observed = value(channel, @"channelID");
    NSMutableArray *matched = [NSMutableArray array];
    for (BTSlot *slot in self.slots.allValues) if (channel && slot.channel == channel) [matched addObject:slot.name];
    emit(@{@"event": @"RFCOMM_close_callback", @"status": @(error),
        @"statusHex": [NSString stringWithFormat:@"0x%08X", (uint32_t)error], @"channelPresent": @(channel != nil),
        @"observedChannelID": [observed isKindOfClass:NSNumber.class] ? observed : NSNull.null,
        @"matchedOwnedRoles": matched, @"identityMatched": @(matched.count == 1)});
    // A channel number alone never grants ownership of a replacement object.
    if (matched.count != 1) return;
    BTSlot *slot = self.slots[matched.firstObject];
    BOOL firstConfirmation = !slot.closed;
    slot.closed = YES; slot.fd = -1; slot.closeEvidence = @"retained_object_disconnect_callback";
    if ([slot.name isEqualToString:@"hfp"]) { hfp.disconnected(); self.hfpAnchorSelected = NO; }
    if ([slot.name isEqualToString:@"helper"]) self.helperSLC = NO;
    if (firstConfirmation && [slot.name isEqualToString:@"helper"] && self.slots[@"hfp"].closeRequested)
        self.helperCloseProgressObserved = YES;
    emit(@{@"event": @"channel_closed", @"role": slot.name, @"callbackStatus": @(error),
        @"closeRequested": @(slot.closeRequested), @"closeEvidence": slot.closeEvidence});
}
- (void)opened:(id)channel error:(NSInteger)error {
    id observedChannelID = value(channel, @"channelID");
    emit(@{@"event": @"RFCOMM_open_callback", @"status": @(error), @"statusHex": [NSString stringWithFormat:@"0x%08X", (uint32_t)error],
        @"channelPresent": @(channel != nil), @"expectedChannelID": @(self.openingChannel),
        @"observedChannelID": [observedChannelID isKindOfClass:NSNumber.class] ? observedChannelID : [NSNull null], @"role": self.opening[@"name"] ?: @"unmatched"});
    if (!channel && self.opening && [self.openingStage isEqualToString:@"opening_rfcomm"]) {
        [self openingFailed:[NSString stringWithFormat:@"RFCOMM_open_callback_without_channel; status=%ld; channelID=%u", (long)error, self.openingChannel]]; return;
    }
    NSNumber *channelID = value(channel, @"channelID");
    if (!self.opening || ![channelID isKindOfClass:NSNumber.class] || channelID.unsignedCharValue != self.openingChannel) {
        emit(@{@"event": @"unmatched_open_callback", @"ignored": @YES, @"status": @(error)}); return;
    }
    NSNumber *fdValue = value(channel, @"socketFD"); int fd = [fdValue isKindOfClass:NSNumber.class] ? fdValue.intValue : -1;
    BTSlot *slot = [BTSlot new]; slot.name = self.opening[@"name"]; slot.channelID = self.openingChannel; slot.channel = channel; slot.fd = fd;
    self.slots[slot.name] = slot;
    int type = 0; socklen_t len = sizeof(type);
    if (error || fd < 0 || getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) || type != SOCK_STREAM || [value(channel, @"isIncoming") boolValue]) {
        [self closeSlot:slot]; [self openingFailed:error ? [NSString stringWithFormat:@"RFCOMM_open_callback_failed; status=%ld; channelID=%u", (long)error, self.openingChannel] : @"RFCOMM_socket_identity_rejected"]; return;
    }
    NSString *rid = self.opening[@"id"];
    if ([slot.name isEqualToString:@"hfp"]) self.hfpAnchorSelected = [self.opening[@"experimentalHFPAnchor"] boolValue];
    self.opening = nil; self.openingStage = @"idle";
    emit(@{@"event": @"channel_open", @"role": slot.name, @"channelID": @(slot.channelID), @"callbackStatus": @0});
    if (self.shutdown) { [self closeSlot:slot]; return; }
    if ([slot.name isEqualToString:@"hfp"]) hfp.start(rid.UTF8String);
    else { if ([slot.name isEqualToString:@"helper"]) { self.helperStateKnown = NO; self.helperStatusAt = 0; self.helperStatusOK = NO; self.helperStopAcknowledged = NO; } [self result:rid ok:YES detail:@"RFCOMM_channel_verified"]; }
}
- (void)openingFailed:(NSString *)detail {
    NSString *rid = self.opening[@"id"]; self.opening = nil; self.openingStage = @"idle";
    [self result:rid ok:NO detail:detail];
}
- (void)closeSlot:(BTSlot *)slot {
    if (!slot || slot.closed || slot.closeRequested) return;
    if ([slot.name isEqualToString:@"hsp"] && self.hspAudioPending) {
        [self result:self.hspAudioPending[@"id"] ok:NO detail:@"HSP_channel_closed_before_audio_command_completed"];
        self.hspAudioPending = nil;
    }
    slot.closeRequested = YES;
    id observed = value(slot.channel, @"channelID");
    emit(@{@"event": @"RFCOMM_close_requested", @"role": slot.name, @"channelID": @(slot.channelID),
        @"retainedObjectChannelID": [observed isKindOfClass:NSNumber.class] ? observed : NSNull.null,
        @"channelPresent": @(slot.channel != nil), @"completionRequired": @YES});
    ((void (*)(id, SEL, uint8_t))objc_msgSend)(self.peer, NSSelectorFromString(@"closeRFCOMMChannel:"), slot.channelID);
    // The framework owns socketFD. Do not close(), dup(), or globally close ACL.
}
- (void)progressOwnedCloseAfterCallback {
    BTSlot *control = self.slots[@"hfp"], *helper = self.slots[@"helper"];
    // This installed daemon can select another same-session, same-peer channel.
    // Reissue only after a real owned closure, only while every owned channel is
    // being retired, and at most once. A timer or a nil callback grants nothing.
    if (!self.shutdown || !self.closesStarted || self.finished || self.opening ||
        now() - self.closeAt >= closeCallbackGraceSeconds || !self.helperCloseProgressObserved ||
        !helper.closed || !control || control.closed || !control.closeRequested || control.closeProgressRetryUsed ||
        !hfp.idleVerified || !hfp.idle() || hfp.hasOwnedDialIntent() || hfp.hasPending() ||
        !self.helperStateKnown || !self.helperStopAcknowledged || self.helperPendingConnect || !self.helperCleanupSucceeded ||
        self.helperPending || self.helperQueue.count) return;
    id channels = invoke(self.peer, @"RFCOMMChannels");
    self.closeProgressCollectionClass = channels ? NSStringFromClass([channels class]) : @"nil";
    // Actual CBClassicPeer property metadata declares NSHashTable. Take a strong
    // snapshot of its current weak entries; never infer ownership from IDs.
    NSArray *snapshot = [channels isKindOfClass:NSHashTable.class] ? [channels allObjects] :
        [channels isKindOfClass:NSArray.class] ? [channels copy] : nil;
    if (!snapshot) { self.closeProgressBlockReason = @"unsupported_peer_collection_type"; return; }
    BOOL containsControl = NO;
    for (id candidate in snapshot) {
        NSUInteger matches = 0;
        for (BTSlot *owned in self.slots.allValues) if (!owned.closed && owned.channel == candidate) matches++;
        if (matches != 1) { self.closeProgressBlockReason = @"unowned_or_ambiguous_cached_channel"; return; }
        if (candidate == control.channel) containsControl = YES;
    }
    if (!containsControl) { self.closeProgressBlockReason = @"retained_HFP_missing_from_peer_cache"; return; }
    self.closeProgressBlockReason = @"none";
    control.closeProgressRetryUsed = YES; self.helperCloseProgressObserved = NO;
    emit(@{@"event": @"RFCOMM_close_progression", @"role": @"hfp", @"channelID": @(control.channelID),
        @"trigger": @"retained_helper_object_disconnect_callback", @"allOwnedShutdownScope": @YES,
        @"cachedPeerContainsOnlyOwnedChannels": @YES, @"peerCollectionClass": self.closeProgressCollectionClass,
        @"cachedPeerChannelCount": @(snapshot.count), @"retryNumber": @1, @"completionRequired": @YES});
    ((void (*)(id, SEL, uint8_t))objc_msgSend)(self.peer, NSSelectorFromString(@"closeRFCOMMChannel:"), control.channelID);
}
- (void)helperLine:(NSData *)data {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class] || !self.helperPending || ![object[@"id"] isEqual:self.helperPending[@"id"]]) {
        emit(@{@"event": @"helper_unmatched_or_invalid_response", @"bytes": @(data.length)}); return;
    }
    NSDictionary *r = object;
    BOOL shape = [r[@"protocol"] isEqual:@"phonebridge-helper/1"] && [r[@"state"] isKindOfClass:NSString.class] && [r[@"state"] length] <= 100;
    for (NSString *k in @[@"ok", @"active", @"peerVerified", @"slcControlComplete", @"cleanupSucceeded", @"pendingConnect"])
        if (![r[k] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)r[k]) != CFBooleanGetTypeID()) shape = NO;
    if (![r[@"hfStage"] isKindOfClass:NSNumber.class] || ![r[@"remainingSeconds"] isKindOfClass:NSNumber.class] ||
        ![r[@"callState"] isKindOfClass:NSNumber.class] || [r[@"callState"] integerValue] < -1 || [r[@"callState"] integerValue] > 3) shape = NO;
    for (NSString *k in @[@"routeRequested", @"routeActive"])
        if (r[k] && (![r[k] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)r[k]) != CFBooleanGetTypeID())) shape = NO;
    if (r[@"routeError"] && (![r[@"routeError"] isKindOfClass:NSString.class] || [r[@"routeError"] length] > 160)) shape = NO;
    if (r[@"dialerStage"] && (![@[@"idle", @"requested", @"submitted", @"failed", @"cancelled"] containsObject:r[@"dialerStage"]])) shape = NO;
    for (NSString *k in @[@"dialerError", @"dialerRequestId"])
        if (r[k] && (![r[k] isKindOfClass:NSString.class] || [r[k] length] > 160)) shape = NO;
    for (NSString *k in @[@"backgroundActive", @"foreground"])
        if (r[k] && (![r[k] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)r[k]) != CFBooleanGetTypeID())) shape = NO;
    if (!shape) {
        [self result:self.helperPending[@"id"] ok:NO detail:@"helper_response_shape_rejected"]; self.helperPending = nil; return;
    }
    BOOL stopAcknowledged = [self.helperPending[@"op"] isEqualToString:@"stop"] && [r[@"ok"] boolValue] &&
        [r[@"cleanupSucceeded"] boolValue] && ![r[@"pendingConnect"] boolValue];
    if (stopAcknowledged) self.helperStopAcknowledged = YES;
    self.helperPeerVerified = [r[@"peerVerified"] boolValue]; self.helperStageState = r[@"state"];
    self.helperStatusOK = [self.helperPending[@"op"] isEqualToString:@"status"] && [r[@"ok"] boolValue];
    self.helperStatusAt = self.helperStatusOK ? now() : 0;
    self.helperActive = [r[@"active"] boolValue]; self.helperSLC = [r[@"peerVerified"] boolValue] && [r[@"slcControlComplete"] boolValue];
    if (r[@"routeRequested"]) self.helperAudioRequested = [r[@"routeRequested"] boolValue];
    if (r[@"routeActive"]) self.helperAudioActive = [r[@"routeActive"] boolValue];
    if (r[@"routeError"]) self.helperAudioError = r[@"routeError"];
    self.helperCallState = [r[@"callState"] integerValue];
    self.helperStateKnown = YES; self.helperCleanupSucceeded = [r[@"cleanupSucceeded"] boolValue]; self.helperPendingConnect = [r[@"pendingConnect"] boolValue];
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"id", @"ok", @"protocol", @"state", @"active", @"peerVerified", @"slcControlComplete", @"hfStage", @"remainingSeconds", @"cleanupSucceeded", @"pendingConnect", @"routeRequested", @"routeActive", @"routeError", @"callState", @"error", @"backgroundActive", @"foreground", @"dialerStage", @"dialerError", @"dialerRequestId"]) {
        id v = r[k]; if ([v isKindOfClass:NSNumber.class] || ([v isKindOfClass:NSString.class] && [v length] <= 160)) safe[k] = v;
    }
    NSString *detail = [r[@"ok"] boolValue] ? @"helper_response" :
        ([r[@"routeError"] isKindOfClass:NSString.class] && [r[@"routeError"] length] ? r[@"routeError"] :
         ([r[@"error"] isKindOfClass:NSString.class] && [r[@"error"] length] ? r[@"error"] : @"helper_rejected_operation"));
    emit(@{@"event": @"result", @"id": self.helperPending[@"id"], @"ok": @([r[@"ok"] boolValue]), @"detail": detail, @"helper": safe, @"state": self.state});
    self.helperPending = nil;
}
- (void)pollSlot:(BTSlot *)slot {
    if (slot.closed || slot.closeRequested || slot.fd < 0) return;
    // Drain all currently available responses before submitting the next command.
    for (int batch = 0; batch < 16; ++batch) {
        char data[1024]; ssize_t n = recv(slot.fd, data, sizeof(data), MSG_DONTWAIT);
        if (n > 0) {
            slot.receivedBytes += NSUInteger(n); slot.lastReceivedAt = now();
            if ([slot.name isEqualToString:@"hfp"]) hfp.feed(data, size_t(n), now());
            else if ([slot.name isEqualToString:@"helper"]) {
                for (ssize_t i = 0; i < n; ++i) {
                    unsigned char c = data[i];
                    if (c == '\n') { if (slot.rx.length) [self helperLine:slot.rx]; [slot.rx setLength:0]; }
                    else if (c != '\r' && c >= 32 && c < 127 && slot.rx.length < 4096) [slot.rx appendBytes:&c length:1];
                    else if (c != '\r') { [self closeSlot:slot]; emit(@{@"event": @"helper_protocol_limit"}); return; }
                }
            } // HSP anchor sends no AT command and discards any inbound bytes.
        } else if (n == 0) { [self closeSlot:slot]; break; }
        else if (errno == EINTR) continue;
        else if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        else { [self closeSlot:slot]; emit(@{@"event": @"socket_read_failed", @"role": slot.name, @"errno": @(errno)}); break; }
    }
    if (slot.closed || slot.closeRequested) return;
    if (slot.tx.length && !slot.txStarted && [slot.name isEqualToString:@"hfp"] && !hfp.firstWriteAllowed(now())) {
        [slot.tx setLength:0]; hfp.cancelUnwrittenControl();
    }
    if (slot.tx.length) {
        ssize_t n = send(slot.fd, slot.tx.bytes, slot.tx.length, MSG_DONTWAIT);
        if (n > 0) {
            slot.txStarted = YES;
            slot.sentBytes += NSUInteger(n); slot.lastSentAt = now();
            [slot.tx replaceBytesInRange:NSMakeRange(0, NSUInteger(n)) withBytes:nullptr length:0];
            if ([slot.name isEqualToString:@"hfp"] && !slot.tx.length)
                emit(@{@"event": @"hfp_command_write_completed", @"pendingKind": @(hfp.pendingKind().c_str()), @"sentBytes": @(slot.sentBytes), @"receivedBytes": @(slot.receivedBytes), @"state": self.state});
            if ([slot.name isEqualToString:@"hsp"] && !slot.tx.length && self.hspAudioPending) {
                NSString *rid = self.hspAudioPending[@"id"];
                self.hspAudioPending = nil;
                self.hspAudioCommandWritten = YES;
                [self result:rid ok:YES detail:@"HSP_audio_transfer_command_written"];
            }
        }
        else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) slot.sendWouldBlockCount += 1;
        else if (n < 0 && errno != EINTR) { [self closeSlot:slot]; if ([slot.name isEqualToString:@"hfp"]) hfp.fail("socket_write_failed"); }
    }
}
- (void)beginShutdown:(NSString *)reason requestID:(NSString *)requestID {
    if (self.shutdown) return;
    self.shutdown = YES; self.shutdownAt = now(); self.stopID = requestID;
    BTSlot *control = [self live:@"hfp"];
    if (control.tx.length && !control.txStarted && (hfp.pendingKind() == "dial" || hfp.pendingKind() == "answer")) {
        [control.tx setLength:0]; hfp.cancelUnwrittenControl();
    }
    hfp.beginStop();
    BTSlot *headset = [self live:@"hsp"];
    if (self.hspAudioPending && headset && !headset.txStarted) {
        [headset.tx setLength:0];
        [self result:self.hspAudioPending[@"id"] ok:NO detail:@"cancelled_for_shutdown_before_write"];
        self.hspAudioPending = nil;
    }
    for (NSDictionary *job in self.helperQueue) [self result:job[@"id"] ok:NO detail:@"cancelled_for_shutdown_before_write"];
    [self.helperQueue removeAllObjects];
    BTSlot *helper = [self live:@"helper"];
    if (self.helperPending && helper.tx.length && !helper.txStarted) {
        [helper.tx setLength:0]; [self result:self.helperPending[@"id"] ok:NO detail:@"cancelled_for_shutdown_before_write"]; self.helperPending = nil;
    }
    emit(@{@"event": @"shutdown_started", @"reason": reason, @"state": self.state});
    if (hfp.ownsCall() && hfp.ready && !hfp.failed) self.cleanupHangupQueued = hfp.enqueue("hangup", "cleanup-hangup");
}
- (void)tick {
    if (self.finished) return;
    double t = now();
    if (self.opening && t >= self.openingDeadline) {
        // Keep peer callbacks alive until shutdown grace; do not reuse an
        // uncertain open attempt for a new request.
        [self result:self.opening[@"id"] ok:NO detail:@"connection_timeout; late_completion_pending"];
        [self beginShutdown:@"connection_timeout" requestID:nil];
        self.openingDeadline = t + 60;
    }
    if (self.opening && [self.openingStage isEqualToString:@"peer_warmup"] && t >= self.warmUntil && !self.shutdown) {
        self.openingStage = @"opening_rfcomm";
        ((void (*)(id, SEL, uint8_t))objc_msgSend)(self.peer, NSSelectorFromString(@"openRFCOMMChannel:"), self.openingChannel);
    }
    for (BTSlot *s in self.slots.allValues) [self pollSlot:s];
    BTSlot *control = [self live:@"hfp"];
    if (control && !control.tx.length) {
        std::string wire = hfp.takeWire(t);
        if (!wire.empty()) { control.txStarted = NO; [control.tx appendBytes:wire.data() length:wire.size()]; }
    }
    hfp.checkTimeout(t);
    for (const auto &e : hfp.events) emit(@{@"event": @(e.kind.c_str()), @"id": @(e.id.c_str()), @"ok": @(e.ok), @"detail": @(e.detail.c_str()), @"state": self.state});
    hfp.events.clear();
    if (self.hspAudioPending && t >= self.hspAudioDeadline) {
        [self result:self.hspAudioPending[@"id"] ok:NO detail:@"HSP_audio_command_timeout"];
        self.hspAudioPending = nil;
        [self beginShutdown:@"HSP_audio_command_timeout" requestID:nil];
    }
    if (self.helperPending && t >= self.helperDeadline) { [self result:self.helperPending[@"id"] ok:NO detail:@"helper_command_timeout"]; self.helperPending = nil; }
    BTSlot *helper = [self live:@"helper"];
    if (helper && !self.helperPending && self.helperQueue.count && !helper.tx.length) {
        self.helperPending = self.helperQueue.firstObject; [self.helperQueue removeObjectAtIndex:0];
        NSData *d = [NSJSONSerialization dataWithJSONObject:self.helperPending options:NSJSONWritingSortedKeys error:nil];
        helper.txStarted = NO; [helper.tx appendData:d]; [helper.tx appendBytes:"\n" length:1];
        self.helperDeadline = t + ([self.helperPending[@"op"] isEqualToString:@"audio"] ? 8 : 4);
    }
    if (!self.shutdown) return;
    if (!self.cleanupHelperQueued && (!hfp.ownsCall() || t - self.shutdownAt >= 6)) {
        self.cleanupHelperQueued = YES;
        if (helper) [self.helperQueue insertObject:@{@"id": @"cleanup-helper-stop", @"op": @"stop"} atIndex:0];
    }
    if (!self.closesStarted && self.cleanupHelperQueued && ((!self.helperPending && !self.helperQueue.count) || t - self.shutdownAt >= 8)) {
        self.closesStarted = YES; self.closeAt = t;
        for (BTSlot *s in self.slots.allValues) [self closeSlot:s];
        if (self.opening && [self.openingStage isEqualToString:@"opening_rfcomm"])
            ((void (*)(id, SEL, uint8_t))objc_msgSend)(self.peer, NSSelectorFromString(@"closeRFCOMMChannel:"), self.openingChannel);
    }
    [self progressOwnedCloseAfterCallback];
    if (self.closesStarted && t - self.closeAt >= closeCallbackGraceSeconds) {
        BOOL channelsClosed = YES; for (BTSlot *s in self.slots.allValues) if (!s.closed) channelsClosed = NO;
        IOReturn removed = self.localHSP ? [self.localHSP removeServiceRecord] : 0; self.localHSP = nil;
        BOOL pendingOpen = self.opening != nil;
        BOOL callEnded = !hfp.ownsCall() || hfp.idleVerified;
        // The phone acknowledges stop before it retires its auxiliary listener.
        // On some HarmonyOS builds that listener closure also closes the control
        // RFCOMM channel, so a post-stop inactive response cannot exist. The
        // acknowledgement plus both owned close callbacks is the complete proof.
        BOOL helperStopped = !self.slots[@"helper"] || (self.helperStopAcknowledged && channelsClosed);
        BOOL verified = channelsClosed && !pendingOpen && removed == 0 && callEnded && helperStopped;
        emit(@{@"event": @"cleanup_finished", @"id": self.stopID ?: @"", @"ok": @(verified),
            @"cleanupVerified": @(verified), @"ownedChannelsClosed": @(channelsClosed), @"pendingOpenUnverified": @(pendingOpen),
            @"localSDPRemoveStatus": @(removed), @"ownedCallEndVerified": @(callEnded),
            @"helperStoppedVerified": @(helperStopped),
            @"closeCallbackGraceSeconds": @(closeCallbackGraceSeconds), @"closeWaitElapsedSeconds": @(t - self.closeAt),
            @"sharedACLClosed": @NO, @"scope": @"owned_RFCOMM_channels_and_local_SDP_only; shared_ACL_preserved", @"state": self.state});
        if (self.stopID) [self result:self.stopID ok:verified detail:verified ? @"cleanup_complete" : @"cleanup_unverified"];
        self.exitCode = verified ? 0 : 1;
        self.generation++;
        if (self.peer) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.peer, NSSelectorFromString(@"setConnectRFCOMMCallback:"), nil);
            ((void (*)(id, SEL, id))objc_msgSend)(self.peer, NSSelectorFromString(@"setDisconnectRFCOMMCallback:"), nil);
        }
        self.finished = YES;
    }
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        bool run = false, validate = false, validateCommands = false, help = false; double limit = 0;
        NSMutableSet *seen = [NSMutableSet set]; NSString *error = nil;
        for (int i = 1; i < argc && !error; ++i) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (!arg || [seen containsObject:arg]) { error = @"invalid_or_duplicate_argument"; break; } [seen addObject:arg];
            if ([arg isEqualToString:@"--run"]) run = true;
            else if ([arg isEqualToString:@"--incoming-only"]) incomingOnly = true;
            else if ([arg isEqualToString:@"--validate-args"]) validate = true;
            else if ([arg isEqualToString:@"--validate-commands"]) validateCommands = true;
            else if ([arg isEqualToString:@"--help"]) help = true;
            else if (([arg isEqualToString:@"--phone-address"] || [arg isEqualToString:@"--phone-name"]) && ++i < argc) {
                NSString *value = [NSString stringWithUTF8String:argv[i]];
                if ([arg isEqualToString:@"--phone-address"]) phoneAddress = value;
                else phoneName = value;
            }
            else if ([arg isEqualToString:@"--allow-number"] && ++i < argc) {
                permittedDialNumber = argv[i];
                if (!phonebridge::validDialNumber(permittedDialNumber)) error = @"invalid_allowed_number";
            }
            else if ([arg isEqualToString:@"--max-seconds"] && ++i < argc) {
                char *end = nullptr; limit = strtod(argv[i], &end);
                if (!end || end == argv[i] || *end || !std::isfinite(limit) || limit < 0 || limit > 2147483647 || std::floor(limit) != limit || (limit > 0 && limit < 15)) error = @"max_seconds_must_be_zero_or_15_to_2147483647";
            } else error = @"unknown_or_missing_argument";
        }
        if (help && argc != 2) error = @"help_must_be_alone";
        if (validateCommands && (run || validate || help || [seen containsObject:@"--max-seconds"] ||
            [seen containsObject:@"--phone-address"] || [seen containsObject:@"--phone-name"])) error = @"validate_commands_accepts_only_allow_number";
        if (!error && !help) {
            if (!run && !validateCommands) error = @"explicit_run_or_validate_commands_required";
            else if (incomingOnly && [seen containsObject:@"--allow-number"]) error = @"incoming_and_outgoing_modes_are_exclusive";
            else if (!incomingOnly && (![seen containsObject:@"--allow-number"] || permittedDialNumber.empty())) error = @"allow_number_required";
            else if (run) error = PBPhoneIdentityError(phoneAddress, phoneName);
        }
        signal(SIGPIPE, SIG_IGN);
        if (error || help || validate || (!run && !validateCommands)) {
            emit(@{@"event": error ? @"args_error" : validate ? @"args_valid" : @"help", @"ok": @(!error), @"detail": error ?: @"--run --phone-address AA:BB:CC:DD:EE:FF --phone-name NAME (--allow-number NUMBER | --incoming-only) [--max-seconds 0=unlimited or 15..2147483647] [--validate-args]; JSONL stdin; startup performs no connection. --validate-commands --allow-number NUMBER is offline only.", @"deviceQueries": @NO, @"dialed": @NO});
            return error ? 2 : 0;
        }
        if (validateCommands) {
            char *line = nullptr; size_t cap = 0; ssize_t n;
            while ((n = getline(&line, &cap, stdin)) >= 0) {
                id r = n <= 4096 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:line length:size_t(n)] options:0 error:nil] : nil;
                NSString *err = validateRequest(r); emit(@{@"event": @"command_validation", @"ok": @(!err), @"detail": err ?: @"valid", @"deviceQueries": @NO, @"dialed": @NO});
            }
            free(line); return 0;
        }
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
        int flags = fcntl(STDIN_FILENO, F_GETFL); if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)) return 2;
        int outputFlags = fcntl(STDOUT_FILENO, F_GETFL);
        if (outputFlags < 0 || fcntl(STDOUT_FILENO, F_SETFL, outputFlags | O_NONBLOCK)) return 2;
        BTController *controller = [BTController new];
        if (incomingOnly) controller->hfp.configureIncomingBeforeStart();
        else controller->hfp.setPermittedNumberBeforeStart(permittedDialNumber);
        NSMutableData *pending = [NSMutableData data];
        const double started = now(); bool eof = false;
        emit(@{@"event": @"ready", @"deviceQueries": @NO, @"dialed": @NO, @"maxSeconds": @(limit), @"helperUUID": helperUUID, @"state": controller.state});
        while (!controller.finished) {
            @autoreleasepool {
                if (interrupted || getppid() == 1 || (limit > 0 && now() - started >= limit)) [controller beginShutdown:interrupted ? @"signal" : @"parent_exit_or_session_deadline" requestID:nil];
                if (!eof && !controller.shutdown) {
                    char bytes[1024]; ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
                    if (count > 0) for (ssize_t i = 0; i < count; ++i) {
                        if (bytes[i] == '\n') {
                            id r = [NSJSONSerialization JSONObjectWithData:pending options:0 error:nil];
                            if ([r isKindOfClass:NSDictionary.class]) [controller request:r];
                            else emit(@{@"event": @"result", @"id": @"", @"ok": @NO, @"detail": @"invalid_JSON_object"});
                            [pending setLength:0];
                        } else if (pending.length < 4096) [pending appendBytes:bytes + i length:1];
                        else { [controller beginShutdown:@"stdin_line_limit" requestID:nil]; break; }
                    }
                    else if (count == 0) { eof = true; [controller beginShutdown:@"stdin_eof" requestID:nil]; }
                    else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) [controller beginShutdown:@"stdin_read_failed" requestID:nil];
                }
                [controller tick];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            }
        }
        return outputFailed ? 1 : controller.exitCode;
    }
    return 0;
}
