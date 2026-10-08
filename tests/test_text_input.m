#import "TextInput.h"
#include <assert.h>
@interface InputClient : NSObject
@property(copy) NSString *text, *command;
@property NSRange range;
@end
@implementation InputClient
- (void)insertText:(id)text replacementRange:(NSRange)range { self.text=text;self.range=range; }
- (void)doCommandBySelector:(SEL)selector { self.command=NSStringFromSelector(selector); }
@end
int main(void) { @autoreleasepool {
    NSMutableArray<NSDictionary *> *keys = [NSMutableArray new];
    AKEnumerateTextKeys(@"aA@ñ🙂e\u0301\r\n\t", ^(NSString *text, NSString *plain, unsigned short code, NSUInteger mods) {
        [keys addObject:@{@"text":text, @"plain":plain, @"code":@(code), @"mods":@(mods)}];
    });
    assert(keys.count == 8);
    assert([keys[0][@"code"] intValue] == 0 && [keys[0][@"mods"] intValue] == 0);
    assert([keys[1][@"code"] intValue] == 0 && [keys[1][@"plain"] isEqual:@"a"] && [keys[1][@"mods"] unsignedLongValue] == (1UL << 17));
    assert([keys[2][@"code"] intValue] == 19 && [keys[2][@"plain"] isEqual:@"2"] && [keys[2][@"text"] isEqual:@"@"]);
    for (unsigned i = 3; i <= 5; i++) assert([keys[i][@"code"] intValue] == 0xFF);
    assert([keys[4][@"text"] isEqual:@"🙂"] && [keys[5][@"text"] isEqual:@"e\u0301"]);
    assert([keys[6][@"code"] intValue] == 36 && [keys[6][@"text"] isEqual:@"\r"]);
    assert([keys[7][@"code"] intValue] == 48);
    AKEnumerateTextKeys(@"", ^(NSString *text, NSString *plain, unsigned short code, NSUInteger mods) {
        (void)text; (void)plain; (void)code; (void)mods; assert(0);
    });
    InputClient *client=[InputClient new];
    AKInterpretTextKey(client,@"é",14,1UL<<19);assert([client.text isEqual:@"é"] && client.range.location==NSNotFound && client.range.length==0);
    AKInterpretTextKey(client,@"a",0,1UL<<20);assert([client.command isEqual:@"selectAll:"] && [client.text isEqual:@"é"]);
    AKInterpretTextKey(client,@"\r",36,0);assert([client.command isEqual:@"insertNewline:"]);
    AKInterpretTextKey(client,@"",123,(1UL<<17)|(1UL<<19));assert([client.command isEqual:@"moveWordLeftAndModifySelection:"]);
    AKInterpretTextKey(client,@"",51,0);assert([client.command isEqual:@"deleteBackward:"]);
    AKInterpretTextKey(client,@"password text must not be logged",0,0);assert([client.text hasPrefix:@"password"]);
    puts("software text keys, composed Unicode, text-client ABI, commands and replacement ranges: PASS");
} }
