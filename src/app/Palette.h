#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One palette row.
@interface GWPaletteItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
/// E.g. "⇧⌘P".
@property (nonatomic, copy, nullable) NSString *shortcut;
/// SF Symbol name.
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) NSColor *symbolColor;
/// UTF-16 indexes into `title` of the characters the query matched.
@property (nonatomic, copy) NSIndexSet *matchedIndexes;
@property (nonatomic, copy) void (^run)(void);
@end

/// Picker on glass for quick-open (Cmd-P) and the command palette (Shift-Cmd-P): type to filter,
/// arrows to move, Enter to run, Esc to close.
@interface GWPalette : NSObject

// ---- Constructors
+ (instancetype)shared;

// ---- Showing
/// `provider` returns rows for the query and runs on every keystroke, so it must be fast.
- (void)showOverWindow:(NSWindow *)window
           placeholder:(NSString *)placeholder
              provider:(NSArray<GWPaletteItem *> * (^)(NSString *query))provider;
/// `onDismiss` runs if closed without choosing a row (Esc, click elsewhere).
- (void)showOverWindow:(NSWindow *)window
           placeholder:(NSString *)placeholder
              provider:(NSArray<GWPaletteItem *> * (^)(NSString *query))provider
             onDismiss:(void (^)(void))onDismiss;
/// Re-runs the provider with the current text, for lists that fill in later.
- (void)refresh;

// ---- Properties
@property (nonatomic, readonly) BOOL isShowing;
@property (nonatomic, readonly, copy) NSString *query;

@end

NS_ASSUME_NONNULL_END
