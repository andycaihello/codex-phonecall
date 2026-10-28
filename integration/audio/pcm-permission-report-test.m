// Foundation-only report predicates. No native action or LaunchServices call.
#define main unused_permission_launcher_main
#include "pcm-permission-launcher.m"
#undef main
static unsigned checks = 0;
static void Check(BOOL condition) { ++checks; if (!condition) { fprintf(stderr, "FAIL report predicate %u\n", checks); exit(1); } }
int main(void) { @autoreleasepool {
    NSMutableDictionary *r = [@{@"bundleIdentifier": @"local.phonebridge.PCMBridge", @"stage": @"permission-status-only",
        @"permissionKind": @"microphone", @"authorizationBefore": @"denied", @"authorizationAfter": @"denied",
        @"ioStarted": @NO, @"deviceQueries": @NO, @"audioRecorded": @NO, @"cleanupVerified": @YES, @"permissionRequested": @NO} mutableCopy];
    Check(PermissionReportValid(r, NO)); // A denied read-only result is still a completed query.
    Check(!PermissionReportValid(r, YES));
    for (NSString *key in @[@"ioStarted", @"deviceQueries", @"audioRecorded", @"permissionRequested"]) {
        id old = r[key]; [r removeObjectForKey:key]; Check(!PermissionReportValid(r, NO));
        r[key] = @0; Check(!PermissionReportValid(r, NO)); r[key] = @YES; Check(!PermissionReportValid(r, NO)); r[key] = old;
    }
    r[@"bundleIdentifier"] = @1; Check(!PermissionReportValid(r, NO)); r[@"bundleIdentifier"] = @"local.phonebridge.PCMBridge";
    r[@"cleanupVerified"] = @NO; Check(!PermissionReportValid(r, NO)); r[@"cleanupVerified"] = @YES;
    r[@"authorizationBefore"] = @"unknown"; Check(!PermissionReportValid(r, NO)); r[@"authorizationBefore"] = @"notDetermined";
    r[@"stage"] = @"permission-only"; r[@"authorizationAfter"] = @"authorized"; r[@"permissionRequested"] = @YES;
    Check(PermissionReportValid(r, YES)); Check(!PermissionReportValid(r, NO));
    r[@"ioStarted"] = @YES; Check(!PermissionReportValid(r, YES));
    printf("{\"passed\":true,\"checks\":%u,\"launchRequested\":false,\"deviceQueries\":false,\"permissionQueries\":false}\n", checks);
    return 0;
} }
