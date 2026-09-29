#pragma once

#import <AppKit/AppKit.h>

@class GWEditorView;

NS_ASSUME_NONNULL_BEGIN

/// The find and replace bar that floats over the top of the editor. It searches the open
/// document as you type, marks every match (the current one stronger), and steps through
/// them. Handles case, whole word and regular expression options.
@interface GWFindBar : NSView

@property (nonatomic, weak, nullable) GWEditorView *editor;

/// Called when the bar closes itself (Escape or the close button).
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// Called when the bar's height changes (the replace row opened or closed).
@property (nonatomic, copy, nullable) void (^onResize)(void);

/// The height needed right now.
@property (nonatomic, readonly) CGFloat preferredHeight;

/// Shows the bar. With `text` the search field is filled with it (the selected word).
- (void)showWithText:(nullable NSString *)text replace:(BOOL)showReplace;
- (void)close;

- (void)findNext;
- (void)findPrevious;
/// Use the given text as the search without showing the bar (⌘E).
- (void)setSearchText:(NSString *)text;

/// The open document was edited or switched: recompute the matches.
- (void)documentChanged;

@end

NS_ASSUME_NONNULL_END
