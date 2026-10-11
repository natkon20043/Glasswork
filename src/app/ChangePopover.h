#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Removed lines (red) then added lines (green) in a monospaced font; shared with the diff previews in chat.
NSAttributedString *GWDiffAttributedText(NSArray<NSString *> *oldLines, NSArray<NSString *> *newLines, CGFloat pointSize);

/// What a gutter change bar shows: old and new lines, with buttons for neighbouring changes, stage and revert.
@interface GWChangePopover : NSObject

+ (void)showRelativeToRect:(NSRect)rect
                    ofView:(NSView *)view
                     title:(NSString *)title
                  oldLines:(NSArray<NSString *> *)oldLines
                  newLines:(NSArray<NSString *> *)newLines
                     count:(NSString *)summary
                   onStage:(void (^_Nullable)(void))onStage
                  onRevert:(void (^_Nullable)(void))onRevert
                onPrevious:(void (^_Nullable)(void))onPrevious
                    onNext:(void (^_Nullable)(void))onNext;

@end

NS_ASSUME_NONNULL_END
