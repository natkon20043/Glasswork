#import "BitmapChrome.h"

#import "Services.h"

#include "BitmapMode.hpp"
#include "PixelFont.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

@class GWBitmapOverlay;

namespace {

/// One font pixel of the chrome, a character cell's width and a line's height, in points.
CGFloat Pixel() { return GWChromePixel(); }
CGFloat Cell() { return gw::pixelfont::kAdvance * Pixel(); }
CGFloat Line() { return gw::pixelfont::kLineHeight * Pixel(); }
/// The hard black shadow under windows, menus and dialogs.
CGFloat ShadowSize() { return GWRetroBox.shadowSize; }

NSColor *Palette(gw::Color color) { return GWColor(color); }

/// The colors chosen in Options (Turbo, Low Tide or Phosphor).
const gw::bitmap::Scheme &Colors() { return GWServices.shared.bitmapScheme; }

/// `value` rounded down to whole chrome pixels.
CGFloat Snap(CGFloat value) {
    return std::floor(value / Pixel()) * Pixel();
}

/// The side window's width, frame included: room for 23 characters.
CGFloat PanelWidth() { return 25 * Cell(); }

/// The status line's keys: what they say and the menu action they run.
struct Hint {
    NSString *key;
    NSString *label;
    SEL action;
};
const std::vector<Hint> &Hints() {
    static const std::vector<Hint> hints = {
        {@"⌘S", @"Save", @selector(saveDocument:)},
        {@"F5", @"Run", @selector(startDebugging:)},
        {@"F9", @"Break", @selector(toggleBreakpoint:)},
        {@"⌘P", @"Open", @selector(quickOpen:)},
        {@"⌘F", @"Find", @selector(showFind:)},
        {@"⌃`", @"Term", @selector(toggleTerminal:)},
    };
    return hints;
}

NSString *const kPanelNames[] = {@"Files", @"Issues", @"Debug"};
constexpr size_t kPanelCount = std::size(kPanelNames);

struct Geometry {
    NSRect menuBar;
    NSRect status;
    NSRect editorWindow;
    NSRect editorContent;
    NSRect closeBox;
    NSRect zoomBox;
    NSRect upArrow;
    NSRect downArrow;
    NSRect track;
    NSRect panelWindow;
    NSRect panelContent;
};

// ---- Drawing helpers

/// A checkerboard of two colors in chrome pixels, like the shaded characters of a text screen.
NSColor *Checker(gw::Color first, gw::Color second) {
    static NSMutableDictionary<NSString *, NSColor *> *cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%08x%08x", first, second];
    NSColor *pattern = cache[key];
    if (pattern == nil) {
        CGFloat pixel = Pixel();
        NSImage *image = [NSImage imageWithSize:NSMakeSize(2 * pixel, 2 * pixel) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [Palette(first) setFill];
            NSRectFill(rect);
            [Palette(second) setFill];
            NSRectFill(NSMakeRect(0, 0, pixel, pixel));
            NSRectFill(NSMakeRect(pixel, pixel, pixel, pixel));
            return YES;
        }];
        pattern = [NSColor colorWithPatternImage:image];
        cache[key] = pattern;
    }
    return pattern;
}

/// A frame drawn through the middle of a text cell all round: two lines, or one.
void DrawFrame(NSRect rect, NSColor *color, BOOL twoLines) {
    CGFloat pixel = Pixel();
    CGFloat line = Line(), cell = Cell();
    [color setFill];
    auto ring = [&](CGFloat inLeft, CGFloat inTop, CGFloat inRight, CGFloat inBottom) {
        CGFloat left = NSMinX(rect) + inLeft, right = NSMaxX(rect) - inRight - pixel;
        CGFloat top = NSMinY(rect) + inTop, bottom = NSMaxY(rect) - inBottom - pixel;
        NSRectFill(NSMakeRect(left, top, right - left + pixel, pixel));
        NSRectFill(NSMakeRect(left, bottom, right - left + pixel, pixel));
        NSRectFill(NSMakeRect(left, top, pixel, bottom - top + pixel));
        NSRectFill(NSMakeRect(right, top, pixel, bottom - top + pixel));
    };
    if (twoLines) {
        ring(2 * pixel, line / 2 - pixel, 2 * pixel, line / 2 - pixel);
        ring(4 * pixel, line / 2 + pixel, 4 * pixel, line / 2 + pixel);
    } else {
        ring(cell / 2, line / 2, cell / 2 - pixel, line / 2 - pixel);
    }
}

/// Text sitting on a frame's edge: a band of `background` behind it so the lines stop at it.
CGFloat DrawOnEdge(NSString *text, CGFloat x, CGFloat top, NSColor *color, NSColor *background, BOOL shadow) {
    CGFloat width = GWPixelTextWidth(text, Pixel());
    [background setFill];
    NSRectFill(NSMakeRect(x, top, std::ceil(width), Line()));
    GWDrawPixelText(text, NSMakePoint(x, top), Pixel(), color, shadow);
    return width;
}

/// A title with its hotkey letter in red, the rest in `color`.
void DrawWithHotkey(NSString *title, NSInteger hotkey, NSPoint origin, NSColor *color, NSColor *hotkeyColor) {
    CGFloat x = origin.x;
    for (NSUInteger index = 0; index < title.length; ++index) {
        NSString *letter = [title substringWithRange:NSMakeRange(index, 1)];
        BOOL isHotkey = static_cast<NSInteger>(index) == hotkey;
        x += GWDrawPixelText(letter, NSMakePoint(x, origin.y), Pixel(), isHotkey ? hotkeyColor : color, NO);
    }
}

/// A box with the frame line and hard shadow of the dialogs and menus, body at `body`.
void DrawBox(NSRect body) {
    CGFloat pixel = Pixel();
    [NSColor.blackColor setFill];
    NSRectFill(NSOffsetRect(body, ShadowSize(), ShadowSize()));
    [Palette(Colors().bar) setFill];
    NSRectFill(body);
    [Palette(Colors().barText) setFill];
    NSFrameRectWithWidth(NSInsetRect(body, 2 * pixel, 2 * pixel), pixel);
}

/// Splits "&File" into "File" and the hotkey's index.
NSString *TitleWithoutHotkeyMark(NSString *marked, NSInteger *hotkey) {
    NSRange mark = [marked rangeOfString:@"&"];
    *hotkey = mark.location == NSNotFound ? -1 : static_cast<NSInteger>(mark.location);
    return mark.location == NSNotFound ? marked : [marked stringByReplacingCharactersInRange:mark withString:@""];
}

}  // namespace

