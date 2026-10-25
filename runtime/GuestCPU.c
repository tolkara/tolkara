#include "GuestCPU.h"
#include <string.h>

enum { INVALID, NOP, WIDE, ADD_IMM, ADD_REG, LOGIC, MADD, BRANCH, BRANCH_REG,
       COND, CBZ, ADDRESS, LOAD, STORE, LOGIC_IMM, TBZ, SELECT,
       ADD_EXT, CCMP, SHIFT_REG, BITFIELD, EXTRACT, ONE_SOURCE, CARRY };
static uint64_t sign_extend(uint64_t x, unsigned bits) {
    uint64_t sign=UINT64_C(1)<<(bits-1); return (x^sign)-sign;
}
static uint64_t mask(unsigned width) { return width==64 ? UINT64_MAX : UINT32_MAX; }
static uint64_t reg(const GCRegisters *c,unsigned r,bool sp) { return r<31 ? c->x[r] : sp ? c->sp : 0; }
static void put(GCRegisters *c,unsigned r,uint64_t value,unsigned width,bool sp) {
    value &= mask(width);
    if (r<31) c->x[r]=value; else if (sp) c->sp=value;
}
static uint64_t shifted(uint64_t value,unsigned type,unsigned amount,unsigned width) {
    value &= mask(width);
    if (!amount) return value;
    if (type==0) return (value<<amount)&mask(width);
    if (type==1) return value>>amount;
    if (type==2) return (value>>amount) | ((value>>(width-1)) ? (mask(width)<<(width-amount))&mask(width) : 0);
    return ((value>>amount)|(value<<(width-amount)))&mask(width);
}
static bool condition(uint8_t flags,unsigned cond) {
    bool n=flags&8,z=flags&4,c=flags&2,v=flags&1,result;
    switch (cond>>1) {
        case 0:result=z;break; case 1:result=c;break; case 2:result=n;break;
        case 3:result=v;break; case 4:result=c&&!z;break; case 5:result=n==v;break;
        case 6:result=!z&&(n==v);break; default:return true;
    }
    return (cond&1) ? !result : result;
}
static uint64_t arithmetic(GCRegisters *c,uint64_t a,uint64_t b,bool sub,bool flags,unsigned width) {
    uint64_t m=mask(width),sign=UINT64_C(1)<<(width-1); a&=m;b&=m;
    uint64_t result=(sub?a-b:a+b)&m;
    if (flags) {
        bool carry=sub?a>=b:result<a;
        bool overflow=((sub?(a^b):~(a^b))&(a^result)&sign)!=0;
        c->nzcv=(result&sign?8:0)|(result==0?4:0)|(carry?2:0)|(overflow?1:0);
    }
    return result;
}
static bool logical_immediate(uint32_t i, unsigned width, uint64_t *value) {
    unsigned n=(i>>22)&1, immr=(i>>16)&63, imms=(i>>10)&63;
    unsigned encoded=(n<<6)|((~imms)&63), length=0;
    for(unsigned bit=1;bit<=6;bit++) if(encoded&(1u<<bit)) length=bit;
    if(!length || (width==32 && n)) return false;
    unsigned bits=1u<<length, s=imms&(bits-1), r=immr&(bits-1);
    if(bits>width || s==bits-1) return false;
    uint64_t element=(UINT64_C(1)<<(s+1))-1;
    if(r) element=(element>>r)|(element<<(bits-r));
    if(bits<64) element&=(UINT64_C(1)<<bits)-1;
    *value=0;
    for(unsigned at=0;at<width;at+=bits) *value|=element<<at;
    return true;
}
static GCDecoded decode(uint64_t pc,uint32_t i) {
    GCDecoded d={.pc=pc,.instruction=i,.rd=i&31,.rn=(i>>5)&31,.rm=(i>>16)&31,
        .ra=(i>>10)&31,.width=(i>>31)?64:32,.valid=true};
    if (i==0xd503201f) d.op=NOP;
    else if ((i&0x1f800000)==0x12800000) {
        d.flags=(i>>29)&3; d.amount=((i>>21)&3)*16;
        if (d.flags!=1 && d.amount<d.width) { d.op=WIDE; d.immediate=(uint64_t)((i>>5)&65535)<<d.amount; }
    } else if ((i&0x1f800000)==0x11000000) {
        d.op=ADD_IMM;d.flags=(i>>29)&3;d.immediate=((i>>10)&4095)<<(((i>>22)&1)*12);
    } else if ((i&0x1f200000)==0x0b000000) {
        d.shift=(i>>22)&3;d.amount=(i>>10)&63;d.flags=(i>>29)&3;
        if (d.shift!=3 && d.amount<d.width) d.op=ADD_REG;
    } else if ((i&0x1f000000)==0x0a000000) {
        d.shift=(i>>22)&3;d.amount=(i>>10)&63;d.flags=((i>>29)&3)|(((i>>21)&1)<<2);
        if (d.amount<d.width) d.op=LOGIC;
    } else if ((i&0x1f800000)==0x12000000) {
        d.flags=(i>>29)&3;
        if(logical_immediate(i,d.width,&d.immediate)) d.op=LOGIC_IMM;
    } else if ((i&0x3fe00800)==0x1a800000) {
        d.op=SELECT;d.shift=(i>>12)&15;d.flags=(((i>>30)&1)<<1)|((i>>10)&1);
    } else if ((i&0x7fe00000)==0x1b000000) { d.op=MADD;d.flags=(i>>15)&1; }
    // Forms a translator's atomic loops use between an exclusive load and store
    else if ((i&0x1fe00000)==0x0b200000 && ((i>>10)&7)<=4) {
        d.op=ADD_EXT;d.flags=(i>>29)&3;d.shift=(i>>13)&7;d.amount=(i>>10)&7;
    } else if ((i&0x3fe00410)==0x3a400000) {
        d.op=CCMP;d.flags=((i>>30)&1)|(((i>>11)&1)<<1);d.shift=(i>>12)&15;d.immediate=i&15;
    } else if ((i&0x7fe0f000)==0x1ac02000) { d.op=SHIFT_REG;d.shift=(i>>10)&3; }
    else if ((i&0x1f800000)==0x13000000 && ((i>>29)&3)!=3 && ((i>>22)&1)==(i>>31)) {
        d.op=BITFIELD;d.flags=(i>>29)&3;d.shift=(i>>16)&63;d.amount=(i>>10)&63;
        if(d.width==32 && (d.shift>31 || d.amount>31)) d.op=INVALID;
    } else if ((i&0x7fa00000)==0x13800000 && ((i>>22)&1)==(i>>31)) {
        d.op=EXTRACT;d.amount=(i>>10)&63;if(d.width==32 && d.amount>31) d.op=INVALID;
    } else if ((i&0x7fff0000)==0x5ac00000 && ((i>>10)&63)<=4) { d.op=ONE_SOURCE;d.shift=(i>>10)&63; }
    else if ((i&0x1fe0fc00)==0x1a000000) { d.op=CARRY;d.flags=(i>>29)&3; }
    else if ((i&0x7c000000)==0x14000000) {
        d.op=BRANCH; d.flags=i>>31; d.immediate=pc+sign_extend(i&0x3ffffff,26)*4;
    } else if ((i&0xfffffc1f)==0xd61f0000 || (i&0xfffffc1f)==0xd63f0000 || (i&0xfffffc1f)==0xd65f0000) {
        d.op=BRANCH_REG; d.flags=(i&0xfffffc1f)==0xd63f0000;
    } else if ((i&0xff000010)==0x54000000) {
        d.op=COND;d.flags=i&15;d.immediate=pc+sign_extend((i>>5)&0x7ffff,19)*4;
    } else if ((i&0x7e000000)==0x34000000) {
        d.op=CBZ;d.flags=(i>>24)&1;d.immediate=pc+sign_extend((i>>5)&0x7ffff,19)*4;
    } else if ((i&0x7e000000)==0x36000000) {
        d.op=TBZ;d.flags=(i>>24)&1;d.amount=((i>>31)<<5)|((i>>19)&31);
        d.immediate=pc+sign_extend((i>>5)&0x3fff,14)*4;
    } else if ((i&0x1f000000)==0x10000000) {
        d.op=ADDRESS; d.width=64;
        uint64_t offset=sign_extend(((uint64_t)(i>>5)&0x7ffff)*4+((i>>29)&3),21);
        d.immediate=(i>>31)?(pc&~UINT64_C(4095))+offset*4096:pc+offset;
    } else if ((i&0x3b000000)==0x39000000 && !(i&(1u<<26))) {
        unsigned opc=(i>>22)&3;
        if (opc<=1) { d.op=opc?LOAD:STORE;d.amount=1u<<(i>>30);d.width=d.amount==8?64:32;
            d.immediate=(uint64_t)((i>>10)&4095)*d.amount; }
    }
    return d;
}
static bool register_decoded(GCRegisters *c,const GCDecoded *d) {
    uint64_t next=c->pc+4,a,b,value=0;bool write=false,sp=false;
    switch(d->op) {
        case NOP:break;
        case WIDE:
            value=d->flags==0?~d->immediate:d->flags==2?d->immediate:
                (reg(c,d->rd,false)&~(UINT64_C(65535)<<d->amount))|d->immediate;
            write=true;break;
        case ADD_IMM:case ADD_REG:
            a=reg(c,d->rn,d->op==ADD_IMM);
            b=d->op==ADD_IMM?d->immediate:shifted(reg(c,d->rm,false),d->shift,d->amount,d->width);
            value=arithmetic(c,a,b,d->flags&2,d->flags&1,d->width);
            write=true;sp=d->op==ADD_IMM && !(d->flags&1);break;
        case LOGIC:case LOGIC_IMM:
            a=reg(c,d->rn,false);
            b=d->op==LOGIC_IMM?d->immediate:shifted(reg(c,d->rm,false),d->shift,d->amount,d->width);
            if(d->op==LOGIC && (d->flags&4)) b=~b;
            value=(d->flags&3)==1?a|b:(d->flags&3)==2?a^b:a&b;
            value&=mask(d->width);
            if((d->flags&3)==3) c->nzcv=(value>>(d->width-1)?8:0)|(value==0?4:0);
            write=true;sp=d->op==LOGIC_IMM && (d->flags&3)!=3;break;
        case SELECT:
            b=reg(c,d->rm,false);
            value=condition(c->nzcv,d->shift)?reg(c,d->rn,false):
                  d->flags==0?b:d->flags==1?b+1:d->flags==2?~b:0-b;
            write=true;break;
        case MADD:
            value=reg(c,d->rn,false)*reg(c,d->rm,false);
            value=d->flags?reg(c,d->ra,false)-value:reg(c,d->ra,false)+value;write=true;break;
        case BRANCH:next=d->immediate;if(d->flags)c->x[30]=c->pc+4;break;
        case BRANCH_REG:next=reg(c,d->rn,false);if(d->flags)c->x[30]=c->pc+4;break;
        case COND:if(condition(c->nzcv,d->flags))next=d->immediate;break;
        case CBZ:if(((reg(c,d->rd,false)&mask(d->width))!=0)==(d->flags!=0))next=d->immediate;break;
        case TBZ:if(((reg(c,d->rd,false)>>d->amount)&1)==d->flags)next=d->immediate;break;
        case ADDRESS:value=d->immediate;write=true;break;
        case ADD_EXT: {
            uint64_t m=reg(c,d->rm,false);
            switch(d->shift) {
                case 0:m&=0xff;break; case 1:m&=0xffff;break; case 2:m&=0xffffffff;break;
                case 4:m=sign_extend(m&0xff,8);break; case 5:m=sign_extend(m&0xffff,16);break;
                case 6:m=sign_extend(m&0xffffffff,32);break; default:break;
            }
            value=arithmetic(c,reg(c,d->rn,true),(m<<d->amount)&mask(d->width),d->flags&2,d->flags&1,d->width);
            write=true;sp=!(d->flags&1);break;
        }
        case CCMP:
            if(condition(c->nzcv,d->shift))
                arithmetic(c,reg(c,d->rn,false),(d->flags&2)?d->rm:reg(c,d->rm,false),d->flags&1,true,d->width);
            else c->nzcv=(uint8_t)d->immediate;
            break;
        case SHIFT_REG:
            value=shifted(reg(c,d->rn,false),d->shift,(unsigned)(reg(c,d->rm,false)%d->width),d->width);
            write=true;break;
        case BITFIELD: {
            unsigned immr=d->shift,imms=d->amount,len,pos;uint64_t source=reg(c,d->rn,false)&mask(d->width),field;
            if(imms>=immr) { len=imms-immr+1;pos=0;field=source>>immr; }
            else { len=imms+1;pos=d->width-immr;field=source; }
            uint64_t bits=len>=64?UINT64_MAX:(UINT64_C(1)<<len)-1;
            field&=bits;
            if(d->flags==0 && (field>>(len-1))&1) field|=~bits;
            uint64_t placed=(field<<pos)&mask(d->width);
            value=d->flags==1?(reg(c,d->rd,false)&~((bits<<pos)&mask(d->width)))|placed:placed;
            write=true;break;
        }
        case EXTRACT: {
            uint64_t n=reg(c,d->rn,false)&mask(d->width),m=reg(c,d->rm,false)&mask(d->width);
            value=d->amount?((m>>d->amount)|(n<<(d->width-d->amount))):m;
            write=true;break;
        }
        case ONE_SOURCE: {
            uint64_t x=reg(c,d->rn,false)&mask(d->width),r=0;unsigned bytes=d->width/8;
            if(d->shift==0) { for(unsigned b=0;b<d->width;b++) if((x>>b)&1) r|=UINT64_C(1)<<(d->width-1-b); }
            else if(d->shift==4) { r=d->width; for(unsigned b=d->width;b-->0;) if((x>>b)&1) { r=d->width-1-b;break; } }
            else {
                unsigned group=d->shift==1?2:d->shift==2&&d->width==64?4:bytes;
                for(unsigned at=0;at<bytes;at+=group)
                    for(unsigned b=0;b<group;b++) r|=((x>>((at+b)*8))&0xff)<<((at+group-1-b)*8);
            }
            value=r;write=true;break;
        }
        case CARRY: {
            uint64_t m=mask(d->width),sign=UINT64_C(1)<<(d->width-1),x=reg(c,d->rn,false)&m;
            uint64_t y=reg(c,d->rm,false)&m;if(d->flags&2) y=~y&m;
            uint64_t carry=(c->nzcv>>1)&1,result=(x+y+carry)&m;
            if(d->flags&1) {
                bool out=d->width==64?(result<x || (carry && result==x)):((x+y+carry)>>32)!=0;
                bool overflow=(~(x^y)&(x^result)&sign)!=0;
                c->nzcv=(result&sign?8:0)|(result==0?4:0)|(out?2:0)|(overflow?1:0);
            }
            value=result;write=true;break;
        }
        default:return false;
    }
    if(write)put(c,d->rd,value,d->width,sp);
    c->pc=next;
    return true;
}
bool gc_register_step(GCRegisters *r,uint32_t instruction) {
    if(!r || (r->pc&3) || r->pc>UINT64_MAX-4) return false;
    GCDecoded d=decode(r->pc,instruction);
    return register_decoded(r,&d);
}
void gc_reset(GuestCPU *c,uint64_t entry,uint64_t stack) {
    memset(c,0,sizeof *c);c->pc=entry;c->sp=stack;c->thread.jit_write_protected=true;
}
GCResult gc_run(GuestCPU *c,GuestMemory *m,uint64_t budget,uint64_t return_pc) {
    for (uint64_t step=0;step<budget;step++) {
        if (c->pc==return_pc) return GC_RETURNED;
        if (c->cache_generation!=m->code_generation || c->cache_write_protected!=c->thread.jit_write_protected) {
            memset(c->cache,0,sizeof c->cache);
            c->cache_generation=m->code_generation;c->cache_write_protected=c->thread.jit_write_protected;
        }
        GCDecoded *d=&c->cache[(c->pc>>2)&(GC_CACHE_SIZE-1)];
        if (!d->valid || d->pc!=c->pc) {
            uint32_t i; c->memory_result=gm_fetch(m,&c->thread,c->pc,&i);
            if (c->memory_result!=GM_OK) return GC_MEMORY;
            *d=decode(c->pc,i);
        }
        if(d->op==LOAD || d->op==STORE) {
                unsigned char bytes[8]={0};uint64_t a=reg(&c->registers,d->rn,true)+d->immediate,value=0;
                if(d->op==STORE) {
                    uint64_t b=reg(&c->registers,d->rd,false);
                    for(unsigned j=0;j<d->amount;j++)bytes[j]=(unsigned char)(b>>(j*8));
                    c->memory_result=gm_write(m,&c->thread,a,bytes,d->amount);
                } else {
                    c->memory_result=gm_read(m,a,bytes,d->amount);
                    for(unsigned j=0;j<d->amount;j++)value|=(uint64_t)bytes[j]<<(j*8);
                }
                if(c->memory_result!=GM_OK)return GC_MEMORY;
                if(d->op==LOAD)put(&c->registers,d->rd,value,d->width,false);
                c->pc+=4;
        } else if(!register_decoded(&c->registers,d)) { c->fault_instruction=d->instruction;return GC_UNSUPPORTED; }
        c->retired++;
    }
    return c->pc==return_pc?GC_RETURNED:GC_BUDGET;
}
const char *gc_result_string(GCResult r) {
    switch(r) {
        case GC_BUDGET:return "instruction budget reached";
        case GC_RETURNED:return "returned";
        case GC_UNSUPPORTED:return "unsupported instruction";
        case GC_MEMORY:return "guest memory fault";
    }
    return "unknown CPU result";
}
