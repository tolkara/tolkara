#include "GuestRemote.h"
#include "GuestProcesses.h"
#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <unistd.h>

// The messages, native byte order (both apps run on the same device).
// Hand-over, first app to the second, on <group>/slots.sock: this header with the
// server socket attached (SCM_RIGHTS), then argc + envc NUL-terminated strings
// (`bytes` in all); the answer is GRReply.
// Signal, the first app's server to the second app, on <group>/s<pid>.sock: GRSignal
// records, as many as the connection carries; no answer.
enum { GR_MAGIC = 0x314b4854 };  // "THK1"
typedef struct { uint32_t magic, argc, envc, bytes; } GRHeader;
typedef struct { int32_t result, pid; } GRReply;
typedef struct { uint32_t thread; int32_t signal; } GRSignal;

static FILE *log_file;
// The first process handed over runs as slot 0 (gr_take_first); later ones in slots.
static pthread_mutex_t first_lock = PTHREAD_MUTEX_INITIALIZER;
static bool first_taken, first_ready;
static char **first_argv, **first_envp;
#define LOG(...) do { if (log_file) { fprintf(log_file, __VA_ARGS__); fflush(log_file); } } while (0)

void gr_configure(FILE *log) { log_file = log; }

static bool socket_address(struct sockaddr_un *address, const char *name) {
    const char *group = getenv("TOLKARA_GROUP_DIR");
    memset(address, 0, sizeof *address);
    address->sun_family = AF_UNIX;
    if (!group || !*group) return false;
    int length = snprintf(address->sun_path, sizeof address->sun_path, "%s/%s", group, name);
    return length > 0 && (size_t)length < sizeof address->sun_path;
}

static bool matches(const char *patterns, const char *text) {
    char copy[512];
    if (!patterns || !text) return false;
    snprintf(copy, sizeof copy, "%s", patterns);
    for (char *save = NULL, *pattern = strtok_r(copy, ";", &save); pattern; pattern = strtok_r(NULL, ";", &save)) {
        size_t length = strlen(pattern);
        for (const char *at = text; length && *at; at++) if (!strncasecmp(at, pattern, length)) return true;
    }
    return false;
}

bool gr_wants_remote(char *const argv[]) {
    return argv && argv[0] && argv[1] && matches(getenv("TOLKARA_REMOTE_PROCESS"), argv[1]);
}

// A background peer may suspend or close its connection. Bound idle handover
// waits and report broken sockets to the caller instead of terminating the app.
static bool configure_connection(int fd, bool handover) {
    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof enabled)) return false;
    if (handover) {
        struct timeval timeout = { .tv_sec = 10 };
        if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) ||
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout)) return false;
    }
    return true;
}

static bool write_all(int fd, const void *data, size_t size) {
    for (const char *at = data; size;) {
        ssize_t done = write(fd, at, size);
        if (done < 0 && errno == EINTR) continue;
        if (done <= 0) { if (!done) errno = EPIPE; return false; }
        at += done; size -= (size_t)done;
    }
    return true;
}

static bool read_all(int fd, void *data, size_t size) {
    for (char *at = data; size;) {
        ssize_t done = read(fd, at, size);
        if (done < 0 && errno == EINTR) continue;
        if (done <= 0) { if (!done) errno = EPIPE; return false; }
        at += done; size -= (size_t)done;
    }
    return true;
}

