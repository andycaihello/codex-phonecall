// One-shot local maintenance tool. The owner explicitly authorizes this action.
// Uses the normal macOS administrator dialog, never reads a password and never
// accepts a command/path/argument from its caller. Does not install a daemon.
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pwd.h>

int main(int argc, char **argv) {
    if (argc != 1) return 64;
    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                          kAuthorizationFlagDefaults, &authorization);
    if (status != errAuthorizationSuccess) return 1;
    AuthorizationItem item = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    puts("Requesting normal macOS administrator authorization for the fixed audio-service reload.");
    fflush(stdout);
    status = AuthorizationCopyRights(authorization, &rights, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize, NULL);
    if (status == errAuthorizationSuccess) {
        // killall filters by real UID even when Authorization Services grants
        // effective root. Signal the single verified daemon directly instead.
        FILE *lookup = popen("/usr/bin/pgrep -x coreaudiod", "r");
        int pid = 0, extra = 0;
        int count = lookup ? fscanf(lookup, "%d %d", &pid, &extra) : 0;
        if (lookup) pclose(lookup);
        char query[128], executable[256] = {0}; unsigned owner = 0;
        snprintf(query, sizeof(query), "/bin/ps -p %d -o uid=,comm=", pid);
        FILE *metadata = count == 1 && pid > 1 ? popen(query, "r") : NULL;
        int fields = metadata ? fscanf(metadata, "%u %255s", &owner, executable) : 0;
        if (metadata) pclose(metadata);
        struct passwd *account = getpwnam("_coreaudiod");
        if (count != 1 || pid <= 1 || fields != 2 || !account || owner != account->pw_uid || strcmp(executable, "/usr/sbin/coreaudiod") != 0) {
            AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
            fputs("Could not uniquely verify the audio daemon; no signal sent.\n", stderr);
            return 1;
        }
        char target[32]; snprintf(target, sizeof(target), "%d", pid);
        char *const arguments[] = { "-TERM", target, NULL };
        FILE *output = NULL;
        status = AuthorizationExecuteWithPrivileges(authorization, "/bin/kill",
            kAuthorizationFlagDefaults, arguments, &output);
        if (output) {
            char buffer[512];
            while (fgets(buffer, sizeof(buffer), output)) fputs(buffer, stdout);
            fclose(output);
        }
    }
    AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
    if (status != errAuthorizationSuccess) {
        fprintf(stderr, "Audio-service reload authorization/launch failed (%d).\n", (int)status);
        return 1;
    }
    puts("Fixed reload command submitted; device enumeration must verify its result.");
    return 0;
}
