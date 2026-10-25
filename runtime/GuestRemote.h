#pragma once
#include <stdbool.h>
#include <stdio.h>

// A Windows process in a second app (docs/MULTIPROCESS.md, "Two apps"): one that
// needs more address space than it can share with the others runs in its own
// build of Tolkara, in the same App Group. The first app hands it over instead of
// starting it in a slot; the second app's slot host starts it in one of its own.
// Both talk through Unix sockets in the App Group container (TOLKARA_GROUP_DIR).

void gr_configure(FILE *log);

// First app: whether the runtime's spawn of this command line (argv[0] the runtime
// itself, argv[1] the program) goes to the second app (TOLKARA_REMOTE_PROCESS,
// patterns separated by ';' matched as substrings ignoring case).
bool gr_wants_remote(char *const argv[]);
// First app: hands the command line, the environment and the server socket named
// by WINESERVERSOCKET to the second app's slot host; on success the socket is
// closed here (the process's copy is the other app's now). errno-style result.
// Idle I/O expires after 10 seconds. Failure retains the caller's descriptor.
// A lost reply does not prove the child never started; do not automatically retry.
int gr_hand_over(char *const argv[], char *const envp[]);

// Second app (TOLKARA_SLOT_HOST): instead of its own first program, starts each
// process handed over, in a free slot, and delivers the server's signals to their
// threads. Does not return.
void gr_serve(void) __attribute__((noreturn));
// The same on a thread of its own, so the caller's thread (the app's main thread, whose run
// loop the processes' windows need) returns to its run loop.
void gr_serve_in_background(void);
// The first process handed over, if one has arrived: its command line and environment
// (NULL-terminated, the server socket already this app's descriptor), for the caller to
// run as this app's own first program (slot 0, whose windows are the app's). Later ones
// start in slots. False until one arrives; never blocks.
bool gr_take_first(char ***argv, char ***envp);
