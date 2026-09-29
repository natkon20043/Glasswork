#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Holds a rounded glass view inside a transparent margin and gives it a soft shadow that is drawn
/// only outside the rounded shape. Floating panels use this instead of the window's own shadow,
/// which is computed from the window's rectangle and leaves a thin outline around rounded corners.
///
/// Make the panel `padding` larger than the glass on every side, and use this as its content view.
@interface GWShadowedGlass : NSView

/// The glass, kept `padding` in from the edges.
@property (nonatomic, readonly) NSGlassEffectView *glass;

/// Margin around the glass that the shadow can spread into.
+ (CGFloat)padding;

- (instancetype)initWithCornerRadius:(CGFloat)radius;

@end

NS_ASSUME_NONNULL_END
