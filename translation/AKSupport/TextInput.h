#import <Foundation/Foundation.h>
// AppKit key-binding result delivered to the original NSTextInputClient.
void AKInterpretTextKey(id client,NSString *characters,unsigned short keyCode,NSUInteger modifiers);
// Software keyboards commit text, not HID presses. Preserve composed Unicode
// characters and provide virtual key codes where a character has an ANSI key.
void AKEnumerateTextKeys(NSString *text, void (^emit)(NSString *characters, NSString *unmodified,
                                                   unsigned short keyCode, NSUInteger modifiers));
// Text from the clipboard, as the on-screen keyboard's Paste types it: line
// breaks, tabs and other control characters removed (Paste never presses
// Return or Tab), at most AKPastedTextLimit UTF-16 units, whole characters.
enum { AKPastedTextLimit = 1024 };
NSString *AKPastedText(NSString *text);