// MARK: - Rows and menus

@implementation GWBitmapRow

+ (instancetype)rowWithText:(NSString *)text color:(NSColor *)color {
    GWBitmapRow *row = [self new];
    row.text = text;
    row.textColor = color;
    row.iconColor = color;
    return row;
}

+ (instancetype)rowWithIcon:(GWPixelIcon)icon iconColor:(NSColor *)iconColor text:(NSString *)text {
    GWBitmapRow *row = [self rowWithText:text color:Palette(Colors().text)];
    row.hasIcon = YES;
    row.icon = icon;
    row.iconColor = iconColor;
    return row;
}

@end

@implementation GWBitmapMenuItem

+ (instancetype)itemWithTitle:(NSString *)title action:(SEL)action shortcut:(NSString *)shortcut {
    GWBitmapMenuItem *item = [self new];
    NSInteger hotkey = -1;
    item->_title = [TitleWithoutHotkeyMark(title, &hotkey) copy];
    item->_hotkeyIndex = hotkey;
    item->_action = action;
    item->_shortcut = [shortcut copy] ?: @"";
    return item;
}

+ (instancetype)separator {
    GWBitmapMenuItem *item = [self new];
    item->_title = @"";
    item->_shortcut = @"";
    item->_hotkeyIndex = -1;
    item->_isSeparator = YES;
    return item;
}

@end

@implementation GWBitmapMenu

+ (instancetype)menuWithTitle:(NSString *)title items:(NSArray<GWBitmapMenuItem *> *)items {
    GWBitmapMenu *menu = [self new];
    NSInteger hotkey = -1;
    menu->_title = [TitleWithoutHotkeyMark(title, &hotkey) copy];
    menu->_hotkeyIndex = hotkey;
    menu->_items = [items copy];
    return menu;
}

@end

// MARK: - Chrome

@interface GWBitmapChrome ()
/// The menu showing, or -1; its title is drawn highlighted.
@property (nonatomic) NSInteger openMenu;
- (std::vector<NSRect>)menuTitleRects;
- (NSRect)menuBarRect;
- (void)overlayClosed;
@end

/// Floats over the whole window while a menu or a dialog is up: draws it, takes the keys and the
/// clicks, and goes away again.
@interface GWBitmapOverlay : NSView
@property (nonatomic, weak) GWBitmapChrome *chrome;
@property (nonatomic, weak) NSResponder *previousResponder;
- (void)showMenu:(NSInteger)index;
- (void)showDialogWithTitle:(NSString *)title lines:(NSArray<NSString *> *)lines;
- (void)close;
@end

@implementation GWBitmapChrome {
    std::vector<NSRect> _tabRects;       // filled in while drawing, for clicks
    std::vector<NSRect> _panelTabRects;
    std::vector<NSRect> _hintRects;
    GWBitmapOverlay *_overlay;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _menus = @[];
        _title = @"";
        _tabs = @[];
        _selectedTab = -1;
        _position = @"";
        _mode = @"";
        _message = @"";
        _panelOpen = YES;
        _openMenu = -1;
        _lineScroll = 24;
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

// ---- Geometry

/// Tall enough for the window's close, minimise and zoom buttons, in whole pixels.
- (CGFloat)menuBarHeight {
    CGFloat height = std::max(14 * Pixel(), Line());
    NSButton *close = [self.window standardWindowButton:NSWindowCloseButton];
    if (close.superview != nil) {
        NSRect frame = [self convertRect:close.bounds fromView:close];
        height = std::max(height, std::ceil((NSMaxY(frame) + 6) / Pixel()) * Pixel());
    }
    return height;
}

- (NSRect)menuBarRect {
    return NSMakeRect(0, 0, NSWidth(self.bounds), [self menuBarHeight]);
}

/// Right of the window buttons.
- (CGFloat)menuLeft {
    NSButton *zoom = [self.window standardWindowButton:NSWindowZoomButton];
    if (zoom.superview == nil) {
        return 84;
    }
    return Snap(NSMaxX([self convertRect:zoom.bounds fromView:zoom]) + 12);
}

- (std::vector<NSRect>)menuTitleRects {
    std::vector<NSRect> rects;
    NSRect bar = [self menuBarRect];
    CGFloat x = [self menuLeft];
    for (GWBitmapMenu *menu : _menus) {
        CGFloat width = [menu.title isEqualToString:@"≡"] ? 3 * Cell() : GWPixelTextWidth(menu.title, Pixel()) + 2 * Cell();
        rects.push_back(NSMakeRect(x, 0, std::ceil(width), NSHeight(bar)));
        x += std::ceil(width);
    }
    return rects;
}

- (Geometry)geometry {
    CGFloat pixel = Pixel(), cell = Cell(), line = Line(), shadow = ShadowSize();
    NSRect bounds = self.bounds;
    CGFloat width = NSWidth(bounds), height = NSHeight(bounds);
    Geometry g{};
    g.menuBar = [self menuBarRect];
    g.status = NSMakeRect(0, height - line, width, line);

    CGFloat top = NSMaxY(g.menuBar) + 2 * pixel;
    CGFloat bottom = NSMinY(g.status) - shadow - pixel;
    CGFloat right = width - shadow - pixel;
    if (_panelOpen) {
        g.panelWindow = NSMakeRect(Snap(right - PanelWidth()), top, PanelWidth(), std::max(0.0, bottom - top));
        g.panelContent = NSMakeRect(NSMinX(g.panelWindow) + cell, top + line, NSWidth(g.panelWindow) - 2 * cell,
                                    std::max(0.0, NSHeight(g.panelWindow) - 2 * line));
        right = NSMinX(g.panelWindow) - shadow - 2 * pixel;
    }
    g.editorWindow = NSMakeRect(2 * pixel, top, std::max(0.0, right - 2 * pixel), std::max(0.0, bottom - top));
    NSRect window = g.editorWindow;
    g.editorContent = NSMakeRect(NSMinX(window) + cell, NSMinY(window) + line, std::max(0.0, NSWidth(window) - 2 * cell),
                                 std::max(0.0, NSHeight(window) - 2 * line));
    g.closeBox = NSMakeRect(NSMinX(window) + cell, NSMinY(window), 3 * cell, line);
    g.zoomBox = NSMakeRect(NSMaxX(window) - 5 * cell, NSMinY(window), 3 * cell, line);
    CGFloat scrollLeft = NSMaxX(window) - cell;
    g.upArrow = NSMakeRect(scrollLeft, NSMinY(g.editorContent), cell, cell);
    g.downArrow = NSMakeRect(scrollLeft, NSMaxY(g.editorContent) - cell, cell, cell);
    g.track = NSMakeRect(scrollLeft, NSMaxY(g.upArrow), cell, std::max(0.0, NSMinY(g.downArrow) - NSMaxY(g.upArrow)));
    return g;
}

- (NSRect)editorFrame { return [self geometry].editorContent; }
- (NSRect)panelContentFrame { return _panelOpen ? [self geometry].panelContent : NSZeroRect; }

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    self.needsDisplay = YES;  // every part's place depends on the size
}

