/* Owned loader fixture. Build as native ARM64, with 64 KiB sections and
 * 16 KiB file alignment, -nostdlib, and entry point DllMain. */
static int expected = 7349;
static int *volatile relocated = &expected;

__declspec(dllexport) int aligned_probe_value(void)
{
    return *relocated;
}

int __stdcall DllMain(void *module, unsigned long reason, void *reserved)
{
    (void)module;
    (void)reason;
    (void)reserved;
    return 1;
}
