#pragma once
#import <Foundation/Foundation.h>
#include <chrono>
#include <deque>
#include <string>
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace phonebridge {
using Clock = std::chrono::steady_clock;
inline double nowSeconds() { return std::chrono::duration<double>(Clock::now().time_since_epoch()).count(); }
inline bool privateParent(NSString *path) {
    if (!path.isAbsolutePath) return false;
    struct stat st{};
    NSString *parent = path.stringByDeletingLastPathComponent;
    return !lstat(parent.fileSystemRepresentation, &st) && S_ISDIR(st.st_mode) &&
        st.st_uid == getuid() && (st.st_mode & 0777) == 0700;
}
inline int createPrivateReport(NSString *path) {
    if (!path || !privateParent(path)) return -1;
    return open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
}
struct PendingMessage { std::string line; size_t sent = 0; double enqueued = 0; bool audio = false; };
class PrivateIPC {
public:
    int fd = -1;
    pid_t peerPID = -1;
    NSString *error = nil;
    ~PrivateIPC() { if (fd >= 0) close(fd); }
    bool connectTo(NSString *path, NSString *tokenPath) {
        if (!privateParent(path) || !privateParent(tokenPath) ||
            ![path.stringByDeletingLastPathComponent isEqualToString:tokenPath.stringByDeletingLastPathComponent])
            return fail(@"Socket and token must share a private owner-only directory");
        struct stat st{};
        if (lstat(path.fileSystemRepresentation, &st) || !S_ISSOCK(st.st_mode) ||
            st.st_uid != getuid() || (st.st_mode & 0777) != 0600) return fail(@"Require an owned mode-0600 Unix socket");
        int tokenFD = open(tokenPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (tokenFD < 0) return fail(@"Cannot open private token");
        bool valid = !fstat(tokenFD, &st) && S_ISREG(st.st_mode) && st.st_uid == getuid() &&
            (st.st_mode & 0777) == 0600 && (st.st_size == 64 || st.st_size == 65);
        char raw[66]{}; ssize_t n = valid ? read(tokenFD, raw, sizeof(raw)) : -1; close(tokenFD);
        valid = valid && (n == 64 || (n == 65 && raw[64] == '\n'));
        for (size_t i = 0; valid && i < 64; ++i)
            valid = (raw[i] >= '0' && raw[i] <= '9') || (raw[i] >= 'a' && raw[i] <= 'f') || (raw[i] >= 'A' && raw[i] <= 'F');
        if (!valid) return fail(@"Token must contain exactly 64 hexadecimal characters");
        NSString *token = [[NSString alloc] initWithBytes:raw length:64 encoding:NSASCIIStringEncoding];
        memset(raw, 0, sizeof(raw));
        struct sockaddr_un address{}; address.sun_family = AF_UNIX;
        const char *p = path.fileSystemRepresentation;
        if (strlen(p) >= sizeof(address.sun_path)) return fail(@"Unix socket path is too long");
        strlcpy(address.sun_path, p, sizeof(address.sun_path));
        address.sun_len = uint8_t(offsetof(sockaddr_un, sun_path) + strlen(p) + 1);
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return fail(@"Cannot create Unix socket");
        int yes = 1;
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) || fcntl(fd, F_SETFL, O_NONBLOCK) ||
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes))) return fail(@"Cannot configure private socket");
        int connected = connect(fd, reinterpret_cast<sockaddr *>(&address), address.sun_len);
        if (connected && errno != EINPROGRESS) return fail(@"Cannot connect to coordinator");
        if (connected) {
            pollfd wait{fd, POLLOUT, 0}; int socketError = 0; socklen_t len = sizeof(socketError);
            if (poll(&wait, 1, 5000) != 1 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &len) || socketError)
                return fail(@"Coordinator connection timed out");
        }
        uid_t uid = uid_t(-1); gid_t gid = gid_t(-1); socklen_t length = sizeof(peerPID);
        if (getpeereid(fd, &uid, &gid) || uid != getuid() ||
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) || length != sizeof(peerPID) || peerPID <= 1 || peerPID == getpid())
            return fail(@"Coordinator peer identity could not be verified");
        return enqueue(@{@"type": @"hello", @"protocol": @1, @"token": token, @"pid": @(getpid()), @"generation": @0}, false);
    }
    bool enqueue(NSDictionary *event, bool audio) {
        NSData *bytes = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        if (!bytes || bytes.length > 98304 || queuedBytes + bytes.length + 1 > 262144)
            return fail(@"Local event queue exceeded its bound");
        PendingMessage message; message.line.assign(static_cast<const char *>(bytes.bytes), bytes.length);
        message.line.push_back('\n'); message.enqueued = nowSeconds(); message.audio = audio;
        queuedBytes += message.line.size(); outgoing.push_back(std::move(message)); return true;
    }
    bool flush() {
        double now = nowSeconds();
        for (const auto &message : outgoing) if (message.audio && now - message.enqueued > 2)
            return fail(@"Input PCM could not reach the local coordinator within two seconds");
        size_t budget = 65536;
        while (!outgoing.empty() && budget) {
            auto &message = outgoing.front(); size_t count = std::min(budget, message.line.size() - message.sent);
            ssize_t n = send(fd, message.line.data() + message.sent, count, 0);
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return true;
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return fail(@"Coordinator socket disconnected while sending");
            message.sent += size_t(n); queuedBytes -= size_t(n); budget -= size_t(n);
            if (message.sent == message.line.size()) outgoing.pop_front();
        }
        return true;
    }
    // Bounded work per iteration, even if the peer continuously writes.
    bool receive(NSMutableArray<NSDictionary *> *commands) {
        char buffer[16384]; size_t budget = 65536;
        while (budget) {
            ssize_t n = recv(fd, buffer, std::min(budget, sizeof(buffer)), 0);
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return fail(@"Coordinator socket disconnected");
            incoming.append(buffer, size_t(n)); budget -= size_t(n);
            size_t end;
            while ((end = incoming.find('\n')) != std::string::npos) {
                if (!end || end > 98304 || commands.count >= 64) return fail(@"Invalid or excessive command framing");
                NSData *line = [NSData dataWithBytes:incoming.data() length:end];
                id parsed = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if (![parsed isKindOfClass:NSDictionary.class]) return fail(@"Command must be one JSON object per line");
                [commands addObject:parsed]; incoming.erase(0, end + 1);
            }
            if (incoming.size() > 98304) return fail(@"Command line exceeded its bound");
        }
        return true;
    }
    bool empty() const { return outgoing.empty(); }
    bool discardUnsentAudio() {
        // A partially written JSON line cannot be removed without corrupting the
        // stream. Close in that case and let the metadata report prove cleanup.
        for (const auto &message : outgoing) if (message.audio && message.sent) {
            close(fd); fd = -1; outgoing.clear(); queuedBytes = 0; return false;
        }
        for (auto it = outgoing.begin(); it != outgoing.end();) {
            if (it->audio) { queuedBytes -= it->line.size(); it = outgoing.erase(it); }
            else ++it;
        }
        return true;
    }
private:
    size_t queuedBytes = 0;
    std::deque<PendingMessage> outgoing;
    std::string incoming;
    bool fail(NSString *reason) { error = reason; return false; }
};
}