// ---- Properties

- (void)setMenus:(NSArray<GWBitmapMenu *> *)menus {
    _menus = [menus copy];
    [self setNeedsDisplayInRect:[self menuBarRect]];
}

- (void)setTitle:(NSString *)title {
    if (![_title isEqualToString:title]) {
        _title = [title copy];
        [self setNeedsDisplayInRect:[self menuBarRect]];
    }
}

- (void)setTabs:(NSArray<GWTabItem *> *)tabs {
    _tabs = [tabs copy];
    [self setNeedsDisplayInRect:[self editorTopEdge]];
}

- (void)setSelectedTab:(NSInteger)selectedTab {
    _selectedTab = selectedTab;
    [self setNeedsDisplayInRect:[self editorTopEdge]];
}

- (void)setPosition:(NSString *)position {
    if (![_position isEqualToString:position]) {
        _position = [position copy];
        [self setNeedsDisplayInRect:[self editorBottomEdge]];
    }
}

- (void)setMode:(NSString *)mode {
    if (![_mode isEqualToString:mode]) {
        _mode = [mode copy];
        [self setNeedsDisplayInRect:[self editorBottomEdge]];
    }
}

- (void)setMessage:(NSString *)message {
    if (![_message isEqualToString:message]) {
        _message = [message copy];
        [self setNeedsDisplayInRect:[self geometry].status];
    }
}

- (void)setPanel:(GWBitmapPanel)panel {
    _panel = panel;
    self.needsDisplay = YES;
}

- (void)setPanelOpen:(BOOL)panelOpen {
    _panelOpen = panelOpen;
    self.needsDisplay = YES;
}

- (void)setHasFile:(BOOL)hasFile {
    if (_hasFile != hasFile) {
        _hasFile = hasFile;
        self.needsDisplay = YES;
    }
}

- (void)setOpenMenu:(NSInteger)openMenu {
    _openMenu = openMenu;
    [self setNeedsDisplayInRect:[self menuBarRect]];
}

- (void)setScrollView:(NSScrollView *)scrollView {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_scrollView != nil) {
        [center removeObserver:self name:NSViewBoundsDidChangeNotification object:_scrollView.contentView];
        [center removeObserver:self name:NSViewFrameDidChangeNotification object:_scrollView.documentView];
    }
    _scrollView = scrollView;
    if (scrollView != nil) {
        scrollView.contentView.postsBoundsChangedNotifications = YES;
        scrollView.documentView.postsFrameChangedNotifications = YES;
        [center addObserver:self selector:@selector(scrollPositionChanged:) name:NSViewBoundsDidChangeNotification object:scrollView.contentView];
        [center addObserver:self selector:@selector(scrollPositionChanged:) name:NSViewFrameDidChangeNotification object:scrollView.documentView];
    }
}

- (void)scrollPositionChanged:(NSNotification *)notification {
    Geometry g = [self geometry];
    [self setNeedsDisplayInRect:NSUnionRect(g.upArrow, g.downArrow)];
}

- (NSRect)editorTopEdge {
    NSRect window = [self geometry].editorWindow;
    return NSMakeRect(NSMinX(window), NSMinY(window), NSWidth(window), Line());
}

- (NSRect)editorBottomEdge {
    NSRect window = [self geometry].editorWindow;
    return NSMakeRect(NSMinX(window), NSMaxY(window) - Line(), NSWidth(window), Line());
}

// ---- Drawing

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldAntialias(NSGraphicsContext.currentContext.CGContext, false);
    Geometry g = [self geometry];
    [Checker(Colors().desktop, Colors().desktopDots) setFill];
    NSRectFill(dirtyRect);
    if (NSIntersectsRect(dirtyRect, g.menuBar)) {
        [self drawMenuBar:g];
    }
    if (NSIntersectsRect(dirtyRect, NSInsetRect(g.editorWindow, -ShadowSize(), -ShadowSize()))) {
        [self drawEditorWindow:g];
    }
    if (_panelOpen && NSIntersectsRect(dirtyRect, NSInsetRect(g.panelWindow, -ShadowSize(), -ShadowSize()))) {
        [self drawPanelWindow:g];
    }
    if (NSIntersectsRect(dirtyRect, g.status)) {
        [self drawStatusLine:g];
    }
}

- (void)drawMenuBar:(const Geometry &)g {
    const gw::bitmap::Scheme &colors = Colors();
    [Palette(colors.bar) setFill];
    NSRectFill(g.menuBar);
    NSColor *ink = Palette(colors.barText);
    NSColor *hotkey = Palette(colors.barHotkey);
    std::vector<NSRect> titles = [self menuTitleRects];
    CGFloat textTop = Snap(NSMidY(g.menuBar) - Line() / 2) + Pixel();
    for (NSUInteger index = 0; index < _menus.count; ++index) {
        GWBitmapMenu *menu = _menus[index];
        NSRect rect = titles[index];
        BOOL open = static_cast<NSInteger>(index) == _openMenu;
        if (open) {
            [Palette(colors.barHighlight) setFill];
            NSRectFill(NSMakeRect(NSMinX(rect), textTop, NSWidth(rect), Line()));
        }
        if ([menu.title isEqualToString:@"≡"]) {
            NSSize size = GWPixelIconSize(GWPixelIconMenu, Pixel());
            NSPoint origin = NSMakePoint(NSMinX(rect) + Snap((NSWidth(rect) - size.width) / 2), textTop + Snap((Line() - size.height) / 2));
            GWDrawPixelIcon(GWPixelIconMenu, origin, Pixel(), hotkey, NO);
            continue;
        }
        NSColor *color = open ? Palette(colors.barHighlightText) : ink;
        DrawWithHotkey(menu.title, menu.hotkeyIndex, NSMakePoint(NSMinX(rect) + Cell(), textTop), color, hotkey);
    }
    if (_title.length > 0) {
        CGFloat width = GWPixelTextWidth(_title, Pixel());
        CGFloat x = std::max(titles.empty() ? 0 : NSMaxX(titles.back()) + 2 * Cell(), Snap(NSMaxX(g.menuBar) - 2 * Cell() - width));
        GWDrawPixelText(_title, NSMakePoint(x, textTop), Pixel(), Palette(colors.barDim), NO);
    }
}

