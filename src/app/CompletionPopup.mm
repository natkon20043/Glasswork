#import "CompletionPopup.h"

#import "MarkdownView.h"
#import "ShadowedGlass.h"

#import <objc/runtime.h>

#include "Fuzzy.hpp"

#include <algorithm>

@implementation GWSuggestion
@end

// ---------------------------------------------------------------------------
// MARK: The list

namespace {

constexpr CGFloat kRowHeight = 24;
constexpr NSUInteger kMaxVisibleRows = 10;
constexpr CGFloat kPopupWidth = 400;

/// SF Symbol and colour for a CompletionItemKind.
void iconForKind(NSInteger kind, NSString **symbol, NSColor **color) {
    switch (kind) {
        case 2: case 3: case 4:
            *symbol = @"f.square.fill";
            *color = NSColor.systemPurpleColor;
            break;
        case 5: case 10:
            *symbol = @"p.square.fill";
            *color = NSColor.systemTealColor;
            break;
        case 6: case 12:
            *symbol = @"v.square.fill";
            *color = NSColor.systemBlueColor;
            break;
        case 7: case 8: case 25:
            *symbol = @"c.square.fill";
            *color = NSColor.systemOrangeColor;
            break;
        case 22:
            *symbol = @"s.square.fill";
            *color = NSColor.systemOrangeColor;
            break;
        case 9:
            *symbol = @"m.square.fill";
            *color = NSColor.systemIndigoColor;
            break;
        case 13: case 20:
            *symbol = @"e.square.fill";
            *color = NSColor.systemYellowColor;
            break;
        case 14:
            *symbol = @"k.square.fill";
            *color = NSColor.systemPinkColor;
            break;
        case 21:
            *symbol = @"c.square.fill";
            *color = NSColor.systemMintColor;
            break;
        case 15:
            *symbol = @"text.append";
            *color = NSColor.secondaryLabelColor;
            break;
        default:
            *symbol = @"circle.fill";
            *color = NSColor.tertiaryLabelColor;
            break;
    }
}

}  // namespace

/// A borderless panel that can never become key, so typing keeps going to the editor.
@interface GWSuggestionPanel : NSPanel
@end

@implementation GWSuggestionPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface GWSuggestionPopup () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation GWSuggestionPopup {
    NSArray<GWSuggestion *> *_allItems;
    NSArray<GWSuggestion *> *_shownItems;
    GWSuggestionPanel *_panel;
    NSTableView *_table;
    NSScrollView *_scroll;
    NSRect _anchorRect;
    NSString *_prefix;
}

- (instancetype)init {
    if ((self = [super init])) {
        _allItems = @[];
        _shownItems = @[];
        _prefix = @"";
    }
    return self;
}

- (BOOL)visible { return _panel != nil && _panel.isVisible; }
- (NSUInteger)itemCount { return _allItems.count; }

