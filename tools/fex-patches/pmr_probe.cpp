#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/fextl/memory_resource.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <map>
static std::map<void*,size_t> live;
static void* map_pages(void*,size_t n,int,int,int,off_t) {
    void* p=nullptr;
    if (posix_memalign(&p,4096,n)) std::abort();
    live.emplace(p,n);
    return p;
}
static int unmap_pages(void* p,size_t n) {
    auto i=live.find(p);assert(i!=live.end() && i->second==n);
    live.erase(i);std::free(p);return 0;
}
namespace FEXCore::Allocator {
MMAP_Hook mmap=map_pages;
MUNMAP_Hook munmap=unmap_pages;
void VirtualName(const char*,void*,size_t) {}
void* malloc(size_t n) {return ::malloc(n);}
void free(void* p) {::free(p);}
void* aligned_alloc(size_t a,size_t n) {void* p=nullptr;if(::posix_memalign(&p,std::max(a,sizeof(void*)),n))return nullptr;return p;}
void aligned_free(void* p) {::free(p);}
}
namespace LogMan::Throw { [[noreturn]] void MFmt(const char*,const fmt::format_args&) {std::abort();} }
int main() {
    for(unsigned r=0;r<100;r++) {
        {
            fextl::pmr::named_monotonic_page_buffer_resource arena("owned-test");
            for(unsigned i=0;i<100;i++) {
                auto p=static_cast<unsigned char*>(arena.allocate(1000+i*16,64));
                assert(reinterpret_cast<uintptr_t>(p)%64==0);p[0]=1;p[999+i*16]=2;
            }
            if(r%2) {arena.release();assert(live.empty());arena.release();(void)arena.allocate(8192,4096);}
        }
        if(!live.empty()) {std::printf("Leaked backing regions after destruction: %zu\n",live.size());return 1;}
    }
    puts("PMR page ownership and release/reuse passed");
}
