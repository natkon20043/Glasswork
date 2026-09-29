#import "ShadowedGlass.h"

#import <QuartzCore/QuartzCore.h>

@implementation GWShadowedGlass {
    CALayer *_shadowLayer;
    CAShapeLayer *_shadowMask;
    CGFloat _radius;
}

+ (CGFloat)padding { return 44; }

- (instancetype)initWithCornerRadius:(CGFloat)radius {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _radius = radius;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;

        _shadowLayer = [CALayer layer];
        _shadowLayer.shadowColor = NSColor.blackColor.CGColor;
        _shadowLayer.shadowOpacity = 0.34;
        _shadowLayer.shadowRadius = 22;
        _shadowLayer.shadowOffset = CGSizeMake(0, -9);  // the layer is flipped: this is down
        _shadowMask = [CAShapeLayer layer];
        _shadowMask.fillRule = kCAFillRuleEvenOdd;
        _shadowLayer.mask = _shadowMask;
        [self.layer addSublayer:_shadowLayer];

        _glass = [NSGlassEffectView new];
        _glass.cornerRadius = radius;
        [self addSubview:_glass];
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

- (void)layout {
    [super layout];
    CGFloat pad = GWShadowedGlass.padding;
    NSRect glassFrame = NSInsetRect(self.bounds, pad, pad);
    _glass.frame = glassFrame;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shadowLayer.frame = self.bounds;
    CGPathRef rounded = CGPathCreateWithRoundedRect(NSInsetRect(self.bounds, pad, pad), _radius, _radius, nullptr);
    _shadowLayer.shadowPath = rounded;
    // The shadow shows only outside the glass, so it never darkens the glass itself.
    CGMutablePathRef outside = CGPathCreateMutable();
    CGPathAddRect(outside, nullptr, self.bounds);
    CGPathAddPath(outside, nullptr, rounded);
    _shadowMask.frame = self.bounds;
    _shadowMask.path = outside;
    CGPathRelease(outside);
    CGPathRelease(rounded);
    [CATransaction commit];
}

@end
