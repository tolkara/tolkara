#ifndef PROCESS_END_H
#define PROCESS_END_H

// A bound on how long the process takes to end. exit() runs the guest's
// atexit handlers and static destructors while its audio, Metal and network
// threads are still alive; one that waits for such a thread never returns,
// and iOS leaves a hung foreground app on screen. Arming the deadline ends the
// process with _exit(code) once `seconds` have passed; arming again moves it
// (longer for a save upload, short again for the handlers). It never fires
// before the latest deadline, and a process that ends in time never sees it.
void pe_deadline(int code, double seconds);

#endif
