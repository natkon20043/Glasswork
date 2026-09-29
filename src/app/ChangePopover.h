#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Removed lines (red) followed by added lines (green), in a monospaced font of the given size.
/// Shared by the change popover and the diff previews in chat.
NSAttributedString *GWDiffAttributedText(NSArray<NSString *> *oldLines, NSArray<NSString *> *newLines, CGFloat pointSize);

/// What clicking a change bar in the gutter shows: the lines as committed and as they are
/// now, with buttons to go to the neighbouring changes, stage this one, or revert it.
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
