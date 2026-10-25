// Owned socket fixture: no guest application executes.
#include "../runtime/GuestRemote.c"
#include <assert.h>
#include <fcntl.h>
#include <time.h>
#include <sys/wait.h>

int gp_spawn(char *const argv[], char *const envp[]) { (void)argv; (void)envp; return ENOTSUP; }

static void *silent_peer(void *arg) {
    int listener = *(int *)arg;
    int fd = accept(listener, NULL, NULL);
    assert(fd >= 0);
    // Read the request but deliberately never acknowledge it, like suspension.
    char buffer[4096];
    assert(read(fd, buffer, sizeof buffer) > 0);
    sleep(12);
    close(fd);
    return NULL;
}

int main(void) {
    signal(SIGPIPE, SIG_DFL);
    int pair[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    assert(configure_connection(pair[0], true));
    close(pair[1]);
    assert(!write_all(pair[0], "test", 4) && errno == EPIPE);
    close(pair[0]);

    char dir[] = "/tmp/tk-remote-XXXXXX";
    assert(mkdtemp(dir));
    assert(!setenv("TOLKARA_GROUP_DIR", dir, 1));
    int listener = listen_at("slots.sock");
    assert(listener >= 0);
    // A separate Mac process receives the real SCM_RIGHTS descriptor. Close
    // inherited copies before accepting, so only the transferred one can work.
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        close(pair[0]); close(pair[1]);
        int connection = accept(listener, NULL, NULL);
        assert(connection >= 0 && configure_connection(connection, true));
        serve_one(connection);
        close(connection);
        char **received_args = NULL, **received_env = NULL;
        assert(gr_take_first(&received_args, &received_env));
        assert(!strcmp(received_args[1], "owned-test.exe"));
        assert(!strcmp(received_args[2], "argument with spaces"));
        int transferred = -1;
        for (char **entry = received_env; *entry; entry++)
            if (!strncmp(*entry, "WINESERVERSOCKET=", 17)) transferred = atoi(*entry + 17);
        assert(transferred >= 0 && configure_connection(transferred, true));
        assert(write_all(transferred, "child-ready", 11));
        char ack[3];
        assert(read_all(transferred, ack, sizeof ack) && !memcmp(ack, "ack", 3));
        close(transferred); close(listener);
        for (char **a = received_args; *a; a++) free(*a);
        for (char **e = received_env; *e; e++) free(*e);
        free(received_args); free(received_env);
        _exit(0);
    }
    char success_env[64];
    snprintf(success_env, sizeof success_env, "WINESERVERSOCKET=%d", pair[0]);
    char *success_args[] = { "wine", "owned-test.exe", "argument with spaces", NULL };
    char *success_envs[] = { success_env, NULL };
    assert(gr_hand_over(success_args, success_envs) == 0);
    assert(fcntl(pair[0], F_GETFD) == -1 && errno == EBADF);
    assert(configure_connection(pair[1], true));
    char ready[11];
    assert(read_all(pair[1], ready, sizeof ready) && !memcmp(ready, "child-ready", 11));
    assert(write_all(pair[1], "ack", 3));
    close(pair[1]);
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);

    pthread_t thread;
    assert(!pthread_create(&thread, NULL, silent_peer, &listener));
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    char env[64];
    snprintf(env, sizeof env, "WINESERVERSOCKET=%d", pair[0]);
    char *args[] = { "wine", "owned-test.exe", NULL };
    char *envs[] = { env, NULL };
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    assert(gr_hand_over(args, envs) == ETIMEDOUT);
    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = end.tv_sec - start.tv_sec + (end.tv_nsec - start.tv_nsec) / 1e9;
    assert(elapsed >= 9 && elapsed < 12);
    assert(fcntl(pair[0], F_GETFD) >= 0); // failure preserves ownership
    close(pair[0]); close(pair[1]);
    pthread_join(thread, NULL);
    close(listener);
    char path[128]; snprintf(path, sizeof path, "%s/slots.sock", dir);
    unlink(path); rmdir(dir);
    puts("PASS: cross-process handover and bidirectional server socket; broken peer does not SIGPIPE; silent peer times out; descriptor retained");
    return 0;
}
