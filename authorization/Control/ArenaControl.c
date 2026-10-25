#include "ArenaControl.h"
#include <limits.h>
#include <string.h>
static uint64_t read_number(const uint8_t *p, unsigned n) {
    uint64_t value=0; for(unsigned i=0;i<n;i++) value=(value<<8)|p[i]; return value;
}
static void write_number(uint8_t *p, unsigned n, uint64_t value) {
    for(unsigned i=0;i<n;i++) { p[n-i-1]=(uint8_t)value; value>>=8; }
}
static bool nonzero(const uint8_t *bytes,size_t count) {
    uint8_t any=0; for(size_t i=0;i<count;i++)any|=bytes[i]; return any!=0;
}
// Match the runtime's 2 GiB cap and DebugArenaRequest. Full zero preflight
// remains mandatory; the helper allows 1800 s for this bounded transaction.
static bool valid(const TKACRequest *r) {
    const uint64_t maximum=UINT64_C(0x0000ffffffffffff);
    if (!r) return false;
    if (r->second_size || r->second_address) {
        if (!r->second_size || r->second_size>TKAC_MAX_ARENA_BYTES ||
            r->size>TKAC_MAX_ARENA_BYTES-r->second_size || r->second_size%16384 ||
            r->second_address<16384 || r->second_address%16384 ||
            r->second_address>maximum-r->second_size ||
            !(r->address<r->second_address ? r->size<=r->second_address-r->address :
              r->second_size<=r->address-r->second_address) ||
            !(r->challenge_address<r->second_address ? 32<=r->second_address-r->challenge_address :
              r->second_size<=r->challenge_address-r->second_address)) return false;
    }
    return r->pid>1 && r->pid<=INT_MAX && r->size &&
        r->size<=TKAC_MAX_ARENA_BYTES && r->size%16384==0 && r->address>=16384 &&
        r->address%16384==0 && r->address<=maximum-r->size &&
        r->challenge_address>=4096 && r->challenge_address<=maximum-32 &&
        (r->challenge_address+32<=r->address || r->address+r->size<=r->challenge_address) &&
        r->deadline_ms && nonzero(r->challenge,32) && nonzero(r->identifier,16);
}
bool tkac_encode(const TKACRequest *r,uint8_t *out,size_t size) {
    if(!out || size!=TKAC_SIZE || !valid(r))return false;
    memcpy(out,"TKAR\2\1\0\0",8);
    write_number(out+8,4,r->pid); write_number(out+12,4,r->uid);
    write_number(out+16,8,r->address); write_number(out+24,8,r->size);
    write_number(out+32,8,r->challenge_address); write_number(out+40,8,r->deadline_ms);
    memcpy(out+48,r->challenge,32); memcpy(out+80,r->identifier,16);
    write_number(out+96,8,r->second_address); write_number(out+104,8,r->second_size); return true;
}
bool tkac_decode(const uint8_t *bytes,size_t size,TKACRequest *r) {
    if(!bytes || !r || size!=TKAC_SIZE || memcmp(bytes,"TKAR\2\1\0\0",8))return false;
    TKACRequest staged={0};
    staged.pid=(uint32_t)read_number(bytes+8,4); staged.uid=(uint32_t)read_number(bytes+12,4);
    staged.address=read_number(bytes+16,8); staged.size=read_number(bytes+24,8);
    staged.challenge_address=read_number(bytes+32,8); staged.deadline_ms=read_number(bytes+40,8);
    memcpy(staged.challenge,bytes+48,32); memcpy(staged.identifier,bytes+80,16);
    staged.second_address=read_number(bytes+96,8); staged.second_size=read_number(bytes+104,8);
    if(!valid(&staged))return false;
    *r=staged; return true;
}
bool tkac_reply(const uint8_t *request,size_t size,TKACOutcome outcome,uint8_t *out,size_t capacity) {
    TKACRequest decoded;
    if(!out || capacity!=TKAC_SIZE || outcome<TKAC_PREPARED || outcome>TKAC_PENDING ||
       !tkac_decode(request,size,&decoded))return false;
    memmove(out,request,TKAC_SIZE); out[5]=2; out[6]=(uint8_t)outcome; return true;
}
bool tkac_match(const uint8_t *request,size_t request_size,const uint8_t *reply,size_t reply_size,TKACOutcome *outcome) {
    TKACRequest decoded;
    if(!reply || !outcome || reply_size!=TKAC_SIZE || !tkac_decode(request,request_size,&decoded) ||
       memcmp(reply,"TKAR\2\2",6) || reply[7] || reply[6]<TKAC_PREPARED || reply[6]>TKAC_PENDING ||
       memcmp(request+8,reply+8,TKAC_SIZE-8))return false;
    *outcome=(TKACOutcome)reply[6]; return true;
}
bool tkac_command(const uint8_t *request,size_t size,TKACCommand command,uint8_t *out,size_t capacity) {
    TKACRequest decoded;
    if(!out || capacity!=TKAC_SIZE || (command!=TKAC_SUBMIT && command!=TKAC_POLL) || !tkac_decode(request,size,&decoded))return false;
    memmove(out,request,TKAC_SIZE);out[5]=(uint8_t)command;return true;
}
bool tkac_normalize(const uint8_t *message,size_t size,TKACCommand *command,uint8_t *request,size_t capacity) {
    if(!message || !command || !request || size!=TKAC_SIZE || capacity!=TKAC_SIZE ||
       (message[5]!=TKAC_SUBMIT && message[5]!=TKAC_POLL))return false;
    uint8_t normalized[TKAC_SIZE];TKACRequest decoded;
    memcpy(normalized,message,TKAC_SIZE);normalized[5]=1;
    if(!tkac_decode(normalized,sizeof normalized,&decoded))return false;
    *command=(TKACCommand)message[5];memmove(request,normalized,TKAC_SIZE);return true;
}
