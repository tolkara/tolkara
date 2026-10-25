#include <FEXCore/Utils/ThreadPoolAllocator.h>
#include <array>
#include <thread>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cassert>
namespace FEXCore::Allocator {
void* malloc(size_t n) { return ::malloc(n); }
void free(void* p) { ::free(p); }
void* aligned_alloc(size_t a,size_t n) { void *p=nullptr; if(::posix_memalign(&p,std::max(a,sizeof(void*)),n)) return nullptr; return p; }
void aligned_free(void* p) { ::free(p); }
}
namespace LogMan::Throw {
[[noreturn]] void MFmt(const char*,const fmt::format_args&) { std::abort(); }
}
class Pool: public FEXCore::Utils::IntrusivePooledAllocator {
public:
 std::atomic<unsigned> allocations{0};
 ~Pool() { FreeAllBuffers(); }
private:
 void* Alloc(size_t size) override { ++allocations; return ::malloc(size); }
 void Free(void* p,size_t) override { ::free(p); }
};
using Client=FEXCore::Utils::PoolBufferWithTimedRetirement<unsigned char*,5000,500>;
int main() {
 setvbuf(stdout,nullptr,_IONBF,0);
 Pool pool;
 std::vector<std::unique_ptr<Client>> clients;
 for(unsigned i=0;i<32;i++) {
  clients.push_back(std::make_unique<Client>(pool,1048576));
  for(unsigned warm=0;warm<2;warm++) {
   auto p=clients.back()->ReownOrClaimBuffer();p[0]=static_cast<unsigned char>(i);
   clients.back()->DelayedDisownBuffer();
  }
 }
 printf("Sequential backing allocations: %u\n",pool.allocations.load());
 assert(pool.allocations==1);
 std::vector<std::thread> threads;
 for(unsigned t=0;t<8;t++) threads.emplace_back([&,t] {
  Client client(pool,1048576);
  for(unsigned i=0;i<1000;i++) {
   auto p=client.ReownOrClaimBuffer();
   p[0]=static_cast<unsigned char>(t+1);p[1048575]=static_cast<unsigned char>(t+1);
   std::this_thread::yield();
   assert(p[0]==t+1 && p[1048575]==t+1);
   client.DelayedDisownBuffer();
  }
 });
 for(auto& t:threads)t.join();
 assert(pool.allocations<=8);
 puts("Shared translation-buffer ownership/reuse passed");
}
