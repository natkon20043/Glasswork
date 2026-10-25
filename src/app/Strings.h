#pragma once

#import <Foundation/Foundation.h>

#include "TextBuffer.hpp"

#include <string>

// ---- Converting

/// A C++ string as an NSString. Text that isn't valid UTF-8 gets "�" in place of the broken bytes
/// instead of becoming nil, which would crash in an array, a dictionary or a label.
inline NSString *StringFromUTF8(const std::string &text) {
    NSString *string = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    if (string != nil) {
        return string;
    }
    std::string repaired = gw::withValidUtf8(text);
    NSString *repairedString = [[NSString alloc] initWithBytes:repaired.data()
                                                        length:repaired.size()
                                                      encoding:NSUTF8StringEncoding];
    if (repairedString == nil) {
        return @"";
    }
    return repairedString;
}

// ---- Cutting

/// At most the first `length` UTF-16 units of `text`, never ending halfway through a character
/// (an emoji or an accented letter made of two parts).
inline NSString *PrefixOfString(NSString *text, NSUInteger length) {
    if (text.length <= length) {
        return text;
    }
    NSRange character = [text rangeOfComposedCharacterSequenceAtIndex:length];
    return [text substringToIndex:character.location];
}
