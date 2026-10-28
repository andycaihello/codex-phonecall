// Permission-only public LaunchServices path for the frozen PCM helper.
// Exactly one of two native flags is accepted; never bridge/audio/custom args.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t interruption = 0;
static void OnSignal(int value) { if (!interruption) interruption = value; }
static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSString *Canonical(NSURL *url) {
    return url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path ?: @"";
}
static BOOL PrivateParent(NSString *path) {
    struct stat st = {};
    return path.isAbsolutePath && !lstat(path.stringByDeletingLastPathComponent.fileSystemRepresentation, &st) &&
        S_ISDIR(st.st_mode) && st.st_uid == getuid() && (st.st_mode & 0777) == 0700;
}
static BOOL Fresh(NSString *path) {
    struct stat st = {}; errno = 0;
    return lstat(path.fileSystemRepresentation, &st) < 0 && errno == ENOENT;
}
static BOOL FalseBoolean(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && ![value boolValue];
}
static BOOL TrueBoolean(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue];
}
static NSDictionary *ReadNativeReport(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat before = {}, after = {};
    BOOL valid = !fstat(fd, &before) && S_ISREG(before.st_mode) && before.st_uid == getuid() &&
        (before.st_mode & 0777) == 0600 && before.st_size > 0 && before.st_size <= 65536;
    NSMutableData *bytes = valid ? [NSMutableData dataWithLength:(NSUInteger)before.st_size] : nil;
    size_t at = 0;
    while (valid && at < bytes.length) {
        ssize_t n = read(fd, (char *)bytes.mutableBytes + at, bytes.length - at);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { valid = NO; break; }
        at += (size_t)n;
    }
    valid = valid && !fstat(fd, &after) && before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
    close(fd);
    id result = valid ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
static BOOL PermissionReportValid(NSDictionary *report, BOOL request) {
    NSSet *authorizations = [NSSet setWithArray:@[@"authorized", @"denied", @"restricted", @"notDetermined"]];
    return [@"local.phonebridge.PCMBridge" isEqual:report[@"bundleIdentifier"]] &&
        [(request ? @"permission-only" : @"permission-status-only") isEqual:report[@"stage"]] &&
        [@"microphone" isEqual:report[@"permissionKind"]] &&
        [authorizations containsObject:report[@"authorizationBefore"] ?: NSNull.null] &&
        [authorizations containsObject:report[@"authorizationAfter"] ?: NSNull.null] &&
        FalseBoolean(report[@"ioStarted"]) && FalseBoolean(report[@"deviceQueries"]) &&
        FalseBoolean(report[@"audioRecorded"]) && TrueBoolean(report[@"cleanupVerified"]) &&
        (request ? (TrueBoolean(report[@"permissionRequested"]) || FalseBoolean(report[@"permissionRequested"])) : FalseBoolean(report[@"permissionRequested"]));
}
static void Print(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}
static BOOL Persist(NSMutableDictionary *state, NSString *path) {
    state[@"updatedAt"] = NSDate.now.description;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
    NSError *error = nil;
    BOOL ok = data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!ok) state[@"statusWriteError"] = error.localizedDescription ?: @"Cannot write launcher status";
    return ok;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        umask(0077);
        NSString *application = nil, *report = nil, *statusPath = nil;
        double limit = 0;
        BOOL validate = NO, nativeSection = NO;
        NSMutableArray<NSString *> *nativeArguments = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (!arg) { Print(@{@"error": @"Invalid UTF-8 option"}); return 2; }
            if (nativeSection) {
                [nativeArguments addObject:arg]; continue;
            }
            if ([arg isEqualToString:@"--"]) { nativeSection = YES; continue; }
            if ([arg isEqualToString:@"--validate-launch-args"]) {
                if (validate) { Print(@{@"error": @"Repeated validate flag"}); return 2; }
                validate = YES; continue;
            }
            if ([seen containsObject:arg] || i + 1 >= argc) { Print(@{@"error": @"Missing or repeated launcher option"}); return 2; }
            [seen addObject:arg];
            NSString *value = [NSString stringWithUTF8String:argv[++i]];
            if ([arg isEqualToString:@"--application"]) application = value;
            else if ([arg isEqualToString:@"--report"]) report = value;
            else if ([arg isEqualToString:@"--status"]) statusPath = value;
            else if ([arg isEqualToString:@"--limit"]) {
                char *end = NULL; limit = strtod(value.UTF8String, &end);
                if (!end || *end || !isfinite(limit)) limit = 0;
            } else { Print(@{@"error": @"Unknown launcher option"}); return 2; }
        }
        BOOL request = [nativeArguments isEqualToArray:@[@"--request-microphone-permission"]];
        BOOL readOnly = [nativeArguments isEqualToArray:@[@"--microphone-permission-status"]];
        if (!application.isAbsolutePath || !report.isAbsolutePath || !statusPath.isAbsolutePath ||
            ![application isEqualToString:application.stringByStandardizingPath] ||
            ![report isEqualToString:report.stringByStandardizingPath] ||
            ![statusPath isEqualToString:statusPath.stringByStandardizingPath] ||
            [report isEqualToString:statusPath] || limit < 1 || limit > 55 || !nativeSection || (!request && !readOnly)) {
            Print(@{@"error": @"Require absolute standardized application/report/status, distinct fresh reports, limit 1..55 and -- followed by exactly one microphone status/request flag"}); return 2;
        }
        NSURL *appURL = [NSURL fileURLWithPath:application isDirectory:YES];
        NSString *appPath = Canonical(appURL);
        NSBundle *bundle = [NSBundle bundleWithURL:appURL];
        NSString *bundleID = @"local.phonebridge.PCMBridge";
        NSString *executablePath = Canonical(bundle.executableURL);
        if (![bundle.bundleIdentifier isEqualToString:bundleID] ||
            ![bundle.executableURL.lastPathComponent isEqualToString:@"phonebridge-pcm"] ||
            ![executablePath isEqualToString:[appPath stringByAppendingPathComponent:@"Contents/MacOS/phonebridge-pcm"]] ||
            ![NSFileManager.defaultManager isExecutableFileAtPath:executablePath]) {
            Print(@{@"error": @"Expected fixed PhoneBridgePCM app bundle/executable"}); return 2;
        }
        if (!PrivateParent(report) || !PrivateParent(statusPath) || !Fresh(report) || !Fresh(statusPath)) {
            Print(@{@"error": @"Report and status must be new files in owned mode-0700 directories"}); return 2;
        }
        if (validate) {
            Print(@{@"stage": @"launcher-arguments-valid", @"launchRequested": @NO,
                    @"deviceQueries": @NO, @"nativeArgumentsValidated": @YES,
                    @"permissionAction": request ? @"request" : @"status"}); return 0;
        }
        int fd = open(statusPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) { Print(@{@"error": @"Cannot exclusively create launcher status"}); return 2; }
        close(fd);
        signal(SIGTERM, OnSignal); signal(SIGINT, OnSignal); signal(SIGPIPE, SIG_IGN);
        const pid_t ownerPID = getppid();
        const double started = Now();
        __block NSRunningApplication *ownedApplication = nil;
        __block BOOL completionReceived = NO;
        __block pid_t ownedPID = 0;
        __block NSMutableDictionary *state = [@{@"schema": @1, @"stage": @"launch-requested",
            @"launchRequested": @YES, @"launchPending": @YES, @"completionReceived": @NO,
            @"ownedAppPID": NSNull.null, @"ownedAppVerified": @NO, @"appTerminated": @NO,
            @"terminationRequested": @NO, @"hardKillRequired": @NO, @"cleanupVerified": @NO,
            @"nativeExitCode": NSNull.null, @"nativeExitCodeUnavailable": @YES,
            @"applicationPath": appPath, @"executablePath": executablePath,
            @"bundleIdentifier": bundleID, @"ownerPID": @(ownerPID), @"launcherPID": @(getpid()),
            @"limitSeconds": @(limit), @"permissionAction": request ? @"request" : @"status",
            @"nativePermissionResultValid": @NO, @"launchError": NSNull.null} mutableCopy];
        NSMutableSet<NSNumber *> *existingPIDs = [NSMutableSet set];
        NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
        for (NSRunningApplication *app in workspace.runningApplications) {
            if ([Canonical(app.bundleURL) isEqualToString:appPath]) [existingPIDs addObject:@(app.processIdentifier)];
        }
        if (!Persist(state, statusPath)) { Print(state); return 1; }
        NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
        configuration.createsNewApplicationInstance = YES;
        configuration.allowsRunningApplicationSubstitution = NO;
        configuration.activates = NO;
        configuration.addsToRecentItems = NO;
        configuration.promptsUserIfNeeded = NO;
        configuration.arguments = [nativeArguments arrayByAddingObjectsFromArray:@[@"--report", report]];
        if (interruption || getppid() != ownerPID || Now() >= started + limit) {
            state[@"stage"] = @"cancelled-before-launch";
            state[@"launchRequested"] = @NO; state[@"launchPending"] = @NO;
            state[@"cleanupVerified"] = @YES;
            state[@"stopReason"] = interruption ? @"signal" : getppid() != ownerPID ? @"owner-exited" : @"deadline";
            Persist(state, statusPath); Print(state);
            return interruption ? 128 + interruption : 124;
        }
        [workspace openApplicationAtURL:appURL configuration:configuration completionHandler:
            ^(NSRunningApplication *app, NSError *error) {
            // NSWorkspace calls completion on a concurrent queue. Keep state on main run loop.
            dispatch_async(dispatch_get_main_queue(), ^{
                completionReceived = YES;
                state[@"completionReceived"] = @YES; state[@"launchPending"] = @NO;
                if (error || !app) {
                    state[@"stage"] = @"launch-failed";
                    state[@"launchError"] = error.localizedDescription ?: @"No returned application";
                } else {
                    pid_t pid = app.processIdentifier;
                    BOOL identity = [Canonical(app.bundleURL) isEqualToString:appPath] &&
                        [Canonical(app.executableURL) isEqualToString:executablePath] &&
                        [app.bundleIdentifier isEqualToString:bundleID];
                    state[@"completionAppPID"] = @(pid);
                    state[@"completionAppTerminated"] = @(app.isTerminated);
                    state[@"completionIdentityMatched"] = @(identity);
                    state[@"completionPIDWasExisting"] = @([existingPIDs containsObject:@(pid)]);
                    NSDictionary *nativeReport = ReadNativeReport(report);
                    BOOL readOnlyStatusCompleted = readOnly && PermissionReportValid(nativeReport, NO) && app.isTerminated;
                    // AppKit documents that metadata may disappear after termination.
                    // A fast status-only app can already have exited at completion.
                    // This fallback is never used to authorize signalling a live PID.
                    if (!identity || pid <= 1 || pid == getpid() || pid == ownerPID || [existingPIDs containsObject:@(pid)]) {
                        state[@"stage"] = readOnlyStatusCompleted ? @"readonly-result-complete-ownership-unverified" : @"ownership-rejected";
                        state[@"readOnlyResultCompleted"] = @(readOnlyStatusCompleted);
                        state[@"launchError"] = @"Returned application did not establish a unique owned instance";
                    } else {
                        ownedApplication = app; ownedPID = pid;
                        state[@"ownedAppPID"] = @(pid); state[@"ownedAppVerified"] = @YES;
                        state[@"ownershipProof"] = @"LaunchServices completion identity";
                        state[@"stage"] = @"application-running";
                    }
                }
                Persist(state, statusPath);
            });
        }];

        BOOL stopping = NO, termSent = NO, killSent = NO;
        double pendingStopDeadline = 0, termDeadline = 0, killDeadline = 0;
        int exitCode = 0;
        for (;;) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.025]];
            double now = Now();
            if (!stopping && (interruption || getppid() != ownerPID || now >= started + limit)) {
                stopping = YES; pendingStopDeadline = now + 8;
                exitCode = interruption ? 128 + interruption : 124;
                state[@"terminationRequested"] = @YES;
                state[@"stopReason"] = interruption ? @"signal" : getppid() != ownerPID ? @"owner-exited" : @"deadline";
                Persist(state, statusPath);
            }
            if (ownedApplication) {
                if (ownedApplication.isTerminated) {
                    state[@"appTerminated"] = @YES; state[@"cleanupVerified"] = @YES;
                    state[@"stage"] = @"application-terminated"; break;
                }
                // Do not retarget a changed NSRunningApplication PID (automatic relaunch).
                if (ownedApplication.processIdentifier != ownedPID) {
                    state[@"stage"] = @"owned-pid-changed-cleanup-unverified"; exitCode = 1; break;
                }
                if (stopping && !termSent) {
                    int result = kill(ownedPID, SIGTERM);
                    state[@"termSignalStatus"] = @(result == 0 ? 0 : errno);
                    termSent = YES; termDeadline = now + 3;
                    state[@"stage"] = @"application-terminating"; Persist(state, statusPath);
                }
                if (termSent && !killSent && now >= termDeadline) {
                    int result = kill(ownedPID, SIGKILL);
                    state[@"killSignalStatus"] = @(result == 0 ? 0 : errno);
                    state[@"hardKillRequired"] = @YES;
                    killSent = YES; killDeadline = now + 1; Persist(state, statusPath);
                }
                if (killSent && now >= killDeadline) {
                    state[@"stage"] = @"termination-unverified"; exitCode = 1; break;
                }
            } else if (completionReceived) {
                // A fresh read-only status result can be useful even when the app
                // exited too quickly to establish PID ownership. No IO or cleanup
                // success is inferred from that result.
                if (![state[@"readOnlyResultCompleted"] boolValue]) exitCode = 1;
                break;
            } else if (stopping && now >= pendingStopDeadline) {
                state[@"stage"] = @"launch-pending-cleanup-unverified";
                state[@"launchCancellationConfirmed"] = @NO;
                break;
            }
        }
        state[@"elapsedSeconds"] = @(Now() - started);
        state[@"nativeReportPresent"] = @([NSFileManager.defaultManager fileExistsAtPath:report]);
        NSDictionary *nativeResult = ReadNativeReport(report);
        BOOL resultValid = PermissionReportValid(nativeResult, request);
        state[@"nativePermissionResultValid"] = @(resultValid);
        state[@"microphoneAuthorized"] = @(resultValid && [nativeResult[@"authorizationAfter"] isEqualToString:@"authorized"]);
        state[@"resultScope"] = [state[@"readOnlyResultCompleted"] boolValue] ?
            @"Fresh read-only permission result only; owned PID and launcher cleanup remain unverified" :
            @"Permission result and LaunchServices ownership/termination are separately reported";
        if (!resultValid || (request && ![state[@"microphoneAuthorized"] boolValue])) exitCode = exitCode ?: 1;
        Persist(state, statusPath); Print(state);
        return exitCode;
    }
}
