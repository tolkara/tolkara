#import <Foundation/Foundation.h>
// AppKit key-binding result delivered to the original NSTextInputClient.
void AKInterpretTextKey(id client,NSString *characters,unsigned short keyCode,NSUInteger modifiers);
// Software keyboards commit text, not HID presses. Preserve composed Unicode
// characters and provide virtual key codes where a character has an ANSI key.
void AKEnumerateTextKeys(NSString *text, void (^emit)(NSString *characters, NSString *unmodified,
                                                   unsigned short keyCode, NSUInteger modifiers));