- (void)drawEditorWindow:(const Geometry &)g {
    CGFloat cell = Cell(), line = Line();
    NSRect window = g.editorWindow;
    const gw::bitmap::Scheme &colors = Colors();
    NSColor *blue = Palette(colors.window);
    NSColor *white = Palette(colors.text);
    NSColor *box = Palette(colors.closeBox);
    [NSColor.blackColor setFill];
    NSRectFill(NSOffsetRect(window, ShadowSize(), ShadowSize()));
    [blue setFill];
    NSRectFill(window);
    DrawFrame(window, Palette(colors.frame), YES);

    // Top edge: the close box, the tabs, and the box that opens or closes the side window.
    CGFloat x = NSMinX(g.closeBox);
    x += DrawOnEdge(@"[", x, NSMinY(window), white, blue, YES);
    x += DrawOnEdge(@"■", x, NSMinY(window), box, blue, YES);
    DrawOnEdge(@"]", x, NSMinY(window), white, blue, YES);
    x = NSMinX(g.zoomBox);
    x += DrawOnEdge(@"[", x, NSMinY(window), white, blue, YES);
    x += DrawOnEdge(_panelOpen ? @"→" : @"←", x, NSMinY(window), box, blue, YES);
    DrawOnEdge(@"]", x, NSMinY(window), white, blue, YES);
    [self drawTabsFrom:NSMaxX(g.closeBox) + cell to:NSMinX(g.zoomBox) - cell top:NSMinY(window)];

    // Bottom edge: where the caret is, and Vim's mode.
    CGFloat bottomTop = NSMaxY(window) - line;
    if (_position.length > 0) {
        DrawOnEdge([NSString stringWithFormat:@" %@ ", _position], NSMinX(window) + 2 * cell, bottomTop, white, blue, YES);
    }
    if (_mode.length > 0) {
        NSString *mode = [NSString stringWithFormat:@" %@ ", _mode];
        CGFloat width = GWPixelTextWidth(mode, Pixel());
        DrawOnEdge(mode, Snap(NSMaxX(window) - 3 * cell - width), bottomTop, Palette(colors.textAccent), blue, YES);
    }

    [self drawScrollbar:g];
    if (!_hasFile) {
        [self drawEmptyHint:g.editorContent];
    }
}

- (void)drawTabsFrom:(CGFloat)start to:(CGFloat)limit top:(CGFloat)top {
    CGFloat cell = Cell();
    std::vector<CGFloat> widths;
    for (NSUInteger index = 0; index < _tabs.count; ++index) {
        widths.push_back(std::ceil(GWPixelTextWidth([self labelForTab:index], Pixel())));
    }
    // If the selected tab would be cut off, everything moves left until it shows.
    CGFloat shift = 0;
    if (_selectedTab >= 0 && static_cast<NSUInteger>(_selectedTab) < _tabs.count) {
        CGFloat right = start;
        for (NSInteger index = 0; index <= _selectedTab; ++index) {
            right += widths[static_cast<size_t>(index)] + cell;
        }
        shift = std::max(0.0, right - cell - limit);
    }
    _tabRects.assign(_tabs.count, NSZeroRect);
    NSRect clip = NSMakeRect(start, top, std::max(0.0, limit - start), Line());
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(clip);
    CGFloat x = start - shift;
    for (NSUInteger index = 0; index < _tabs.count; ++index) {
        BOOL selected = static_cast<NSInteger>(index) == _selectedTab;
        NSString *label = [self labelForTab:index];
        const gw::bitmap::Scheme &colors = Colors();
        if (selected) {
            DrawOnEdge(label, x, top, Palette(colors.selectionText), Palette(colors.selection), NO);
        } else {
            DrawOnEdge(label, x, top, Palette(colors.text), Palette(colors.window), YES);
        }
        _tabRects[index] = NSIntersectionRect(NSMakeRect(x, top, widths[index], Line()), clip);
        x += widths[index] + cell;
    }
    [NSGraphicsContext restoreGraphicsState];
}

- (NSString *)labelForTab:(NSUInteger)index {
    GWTabItem *item = _tabs[index];
    return [NSString stringWithFormat:@" %@%@ ", item.title, item.dirty ? @"*" : @""];
}

/// The scrollbar in the code window's right edge: arrows at the ends, a shaded track, the thumb.
- (void)drawScrollbar:(const Geometry &)g {
    CGFloat pixel = Pixel();
    const gw::bitmap::Scheme &colors = Colors();
    [Checker(colors.window, colors.scrollTrack) setFill];
    NSRectFill(g.track);
    for (NSRect arrow : {g.upArrow, g.downArrow}) {
        [Palette(colors.scrollButton) setFill];
        NSRectFill(arrow);
    }
    GWPixelIcon up = GWPixelIconUp, down = GWPixelIconDown;
    NSSize size = GWPixelIconSize(up, pixel);
    auto centered = [&](NSRect box) {
        return NSMakePoint(NSMinX(box) + Snap((NSWidth(box) - size.width) / 2), NSMinY(box) + Snap((NSHeight(box) - size.height) / 2));
    };
    GWDrawPixelIcon(up, centered(g.upArrow), pixel, Palette(colors.scrollArrow), NO);
    GWDrawPixelIcon(down, centered(g.downArrow), pixel, Palette(colors.scrollArrow), NO);
    NSRect thumb = [self thumbRect:g];
    if (!NSIsEmptyRect(thumb)) {
        [Palette(colors.scrollThumb) setFill];
        NSRectFill(thumb);
    }
}

/// Where the thumb is in the track, from the scroll view; empty when everything fits.
- (NSRect)thumbRect:(const Geometry &)g {
    NSScrollView *scroll = _scrollView;
    CGFloat document = NSHeight(scroll.documentView.frame);
    CGFloat visible = NSHeight(scroll.contentView.bounds);
    if (scroll == nil || document <= visible + 1 || NSHeight(g.track) <= Cell()) {
        return NSZeroRect;
    }
    CGFloat height = std::max(Cell(), Snap(NSHeight(g.track) * visible / document));
    CGFloat fraction = std::clamp(NSMinY(scroll.contentView.bounds) / (document - visible), 0.0, 1.0);
    CGFloat y = NSMinY(g.track) + Snap((NSHeight(g.track) - height) * fraction);
    return NSMakeRect(NSMinX(g.track), y, NSWidth(g.track), height);
}

