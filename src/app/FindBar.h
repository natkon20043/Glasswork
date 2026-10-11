#pragma once

#import <AppKit/AppKit.h>

@class GWEditorView;

NS_ASSUME_NONNULL_BEGIN

/// Find and replace bar floating over the editor. Searches as you type, marks every match (current
/// stronger), and supports case, whole word and regex options.
@interface GWFindBar : NSView

// ---- Showing
/// With `text`, the search field is filled with it (the selected word).
- (void)showWithText:(nullable NSString *)text replace:(BOOL)showReplace;
- (void)close;

// ---- Searching
- (void)findNext;
- (void)findPrevious;
/// Sets the search without showing the bar (Cmd-E).
- (void)setSearchText:(NSString *)text;
/// The document was edited or switched: recompute matches.
- (void)documentChanged;

// ---- Properties
@property (nonatomic, weak, nullable) GWEditorView *editor;
@property (nonatomic, readonly) CGFloat preferredHeight;

// ---- Callbacks
/// The bar closed itself (Escape or the close button).
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// Height changed (the replace row opened or closed).
@property (nonatomic, copy, nullable) void (^onResize)(void);

@end

NS_ASSUME_NONNULL_END
