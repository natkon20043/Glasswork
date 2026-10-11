#pragma once

#import <AppKit/AppKit.h>

@class GWEditorView;

NS_ASSUME_NONNULL_BEGIN

/// Floating panel for recoloring a name everywhere, or a kind of code (TextMate scope) under the
/// caret. Changes apply live and are saved to settings.json.
@interface GWColorInspector : NSObject

+ (instancetype)shared;

/// Opens or refreshes the panel for the caret in `editor`.
- (void)showForEditor:(GWEditorView *)editor;
/// Re-reads the caret's name and scopes if the panel is open.
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