int gr_hand_over(char *const argv[], char *const envp[]) {
    int server_socket = -1;
    size_t argc = 0, envc = 0, bytes = 0;
    for (; argv[argc]; argc++) bytes += strlen(argv[argc]) + 1;
    for (; envp && envp[envc]; envc++) {
        bytes += strlen(envp[envc]) + 1;
        if (!strncmp(envp[envc], "WINESERVERSOCKET=", 17)) server_socket = atoi(envp[envc] + 17);
    }
    if (server_socket < 0) { LOG("[remote] no server socket to hand over for %s\n", argv[1]); return EINVAL; }
    struct sockaddr_un address;
    if (!socket_address(&address, "slots.sock")) { LOG("[remote] no App Group folder (TOLKARA_GROUP_DIR)\n"); return ENOTSUP; }
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0) return errno;
    if (!configure_connection(connection, true)) { int error = errno; close(connection); return error; }
    if (connect(connection, (struct sockaddr *)&address, sizeof address)) {
        int error = errno;
        LOG("[remote] the second app is not waiting (%s): %s stays unstarted\n", strerror(error), argv[1]);
        close(connection);
        return error;
    }
    GRHeader header = { GR_MAGIC, (uint32_t)argc, (uint32_t)envc, (uint32_t)bytes };
    union { struct cmsghdr header; char space[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof control);
    struct iovec vector = { &header, sizeof header };
    struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1, .msg_control = &control, .msg_controllen = sizeof control };
    struct cmsghdr *attached = CMSG_FIRSTHDR(&message);
    attached->cmsg_level = SOL_SOCKET; attached->cmsg_type = SCM_RIGHTS; attached->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(attached), &server_socket, sizeof(int));
    bool sent = sendmsg(connection, &message, 0) == (ssize_t)sizeof header;
    for (size_t i = 0; sent && i < argc; i++) sent = write_all(connection, argv[i], strlen(argv[i]) + 1);
    for (size_t i = 0; sent && i < envc; i++) sent = write_all(connection, envp[i], strlen(envp[i]) + 1);
    GRReply reply = { EPIPE, 0 };
    if (!sent || !read_all(connection, &reply, sizeof reply))
        reply.result = (errno == EAGAIN || errno == EWOULDBLOCK) ? ETIMEDOUT : EPIPE;
    close(connection);
    LOG("[remote] %s handed to the second app (pid %d): result %d\n", argv[1], reply.pid, reply.result);
    // The process's end of the server connection lives in the other app now.
    if (!reply.result) close(server_socket);
    return reply.result;
}

static int listen_at(const char *name) {
    struct sockaddr_un address;
    if (!socket_address(&address, name)) return -1;
    unlink(address.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (bind(fd, (struct sockaddr *)&address, sizeof address) || listen(fd, 8)) { close(fd); return -1; }
    return fd;
}

extern int __pthread_kill(mach_port_t thread, int signal);

// The server names each thread by its Mach port in this task, as the thread told it.
static void *deliver_signals(void *context) {
    int listener = (int)(intptr_t)context;
    for (;;) {
        int connection = accept(listener, NULL, NULL);
        if (connection < 0) { if (errno == EINTR) continue; LOG("[remote] signal socket failed: %s\n", strerror(errno)); return NULL; }
        if (!configure_connection(connection, false)) { close(connection); continue; }
        GRSignal record;
        while (read_all(connection, &record, sizeof record)) {
            // Only what the server sends its clients; the answer is the kernel's.
            int32_t result = EINVAL;
            if (record.thread && (record.signal == SIGUSR1 || record.signal == SIGQUIT || record.signal == SIGINT))
                result = __pthread_kill((mach_port_t)record.thread, record.signal);
            if (result) LOG("[remote] signal %d for thread %#x: %d\n", record.signal, record.thread, result);
            if (!write_all(connection, &result, sizeof result)) break;
        }
        close(connection);
    }
}

// Paths into the first app's container name the same files in this one.
static char *rehome(const char *entry, const char *from, const char *to) {
    const char *at = from && *from && to ? strstr(entry, from) : NULL;
    if (!at || !strcmp(from, to)) return strdup(entry);
    size_t before = (size_t)(at - entry), length = strlen(entry) - strlen(from) + strlen(to) + 1;
    char *result = malloc(length);
    if (result) snprintf(result, length, "%.*s%s%s", (int)before, entry, to, at + strlen(from));
    return result;
}

static void serve_one(int connection) {
    GRHeader header;
    int server_socket = -1;
    union { struct cmsghdr header; char space[CMSG_SPACE(sizeof(int))]; } control;
    struct iovec vector = { &header, sizeof header };
    struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1, .msg_control = &control, .msg_controllen = sizeof control };
    GRReply reply = { EPROTO, getpid() };
    char *payload = NULL, **argv = NULL, **envp = NULL;
    ssize_t received = recvmsg(connection, &message, 0);
    int descriptors = 0;
    if (received > 0)
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&message); c; c = CMSG_NXTHDR(&message, c)) {
            if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
            // Every descriptor received is ours to close unless it is the one expected.
            size_t count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            for (size_t i = 0; i < count; i++) {
                int fd;
                memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
                if (!descriptors++) server_socket = fd; else close(fd);
            }
        }
    if (descriptors != 1 && server_socket >= 0) { close(server_socket); server_socket = -1; }
    if (received != (ssize_t)sizeof header || header.magic != GR_MAGIC ||
        header.argc < 2 || header.argc > 4096 || header.envc > 65536 || header.bytes > (16u << 20)) goto done;
    // Exactly one descriptor, the process's server connection; anything else is refused.
    if (message.msg_flags & MSG_CTRUNC) goto done;
    if (server_socket < 0 || !(payload = malloc(header.bytes + 1)) || !read_all(connection, payload, header.bytes)) goto done;
    payload[header.bytes] = 0;
    argv = calloc(header.argc + 1, sizeof *argv);
    envp = calloc(header.envc + 2, sizeof *envp);
    if (!argv || !envp) goto done;
    char *at = payload, *end = payload + header.bytes;
    for (uint32_t i = 0; i < header.argc; i++) { if (at >= end) goto done; argv[i] = at; at += strlen(at) + 1; }
    const char *their_home = NULL, *home = getenv("HOME");
    char *entries = at;
    for (uint32_t i = 0; i < header.envc; i++) {
        if (at >= end) goto done;
        if (!strncmp(at, "HOME=", 5)) their_home = at + 5;
        at += strlen(at) + 1;
    }
    at = entries;
    size_t count = 0;
    char socket_entry[64];
    snprintf(socket_entry, sizeof socket_entry, "WINESERVERSOCKET=%d", server_socket);
    for (uint32_t i = 0; i < header.envc; i++, at += strlen(at) + 1)
        envp[count++] = strncmp(at, "WINESERVERSOCKET=", 17) ? rehome(at, their_home, home) : strdup(socket_entry);
    // The runtime here is this app's own.
    char own[PATH_MAX];
    uint32_t size = sizeof own;
    extern int _NSGetExecutablePath(char *, uint32_t *);
    if (!_NSGetExecutablePath(own, &size)) argv[0] = own;
    LOG("[remote] starting %s, handed over by the first app\n", argv[1]);
    pthread_mutex_lock(&first_lock);
    bool first = !first_taken;
    first_taken = true;
    pthread_mutex_unlock(&first_lock);
    if (first) {
        // Kept for slot 0: copies, since the payload is freed here.
        char **args = calloc(header.argc + 1, sizeof *args);
        for (uint32_t i = 0; args && i < header.argc; i++) args[i] = strdup(argv[i]);
        envp[count] = NULL;
        pthread_mutex_lock(&first_lock);
        first_argv = args; first_envp = envp; first_ready = true;
        pthread_mutex_unlock(&first_lock);
        envp = NULL; count = 0;
        reply.result = args ? 0 : ENOMEM;
        LOG("[remote] it runs as this app's first program\n");
    } else reply.result = gp_spawn(argv, envp);
    for (size_t i = 0; i < count; i++) free(envp[i]);
