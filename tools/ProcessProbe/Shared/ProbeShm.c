#include <sys/mman.h>
#include "ProbeShm.h"

int probe_shm_open(const char *name, int flags, mode_t mode)
{
    return shm_open(name, flags, mode);
}
