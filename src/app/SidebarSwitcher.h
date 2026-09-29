#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A row of icon buttons that switches the sidebar between Files, Source Control and Search.
/// The selected one sits in a soft pill; a badge can show a count (changed files).
@interface GWSidebarSwitcher : NSView

/// SF Symbol names, one per mode, and tooltips.
- (instancetype)initWithSymbols:(NSArray<NSString *> *)symbols tooltips:(NSArray<NSString *> *)tooltips;

@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger index);

/// Shows a count on one mode's icon; zero hides it.
- (void)setBadge:(NSInteger)count forIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
