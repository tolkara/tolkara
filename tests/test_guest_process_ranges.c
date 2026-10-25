// Owned reservation metadata only: no guest application or fixed mappings.
#include "../runtime/GuestProcesses.c"
#include <assert.h>
const GuestLibrary *gl_library_at(const GuestLinkSet *s, uint64_t a) { (void)s; (void)a; return NULL; }
bool gsv_handle_signal(int n, siginfo_t *i, void *c) { (void)n; (void)i; (void)c; return false; }
int main(void) {
    gp_configure(5,stderr,NULL);
    gp_set_large_reserve(0x7000000000ULL,0x7300000000ULL);
    for (size_t slot=1;slot<4;slot++) {
        assert(!gp_setenv(slot,"WINELARGERESERVE","0x7000000000-0x7100000000",1));
        assert(!gp_setenv(slot,"TOLKARA_PROCESS_RANGE_POOL","0x7000000000-0x7200000000",1));
    }
    assert(claim_range(1)); assert(claim_range(2));
    assert(range_start[1]==0x7000000000ULL && range_start[2]==0x7100000000ULL);
    assert(!strcmp(gp_getenv(2,"WINESMALLRANGE"),"0x7100000000-0x7200000000"));
    assert(!claim_range(3)); // full: never steal a retired range
    assert(!gp_setenv(3,"TOLKARA_PROCESS_RANGE_POOL","0x7200000000-0x7400000000",1));
    assert(!claim_range(3)); // beyond the host-owned reservation
    assert(!gp_setenv(3,"TOLKARA_PROCESS_RANGE_POOL","0x7200000000-0x7300000000junk",1));
    assert(!claim_range(3));
    assert(!gp_setenv(3,"TOLKARA_PROCESS_RANGE_POOL","0x7200000000-0x7300000000",1));
    assert(claim_range(3));
    // A browser keeps the middle of the host reservation. Successive games
    // must skip it and must not steal the first game's retired range.
    memset(range_start,0,sizeof range_start);
    memset(range_end,0,sizeof range_end);
    gp_set_large_reserve(0x7000000000ULL,0x7f00000000ULL);
    assert(!gp_setenv(1,"TOLKARA_PROCESS_RANGE_POOL","",1));
    assert(!gp_setenv(1,"WINELARGERESERVE","0x7100000000-0x7e00000000",1));
    assert(claim_range(1));
    for (size_t slot=2;slot<5;slot++) {
        assert(!gp_setenv(slot,"WINELARGERESERVE","0x7000000000-0x7100000000",1));
        assert(!gp_setenv(slot,"TOLKARA_PROCESS_RANGE_POOL","0x7000000000-0x7f00000000",1));
    }
    assert(claim_range(2));
    assert(claim_range(3));
    assert(range_start[2]==0x7000000000ULL && range_end[2]==0x7100000000ULL);
    assert(range_start[3]==0x7e00000000ULL && range_end[3]==0x7f00000000ULL);
    assert(!claim_range(4));
    gp_set_environment_rules("SteamService.exe>TOLKARA_PROCESS_RANGE_POOL=0x7000000000-0x7f00000000");
    char *service[]={"SteamService.exe",NULL};
    char *child[]={"conhost.exe",NULL};
    gp_apply_environment_rules(4,1,service);
    assert(!strcmp(gp_getenv(4,"TOLKARA_PROCESS_RANGE_POOL"),"0x7000000000-0x7f00000000"));
    gp_apply_environment_rules(4,1,child);
    assert(!*gp_getenv(4,"TOLKARA_PROCESS_RANGE_POOL"));
    puts("fresh process ranges are disjoint, bounded and fail closed: PASS");
}
