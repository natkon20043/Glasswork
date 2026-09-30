#import "TabBar.h"

#import "FileIcons.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>

@implementation GWTabItem
@end

@implementation GWTabBar {
    NSArray<NSValue *> *_tabRects;
    NSInteger _hoverIndex;
    // The selection pill glides between tabs.
    NSRect _pillFrom, _pillTo, _pill;
    NSTimeInterval _pillStart;
    NSTimer *_pillTimer;
    NSTrackingArea *_tracking;

    // Too many tabs to fit: the row scrolls sideways, and its ends fade out where more tabs are hidden.
    CGFloat _scrollX;
    NSTimer *_scrollTimer;
    CAGradientLayer *_fadeMask;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        _hoverIndex = -1;
        _selectedIndex = -1;
        self.wantsLayer = YES;
        _fadeMask = [CAGradientLayer layer];
        _fadeMask.startPoint = CGPointMake(0, 0.5);
        _fadeMask.endPoint = CGPointMake(1, 0.5);
        self.layer.mask = _fadeMask;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setItems:(NSArray<GWTabItem *> *)items {
    _items = [items copy];
    [self layoutTabs];
    [self movePillAnimated:NO];
    [self revealSelectedTabAnimated:NO];
    self.needsDisplay = YES;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    BOOL changed = selectedIndex != _selectedIndex;
    _selectedIndex = selectedIndex;
    [self layoutTabs];
    [self movePillAnimated:changed && !NSIsEmptyRect(_pill)];
    [self revealSelectedTabAnimated:changed];
    self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutTabs];
    [self movePillAnimated:NO];
    _scrollX = std::min(std::max(_scrollX, 0.0), [self maxScroll]);
    [self updateFadeMask];
}

// MARK: Scrolling

/// The full width of all tabs in a row.
- (CGFloat)contentWidth {
    if (_tabRects.count == 0) {
        return 0;
    }
    return NSMaxX(_tabRects.lastObject.rectValue) + 5;
}

- (CGFloat)maxScroll {
    return std::max(0.0, [self contentWidth] - NSWidth(self.bounds));
}

/// Fades the left and right edges where tabs are cut off.
- (void)updateFadeMask {
    CGFloat width = NSWidth(self.bounds);
    _fadeMask.frame = self.bounds;
    if (width <= 0) {
        return;
    }
    BOOL fadeLeft = _scrollX > 0.5;
    BOOL fadeRight = _scrollX < [self maxScroll] - 0.5;
    CGFloat edge = std::min(0.5, 26.0 / width);
    CGColorRef opaque = NSColor.blackColor.CGColor;
    CGColorRef clear = NSColor.clearColor.CGColor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fadeMask.colors = @[(__bridge id)(fadeLeft ? clear : opaque), (__bridge id)opaque, (__bridge id)opaque,
                         (__bridge id)(fadeRight ? clear : opaque)];
    _fadeMask.locations = @[@0, @(fadeLeft ? edge : 0.0), @(fadeRight ? 1 - edge : 1.0), @1];
    [CATransaction commit];
}

- (void)setScrollX:(CGFloat)value {
    _scrollX = std::min(std::max(value, 0.0), [self maxScroll]);
    [self updateFadeMask];
    self.needsDisplay = YES;
}

/// Slides the row so the selected tab is fully visible, with a little room around it.
- (void)revealSelectedTabAnimated:(BOOL)animated {
    [_scrollTimer invalidate];
    _scrollTimer = nil;
    if (_selectedIndex < 0 || _selectedIndex >= static_cast<NSInteger>(_tabRects.count)) {
        [self updateFadeMask];
        return;
    }
    NSRect tab = _tabRects[static_cast<NSUInteger>(_selectedIndex)].rectValue;
    CGFloat margin = 30;
    CGFloat target = _scrollX;
    if (NSMinX(tab) - margin < _scrollX) {
        target = NSMinX(tab) - margin;
    } else if (NSMaxX(tab) + margin > _scrollX + NSWidth(self.bounds)) {
        target = NSMaxX(tab) + margin - NSWidth(self.bounds);
    }
    target = std::min(std::max(target, 0.0), [self maxScroll]);
    if (std::abs(target - _scrollX) < 0.5) {
        [self updateFadeMask];
        return;
    }
    if (!animated) {
        [self setScrollX:target];
        return;
    }
    CGFloat from = _scrollX;
    NSTimeInterval start = NSDate.timeIntervalSinceReferenceDate;
    __weak GWTabBar *weakSelf = self;
    _scrollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        GWTabBar *bar = weakSelf;
        if (!bar) {
            [timer invalidate];
            return;
        }
        double t = std::min(1.0, (NSDate.timeIntervalSinceReferenceDate - start) / 0.24);
        double eased = 1 - std::pow(1 - t, 3);
        [bar setScrollX:from + (target - from) * eased];
        if (t >= 1) {
            [timer invalidate];
            bar->_scrollTimer = nil;
        }
    }];
}