- (void)drawEmptyHint:(NSRect)area {
    NSArray<NSString *> *lines = @[@"No file open", @"", @"File > Open Folder   ⇧⌘O", @"File > Quick Open    ⌘P", @"Debug > Start       F5"];
    CGFloat line = Line();
    CGFloat width = 0;
    for (NSString *text in lines) {
        width = std::max(width, GWPixelTextWidth(text, Pixel()));
    }
    CGFloat x = Snap(NSMidX(area) - width / 2);
    CGFloat y = Snap(NSMidY(area) - lines.count * line / 2);
    for (NSUInteger index = 0; index < lines.count; ++index) {
        gw::Color color = index == 0 ? Colors().text : Colors().textDim;
        GWDrawPixelText(lines[index], NSMakePoint(x, y), Pixel(), Palette(color), YES);
        y += line;
    }
}

- (void)drawPanelWindow:(const Geometry &)g {
    CGFloat cell = Cell();
    NSRect window = g.panelWindow;
    const gw::bitmap::Scheme &colors = Colors();
    NSColor *blue = Palette(colors.window);
    [NSColor.blackColor setFill];
    NSRectFill(NSOffsetRect(window, ShadowSize(), ShadowSize()));
    [blue setFill];
    NSRectFill(window);
    DrawFrame(window, Palette(colors.frameDim), NO);
    _panelTabRects.assign(kPanelCount, NSZeroRect);
    CGFloat x = NSMinX(window) + cell;
    for (size_t index = 0; index < kPanelCount; ++index) {
        NSString *label = [NSString stringWithFormat:@" %@ ", kPanelNames[index]];
        BOOL selected = static_cast<NSInteger>(index) == _panel;
        CGFloat width = selected ? DrawOnEdge(label, x, NSMinY(window), Palette(colors.selectionText), Palette(colors.selection), NO)
                                 : DrawOnEdge(label, x, NSMinY(window), Palette(colors.text), blue, YES);
        _panelTabRects[index] = NSMakeRect(x, NSMinY(window), width, Line());
        x += width;
    }
}

- (void)drawStatusLine:(const Geometry &)g {
    const gw::bitmap::Scheme &colors = Colors();
    [Palette(colors.bar) setFill];
    NSRectFill(g.status);
    NSColor *black = Palette(colors.barText);
    NSColor *red = Palette(colors.barHotkey);
    CGFloat x = Cell();
    _hintRects.clear();
    for (const Hint &hint : Hints()) {
        CGFloat start = x;
        x += GWDrawPixelText(hint.key, NSMakePoint(x, NSMinY(g.status)), Pixel(), red, NO);
        x += GWDrawPixelText([@" " stringByAppendingString:hint.label], NSMakePoint(x, NSMinY(g.status)), Pixel(), black, NO);
        _hintRects.push_back(NSMakeRect(start - Cell() / 2, NSMinY(g.status), x - start + Cell(), Line()));
        x += 2 * Cell();
    }
    // A divider, then the message as far right as it fits.
    [black setFill];
    NSRectFill(NSMakeRect(x - Cell(), NSMinY(g.status) + 2 * Pixel(), Pixel(), Line() - 4 * Pixel()));
    if (_message.length > 0) {
        CGFloat width = GWPixelTextWidth(_message, Pixel());
        CGFloat left = std::max(x, Snap(NSMaxX(g.status) - Cell() - width));
        [NSGraphicsContext saveGraphicsState];
        NSRectClip(NSMakeRect(x, NSMinY(g.status), std::max(0.0, NSMaxX(g.status) - Cell() - x), Line()));
        GWDrawPixelText(_message, NSMakePoint(left, NSMinY(g.status)), Pixel(), black, NO);
        [NSGraphicsContext restoreGraphicsState];
    }
}

// ---- Menus and dialogs

- (GWBitmapOverlay *)overlay {
    if (_overlay == nil) {
        _overlay = [GWBitmapOverlay new];
        _overlay.chrome = self;
        _overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    NSView *top = self.window.contentView;
    if (_overlay.superview != top && top != nil) {
        _overlay.frame = top.bounds;
        _overlay.previousResponder = self.window.firstResponder;
        [top addSubview:_overlay positioned:NSWindowAbove relativeTo:nil];
    }
    return _overlay;
}

- (void)openMenuAtIndex:(NSInteger)index {
    if (index < 0 || index >= static_cast<NSInteger>(_menus.count) || self.window == nil) {
        return;
    }
    [[self overlay] showMenu:index];
}

- (void)showDialogWithTitle:(NSString *)title lines:(NSArray<NSString *> *)lines {
    if (self.window == nil) {
        return;
    }
    [[self overlay] showDialogWithTitle:title lines:lines];
}

- (void)overlayClosed {
    self.openMenu = -1;
}

// ---- Clicks

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    Geometry g = [self geometry];
    if (NSPointInRect(point, g.menuBar)) {
        std::vector<NSRect> titles = [self menuTitleRects];
        for (size_t index = 0; index < titles.size(); ++index) {
            if (NSPointInRect(point, titles[index])) {
                [self openMenuAtIndex:static_cast<NSInteger>(index)];
                return;
            }
        }
        [self dragOrZoomWindow:event];
        return;
    }
    if (NSPointInRect(point, g.status)) {
        for (size_t index = 0; index < _hintRects.size() && index < Hints().size(); ++index) {
            if (NSPointInRect(point, _hintRects[index])) {
                [NSApp sendAction:Hints()[index].action to:nil from:self];
                return;
            }
        }
        return;
    }
    if (NSPointInRect(point, g.closeBox)) {
        if (self.onCloseTab && _selectedTab >= 0) {
            self.onCloseTab(_selectedTab);
        }
        return;
    }
    if (NSPointInRect(point, g.zoomBox)) {
        if (self.onTogglePanel) {
            self.onTogglePanel();
        }
        return;
    }
    for (size_t index = 0; index < _tabRects.size() && index < _tabs.count; ++index) {
        if (NSPointInRect(point, _tabRects[index])) {
            if (self.onSelectTab) {
                self.onSelectTab(static_cast<NSInteger>(index));
            }
            return;
        }
    }
    if (_panelOpen) {
        for (size_t index = 0; index < _panelTabRects.size(); ++index) {
            if (NSPointInRect(point, _panelTabRects[index])) {
                if (self.onChoosePanel) {
                    self.onChoosePanel(static_cast<GWBitmapPanel>(index));
                }
                return;
            }
        }
    }
    if (NSPointInRect(point, NSUnionRect(g.upArrow, g.downArrow))) {
        [self scrollbarMouseDown:event geometry:g];
    }
}

