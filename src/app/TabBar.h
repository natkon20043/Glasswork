#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GWTabItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL dirty;
@end

/// Open files as pills. Drawn inside a Liquid Glass capsule; empty space drags the window.
@interface GWTabBar : NSView

@property (nonatomic, copy) NSArray<GWTabItem *> *items;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger index);
@property (nonatomic, copy, nullable) void (^onClose)(NSInteger index);

@end

NS_ASSUME_NONNULL_END