/// Trackpad swipes sideways, or a mouse wheel: the row scrolls.
- (void)scrollWheel:(NSEvent *)event {
    if ([self maxScroll] <= 0) {
        [super scrollWheel:event];
        return;
    }
    CGFloat horizontal = event.scrollingDeltaX;
    CGFloat vertical = event.scrollingDeltaY;
    CGFloat delta = std::abs(horizontal) > std::abs(vertical) ? -horizontal : -vertical;
    if (!event.hasPreciseScrollingDeltas) {
        delta *= 12;  // a wheel notch is a coarse step
    }
    [_scrollTimer invalidate];
    _scrollTimer = nil;
    [self setScrollX:_scrollX + delta];
}

// MARK: Layout

- (NSDictionary *)titleAttributesSelected:(BOOL)selected {
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:selected ? NSFontWeightSemibold : NSFontWeightMedium],
        NSForegroundColorAttributeName: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
    };
}

- (void)layoutTabs {
    NSMutableArray *rects = [NSMutableArray array];
    CGFloat x = 5, height = NSHeight(self.bounds) - 8;
    for (GWTabItem *item in self.items) {
        NSSize text = [item.title sizeWithAttributes:[self titleAttributesSelected:YES]];
        // Padding, file icon, gap, title, close button.
        CGFloat width = std::min(std::max(text.width + 84, 112.0), 260.0);
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, 4, width, height)]];
        x += width + 3;
    }
    _tabRects = rects;
}

- (NSRect)targetPill {
    if (_selectedIndex < 0 || _selectedIndex >= static_cast<NSInteger>(_tabRects.count)) return NSZeroRect;
    return _tabRects[static_cast<NSUInteger>(_selectedIndex)].rectValue;
}

- (void)movePillAnimated:(BOOL)animated {
    [_pillTimer invalidate];
    _pillTimer = nil;
    _pillTo = [self targetPill];
    if (!animated || NSIsEmptyRect(_pillTo)) {
        _pill = _pillTo;
        return;
    }
    _pillFrom = _pill;
    _pillStart = NSDate.timeIntervalSinceReferenceDate;
    __weak GWTabBar *weakSelf = self;
    _pillTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        GWTabBar *bar = weakSelf;
        if (!bar) return;
        double t = std::min(1.0, (NSDate.timeIntervalSinceReferenceDate - bar->_pillStart) / 0.22);
        double eased = 1 - std::pow(1 - t, 3);  // ease-out cubic
        auto mix = [&](CGFloat a, CGFloat b) { return a + (b - a) * eased; };
        bar->_pill = NSMakeRect(mix(NSMinX(bar->_pillFrom), NSMinX(bar->_pillTo)), NSMinY(bar->_pillTo),
                                mix(NSWidth(bar->_pillFrom), NSWidth(bar->_pillTo)), NSHeight(bar->_pillTo));
        bar.needsDisplay = YES;
        if (t >= 1) {
            [timer invalidate];
            bar->_pillTimer = nil;
        }
    }];
}

- (NSRect)closeRectForTab:(NSRect)tab {
    return NSMakeRect(NSMaxX(tab) - 26, NSMidY(tab) - 9, 18, 18);
}

