#import "SteamCloudWire.h"
#include <zlib.h>

static const NSUInteger TKCloudLimit = 16 * 1024 * 1024;
static NSError *TKCloudError(NSInteger code) {
    return [NSError errorWithDomain:@"TolkaraSteamCloud" code:code userInfo:nil];
}
static void varint(NSMutableData *data, uint64_t value) {
    do { uint8_t byte = (value & 127) | (value > 127 ? 128 : 0);
        [data appendBytes:&byte length:1]; value >>= 7; } while (value);
}
NSData *TKCloudProto(NSDictionary<NSNumber *, id> *fields) {
    NSMutableData *data = [NSMutableData new];
    for (NSNumber *field in [[fields allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id value = fields[field];
        NSArray *values = [value isKindOfClass:NSArray.class] ? value : @[value];
        for (id item in values) {
            if ([item isKindOfClass:NSNumber.class]) {
                varint(data, field.unsignedLongLongValue << 3);
                varint(data, [item unsignedLongLongValue]);
            } else {
                NSData *bytes = [item isKindOfClass:NSString.class] ? [item dataUsingEncoding:NSUTF8StringEncoding] : item;
                NSCAssert([bytes isKindOfClass:NSData.class], @"protobuf values must be numbers, strings or data");
                varint(data, (field.unsignedLongLongValue << 3) | 2);
                varint(data, bytes.length); [data appendData:bytes];
            }
        }
    }
    return data;
}
static BOOL readVarint(const uint8_t *bytes, NSUInteger size, NSUInteger *offset, uint64_t *value) {
    *value = 0;
    for (unsigned shift = 0; shift < 70; shift += 7) {
        if (*offset >= size) return NO;
        uint8_t byte = bytes[(*offset)++];
        if (shift == 63 && (byte & 254)) return NO;
        *value |= (uint64_t)(byte & 127) << shift;
        if (!(byte & 128)) return YES;
    }
    return NO;
}
NSDictionary *TKCloudParse(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length > TKCloudLimit) return nil;
    const uint8_t *bytes = data.bytes; NSUInteger offset = 0;
    NSMutableDictionary *fields = [NSMutableDictionary new];
    while (offset < data.length) {
        uint64_t tag = 0, number = 0;
        if (!readVarint(bytes, data.length, &offset, &tag) || !(tag >> 3) || (tag >> 3) > 0x1fffffff) return nil;
        id value;
        switch (tag & 7) {
        case 0:
            if (!readVarint(bytes, data.length, &offset, &number)) return nil;
            value = @(number); break;
        case 1:
            if (data.length - offset < 8) return nil;
            memcpy(&number, bytes + offset, 8); offset += 8;
            value = @(CFSwapInt64LittleToHost(number)); break;
        case 2:
            if (!readVarint(bytes, data.length, &offset, &number) || number > data.length - offset) return nil;
            value = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)number)]; offset += (NSUInteger)number; break;
        case 5: {
            if (data.length - offset < 4) return nil;
            uint32_t small; memcpy(&small, bytes + offset, 4); offset += 4;
            value = @(CFSwapInt32LittleToHost(small)); break;
        }
        default: return nil;
        }
        NSNumber *key = @(tag >> 3);
        if (!fields[key]) fields[key] = [NSMutableArray new];
        [fields[key] addObject:value];
    }
    return fields;
}
uint64_t TKCloudNumber(NSDictionary *fields, unsigned field) {
    id value = [fields[@(field)] firstObject];
    return [value isKindOfClass:NSNumber.class] ? [value unsignedLongLongValue] : 0;
}
NSData *TKCloudBytes(NSDictionary *fields, unsigned field) {
    id value = [fields[@(field)] firstObject];
    return [value isKindOfClass:NSData.class] ? value : nil;
}