- (void)dragOrZoomWindow:(NSEvent *)event {
    if (event.clickCount == 2) {
        // What the system's "double-click a window's title bar" setting asks for.
        NSString *action = [NSUserDefaults.standardUserDefaults stringForKey:@"AppleActionOnDoubleClick"];
        if ([action isEqualToString:@"Minimize"]) {
            [self.window performMiniaturize:nil];
        } else if (![action isEqualToString:@"None"]) {
            [self.window performZoom:nil];
        }
        return;
    }
    [self.window performWindowDragWithEvent:event];
}

/// Arrows and the track repeat while held; the thumb follows the pointer.
- (void)scrollbarMouseDown:(NSEvent *)event geometry:(const Geometry &)g {
    NSScrollView *scroll = _scrollView;
    if (scroll == nil) {
        return;
    }
    NSClipView *clip = scroll.contentView;
    CGFloat document = NSHeight(scroll.documentView.frame);
    CGFloat visible = NSHeight(clip.bounds);
    auto scrollTo = ^(CGFloat y) {
        CGFloat clamped = std::clamp(y, 0.0, std::max(0.0, document - visible));
        [clip scrollToPoint:NSMakePoint(NSMinX(clip.bounds), clamped)];
        [scroll reflectScrolledClipView:clip];
    };
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect thumb = [self thumbRect:g];
    if (NSPointInRect(point, thumb)) {
        CGFloat grab = point.y - NSMinY(thumb);
        CGFloat room = NSHeight(g.track) - NSHeight(thumb);
        while (true) {
            NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
            if (next.type == NSEventTypeLeftMouseUp) {
                break;
            }
            CGFloat y = [self convertPoint:next.locationInWindow fromView:nil].y - grab - NSMinY(g.track);
            scrollTo(room > 0 ? std::clamp(y / room, 0.0, 1.0) * (document - visible) : 0);
        }
        return;
    }
    CGFloat step = 0;
    if (NSPointInRect(point, g.upArrow)) {
        step = -_lineScroll;
    } else if (NSPointInRect(point, g.downArrow)) {
        step = _lineScroll;
    } else if (NSPointInRect(point, g.track)) {
        step = point.y < NSMinY(thumb) ? -(visible - _lineScroll) : visible - _lineScroll;
    }
    if (step == 0) {
        return;
    }
    scrollTo(NSMinY(clip.bounds) + step);
    [NSEvent startPeriodicEventsAfterDelay:0.35 withPeriod:0.05];
    while (true) {
        NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskPeriodic | NSEventMaskLeftMouseUp];
        if (next.type == NSEventTypeLeftMouseUp) {
            break;
        }
        scrollTo(NSMinY(clip.bounds) + step);
    }
    [NSEvent stopPeriodicEvents];
}

@end

// MARK: - Menus and dialogs

@implementation GWBitmapOverlay {
    NSInteger _menuIndex;          // -1 while a dialog shows
    NSInteger _highlighted;
    std::vector<BOOL> _enabled;
    NSString *_dialogTitle;
    NSArray<NSString *> *_dialogLines;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas.copy) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
}

- (void)takeKeyboard {
    [self.window makeFirstResponder:self];
    self.needsDisplay = YES;
}

- (void)showMenu:(NSInteger)index {
    GWBitmapChrome *chrome = self.chrome;
    // Which items can run is asked of the responder chain before the overlay takes the keyboard.
    if (self.window.firstResponder == self) {
        [self.window makeFirstResponder:self.previousResponder];
    }
    _menuIndex = index;
    _dialogTitle = nil;
    _enabled.clear();
    _highlighted = -1;
    NSArray<GWBitmapMenuItem *> *items = chrome.menus[static_cast<NSUInteger>(index)].items;
    for (GWBitmapMenuItem *item in items) {
        BOOL enabled = !item.isSeparator && [self canRun:item];
        _enabled.push_back(enabled);
        if (enabled && _highlighted < 0) {
            _highlighted = static_cast<NSInteger>(_enabled.size() - 1);
        }
    }
    chrome.openMenu = index;
    [self takeKeyboard];
}

- (void)showDialogWithTitle:(NSString *)title lines:(NSArray<NSString *> *)lines {
    _menuIndex = -1;
    _dialogTitle = [title copy];
    _dialogLines = [lines copy];
    self.chrome.openMenu = -1;
    [self takeKeyboard];
}

/// Whether something in the responder chain takes the action and says it can run now.
- (BOOL)canRun:(GWBitmapMenuItem *)item {
    id target = [NSApp targetForAction:item.action to:nil from:self];
    if (target == nil) {
        return NO;
    }
    NSMenuItem *probe = [[NSMenuItem alloc] initWithTitle:item.title action:item.action keyEquivalent:@""];
    probe.tag = item.tag;
    if ([target respondsToSelector:@selector(validateMenuItem:)]) {
        return [target validateMenuItem:probe];
    }
    if ([target respondsToSelector:@selector(validateUserInterfaceItem:)]) {
        return [target validateUserInterfaceItem:probe];
    }
    return YES;
}

- (void)close {
    NSWindow *window = self.window;
    NSResponder *previous = self.previousResponder;
    [self removeFromSuperview];
    [self.chrome overlayClosed];
    if (window != nil && previous != nil) {
        [window makeFirstResponder:previous];
    }
}

- (void)choose:(NSInteger)row {
    NSArray<GWBitmapMenuItem *> *items = self.chrome.menus[static_cast<NSUInteger>(_menuIndex)].items;
    if (row < 0 || row >= static_cast<NSInteger>(items.count) || !_enabled[static_cast<size_t>(row)]) {
        return;
    }
    GWBitmapMenuItem *item = items[static_cast<NSUInteger>(row)];
    [self close];  // the editor has the keyboard again, so the action goes where a menu's would
    [NSApp sendAction:item.action to:nil from:item];
}

// ---- Menu geometry

- (CGFloat)heightOfItem:(GWBitmapMenuItem *)item {
    return item.isSeparator ? Line() / 2 : Line();
}

