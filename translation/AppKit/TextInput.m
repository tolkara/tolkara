#import "TextInput.h"
#import "AKSupport.h"
void AKEnumerateTextKeys(NSString *text, void (^emit)(NSString *, NSString *, unsigned short, NSUInteger)) {
    // These are macOS virtual key positions; Unicode is always carried in the
    // event too. Never turn an unmapped character into an arbitrary key press.
    static const unsigned short letters[] = {0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6};
    NSString *plain = @"1234567890-=][\\';/.,` ";
    NSString *shifted = @"!@#$%^&*()_+}{|\":?><~ ";
    static const unsigned short keys[] = {18,19,20,21,23,22,26,28,25,29,27,24,30,33,42,39,41,44,47,43,50,49};
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        (void)range; (void)enclosing; (void)stop;
        unsigned short code = 0xFF;
        NSUInteger modifiers = 0;
        NSString *unmodified = character;
        if ([character isEqual:@"\n"] || [character isEqual:@"\r"]) { character = unmodified = @"\r"; code = 36; }
        else if ([character isEqual:@"\t"]) code = 48;
        else if (character.length == 1) {
            unichar c = [character characterAtIndex:0];
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                BOOL upper = c <= 'Z';
                code = letters[c - (upper ? 'A' : 'a')];
                unmodified = character.lowercaseString;
                modifiers = upper ? 1UL << 17 : 0;
            } else {
                NSRange key = [plain rangeOfString:character];
                if (key.location == NSNotFound) {
                    key = [shifted rangeOfString:character];
                    if (key.location != NSNotFound) modifiers = 1UL << 17;
                }
                if (key.location != NSNotFound) {
                    code = keys[key.location];
                    unmodified = [plain substringWithRange:NSMakeRange(key.location, 1)];
                }
            }
        }
        emit(character, unmodified, code, modifiers);
    }];
}

void AKInterpretTextKey(id client,NSString *characters,unsigned short keyCode,NSUInteger modifiers) {
    BOOL shift=(modifiers&(1UL<<17))!=0,option=(modifiers&(1UL<<19))!=0;
    BOOL command=(modifiers&(1UL<<20))!=0,control=(modifiers&(1UL<<18))!=0;
    NSString *name=nil;
    switch(keyCode) {
        case 36: case 76: name=@"insertNewline:";break;
        case 48: name=shift?@"insertBacktab:":@"insertTab:";break;
        case 51: name=option?@"deleteWordBackward:":@"deleteBackward:";break;
        case 117: name=option?@"deleteWordForward:":@"deleteForward:";break;
        case 53: name=@"cancelOperation:";break;
        case 123: name=option?@"moveWordLeft:":@"moveLeft:";break;
        case 124: name=option?@"moveWordRight:":@"moveRight:";break;
        case 125: name=@"moveDown:";break;
        case 126: name=@"moveUp:";break;
        case 115: name=@"moveToBeginningOfDocument:";break;
        case 119: name=@"moveToEndOfDocument:";break;
        case 116: name=@"pageUp:";break;
        case 121: name=@"pageDown:";break;
    }
    if(command) {
        switch(keyCode) {
            case 0:name=@"selectAll:";break;case 8:name=@"copy:";break;
            case 9:name=@"paste:";break;case 7:name=@"cut:";break;
            case 6:name=shift?@"redo:":@"undo:";break;
            case 123:name=@"moveToBeginningOfLine:";break;case 124:name=@"moveToEndOfLine:";break;
        }
    }
    if(shift && ([name hasPrefix:@"move"] || [name hasPrefix:@"page"])) name=[[name substringToIndex:name.length-1] stringByAppendingString:@"AndModifySelection:"];
    if(name) {
        SEL dispatch=NSSelectorFromString(@"doCommandBySelector:");
        if([client respondsToSelector:dispatch]) ((void (*)(id,SEL,SEL))[client methodForSelector:dispatch])(client,dispatch,NSSelectorFromString(name));
        return;
    }
    if(!characters.length || command || control) return;
    SEL insert=NSSelectorFromString(@"insertText:replacementRange:");
    if([client respondsToSelector:insert]) ((void (*)(id,SEL,id,NSRange))[client methodForSelector:insert])(client,insert,characters,NSMakeRange(NSNotFound,0));
    else {
        insert=NSSelectorFromString(@"insertText:");
        if([client respondsToSelector:insert]) ((void (*)(id,SEL,id))[client methodForSelector:insert])(client,insert,characters);
    }
}
