#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// ---- Highlighting

/// Chat fence tag ("cpp", "c++", "py", "sh", "js"...) -> editor language id, or empty if unknown.
NSString *GWLanguageForFenceTag(NSString *tag);

/// Colors code like the editor does (same grammar, theme and rainbow variables). `language` is a
/// fence tag or language id; unknown draws plain. Main thread only.
NSAttributedString *GWHighlightedCode(NSString *code, NSString *language, CGFloat pointSize);

NS_ASSUME_NONNULL_END
