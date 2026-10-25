#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Private owning-app/provider messages. Fixed-size network-order encoding; no
// keys or game bytes. Addresses/challenges must never be logged or persisted.
#define TKAC_SIZE 112
#define TKAC_MAX_ARENA_BYTES (2048ull * 1024u * 1024u)
#define TKAC_MAX_TIMEOUT_SECONDS 1850
typedef struct {
    uint32_t pid, uid;
    uint64_t address, size, challenge_address, deadline_ms;
    uint64_t second_address, second_size; // Optional second region, same transaction.
    uint8_t challenge[32], identifier[16];
} TKACRequest;
typedef enum { TKAC_PREPARED = 1, TKAC_REJECTED = 2,
               TKAC_FAILED_DETACHED = 3, TKAC_UNCERTAIN = 4, TKAC_PENDING = 5 } TKACOutcome;
typedef enum { TKAC_SUBMIT = 3, TKAC_POLL = 4 } TKACCommand;
bool tkac_encode(const TKACRequest *request, uint8_t *out, size_t size);
bool tkac_decode(const uint8_t *bytes, size_t size, TKACRequest *request);
bool tkac_reply(const uint8_t *request, size_t size, TKACOutcome outcome,
                uint8_t *out, size_t capacity);
bool tkac_match(const uint8_t *request, size_t request_size,
                const uint8_t *reply, size_t reply_size, TKACOutcome *outcome);
bool tkac_command(const uint8_t *request,size_t size,TKACCommand command,uint8_t *out,size_t capacity);
bool tkac_normalize(const uint8_t *message,size_t size,TKACCommand *command,uint8_t *request,size_t capacity);
