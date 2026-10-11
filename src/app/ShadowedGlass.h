#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Rounded glass inside a transparent margin with a soft shadow drawn only outside the rounded shape
/// (the window's own shadow leaves an outline at rounded corners). Make the panel `padding` larger than
/// the glass on every side and use this as its content view.
@interface GWShadowedGlass : NSView

// ---- Constructors
- (instancetype)initWithCornerRadius:(CGFloat)radius;
/// Margin the shadow spreads into.
+ (CGFloat)padding;

// ---- Properties
/// Kept `padding` in from the edges.
@property (nonatomic, readonly) NSGlassEffectView *glass;

@end

NS_ASSUME_NONNULL_END
