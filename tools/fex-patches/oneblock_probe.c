#include "rpmalloc.h"
#include <stdio.h>
int main(void) {
    rpmalloc_config_t config = {0};
    config.page_size = 65536;
    if (rpmalloc_initialize_config(0, &config)) return 1;
    void *a = rpmalloc(512 * 1024);
    void *b = rpmalloc(512 * 1024);
    if (!a || !b) return 2;
    rpfree(a);
    rpfree(b);
    rpmalloc_finalize();
    puts("One-block full-to-empty transition passed");
    return 0;
}
