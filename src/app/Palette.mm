#import "Palette.h"

#import "PixelArt.h"
#import "Services.h"
#import "ShadowedGlass.h"

@implementation GWPaletteItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _title = @"";
        _symbol = @"circle";
        _symbolColor = NSColor.secondaryLabelColor;
        _matchedIndexes = [NSIndexSet indexSet];
    }
    return self;
}

@end

/// A row whose selection is a soft rounded pill, so it sits nicely on glass.
@interface GWPaletteRowView : NSTableRowView
@end

@implementation GWPaletteRowView

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    NSRect pill = NSInsetRect(self.bounds, 4, 2);
    NSColor *fill = [NSColor.controlAccentColor colorWithAlphaComponent:0.28];
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:9 yRadius:9] fill];
}

- (BOOL)isEmphasized {
    return NO;  // keep the text colors as they are when selected
}

@end

/// Glasswork Bitmap's rows: a flat band of the scheme's highlight.
@interface GWRetroPaletteRowView : NSTableRowView
@end

@implementation GWRetroPaletteRowView

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [GWColor(GWServices.shared.bitmapScheme.barHighlight) setFill];
    NSRectFill(self.bounds);
}

- (BOOL)isEmphasized {
    return NO;
}

@end

/// A borderless panel that can still take keyboard focus (for the search field).
@interface GWPalettePanel : NSPanel
@end

@implementation GWPalettePanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface GWPalette () <NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@end

@implementation GWPalette {
    void (^_dismissHandler)(void);
    BOOL _itemWasRun;
    GWPalettePanel *_panel;
    NSTextField *_search;
    NSTableView *_table;
    NSArray<GWPaletteItem *> *(^_provider)(NSString *);
    NSArray<GWPaletteItem *> *_items;
    BOOL _retro;  // built for Glasswork Bitmap: a grey box of pixel text instead of glass
}

static const CGFloat kPaletteWidth = 640;
static const CGFloat kRowHeight = 34;
static const NSUInteger kVisibleRows = 10;

+ (instancetype)shared {
    static GWPalette *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = [GWPalette new];
    });
    return palette;
}

// MARK: Building

/// The colors of Glasswork Bitmap's chosen scheme.
static const gw::bitmap::Scheme &RetroColors() {
    return GWServices.shared.bitmapScheme;
}

/// The margin around the visible box: the glass's soft shadow, or the bitmap box's hard one (which
/// only hangs off the right and bottom, so the box is placed by its top left all the same).
- (CGFloat)padding {
    return _retro ? 0 : GWShadowedGlass.padding;
}

- (CGFloat)rowHeight {
    return _retro ? 12 * GWChromePixel() : kRowHeight;
}