// MARK: Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *shift = [NSAffineTransform transform];
    [shift translateXBy:-_scrollX yBy:0];
    [shift concat];
    // The selection pill: a brighter lens of glass with a crisp rim.
    if (!NSIsEmptyRect(_pill)) {
        NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:_pill xRadius:NSHeight(_pill) / 2 yRadius:NSHeight(_pill) / 2];
        NSGradient *fill = [[NSGradient alloc] initWithStartingColor:[NSColor.labelColor colorWithAlphaComponent:0.18]
                                                         endingColor:[NSColor.labelColor colorWithAlphaComponent:0.09]];
        [fill drawInBezierPath:pill angle:90];
        [[NSColor.labelColor colorWithAlphaComponent:0.22] setStroke];
        pill.lineWidth = 0.75;
        [pill stroke];
    }

    for (NSUInteger index = 0; index < self.items.count; ++index) {
        GWTabItem *item = self.items[index];
        NSRect rect = _tabRects[index].rectValue;
        BOOL selected = static_cast<NSInteger>(index) == self.selectedIndex;
        BOOL hovered = static_cast<NSInteger>(index) == _hoverIndex;
        if (hovered && !selected) {
            [[NSColor.labelColor colorWithAlphaComponent:0.06] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:NSHeight(rect) / 2 yRadius:NSHeight(rect) / 2] fill];
        }

        // File-type icon, then the name.
        NSImage *icon = [NSImage imageWithSystemSymbolName:GWSymbolForFile(item.title) accessibilityDescription:nil];
        NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[GWColorForFile(item.title)]]];
        icon = [icon imageWithSymbolConfiguration:configuration];
        NSRect iconRect = NSMakeRect(NSMinX(rect) + 14, NSMidY(rect) - icon.size.height / 2, icon.size.width, icon.size.height);
        [icon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:selected ? 1 : 0.8
                respectFlipped:YES hints:nil];

        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.lineBreakMode = NSLineBreakByTruncatingMiddle;
        NSMutableDictionary *attributes = [[self titleAttributesSelected:selected] mutableCopy];
        attributes[NSParagraphStyleAttributeName] = paragraph;
        NSRect textRect = NSMakeRect(NSMaxX(iconRect) + 7, NSMidY(rect) - 8.5, NSMaxX(rect) - NSMaxX(iconRect) - 36, 17);
        [item.title drawInRect:textRect withAttributes:attributes];

        // Trailing mark: × on hover or selection, otherwise ● for unsaved changes.
        NSRect mark = [self closeRectForTab:rect];
        if (hovered || selected) {
            NSImage *close = [NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"];
            close = [close imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:8.5 weight:NSFontWeightBold]
                configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.secondaryLabelColor]]]];
            NSRect closeRect = NSMakeRect(NSMidX(mark) - close.size.width / 2, NSMidY(mark) - close.size.height / 2,
                                          close.size.width, close.size.height);
            if (item.dirty && !hovered) {
                [NSColor.controlAccentColor setFill];
                [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(mark, 5, 5)] fill];
            } else {
                [close drawInRect:closeRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                   respectFlipped:YES hints:nil];
            }
        } else if (item.dirty) {
            [NSColor.controlAccentColor setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(mark, 5, 5)] fill];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
}

// MARK: Mouse

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (NSInteger)tabAtPoint:(NSPoint)point {
    for (NSUInteger index = 0; index < _tabRects.count; ++index) {
        if (NSPointInRect(point, _tabRects[index].rectValue)) return static_cast<NSInteger>(index);
    }
    return -1;
}

/// A point in the view as a point in the row of tabs, which may be scrolled.
- (NSPoint)rowPointForEvent:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    point.x += _scrollX;
    return point;
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger hover = [self tabAtPoint:[self rowPointForEvent:event]];
    if (hover != _hoverIndex) {
        _hoverIndex = hover;
        self.needsDisplay = YES;
    }
}

- (void)mouseExited:(NSEvent *)event {
    _hoverIndex = -1;
    self.needsDisplay = YES;
}

/// Middle-click closes a tab.
- (void)otherMouseUp:(NSEvent *)event {
    if (event.buttonNumber != 2) {
        return;
    }
    NSInteger index = [self tabAtPoint:[self rowPointForEvent:event]];
    if (index >= 0 && self.onClose) {
        self.onClose(index);
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self rowPointForEvent:event];
    NSInteger index = [self tabAtPoint:point];
    if (index >= 0) {
        NSRect rect = _tabRects[static_cast<NSUInteger>(index)].rectValue;
        if (NSPointInRect(point, NSInsetRect([self closeRectForTab:rect], -3, -3))) {
            if (self.onClose) self.onClose(index);
        } else if (self.onSelect) {
            self.onSelect(index);
        }
        return;
    }
    // Empty space behaves like a title bar.
    if (event.clickCount == 2) {
        [self.window zoom:nil];
    } else {
        [self.window performWindowDragWithEvent:event];
    }
}

@end
