#include "GuestCPU.h"
#include "CPUProbe.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>

static const uint64_t base=0x100000000,done=0xffff0000;
static void instruction(GuestMemory *m,uint32_t i) { assert(gm_populate(m,base,&i,4)==GM_OK); }
static void step(GuestCPU *c,GuestMemory *m,uint32_t i) {
    instruction(m,i);c->pc=base;assert(gc_run(c,m,1,done)==GC_BUDGET);assert(c->pc==base+4);
}
int main(void) {
    GuestCPU *c=calloc(1,sizeof *c);assert(c);
    GuestMemory m={0};
    assert(gm_map(&m,base,GM_PAGE_SIZE,7,7,false,false)==GM_OK);
    gc_reset(c,base,0x2000);
    // ADDS/SUBS at sign/carry boundaries, checked with wider independent arithmetic.
    uint64_t cases[]={0,1,UINT64_MAX,0x7fffffffffffffffULL,0x8000000000000000ULL,0xffffffff};
    for(unsigned width=32;width<=64;width+=32) for(unsigned sub=0;sub<2;sub++)
    for(unsigned a=0;a<6;a++)for(unsigned b=0;b<6;b++) {
        uint64_t mask=width==64?UINT64_MAX:UINT32_MAX,sign=1ULL<<(width-1);
        uint64_t x=cases[a]&mask,y=cases[b]&mask;
        c->x[0]=cases[a];c->x[1]=cases[b];
        step(c,&m,(width==64?0xab010002:0x2b010002)|(sub<<30));
        uint64_t result=(sub?x-y:x+y)&mask;
        bool carry=sub?x>=y:((__uint128_t)x+y)>mask;
        __int128 sx=(x&sign)?(__int128)x-((__int128)1<<width):x;
        __int128 sy=(y&sign)?(__int128)y-((__int128)1<<width):y;
        __int128 sum=sub?sx-sy:sx+sy;
        bool overflow=sum<-((__int128)1<<(width-1)) || sum>(((__int128)1<<(width-1))-1);
        unsigned flags=(result&sign?8:0)|(result==0?4:0)|(carry?2:0)|(overflow?1:0);
        assert(c->x[2]==result && c->nzcv==flags);
    }
    step(c,&m,0x910043ff);assert(c->sp==0x2010); // ADD SP,SP,#16
    c->x[0]=UINT64_MAX;step(c,&m,0x2a1f03e0);assert(c->x[0]==0); // MOV W0,WZR
    // Data page writes do not discard decoded executable instructions.
    assert(gm_map(&m,0x4000,GM_PAGE_SIZE,3,3,false,false)==GM_OK);
    c->x[0]=0xfedcba9876543210ULL;c->x[1]=0x4000;
    instruction(&m,0xf9000020);uint64_t generation=m.code_generation;
    c->pc=base;assert(gc_run(c,&m,1,done)==GC_BUDGET);assert(m.code_generation==generation);
    c->x[0]=0;step(c,&m,0xf9400020);assert(c->x[0]==0xfedcba9876543210ULL);
    // A failing store must not advance the PC or retire the instruction.
    c->x[1]=0x8000;instruction(&m,0xf9000020);c->pc=base;uint64_t retired=c->retired;
    assert(gc_run(c,&m,1,done)==GC_MEMORY && c->pc==base && c->retired==retired && m.fault_address==0x8000);
    // Writing code, revoking execute access and changing JIT write mode invalidate cached fetches.
    step(c,&m,0xd2800540);assert(c->x[0]==42);
    // Forms that translated atomic loops use between an exclusive load and store
    c->x[1]=0xff;c->x[2]=0x3ff;step(c,&m,0x6b22003f);assert(c->nzcv==6); // CMP W1,W2,UXTB
    c->x[1]=0x1ff;c->x[2]=0x1ff;step(c,&m,0x6b22003f);assert(!(c->nzcv&4)); // CMP W1,W2,UXTB
    c->x[1]=100;c->x[2]=0xffffffff;step(c,&m,0x8b22c820);assert(c->x[0]==96); // ADD X0,X1,W2,SXTW #2
    c->x[1]=5;c->x[2]=5;c->nzcv=4;step(c,&m,0xfa420020);assert(c->nzcv==6); // CCMP X1,X2,#0,EQ
    c->nzcv=0;step(c,&m,0xfa420021);assert(c->nzcv==1); // CCMP X1,X2,#1,EQ, condition false
    c->x[1]=1;c->x[2]=65;step(c,&m,0x9ac22020);assert(c->x[0]==2); // LSL X0,X1,X2
    c->x[1]=0x12345678;step(c,&m,0x53083c20);assert(c->x[0]==0x56); // UBFX W0,W1,#8,#8
    c->x[0]=0xffffffff;c->x[1]=0xab;step(c,&m,0x33181c20);assert(c->x[0]==0xffffabff); // BFI W0,W1,#8,#8
    c->x[1]=0x80;step(c,&m,0x93401c20);assert(c->x[0]==0xffffffffffffff80ULL); // SXTB X0,W1
    c->x[1]=0x11223344;step(c,&m,0x5ac00820);assert(c->x[0]==0x44332211); // REV W0,W1
    c->x[1]=1;step(c,&m,0xdac01020);assert(c->x[0]==63); // CLZ X0,X1
    c->x[1]=1;c->x[2]=2;c->nzcv=2;step(c,&m,0x9a020020);assert(c->x[0]==4); // ADC X0,X1,X2
    c->x[1]=1;c->x[2]=0x200;step(c,&m,0x93c22020|(8u<<10));assert(c->x[0]==0x0100000000000002ULL); // EXTR X0,X1,X2,#8
    step(c,&m,0xd2800560);assert(c->x[0]==43);
    assert(gm_protect(&m,base,GM_PAGE_SIZE,3)==GM_OK);c->pc=base;
    assert(gc_run(c,&m,1,done)==GC_MEMORY && c->memory_result==GM_PROTECTION);
    assert(gm_map(&m,base,GM_PAGE_SIZE,7,7,true,true)==GM_OK);
    instruction(&m,0xd503201f);c->pc=base;
    assert(gc_run(c,&m,1,done)==GC_BUDGET);c->pc=base;c->thread.jit_write_protected=false;
    assert(gc_run(c,&m,1,done)==GC_MEMORY && c->memory_result==GM_PROTECTION);
    c->thread.jit_write_protected=true;
    instruction(&m,0xffffffff);c->pc=base;retired=c->retired;
    assert(gc_run(c,&m,1,done)==GC_UNSUPPORTED && c->pc==base && c->retired==retired && c->fault_instruction==0xffffffff);
    c->pc=base+1;assert(gc_run(c,&m,1,done)==GC_MEMORY && m.fault_address==base+1);
    gm_destroy(&m);free(c);
    assert(guest_cpu_probe(stdout,10000));
    puts("PASS: arithmetic boundaries, SP/ZR, memory faults, code invalidation, native/C differential CPU execution");
}