- (NSRect)dropdownRect {
    GWBitmapChrome *chrome = self.chrome;
    NSArray<GWBitmapMenuItem *> *items = chrome.menus[static_cast<NSUInteger>(_menuIndex)].items;
    CGFloat titles = 0, shortcuts = 0, height = 0;
    for (GWBitmapMenuItem *item in items) {
        titles = std::max(titles, GWPixelTextWidth(item.title, Pixel()));
        shortcuts = std::max(shortcuts, GWPixelTextWidth(item.shortcut, Pixel()));
        height += [self heightOfItem:item];
    }
    CGFloat cell = Cell();
    CGFloat width = std::ceil(2 * cell + titles + (shortcuts > 0 ? 3 * cell + shortcuts : 0) + 2 * cell);
    NSRect title = [chrome menuTitleRects][static_cast<size_t>(_menuIndex)];
    NSRect menuBar = [chrome convertRect:[chrome menuBarRect] toView:self];
    CGFloat x = [chrome convertRect:title toView:self].origin.x;
    x = std::max(0.0, std::min(x, NSWidth(self.bounds) - width - ShadowSize()));
    return NSMakeRect(Snap(x), NSMaxY(menuBar), width, height + 8 * Pixel());
}

- (NSInteger)rowAtPoint:(NSPoint)point {
    NSRect box = [self dropdownRect];
    if (!NSPointInRect(point, box)) {
        return -1;
    }
    NSArray<GWBitmapMenuItem *> *items = self.chrome.menus[static_cast<NSUInteger>(_menuIndex)].items;
    CGFloat y = NSMinY(box) + 4 * Pixel();
    for (NSUInteger index = 0; index < items.count; ++index) {
        CGFloat height = [self heightOfItem:items[index]];
        if (point.y >= y && point.y < y + height) {
            return static_cast<NSInteger>(index);
        }
        y += height;
    }
    return -1;
}

/// The menu bar title under `point`, or -1.
- (NSInteger)menuTitleAtPoint:(NSPoint)point {
    GWBitmapChrome *chrome = self.chrome;
    std::vector<NSRect> titles = [chrome menuTitleRects];
    for (size_t index = 0; index < titles.size(); ++index) {
        if (NSPointInRect(point, [chrome convertRect:titles[index] toView:self])) {
            return static_cast<NSInteger>(index);
        }
    }
    return -1;
}

- (NSRect)dialogRect {
    CGFloat width = GWPixelTextWidth(_dialogTitle, Pixel());
    for (NSString *line in _dialogLines) {
        width = std::max(width, GWPixelTextWidth(line, Pixel()));
    }
    width = std::ceil(width + 6 * Cell());
    CGFloat height = Line() * (_dialogLines.count + 4);  // title, a blank line above and below, the button
    NSRect bounds = self.bounds;
    return NSMakeRect(Snap(NSMidX(bounds) - width / 2), Snap(std::max(0.0, NSMidY(bounds) - height / 2)), width, height);
}

- (NSRect)okButtonRect {
    NSRect dialog = [self dialogRect];
    CGFloat width = 8 * Cell();
    return NSMakeRect(Snap(NSMidX(dialog) - width / 2), NSMaxY(dialog) - Line() - 4 * Pixel(), width, Line() - 2 * Pixel());
}

// ---- Drawing

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldAntialias(NSGraphicsContext.currentContext.CGContext, false);
    if (_menuIndex >= 0) {
        [self drawMenu];
    } else if (_dialogTitle != nil) {
        [self drawDialog];
    }
}

- (void)drawMenu {
    NSArray<GWBitmapMenuItem *> *items = self.chrome.menus[static_cast<NSUInteger>(_menuIndex)].items;
    NSRect box = [self dropdownRect];
    DrawBox(box);
    const gw::bitmap::Scheme &colors = Colors();
    CGFloat pixel = Pixel(), cell = Cell();
    CGFloat y = NSMinY(box) + 4 * pixel;
    NSColor *black = Palette(colors.barText);
    for (NSUInteger index = 0; index < items.count; ++index) {
        GWBitmapMenuItem *item = items[index];
        CGFloat height = [self heightOfItem:item];
        if (item.isSeparator) {
            [black setFill];
            NSRectFill(NSMakeRect(NSMinX(box) + 2 * pixel, y + height / 2 - pixel, NSWidth(box) - 4 * pixel, pixel));
            y += height;
            continue;
        }
        BOOL enabled = _enabled[index];
        BOOL highlighted = static_cast<NSInteger>(index) == _highlighted;
        if (highlighted) {
            [Palette(colors.barHighlight) setFill];
            NSRectFill(NSMakeRect(NSMinX(box) + 4 * pixel, y, NSWidth(box) - 8 * pixel, height));
        }
        NSColor *color = !enabled ? Palette(colors.barDim) : highlighted ? Palette(colors.barHighlightText) : black;
        NSColor *hotkey = enabled ? Palette(colors.barHotkey) : color;
        if (item.checked) {
            GWDrawPixelText(@"•", NSMakePoint(NSMinX(box) + cell, y), pixel, color, NO);
        }
        DrawWithHotkey(item.title, item.hotkeyIndex, NSMakePoint(NSMinX(box) + 2 * cell, y), color, hotkey);
        if (item.shortcut.length > 0) {
            CGFloat width = GWPixelTextWidth(item.shortcut, pixel);
            GWDrawPixelText(item.shortcut, NSMakePoint(Snap(NSMaxX(box) - 2 * cell - width), y), pixel, color, NO);
        }
        y += height;
    }
}

- (void)drawDialog {
    NSRect dialog = [self dialogRect];
    CGFloat pixel = Pixel(), cell = Cell(), line = Line();
    const gw::bitmap::Scheme &colors = Colors();
    DrawBox(dialog);
    // A title strip across the top, like the dialogs of the old IDEs.
    NSRect strip = NSMakeRect(NSMinX(dialog), NSMinY(dialog), NSWidth(dialog), line);
    [Palette(colors.dialogTitle) setFill];
    NSRectFill(strip);
    CGFloat titleWidth = GWPixelTextWidth(_dialogTitle, pixel);
    GWDrawPixelText(_dialogTitle, NSMakePoint(Snap(NSMidX(strip) - titleWidth / 2), NSMinY(strip)), pixel, Palette(colors.dialogTitleText), NO);
    CGFloat y = NSMaxY(strip) + line / 2;
    for (NSString *text in _dialogLines) {
        GWDrawPixelText(text, NSMakePoint(NSMinX(dialog) + 3 * cell, y), pixel, Palette(colors.barText), NO);
        y += line;
    }
    NSRect button = [self okButtonRect];
    [NSColor.blackColor setFill];
    NSRectFill(NSOffsetRect(button, 2 * pixel, 2 * pixel));
    [Palette(colors.dialogTitle) setFill];
    NSRectFill(button);
    NSString *ok = @"OK";
    CGFloat okWidth = GWPixelTextWidth(ok, pixel);
    GWDrawPixelText(ok, NSMakePoint(Snap(NSMidX(button) - okWidth / 2), NSMinY(button) - pixel), pixel, Palette(colors.dialogTitleText), NO);
}