- (void)buildPanelIfNeeded {
    if (_panel != nil) {
        return;
    }
    _panel = [[GWSuggestionPanel alloc] initWithContentRect:NSMakeRect(0, 0, kPopupWidth, 200)
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = NO;  // drawn by GWShadowedGlass, without an outline at the corners
    _panel.level = NSFloatingWindowLevel;
    _panel.hidesOnDeactivate = YES;
    _panel.releasedWhenClosed = NO;

    GWShadowedGlass *container = [[GWShadowedGlass alloc] initWithCornerRadius:12];

    _table = [NSTableView new];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = kRowHeight;
    _table.intercellSpacing = NSMakeSize(0, 0);
    _table.backgroundColor = NSColor.clearColor;
    _table.style = NSTableViewStylePlain;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.action = @selector(rowClicked:);
    _table.allowsEmptySelection = NO;

    _scroll = [NSScrollView new];
    _scroll.documentView = _table;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.automaticallyAdjustsContentInsets = NO;
    _scroll.contentInsets = NSEdgeInsetsMake(4, 0, 4, 0);

    container.glass.contentView = _scroll;
    _panel.contentView = container;
}

- (void)setItems:(NSArray<GWSuggestion *> *)items {
    _allItems = [items copy];
    _shownItems = _allItems;
}

- (void)showBelowScreenRect:(NSRect)rect parentWindow:(NSWindow *)window {
    _anchorRect = rect;
    [self buildPanelIfNeeded];
    if (_panel.parentWindow != window) {
        [_panel.parentWindow removeChildWindow:_panel];
        [window addChildWindow:_panel ordered:NSWindowAbove];
    }
    [self refreshLayout];
    [_panel orderFront:nil];
}

- (void)hide {
    [_panel.parentWindow removeChildWindow:_panel];
    [_panel orderOut:nil];
    _prefix = @"";
}

/// Sizes and places the panel for the items now shown.
- (void)refreshLayout {
    [_table reloadData];
    if (_shownItems.count > 0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_table scrollRowToVisible:0];
    }
    NSUInteger rows = std::min(_shownItems.count, kMaxVisibleRows);
    CGFloat height = rows * kRowHeight + 8;
    NSRect frame = NSMakeRect(NSMinX(_anchorRect) - 30, NSMinY(_anchorRect) - height - 2, kPopupWidth, height);
    NSScreen *screen = _panel.parentWindow.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    if (NSMinY(frame) < NSMinY(visible)) {
        frame.origin.y = NSMaxY(_anchorRect) + 2;  // no room below: go above the caret
    }
    frame.origin.x = std::min(frame.origin.x, NSMaxX(visible) - kPopupWidth - 8);
    // The panel is larger than the glass by the shadow margin on every side.
    CGFloat pad = GWShadowedGlass.padding;
    [_panel setFrame:NSInsetRect(frame, -pad, -pad) display:YES];
}

- (void)filterWithPrefix:(NSString *)prefix {
    _prefix = [prefix copy];
    std::string query = prefix.UTF8String ?: "";
    if (query.empty()) {
        _shownItems = _allItems;
    } else {
        // Keep what matches the letters typed. Names that start with them come first; within
        // each group the server's own order (its idea of relevance) is kept.
        NSMutableArray<GWSuggestion *> *prefixMatches = [NSMutableArray array];
        NSMutableArray<GWSuggestion *> *otherMatches = [NSMutableArray array];
        for (GWSuggestion *item in _allItems) {
            std::string candidate = item.filterText.UTF8String ?: "";
            std::optional<int> score = gw::fuzzyScore(query, candidate);
            if (!score) {
                continue;
            }
            BOOL startsWithQuery = [item.filterText rangeOfString:prefix options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound;
            [(startsWithQuery ? prefixMatches : otherMatches) addObject:item];
        }
        NSComparator bySortText = ^NSComparisonResult(GWSuggestion *a, GWSuggestion *b) {
            return [a.sortText compare:b.sortText];
        };
        [prefixMatches sortUsingComparator:bySortText];
        [otherMatches sortUsingComparator:bySortText];
        NSMutableArray<GWSuggestion *> *sorted = [NSMutableArray arrayWithArray:prefixMatches];
        [sorted addObjectsFromArray:otherMatches];
        if (sorted.count > 200) {
            [sorted removeObjectsInRange:NSMakeRange(200, sorted.count - 200)];
        }
        _shownItems = sorted;
    }
    if (_shownItems.count == 0) {
        [self hide];
        return;
    }
    if (self.visible) {
        [self refreshLayout];
    }
}

- (void)rowClicked:(id)sender {
    NSInteger row = _table.clickedRow;
    if (row >= 0 && row < static_cast<NSInteger>(_shownItems.count) && self.onAccept) {
        self.onAccept(_shownItems[static_cast<NSUInteger>(row)]);
    }
}

- (void)moveSelectionBy:(NSInteger)delta {
    NSInteger count = static_cast<NSInteger>(_shownItems.count);
    if (count == 0) return;
    NSInteger next = _table.selectedRow + delta;
    if (next < 0) next = count - 1;
    if (next >= count) next = 0;
    if (std::abs(delta) > 1) {
        next = std::max<NSInteger>(0, std::min<NSInteger>(count - 1, _table.selectedRow + delta));
    }
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(next)] byExtendingSelection:NO];
    [_table scrollRowToVisible:next];
}