- (void)buildPanel {
    _retro = GWServices.shared.settings.bitmapMode;
    CGFloat height = 56 + self.rowHeight * kVisibleRows + 10;
    CGFloat pad = self.padding;
    CGFloat extra = _retro ? GWRetroBox.shadowSize : 0;
    _panel = [[GWPalettePanel alloc] initWithContentRect:NSMakeRect(0, 0, kPaletteWidth + 2 * pad + extra, height + 2 * pad + extra)
                                               styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = NO;  // the shadow is drawn by GWShadowedGlass, without an outline at the corners
    _panel.level = NSFloatingWindowLevel;
    _panel.delegate = self;

    // A plain text field plus our own magnifier: NSSearchField draws its icon over the
    // placeholder once its bezel is turned off.
    NSImageSymbolConfiguration *magnifierSize = [NSImageSymbolConfiguration configurationWithPointSize:16
                                                                                              weight:NSFontWeightMedium];
    NSImageView *magnifier = [NSImageView new];
    magnifier.image = [[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil]
                       imageWithSymbolConfiguration:magnifierSize];
    magnifier.contentTintColor = NSColor.secondaryLabelColor;

    _search = [NSTextField new];
    _search.delegate = self;
    _search.font = [NSFont systemFontOfSize:17];
    _search.bezeled = NO;
    _search.bordered = NO;
    _search.drawsBackground = NO;
    _search.focusRingType = NSFocusRingTypeNone;
    _search.cell.scrollable = YES;
    _search.cell.wraps = NO;

    NSBox *separator = [NSBox new];
    separator.boxType = NSBoxSeparator;

    _table = [NSTableView new];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    column.width = kPaletteWidth - 24;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = self.rowHeight;
    _table.backgroundColor = NSColor.clearColor;
    _table.style = NSTableViewStylePlain;
    _table.intercellSpacing = NSMakeSize(0, 0);
    _table.gridStyleMask = NSTableViewGridNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(runSelected);

    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _table;
    scroll.drawsBackground = NO;
    scroll.contentView.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;

    NSView *content = [NSView new];
    for (NSView *view in @[magnifier, _search, separator, scroll]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [magnifier.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [magnifier.centerYAnchor constraintEqualToAnchor:_search.centerYAnchor],
        [_search.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [_search.leadingAnchor constraintEqualToAnchor:magnifier.trailingAnchor constant:10],
        [_search.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [separator.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:12],
        [separator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [separator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [scroll.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:6],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-6],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-8],
    ]];

    if (_retro) {
        const gw::bitmap::Scheme &colors = RetroColors();
        CGFloat pixel = GWChromePixel();
        magnifier.hidden = YES;
        separator.hidden = YES;
        _search.font = GWPixelFont(pixel);
        _search.textColor = GWColor(colors.barText);
        GWRetroBox *box = [[GWRetroBox alloc] initWithFrame:NSMakeRect(0, 0, kPaletteWidth + extra, height + extra)];
        box.fillColor = GWColor(colors.bar);
        box.lineColor = GWColor(colors.barText);
        content.translatesAutoresizingMaskIntoConstraints = YES;
        content.frame = box.contentRect;
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [box addSubview:content];
        _panel.contentView = box;
        return;
    }
    GWShadowedGlass *container = [[GWShadowedGlass alloc] initWithCornerRadius:24];
    container.glass.contentView = content;
    _panel.contentView = container;
}

// MARK: Showing and hiding

- (void)showOverWindow:(NSWindow *)window
           placeholder:(NSString *)placeholder
              provider:(NSArray<GWPaletteItem *> *(^)(NSString *))provider {
    if (_panel != nil && _retro != GWServices.shared.settings.bitmapMode) {
        _panel = nil;  // built for the other look
    }
    if (!_panel) {
        [self buildPanel];
    }
    _provider = [provider copy];
    if (_retro) {
        // Rebuilt each time, so a newly chosen color scheme shows straight away.
        GWRetroBox *box = (GWRetroBox *)_panel.contentView;
        box.fillColor = GWColor(RetroColors().bar);
        box.lineColor = GWColor(RetroColors().barText);
        box.needsDisplay = YES;
        _search.textColor = GWColor(RetroColors().barText);
        _search.placeholderAttributedString = [[NSAttributedString alloc]
            initWithString:placeholder attributes:GWPixelPlainAttributes(GWChromePixel(), GWColor(RetroColors().barDim))];
    } else {
        _search.placeholderString = placeholder;
    }
    _search.stringValue = @"";
    _panel.appearance = window.effectiveAppearance;
    [self reload];

    // Centered horizontally, near the top of the window, like VS Code and Zed.
    NSRect frame = window.frame;
    CGFloat pad = self.padding;
    NSPoint topLeft = NSMakePoint(NSMidX(frame) - kPaletteWidth / 2 - pad, NSMaxY(frame) - 70 + pad);
    [_panel setFrameTopLeftPoint:topLeft];
    [window addChildWindow:_panel ordered:NSWindowAbove];
    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_search];
}

- (void)close {
    BOOL wasShowing = self.isShowing;
    [_panel.parentWindow removeChildWindow:_panel];
    [_panel orderOut:nil];
    void (^handler)(void) = _dismissHandler;
    _dismissHandler = nil;
    if (handler != nil && wasShowing && !_itemWasRun) {
        dispatch_async(dispatch_get_main_queue(), handler);
    }
}

- (void)showOverWindow:(NSWindow *)window
           placeholder:(NSString *)placeholder
              provider:(NSArray<GWPaletteItem *> * (^)(NSString *query))provider
             onDismiss:(void (^)(void))onDismiss {
    // A newer question replaces an older one that is still showing: the older one is dismissed.
    void (^previous)(void) = _dismissHandler;
    _dismissHandler = nil;
    if (previous != nil && !_itemWasRun) {
        dispatch_async(dispatch_get_main_queue(), previous);
    }
    [self showOverWindow:window placeholder:placeholder provider:provider];
    _dismissHandler = [onDismiss copy];
    _itemWasRun = NO;
}

- (void)refresh {
    if (self.isShowing) {
        [self reload];
    }
}

- (BOOL)isShowing { return _panel != nil && _panel.isVisible; }

- (NSString *)query { return _search.stringValue ?: @""; }

- (void)windowDidResignKey:(NSNotification *)notification {
    [self close];  // clicking anywhere else dismisses it
}

// MARK: Filtering

- (void)reload {
    _items = _provider ? _provider(_search.stringValue) : @[];
    [_table reloadData];
    if (_items.count > 0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_table scrollRowToVisible:0];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self reload];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command == @selector(moveDown:)) {
        [self moveSelectionBy:1];
        return YES;
    }
    if (command == @selector(moveUp:)) {
        [self moveSelectionBy:-1];
        return YES;
    }
    if (command == @selector(insertNewline:)) {
        [self runSelected];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        [self close];
        return YES;
    }
    return NO;
}

