#ifndef AK_SESSION_AUDIO_H
#define AK_SESSION_AUDIO_H
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
// A device identity shared by the desktop property and RemoteIO adapters.
// This names the iOS session's output route, not a native desktop HAL device.
#define AK_SESSION_OUTPUT_DEVICE UINT32_C(0x544b0001)
static inline bool AKSessionAudioOnly(void) {
    const char *value=getenv("TOLKARA_SESSION_AUDIO_ONLY");
    return value && !strcmp(value,"1");
}
#endif
