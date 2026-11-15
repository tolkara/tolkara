// The bound on a process's end (runtime/ProcessEnd.c): an exit handler that
// never returns does not keep the process, a deadline moved later holds, and
// an exit that finishes in time keeps its own code.
#include "ProcessEnd.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void stuck(void) { for (;;) pause(); }
static double seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static int run(int scenario, double *took) {
    double start = seconds();
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        close(STDERR_FILENO);
        if (scenario == 0) { atexit(stuck); pe_deadline(3, 0.3); exit(3); }
        if (scenario == 1) { pe_deadline(4, 5); exit(0); }
        // Armed short, then moved later: the first deadline must not fire.
        atexit(stuck); pe_deadline(5, 0.2); pe_deadline(6, 1.0); exit(6);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status));
    *took = seconds() - start;
    return WEXITSTATUS(status);
}
int main(void) {
    double took;
    assert(run(0, &took) == 3 && took >= 0.25 && took < 4);
    assert(run(1, &took) == 0 && took < 2);
    assert(run(2, &took) == 6 && took >= 0.9 && took < 5);
    puts("process end: a stuck exit handler is cut off, a moved deadline holds, a prompt exit keeps its code: PASS");
    return 0;
}
