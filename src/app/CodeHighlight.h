#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The language id the editor uses for a code fence tag written in chat ("cpp", "c++", "py",
/// "sh", "js"…), or an empty string if it isn't known.
NSString *GWLanguageForFenceTag(NSString *tag);

/// Colours `code` the way the editor would, with the same grammar, theme and rainbow
/// variables, in a monospaced font of the given size. `language` may be a fence tag or a
/// language id; with an unknown one the code is drawn plain. Main thread only.
NSAttributedString *GWHighlightedCode(NSString *code, NSString *language, CGFloat pointSize);

NS_ASSUME_NONNULL_END
