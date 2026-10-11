#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GWTabItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL dirty;
@end

/// Open files as pills inside a Liquid Glass capsule; empty space drags the window.
@interface GWTabBar : NSView

// ---- Properties
@property (nonatomic, copy) NSArray<GWTabItem *> *items;
@property (nonatomic) NSInteger selectedIndex;

// ---- Callbacks
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger index);
@property (nonatomic, copy, nullable) void (^onClose)(NSInteger index);

@end

NS_ASSUME_NONNULL_END
