// shm_open is variadic, which Swift cannot call: a fixed-argument wrapper.
#include <sys/types.h>
int probe_shm_open(const char *name, int flags, mode_t mode);
