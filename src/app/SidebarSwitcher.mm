#import "SidebarSwitcher.h"

@implementation GWSidebarSwitcher {
    NSArray<NSString *> *_symbols;
    NSArray<NSString *> *_tooltips;
    NSMutableArray<NSNumber *> *_badges;
    NSInteger _hovered;
}

- (instancetype)initWithSymbols:(NSArray<NSString *> *)symbols tooltips:(NSArray<NSString *> *)tooltips {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _symbols = [symbols copy];
        _tooltips = [tooltips copy];
        _badges = [NSMutableArray array];
        for (NSUInteger index = 0; index < symbols.count; ++index) {
            [_badges addObject:@0];
        }
        _hovered = -1;
        self.clipsToBounds = YES;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 32); }

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    self.needsDisplay = YES;
}

- (void)setBadge:(NSInteger)count forIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_badges.count)) {
        return;
    }
    _badges[static_cast<NSUInteger>(index)] = @(count);
    self.needsDisplay = YES;
}

/// The rectangle of one button. The buttons share the width equally.
- (NSRect)rectForIndex:(NSInteger)index {
    CGFloat width = NSWidth(self.bounds) / static_cast<CGFloat>(_symbols.count);
    return NSMakeRect(index * width, 0, width, NSHeight(self.bounds));
}

- (NSInteger)indexAtPoint:(NSPoint)point {
    for (NSInteger index = 0; index < static_cast<NSInteger>(_symbols.count); ++index) {
        if (NSPointInRect(point, [self rectForIndex:index])) {
            return index;
        }
    }
    return -1;
}

- (void)drawRect:(NSRect)dirtyRect {
    // The track.
    NSRect track = NSInsetRect(self.bounds, 0.5, 0.5);
    [[NSColor.labelColor colorWithAlphaComponent:0.06] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:NSHeight(track) / 2 yRadius:NSHeight(track) / 2] fill];

    for (NSInteger index = 0; index < static_cast<NSInteger>(_symbols.count); ++index) {
        NSRect cell = NSInsetRect([self rectForIndex:index], 3, 3);
        BOOL selected = index == _selectedIndex;
        BOOL hovered = index == _hovered;

        if (selected || hovered) {
            CGFloat alpha = selected ? 0.16 : 0.07;
            [[NSColor.labelColor colorWithAlphaComponent:alpha] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:cell xRadius:NSHeight(cell) / 2 yRadius:NSHeight(cell) / 2] fill];
        }

        NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration
            configurationWithPointSize:13
                                weight:selected ? NSFontWeightSemibold : NSFontWeightMedium];
        NSImage *symbol = [[NSImage imageWithSystemSymbolName:_symbols[static_cast<NSUInteger>(index)] accessibilityDescription:nil]
            imageWithSymbolConfiguration:configuration];
        NSColor *tint = selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
        NSImage *tinted = [symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[tint]]];
        NSSize size = tinted.size;
        NSRect iconRect = NSMakeRect(NSMidX(cell) - size.width / 2, NSMidY(cell) - size.height / 2, size.width, size.height);
        [tinted drawInRect:iconRect];

        NSInteger badge = _badges[static_cast<NSUInteger>(index)].integerValue;
        if (badge > 0) {
            NSString *text = badge > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", static_cast<long>(badge)];
            NSDictionary *attributes = @{
                NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: NSColor.whiteColor,
            };
            NSSize textSize = [text sizeWithAttributes:attributes];
            CGFloat width = MAX(textSize.width + 8, 14);
            NSRect pill = NSMakeRect(NSMidX(cell) + 7, NSMinY(cell) - 1, width, 13);
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.95] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6.5 yRadius:6.5] fill];
            [text drawAtPoint:NSMakePoint(NSMidX(pill) - textSize.width / 2, NSMidY(pill) - textSize.height / 2) withAttributes:attributes];
        }
    }
}

// MARK: Mouse

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas.copy) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index != _hovered) {
        _hovered = index;
        self.toolTip = index >= 0 ? _tooltips[static_cast<NSUInteger>(index)] : nil;
        self.needsDisplay = YES;
    }
}

- (void)mouseExited:(NSEvent *)event {
    _hovered = -1;
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
    NSInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index < 0) {
        return;
    }
    self.selectedIndex = index;
    if (self.onSelect) {
        self.onSelect(index);
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

@end
