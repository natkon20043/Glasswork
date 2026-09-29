#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One row in the palette.
@interface GWPaletteItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *shortcut;  // e.g. "⇧⌘P"
@property (nonatomic, copy) NSString *symbol;             // SF Symbol name
@property (nonatomic, strong) NSColor *symbolColor;
/// UTF-16 indexes into `title` to emphasise (the characters the query matched).
@property (nonatomic, copy) NSIndexSet *matchedIndexes;
@property (nonatomic, copy) void (^run)(void);
@end

/// A Zed/VS Code-style picker on glass: type to filter, arrows to move, Enter to run,
/// Esc to close. Used for quick-open (⌘P) and the command palette (⇧⌘P).
@interface GWPalette : NSObject

+ (instancetype)shared;

/// Shows the palette over `window`. `provider` returns the rows for the current query and
/// is called on every keystroke, so it must be fast.
- (void)showOverWindow:(NSWindow *)window
           placeholder:(NSString *)placeholder
              provider:(NSArray<GWPaletteItem *> * (^)(NSString *query))provider;

/// Runs the provider again with the text now in the search field. For lists that fill in
/// later (results that arrive from a language server).
- (void)refresh;
/// True while the palette is on screen.
@property (nonatomic, readonly) BOOL isShowing;
/// The text in the search field.
@property (nonatomic, readonly, copy) NSString *query;

@end

NS_ASSUME_NONNULL_END