@interface TKSteamCloudConnection () {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_socket;
    NSCondition *_condition;
    NSMutableArray<NSDictionary *> *_packets;
    NSError *_receiveError;
    dispatch_source_t _heartbeat;
    uint64_t _steamID, _clientID, _job;
    uint32_t _sessionID;
}
@end
@implementation TKSteamCloudConnection
- (instancetype)init {
    if ((self = [super init])) { _condition = [NSCondition new]; _packets = [NSMutableArray new];
        arc4random_buf(&_job,sizeof _job);_job &= UINT64_C(0x3fffffffffffffff);if(!_job)_job=1; }
    return self;
}
- (uint64_t)steamID { return _steamID; }
- (uint64_t)clientID { return _clientID; }
- (void)receivePacket:(NSData *)data depth:(unsigned)depth {
    if (depth > 8 || data.length < 4 || data.length > TKCloudLimit) { _receiveError = TKCloudError(100); return; }
    uint32_t rawMessage; memcpy(&rawMessage, data.bytes, 4);
    // Steam also sends legacy notifications unrelated to this Cloud client.
    if (!(CFSwapInt32LittleToHost(rawMessage) & 0x80000000)) return;
    if (data.length < 8) { _receiveError = TKCloudError(100); return; }
    uint32_t words[2]; memcpy(words, data.bytes, 8);
    uint32_t message = CFSwapInt32LittleToHost(words[0]), headerSize = CFSwapInt32LittleToHost(words[1]);
    if (headerSize > data.length - 8) { _receiveError = TKCloudError(101); return; }
    NSDictionary *header = TKCloudParse([data subdataWithRange:NSMakeRange(8, headerSize)]);
    NSDictionary *body = TKCloudParse([data subdataWithRange:NSMakeRange(8 + headerSize, data.length - 8 - headerSize)]);
    if (!header || !body) { _receiveError = TKCloudError(102); return; }
    message &= 0x7fffffff;
    if (message == 1) {
        NSData *payload = TKCloudBytes(body, 2); uint64_t inflatedSize = TKCloudNumber(body, 1);
        if (!payload || inflatedSize > TKCloudLimit) { _receiveError = TKCloudError(103); return; }
        if (inflatedSize) {
            NSMutableData *inflated = [NSMutableData dataWithLength:(NSUInteger)inflatedSize];
            z_stream stream = {0}; stream.next_in = (Bytef *)payload.bytes; stream.avail_in = (uInt)payload.length;
            stream.next_out = inflated.mutableBytes; stream.avail_out = (uInt)inflated.length;
            int status = inflateInit2(&stream, 15 + 16);
            if (status == Z_OK) { status = inflate(&stream, Z_FINISH); inflateEnd(&stream); }
            if (status != Z_STREAM_END || stream.total_out != inflatedSize) { _receiveError = TKCloudError(104); return; }
            payload = inflated;
        }
        NSUInteger offset = 0;
        while (offset < payload.length && !_receiveError) {
            uint32_t length;
            if (payload.length - offset < 4) { _receiveError = TKCloudError(105); return; }
            memcpy(&length, (const uint8_t *)payload.bytes + offset, 4); length = CFSwapInt32LittleToHost(length); offset += 4;
            if (length > payload.length - offset) { _receiveError = TKCloudError(106); return; }
            [self receivePacket:[payload subdataWithRange:NSMakeRange(offset, length)] depth:depth + 1]; offset += length;
        }
    } else if (message == 751 || message == 147) {
        [_packets addObject:@{@"message":@(message), @"header":header, @"body":body}];
    } else if (message == 757) {
        _receiveError = TKCloudError(200 + (NSInteger)TKCloudNumber(body, 1));
    }
}
- (void)readNext {
    __weak TKSteamCloudConnection *weakSelf = self;
    NSURLSessionWebSocketTask *socket = _socket;
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        TKSteamCloudConnection *self = weakSelf; if (!self) return;
        [self->_condition lock];
        if (self->_socket != socket) { [self->_condition unlock]; return; }
        if (error) self->_receiveError = TKCloudError(107);
        else if (message.type == NSURLSessionWebSocketMessageTypeData) [self receivePacket:message.data depth:0];
        else self->_receiveError = TKCloudError(108);
        [self->_condition broadcast]; BOOL again = self->_socket && !self->_receiveError; [self->_condition unlock];
        if (again) [self readNext];
    }];
}
- (NSData *)frame:(uint32_t)message body:(NSData *)body job:(uint64_t)job method:(NSString *)method {
    NSMutableDictionary *fields = [@{@1:@(_steamID), @2:@(_sessionID)} mutableCopy];
    // SteamIDs and job IDs use protobuf fixed64, unlike most numeric fields.
    NSMutableData *header = [NSMutableData new];
    uint8_t tag = 9; uint64_t sid = CFSwapInt64HostToLittle(_steamID);
    [header appendBytes:&tag length:1]; [header appendBytes:&sid length:8]; [fields removeObjectForKey:@1];
    if (job) { tag = 81; uint64_t jid = CFSwapInt64HostToLittle(job); [header appendBytes:&tag length:1]; [header appendBytes:&jid length:8]; }
    if (method) fields[@12] = method;
    [header appendData:TKCloudProto(fields)];
    uint32_t words[] = { CFSwapInt32HostToLittle(message | 0x80000000), CFSwapInt32HostToLittle((uint32_t)header.length) };
    NSMutableData *frame = [NSMutableData dataWithBytes:words length:8]; [frame appendData:header]; [frame appendData:body]; return frame;
}
- (BOOL)send:(uint32_t)message fields:(NSDictionary *)fields job:(uint64_t)job method:(NSString *)method error:(NSError **)error {
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSError *failure;
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:[self frame:message body:TKCloudProto(fields) job:job method:method]] completionHandler:^(NSError *e) { failure = e; dispatch_semaphore_signal(done); }];
    BOOL timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC)) != 0;
    if (timedOut || failure) { if (error) *error = TKCloudError(109); return NO; } return YES;
}
- (NSDictionary *)waitForMessage:(uint32_t)message job:(uint64_t)job error:(NSError **)error {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45]; [_condition lock];
    while (true) {
        for (NSDictionary *packet in [_packets copy]) {
            if ([packet[@"message"] unsignedIntValue] == message && (!job || TKCloudNumber(packet[@"header"], 11) == job)) {
                [_packets removeObject:packet]; [_condition unlock]; return packet;
            }
        }
        if (_receiveError || ![_condition waitUntilDate:deadline]) {
            if (error) *error = _receiveError ?: TKCloudError(110); [_condition unlock]; return nil;
        }
    }
}
- (BOOL)connectWithUsername:(NSString *)username token:(NSString *)token error:(NSError **)error {
    [self disconnect]; _receiveError = nil; [_packets removeAllObjects];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 90;
    _session = [NSURLSession sessionWithConfiguration:configuration];
    NSURL *directory = [NSURL URLWithString:@"https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets"];
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSData *response; __block NSInteger status;
    [[_session dataTaskWithURL:directory completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!e) { response = data; status = [(NSHTTPURLResponse *)r statusCode]; } dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_SEC)) || status != 200) { if (error) *error = TKCloudError(111); return NO; }
    NSDictionary *listing = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    NSString *endpoint = [listing[@"response"][@"serverlist"] firstObject][@"endpoint"];
    // Restrict the credential-bearing connection to Valve's TLS hosts.
    NSURL *url = endpoint ? [NSURL URLWithString:[NSString stringWithFormat:@"wss://%@/cmsocket/", endpoint]] : nil;
    if (!url || ![url.host hasSuffix:@".steamserver.net"] || url.user || url.password) { if (error) *error = TKCloudError(112); return NO; }
    _socket = [_session webSocketTaskWithURL:url]; [_socket resume]; [self readNext];
    if (![self send:9805 fields:@{@1:@65581} job:0 method:nil error:error]) return NO;
    _steamID = UINT64_C(0x0110000100000000); // Public-universe individual, account not known until login.
    uint32_t loginID=arc4random();
    uint8_t ipTag=13;uint32_t littleIP=CFSwapInt32HostToLittle(loginID);
    NSMutableData *ip=[NSMutableData dataWithBytes:&ipTag length:1];[ip appendBytes:&littleIP length:4];
    if (![self send:5514 fields:@{@1:@65581, @2:@(loginID), @11:ip, @5:@1771, @6:@"english", @7:@20, @8:@YES,
        @50:username, @96:@"Tolkara Steam Cloud", @102:@YES, @108:token} job:0 method:nil error:error]) return NO;
    NSDictionary *packet = [self waitForMessage:751 job:0 error:error];
    if (!packet) return NO;
    uint64_t result = TKCloudNumber(packet[@"body"], 1);
    if (result != 1) { if (error) *error = TKCloudError(1000 + (NSInteger)result); return NO; }
    _clientID = TKCloudNumber(packet[@"body"], 27);
    _steamID = TKCloudNumber(packet[@"header"], 1); _sessionID = (uint32_t)TKCloudNumber(packet[@"header"], 2);
    if (!_steamID || !_sessionID) { if (error) *error = TKCloudError(113); return NO; }
    _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_heartbeat, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    __weak TKSteamCloudConnection *weakSelf = self;
    dispatch_source_set_event_handler(_heartbeat, ^{ TKSteamCloudConnection *s = weakSelf; if (s) [s send:703 fields:@{} job:0 method:nil error:nil]; });
    dispatch_resume(_heartbeat); return YES;
}
- (NSDictionary *)call:(NSString *)method fields:(NSDictionary *)fields error:(NSError **)error {
    uint64_t job = ++_job;
    if (![self send:151 fields:fields job:job method:method error:error]) return nil;
    NSDictionary *packet = [self waitForMessage:147 job:job error:error]; if (!packet) return nil;
    uint64_t result = TKCloudNumber(packet[@"header"], 13);
    if (result != 1) { if (error) *error = TKCloudError(2000 + (NSInteger)result); return nil; }
    return packet[@"body"];
}
- (void)disconnect {
    if (_heartbeat) { dispatch_source_cancel(_heartbeat); _heartbeat = nil; }
    [_socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil]; _socket = nil;
    [_session invalidateAndCancel]; _session = nil; _steamID = 0; _clientID = 0; _sessionID = 0;
}
- (void)dealloc { [self disconnect]; }
@end