- (void)moveSelectionBy:(NSInteger)delta {
    if (_items.count == 0) {
        return;
    }
    NSInteger count = static_cast<NSInteger>(_items.count);
    NSInteger row = (_table.selectedRow + delta + count) % count;
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)] byExtendingSelection:NO];
    [_table scrollRowToVisible:row];
}

- (void)runSelected {
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= static_cast<NSInteger>(_items.count)) {
        return;
    }
    GWPaletteItem *item = _items[static_cast<NSUInteger>(row)];
    _itemWasRun = YES;
    [self close];
    // Run once the palette is gone, so commands reach the editor window, not the palette.
    if (item.run) {
        dispatch_async(dispatch_get_main_queue(), item.run);
    }
}

// MARK: Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(_items.count);
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return _retro ? [GWRetroPaletteRowView new] : [GWPaletteRowView new];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (!_retro) {
        return;
    }
    // The selected row's text takes the highlight's color, so the visible rows are redrawn.
    NSRange visible = [_table rowsInRect:_table.visibleRect];
    if (visible.length > 0) {
        [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:visible] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    GWPaletteItem *item = _items[static_cast<NSUInteger>(row)];

    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"row" owner:self];
    NSTextField *shortcut = nil;
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"row";
        NSImageView *icon = [NSImageView new];
        NSTextField *text = [NSTextField labelWithString:@""];
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        text.maximumNumberOfLines = 1;   // a long subtitle is cut off, never wrapped into the next row
        text.usesSingleLineMode = YES;
        shortcut = [NSTextField labelWithString:@""];
        shortcut.identifier = @"shortcut";
        shortcut.textColor = NSColor.secondaryLabelColor;
        shortcut.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        for (NSView *view in @[icon, text, shortcut]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:view];
        }
        cell.imageView = icon;
        cell.textField = text;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [text.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [shortcut.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
            [shortcut.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [text.trailingAnchor constraintLessThanOrEqualToAnchor:shortcut.leadingAnchor constant:-12],
        ]];
    } else {
        for (NSView *view in cell.subviews) {
            if ([view.identifier isEqualToString:@"shortcut"]) {
                shortcut = (NSTextField *)view;
            }
        }
    }

    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
    cell.imageView.image = [[NSImage imageWithSystemSymbolName:item.symbol accessibilityDescription:nil]
                            imageWithSymbolConfiguration:configuration];
    cell.imageView.contentTintColor = item.symbolColor;
    cell.imageView.hidden = _retro;
    if (_retro) {
        BOOL selected = row == tableView.selectedRow;
        cell.textField.attributedStringValue = [self retroTitleFor:item selected:selected];
        const gw::bitmap::Scheme &colors = RetroColors();
        shortcut.attributedStringValue = [[NSAttributedString alloc]
            initWithString:item.shortcut ?: @""
                attributes:GWPixelPlainAttributes(GWChromePixel(), GWColor(selected ? colors.barHighlightText : colors.barDim))];
        return cell;
    }
    cell.textField.attributedStringValue = [self attributedTitleFor:item];
    shortcut.stringValue = item.shortcut ?: @"";
    return cell;
}

/// Pixel text: matched letters in the hotkey color, like the menus' hotkeys, and the subtitle dimmed.
- (NSAttributedString *)retroTitleFor:(GWPaletteItem *)item selected:(BOOL)selected {
    const gw::bitmap::Scheme &colors = RetroColors();
    CGFloat pixel = GWChromePixel();
    NSColor *ink = GWColor(selected ? colors.barHighlightText : colors.barText);
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:item.title
                                                                             attributes:GWPixelPlainAttributes(pixel, ink)];
    NSColor *hotkey = GWColor(colors.barHotkey);
    [item.matchedIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        if (index < item.title.length) {
            [text addAttribute:NSForegroundColorAttributeName value:hotkey range:NSMakeRange(index, 1)];
        }
    }];
    if (item.subtitle.length > 0) {
        NSString *subtitle = [@"  " stringByAppendingString:item.subtitle];
        NSColor *dim = GWColor(selected ? colors.barHighlightText : colors.barDim);
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:subtitle attributes:GWPixelPlainAttributes(pixel, dim)]];
    }
    return text;
}

/// Title with the matched characters in bold accent color, then the subtitle, dimmed.
- (NSAttributedString *)attributedTitleFor:(GWPaletteItem *)item {
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:item.title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor,
    }];
    [item.matchedIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        if (index < item.title.length) {
            [text addAttributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: NSColor.controlAccentColor,
            } range:NSMakeRange(index, 1)];
        }
    }];
    if (item.subtitle.length > 0) {
        NSString *subtitle = [@"   " stringByAppendingString:item.subtitle];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:subtitle attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        }]];
    }
    return text;
}

@end
