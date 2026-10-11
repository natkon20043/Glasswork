#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Icon buttons switching the sidebar between Files, Source Control and Search. The selected one sits
/// in a soft pill; a badge can show a count.
@interface GWSidebarSwitcher : NSView

// ---- Constructors
/// One SF Symbol name and tooltip per mode.
- (instancetype)initWithSymbols:(NSArray<NSString *> *)symbols tooltips:(NSArray<NSString *> *)tooltips;

// ---- Setters
/// Zero hides it.
- (void)setBadge:(NSInteger)count forIndex:(NSInteger)index;

// ---- Properties
@property (nonatomic) NSInteger selectedIndex;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger index);

@end

NS_ASSUME_NONNULL_END