- (BOOL)handleSelector:(SEL)selector {
    if (!self.visible) {
        return NO;
    }
    if (selector == @selector(moveDown:)) {
        [self moveSelectionBy:1];
        return YES;
    }
    if (selector == @selector(moveUp:)) {
        [self moveSelectionBy:-1];
        return YES;
    }
    if (selector == @selector(pageDown:) || selector == @selector(scrollPageDown:)) {
        [self moveSelectionBy:8];
        return YES;
    }
    if (selector == @selector(pageUp:) || selector == @selector(scrollPageUp:)) {
        [self moveSelectionBy:-8];
        return YES;
    }
    if (selector == @selector(insertNewline:) || selector == @selector(insertTab:)) {
        NSInteger row = _table.selectedRow;
        if (row >= 0 && row < static_cast<NSInteger>(_shownItems.count) && self.onAccept) {
            GWSuggestion *item = _shownItems[static_cast<NSUInteger>(row)];
            [self hide];
            self.onAccept(item);
            return YES;
        }
        return NO;
    }
    if (selector == @selector(cancelOperation:)) {
        [self hide];
        return YES;
    }
    return NO;
}

// ---- Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(_shownItems.count);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"completion" owner:self];
    if (cell == nil) {
        cell = [NSTableCellView new];
        cell.identifier = @"completion";
        NSImageView *icon = [NSImageView new];
        NSTextField *label = [NSTextField labelWithString:@""];
        NSTextField *detail = [NSTextField labelWithString:@""];
        label.font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        detail.font = [NSFont systemFontOfSize:11.5];
        detail.textColor = NSColor.tertiaryLabelColor;
        detail.lineBreakMode = NSLineBreakByTruncatingTail;
        detail.alignment = NSTextAlignmentRight;
        for (NSView *view in @[icon, label, detail]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:view];
        }
        cell.imageView = icon;
        cell.textField = label;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
        [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:15],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:10],
            [detail.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
            [detail.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        objc_setAssociatedObject(cell, "detail", detail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    GWSuggestion *item = _shownItems[static_cast<NSUInteger>(row)];
    NSString *symbol = nil;
    NSColor *color = nil;
    iconForKind(item.kind, &symbol, &color);
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
    cell.imageView.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
    cell.imageView.contentTintColor = color;
    cell.textField.stringValue = item.label;
    NSTextField *detail = objc_getAssociatedObject(cell, "detail");
    detail.stringValue = item.detail ?: @"";
    return cell;
}

@end

// ---------------------------------------------------------------------------
// MARK: Hover

static NSPopover *gHoverPopover = nil;

@implementation GWHoverPopover

+ (void)hide {
    [gHoverPopover close];
    gHoverPopover = nil;
}

+ (void)showMarkdown:(NSString *)markdown
            problems:(NSArray<NSString *> *)problems
      relativeToRect:(NSRect)rect
              ofView:(NSView *)view {
    [self hide];
    if (markdown.length == 0 && problems.count == 0) {
        return;
    }
    if (markdown.length > 2400) {
        markdown = [[markdown substringToIndex:2400] stringByAppendingString:@"\n\n…"];
    }
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);

    for (NSString *problem in problems) {
        NSTextField *label = [NSTextField wrappingLabelWithString:problem];
        label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
        label.textColor = NSColor.systemOrangeColor;
        label.preferredMaxLayoutWidth = 440;
        [stack addArrangedSubview:label];
    }
    if (markdown.length > 0) {
        GWMarkdownView *body = [GWMarkdownView new];
        body.fontSize = 12.5;
        [body setMarkdown:markdown];
        body.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:body];
        [body.widthAnchor constraintEqualToConstant:440].active = YES;
    }
    NSViewController *controller = [NSViewController new];
    controller.view = stack;
    [stack layoutSubtreeIfNeeded];
    NSSize fitting = stack.fittingSize;
    controller.preferredContentSize = NSMakeSize(std::max<CGFloat>(fitting.width, 200), std::min<CGFloat>(fitting.height, 420));

    NSPopover *popover = [NSPopover new];
    popover.contentViewController = controller;
    popover.behavior = NSPopoverBehaviorApplicationDefined;
    popover.animates = NO;
    gHoverPopover = popover;
    [popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMaxY];
}

@end