// ---- Events

- (void)mouseMoved:(NSEvent *)event {
    if (_menuIndex < 0) {
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger title = [self menuTitleAtPoint:point];
    if (title >= 0 && title != _menuIndex) {
        [self showMenu:title];
        return;
    }
    NSInteger row = [self rowAtPoint:point];
    if (row >= 0 && row != _highlighted && _enabled[static_cast<size_t>(row)]) {
        _highlighted = row;
        self.needsDisplay = YES;
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (_menuIndex < 0) {
        [self close];  // a click anywhere (the OK button too) closes a dialog
        return;
    }
    NSInteger title = [self menuTitleAtPoint:point];
    if (title >= 0) {
        if (title == _menuIndex) {
            [self close];
        } else {
            [self showMenu:title];
        }
        return;
    }
    NSInteger row = [self rowAtPoint:point];
    if (row >= 0) {
        [self choose:row];
        return;
    }
    if (!NSPointInRect(point, [self dropdownRect])) {
        [self close];
    }
}

- (void)moveHighlightBy:(NSInteger)step {
    NSInteger count = static_cast<NSInteger>(_enabled.size());
    for (NSInteger tries = 0, row = _highlighted; tries < count; ++tries) {
        row = (row + step + count) % count;
        if (_enabled[static_cast<size_t>(row)]) {
            _highlighted = row;
            self.needsDisplay = YES;
            return;
        }
    }
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length > 0 ? [characters characterAtIndex:0] : 0;
    if (_menuIndex < 0) {
        if (key == 27 || key == '\r' || key == ' ' || key == 3) {
            [self close];
        }
        return;
    }
    NSInteger menus = static_cast<NSInteger>(self.chrome.menus.count);
    switch (key) {
        case 27:
            [self close];
            return;
        case NSLeftArrowFunctionKey:
            [self showMenu:(_menuIndex + menus - 1) % menus];
            return;
        case NSRightArrowFunctionKey:
            [self showMenu:(_menuIndex + 1) % menus];
            return;
        case NSUpArrowFunctionKey:
            [self moveHighlightBy:-1];
            return;
        case NSDownArrowFunctionKey:
            [self moveHighlightBy:1];
            return;
        case '\r':
        case 3:
            [self choose:_highlighted];
            return;
        default:
            break;
    }
    // A hotkey letter runs its item, as in the old menus.
    NSArray<GWBitmapMenuItem *> *items = self.chrome.menus[static_cast<NSUInteger>(_menuIndex)].items;
    NSString *typed = characters.lowercaseString;
    for (NSUInteger index = 0; index < items.count; ++index) {
        GWBitmapMenuItem *item = items[index];
        if (item.hotkeyIndex < 0 || !_enabled[index]) {
            continue;
        }
        NSString *letter = [item.title substringWithRange:NSMakeRange(static_cast<NSUInteger>(item.hotkeyIndex), 1)].lowercaseString;
        if ([letter isEqualToString:typed]) {
            [self choose:static_cast<NSInteger>(index)];
            return;
        }
    }
}

@end

// MARK: - List

@implementation GWBitmapList

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _rows = @[];
        _scrollView = [NSScrollView new];
        _scrollView.drawsBackground = NO;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.autohidesScrollers = YES;
        _scrollView.scrollerStyle = NSScrollerStyleOverlay;
        _scrollView.automaticallyAdjustsContentInsets = NO;
        _scrollView.contentView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        _scrollView.documentView = self;
        self.autoresizingMask = NSViewWidthSizable;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)setRows:(NSArray<GWBitmapRow *> *)rows {
    _rows = [rows copy];
    [self fitHeight];
    self.needsDisplay = YES;
}

- (void)fitHeight {
    NSSize visible = _scrollView.contentSize;
    [self setFrameSize:NSMakeSize(visible.width, std::max(visible.height, _rows.count * Line()))];
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [self fitHeight];
}

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize {
    [super resizeWithOldSuperviewSize:oldSize];
    [self fitHeight];
}

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat pixel = Pixel(), line = Line();
    CGContextSetShouldAntialias(NSGraphicsContext.currentContext.CGContext, false);
    NSUInteger first = static_cast<NSUInteger>(std::max(0.0, std::floor(NSMinY(dirtyRect) / line)));
    NSUInteger last = std::min<NSUInteger>(_rows.count, static_cast<NSUInteger>(std::ceil(NSMaxY(dirtyRect) / line)) + 1);
    CGFloat iconColumn = 10 * pixel;
    for (NSUInteger index = first; index < last; ++index) {
        GWBitmapRow *row = _rows[index];
        CGFloat top = index * line;
        if (row.highlighted) {
            [Palette(Colors().selection) setFill];
            NSRectFill(NSMakeRect(0, top, NSWidth(self.bounds), line));
        }
        CGFloat x = pixel;
        if (row.hasIcon) {
            NSSize size = GWPixelIconSize(row.icon, pixel);
            NSPoint origin = NSMakePoint(x + Snap((iconColumn - size.width) / 2), top + Snap((line - size.height) / 2));
            GWDrawPixelIcon(row.icon, origin, pixel, row.iconColor, YES);
            x += iconColumn + 2 * pixel;
        }
        // A highlighted row's text takes the selection's own color, which reads on it in every scheme.
        if (row.highlighted) {
            GWDrawPixelText(row.text, NSMakePoint(x, top), pixel, Palette(Colors().selectionText), NO);
        } else {
            GWDrawPixelText(row.text, NSMakePoint(x, top), pixel, row.textColor, YES);
        }
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = static_cast<NSInteger>(std::floor(point.y / Line()));
    if (index < 0 || index >= static_cast<NSInteger>(_rows.count) || self.onChoose == nil) {
        return;
    }
    self.onChoose(_rows[static_cast<NSUInteger>(index)]);
}

@end