done:
    if (reply.result && server_socket >= 0) close(server_socket);
    if (reply.result) LOG("[remote] hand-over refused or failed: %d\n", reply.result);
    write_all(connection, &reply, sizeof reply);
    free(argv); free(envp); free(payload);
}

void gr_serve(void) {
    char name[32];
    snprintf(name, sizeof name, "s%d.sock", (int)getpid());
    int signals = listen_at(name), slots = listen_at("slots.sock");
    if (signals < 0 || slots < 0) LOG("[remote] cannot listen in the App Group folder (%s)\n", strerror(errno));
    else {
        pthread_t thread;
        pthread_create(&thread, NULL, deliver_signals, (void *)(intptr_t)signals);
        pthread_detach(thread);
        LOG("[remote] slot host ready: waiting for processes from the first app\n");
        for (;;) {
            int connection = accept(slots, NULL, NULL);
            if (connection < 0) { if (errno == EINTR) continue; break; }
            if (configure_connection(connection, true)) serve_one(connection);
            close(connection);
        }
        LOG("[remote] slot host socket failed: %s\n", strerror(errno));
    }
    for (;;) pause();
}

static void *serve_thread(void *unused) { (void)unused; gr_serve(); }

void gr_serve_in_background(void) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, serve_thread, NULL)) { LOG("[remote] slot host thread failed\n"); return; }
    pthread_detach(thread);
}

bool gr_take_first(char ***argv, char ***envp) {
    pthread_mutex_lock(&first_lock);
    bool ready = first_ready;
    if (ready) { *argv = first_argv; *envp = first_envp; first_ready = false; }
    pthread_mutex_unlock(&first_lock);
    return ready;
}
