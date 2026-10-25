#include "Control/ArenaControl.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
int main(void) {
    TKACRequest request={.pid=1234,.uid=501,.address=0x200000,.size=16384,
        .challenge_address=0x100000,.deadline_ms=123456};
    for(unsigned i=0;i<32;i++)request.challenge[i]=(uint8_t)(i+1);
    memset(request.identifier,0xa5,16);
    uint8_t wire[TKAC_SIZE],reply[TKAC_SIZE]; TKACRequest decoded={0};
    assert(tkac_encode(&request,wire,sizeof wire));
    // Independent literal header/endianness fixture, not just a round trip.
    const uint8_t expected[]={84,75,65,82,2,1,0,0,0,0,4,210,0,0,1,245,
        0,0,0,0,0,32,0,0,0,0,0,0,0,0,64,0,0,0,0,0,0,16,0,0,
        0,0,0,0,0,1,226,64};
    assert(!memcmp(wire,expected,sizeof expected));
    assert(tkac_decode(wire,sizeof wire,&decoded) && decoded.size==16384 && decoded.pid==1234);
    for(size_t size=0;size<TKAC_SIZE;size++)assert(!tkac_decode(wire,size,&decoded));
    for(int value=TKAC_PREPARED;value<=TKAC_PENDING;value++) {
        TKACOutcome outcome=0;
        assert(tkac_reply(wire,sizeof wire,(TKACOutcome)value,reply,sizeof reply));
        assert(tkac_match(wire,sizeof wire,reply,sizeof reply,&outcome) && outcome==(TKACOutcome)value);
        for(size_t i=0;i<TKAC_SIZE;i++) {
            if(i==6)continue; // Other valid outcomes are meaningful distinct replies.
            reply[i]^=1; assert(!tkac_match(wire,sizeof wire,reply,sizeof reply,&outcome));reply[i]^=1;
        }
    }
    for(int kind=TKAC_SUBMIT;kind<=TKAC_POLL;kind++) {
        uint8_t command[TKAC_SIZE],normalized[TKAC_SIZE];TKACCommand decodedCommand=0;
        assert(tkac_command(wire,sizeof wire,(TKACCommand)kind,command,sizeof command));
        assert(command[5]==kind && !tkac_decode(command,sizeof command,&decoded));
        assert(tkac_normalize(command,sizeof command,&decodedCommand,normalized,sizeof normalized));
        assert(decodedCommand==(TKACCommand)kind && !memcmp(wire,normalized,sizeof wire));
        command[7]=1;assert(!tkac_normalize(command,sizeof command,&decodedCommand,normalized,sizeof normalized));
    }
    request.second_address=0x300000; request.second_size=16384;
    assert(tkac_encode(&request,wire,sizeof wire));
    assert(tkac_decode(wire,sizeof wire,&decoded) && decoded.second_address==0x300000 && decoded.second_size==16384);
    assert(tkac_reply(wire,sizeof wire,TKAC_PREPARED,reply,sizeof reply));
    TKACOutcome outcome=0;
    for(size_t i=96;i<TKAC_SIZE;i++) {
        reply[i]^=1; assert(!tkac_match(wire,sizeof wire,reply,sizeof reply,&outcome)); reply[i]^=1;
    }
    request.second_address=request.address;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.second_address=request.challenge_address;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.second_address=UINT64_MAX-16383;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.second_address=0x300000;request.second_size=TKAC_MAX_ARENA_BYTES;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.second_size=0;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.second_address=0;
    request.challenge_address=request.address;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.challenge_address=UINT64_MAX;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.challenge_address=0x100000;request.address=UINT64_MAX;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.address=0x200000;request.size=UINT64_C(2048)*1024*1024; // Exactly the ceiling is accepted both ways.
    assert(tkac_encode(&request,wire,sizeof wire));
    assert(tkac_decode(wire,sizeof wire,&decoded) && decoded.size==UINT64_C(2048)*1024*1024);
    wire[30]=0x40; // The extension's decoder refuses 1 GiB + 16 KiB on the wire.
    assert(!tkac_decode(wire,sizeof wire,&decoded));
    request.size=UINT64_C(2048)*1024*1024+16384;
    assert(!tkac_encode(&request,wire,sizeof wire));
    request.size=16384;memset(request.challenge,0,32);
    assert(!tkac_encode(&request,wire,sizeof wire));
    puts("PASS: bounded arena IPC literal layout, every-byte reply binding, truncation, overflow and overlap");
}
