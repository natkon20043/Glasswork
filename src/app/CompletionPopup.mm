#import "CompletionPopup.h"
#import "Strings.h"

#import "MarkdownView.h"
#import "PixelArt.h"
#import "Services.h"
#import "ShadowedGlass.h"

#import <objc/runtime.h>

#include "BitmapMode.hpp"
#include "CompletionRank.hpp"
#include "Fuzzy.hpp"

#include <algorithm>
#include <vector>

@implementation GWSuggestion
@end

// ---------------------------------------------------------------------------
// MARK: The list

namespace {

constexpr CGFloat kRowHeight = 24;
constexpr NSUInteger kMaxVisibleRows = 10;
constexpr CGFloat kPopupWidth = 400;

/// SF Symbol and color for a CompletionItemKind.
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

/// Bitmap mode draws popups as flat maroon boxes of pixel text instead of glass.
BOOL UsesBitmapLook() {
    return GWServices.shared.settings.bitmapMode;
}

/// One line of a Markdown answer as plain text, and whether it was code.
struct PlainLine {
    NSString *text;
    bool code = false;
};

/// Markdown reduced to plain lines for pixel text: fences, emphasis marks and heading marks go,
/// code keeps its own lines.
std::vector<PlainLine> PlainLinesOf(NSString *markdown) {
    std::vector<PlainLine> lines;
    bool inCode = false;
    for (NSString *raw in [markdown componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByReplacingOccurrencesOfString:@"\t" withString:@"    "];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"```"]) {
            inCode = !inCode;
            continue;
        }
        if (!inCode) {
            if ([trimmed isEqualToString:@"---"] || [trimmed isEqualToString:@"***"]) {
                line = @"";
            }
            while ([line hasPrefix:@"#"]) {
                line = [line substringFromIndex:1];
            }
            for (NSString *mark in @[@"**", @"__", @"`"]) {
                line = [line stringByReplacingOccurrencesOfString:mark withString:@""];
            }
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        // No more than one empty line in a row, and none at the start.
        if (line.length == 0 && (lines.empty() || lines.back().text.length == 0)) {
            continue;
        }
        lines.push_back({line, inCode});
    }
    while (!lines.empty() && lines.back().text.length == 0) {
        lines.pop_back();
    }
    return lines;
}

/// Code lines start at the edge and the rest one character in. Returns whether the first line is
/// code (a signature), which then goes on the box's title strip.
BOOL AddPlainLines(GWRetroTextView *view, NSString *markdown, NSColor *color) {
    std::vector<PlainLine> lines = PlainLinesOf(markdown);
    for (const PlainLine &line : lines) {
        [view addLine:line.text color:color indent:line.code ? 0 : 1];
    }
    return !lines.empty() && lines.front().code;
}

/// The colors of the chosen scheme's dialogs.
const gw::bitmap::Scheme &Colors() {
    return GWServices.shared.bitmapScheme;
}

void StyleRetroBox(GWRetroBox *box) {
    box.fillColor = GWColor(Colors().bar);
    box.lineColor = GWColor(Colors().barText);
}

/// A grey box holding `text`, sized to it, the way the old IDEs drew their dialogs.
GWRetroBox *RetroBoxAround(GWRetroTextView *text, NSUInteger columns, NSUInteger maxLines) {
    NSSize size = [GWRetroBox sizeForContentSize:[text fittingSizeForColumns:columns maxLines:maxLines]];
    GWRetroBox *box = [[GWRetroBox alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    StyleRetroBox(box);
    text.bandColor = GWColor(Colors().dialogTitle);
    text.bandTextColor = GWColor(Colors().dialogTitleText);
    text.frame = box.contentRect;
    text.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;  // the title strip spans the box
    [box addSubview:text];
    return box;
}

}  // namespace

/// A table row whose selection is a flat band, for bitmap mode.
@interface GWRetroRowView : NSTableRowView
@end

@implementation GWRetroRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [GWColor(Colors().barHighlight) setFill];
    NSRectFill(self.bounds);
}
@end

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
    std::vector<gw::CompletionCandidate> _candidates;  // one per item in _allItems, for ranking
    gw::CompletionHistory _history;
    GWSuggestionPanel *_docPanel;
    NSViewController *_docController;
    BOOL _panelIsRetro;  // the panel was built for bitmap mode
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

/// The margin around the visible box: the glass's shadow, or nothing for a bitmap box (whose hard
/// shadow is part of its own view).
- (CGFloat)panelPadding {
    return _panelIsRetro ? 0 : GWShadowedGlass.padding;
}

/// The list's visible box on screen, without any shadow.
- (NSRect)listBodyFrame {
    NSRect frame = _panel.frame;
    if (_panelIsRetro) {
        CGFloat shadow = GWRetroBox.shadowSize;
        return NSMakeRect(NSMinX(frame), NSMinY(frame) + shadow, NSWidth(frame) - shadow, NSHeight(frame) - shadow);
    }
    CGFloat pad = GWShadowedGlass.padding;
    return NSInsetRect(frame, pad, pad);
}

- (void)buildPanelIfNeeded {
    BOOL retro = UsesBitmapLook();
    if (_panel != nil && _panelIsRetro == retro) {
        return;
    }
    if (_panel != nil) {
        // The look changed: start again with a panel of the new kind.
        [self hide];
        _panel = nil;
        _docPanel = nil;
    }
    _panelIsRetro = retro;
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

    if (retro) {
        GWRetroBox *box = [[GWRetroBox alloc] initWithFrame:NSMakeRect(0, 0, kPopupWidth + GWRetroBox.shadowSize, 200)];
        StyleRetroBox(box);
        _scroll.frame = box.contentRect;
        _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _scroll.contentInsets = NSEdgeInsetsZero;
        [box addSubview:_scroll];
        _panel.contentView = box;
        return;
    }
    container.glass.contentView = _scroll;
    _panel.contentView = container;
}

- (void)setItems:(NSArray<GWSuggestion *> *)items {
    _allItems = [items copy];
    _shownItems = _allItems;
    [_table reloadData];
    _candidates.clear();
    _candidates.reserve(_allItems.count);
    for (GWSuggestion *item in _allItems) {
        gw::CompletionCandidate candidate;
        candidate.label = item.label.UTF8String ?: "";
        candidate.filterText = item.filterText.UTF8String ?: "";
        candidate.sortText = item.sortText.UTF8String ?: "";
        candidate.kind = static_cast<int>(item.kind);
        candidate.deprecated = item.deprecated;
        candidate.preselect = item.preselect;
        _candidates.push_back(std::move(candidate));
    }
}

- (void)recordAccepted:(GWSuggestion *)item {
    _history.accepted(item.label.UTF8String ?: "", static_cast<int>(item.kind));
}

- (GWSuggestion *)selectedSuggestion {
    NSInteger row = _table.selectedRow;
    if (!self.visible || row < 0 || row >= static_cast<NSInteger>(_shownItems.count)) {
        return nil;
    }
    return _shownItems[static_cast<NSUInteger>(row)];
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
    [self hideDocumentation];
    _prefix = @"";
}

/// Sizes and places the panel for the items now shown.
- (void)refreshLayout {
    [_table reloadData];
    if (_shownItems.count > 0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_table scrollRowToVisible:0];
    }
    [self selectionMayHaveChanged];
    NSUInteger rows = std::min(_shownItems.count, kMaxVisibleRows);
    CGFloat height = rows * kRowHeight + (_panelIsRetro ? 8 * GWChromePixel() : 8);
    NSRect frame = NSMakeRect(NSMinX(_anchorRect) - 30, NSMinY(_anchorRect) - height - 2, kPopupWidth, height);
    NSScreen *screen = _panel.parentWindow.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    if (NSMinY(frame) < NSMinY(visible)) {
        frame.origin.y = NSMaxY(_anchorRect) + 2;  // no room below: go above the caret
    }
    frame.origin.x = std::min(frame.origin.x, NSMaxX(visible) - kPopupWidth - 8);
    if (_panelIsRetro) {
        // The box's hard shadow hangs below and to the right of it.
        CGFloat shadow = GWRetroBox.shadowSize;
        [_panel setFrame:NSMakeRect(NSMinX(frame), NSMinY(frame) - shadow, NSWidth(frame) + shadow, NSHeight(frame) + shadow) display:YES];
        return;
    }
    // The panel is larger than the glass by the shadow margin on every side.
    CGFloat pad = self.panelPadding;
    [_panel setFrame:NSInsetRect(frame, -pad, -pad) display:YES];
}

- (void)filterWithPrefix:(NSString *)prefix {
    _prefix = [prefix copy];
    std::string query = prefix.UTF8String ?: "";

    // Ranking lives in the core (CompletionRank): fuzzy match, start-of-name and case bonuses,
    // recently used names and deprecation, with the server's sort text breaking ties.
    std::vector<size_t> order = gw::rankCompletions(query, _candidates, _history);
    NSMutableArray<GWSuggestion *> *sorted = [NSMutableArray arrayWithCapacity:order.size()];
    for (size_t index : order) {
        [sorted addObject:_allItems[index]];
    }
    _shownItems = sorted;
    // The table must always agree with the list: if nothing matches, the popup hides but the
    // table still holds the old rows, and its next layout would ask for a row that no longer exists.
    [_table reloadData];

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
    if (count == 0) {
        return;
    }
    NSInteger next = _table.selectedRow + delta;
    if (next < 0) {
        next = count - 1;
    }
    if (next >= count) {
        next = 0;
    }
    if (std::abs(delta) > 1) {
        next = std::max<NSInteger>(0, std::min<NSInteger>(count - 1, _table.selectedRow + delta));
    }
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(next)] byExtendingSelection:NO];
    [_table scrollRowToVisible:next];
    [self selectionMayHaveChanged];
}

// ---- Documentation beside the list

- (void)selectionMayHaveChanged {
    if (_panelIsRetro) {
        // The selected row's text takes the highlight's color, so the rows around it are redrawn.
        NSRange visible = [_table rowsInRect:_table.visibleRect];
        if (visible.length > 0) {
            [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:visible] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
        }
    }
    GWSuggestion *item = self.selectedSuggestion;
    if (item == nil) {
        [self hideDocumentation];
        return;
    }
    [self showDocumentationFor:item];
    if (self.onSelectionChanged) {
        self.onSelectionChanged(item);
    }
}

- (void)documentationChangedForSuggestion:(GWSuggestion *)item {
    if (item == self.selectedSuggestion) {
        [self showDocumentationFor:item];
    }
}

- (void)hideDocumentation {
    [_docPanel.parentWindow removeChildWindow:_docPanel];
    [_docPanel orderOut:nil];
}

/// A second panel to the right of the list (or the left, when there is no room): the item's
/// signature, then its documentation. Hidden when the server has nothing to say about it.
- (void)showDocumentationFor:(GWSuggestion *)item {
    NSString *signature = item.detail ?: @"";
    NSString *documentation = item.documentation ?: @"";
    if (signature.length == 0 && documentation.length == 0) {
        [self hideDocumentation];
        return;
    }
    constexpr CGFloat kDocWidth = 380;
    if (documentation.length > 3000) {
        documentation = [PrefixOfString(documentation, 3000) stringByAppendingString:@"\n\n…"];
    }
    if (_panelIsRetro) {
        [self showRetroDocumentationSignature:signature documentation:documentation];
        return;
    }

    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    if (signature.length > 0) {
        NSTextField *label = [NSTextField wrappingLabelWithString:signature];
        label.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        label.preferredMaxLayoutWidth = kDocWidth - 28;
        [stack addArrangedSubview:label];
    }
    if (documentation.length > 0) {
        GWMarkdownView *body = [GWMarkdownView new];
        body.fontSize = 12.5;
        [body setMarkdown:documentation];
        body.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:body];
        [body.widthAnchor constraintEqualToConstant:kDocWidth - 28].active = YES;
    }
    [stack layoutSubtreeIfNeeded];
    NSSize fitting = stack.fittingSize;
    NSSize size = NSMakeSize(kDocWidth, std::min<CGFloat>(std::max<CGFloat>(fitting.height, 40), 320));

    [self makeDocumentationPanelIfNeeded];
    GWShadowedGlass *container = [[GWShadowedGlass alloc] initWithCornerRadius:12];
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = stack;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    container.glass.contentView = scroll;
    _docPanel.contentView = container;

    [self placeDocumentationPanelWithSize:size];
}

/// The documentation as pixel text in a grey box, the signature on its title strip, for bitmap mode.
- (void)showRetroDocumentationSignature:(NSString *)signature documentation:(NSString *)documentation {
    [self makeDocumentationPanelIfNeeded];
    GWRetroTextView *text = [GWRetroTextView new];
    if (signature.length > 0) {
        [text addLine:signature color:GWColor(Colors().barText) indent:0];
        text.bandLines = 1;
    }
    AddPlainLines(text, documentation, GWColor(Colors().barText));
    GWRetroBox *box = RetroBoxAround(text, 44, 24);
    _docPanel.contentView = box;
    [self placeDocumentationPanelWithSize:box.frame.size];
}

- (void)makeDocumentationPanelIfNeeded {
    if (_docPanel != nil) {
        return;
    }
    _docPanel = [[GWSuggestionPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 100)
                                                     styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                       backing:NSBackingStoreBuffered
                                                         defer:YES];
    _docPanel.opaque = NO;
    _docPanel.backgroundColor = NSColor.clearColor;
    _docPanel.hasShadow = NO;
    _docPanel.level = NSFloatingWindowLevel;
    _docPanel.hidesOnDeactivate = YES;
    _docPanel.releasedWhenClosed = NO;
}

/// Beside the list, level with its top (or to its left when there's no room on the right).
- (void)placeDocumentationPanelWithSize:(NSSize)size {
    CGFloat pad = self.panelPadding;
    NSRect listGlass = [self listBodyFrame];
    NSScreen *screen = _panel.parentWindow.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat x = NSMaxX(listGlass) + 6;
    if (x + size.width > NSMaxX(visible) - 8) {
        x = NSMinX(listGlass) - 6 - size.width;
    }
    CGFloat y = NSMaxY(listGlass) - size.height;
    NSRect frame = NSMakeRect(x, std::max(y, NSMinY(visible) + 8), size.width, size.height);
    [_docPanel setFrame:NSInsetRect(frame, -pad, -pad) display:YES];
    if (_docPanel.parentWindow != _panel.parentWindow) {
        [_docPanel.parentWindow removeChildWindow:_docPanel];
        [_panel.parentWindow addChildWindow:_docPanel ordered:NSWindowAbove];
    }
    [_docPanel orderFront:nil];
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

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return _panelIsRetro ? [GWRetroRowView new] : nil;
}

/// A row of pixel text: the name, and the detail dimmer at the right.
- (NSView *)retroCellForRow:(NSInteger)row tableView:(NSTableView *)tableView {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"completionRetro" owner:self];
    if (cell == nil) {
        cell = [NSTableCellView new];
        cell.identifier = @"completionRetro";
        NSTextField *label = [NSTextField labelWithString:@""];
        NSTextField *detail = [NSTextField labelWithString:@""];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        detail.lineBreakMode = NSLineBreakByTruncatingTail;
        detail.alignment = NSTextAlignmentRight;
        for (NSView *view in @[label, detail]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:view];
        }
        cell.textField = label;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
        [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:12],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:12],
            [detail.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
            [detail.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        objc_setAssociatedObject(cell, "detail", detail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (row < 0 || row >= static_cast<NSInteger>(_shownItems.count)) {
        return cell;
    }
    GWSuggestion *item = _shownItems[static_cast<NSUInteger>(row)];
    CGFloat pixel = GWChromePixel();
    // On the selected row the text takes the highlight's own color.
    BOOL selected = row == tableView.selectedRow;
    NSColor *color = item.deprecated ? GWColor(Colors().barDim) : GWColor(selected ? Colors().barHighlightText : Colors().barText);
    cell.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:item.label attributes:GWPixelPlainAttributes(pixel, color)];
    NSTextField *detail = objc_getAssociatedObject(cell, "detail");
    detail.attributedStringValue = [[NSAttributedString alloc] initWithString:item.detail ?: @""
                                                                   attributes:GWPixelPlainAttributes(pixel, GWColor(Colors().barDim))];
    return cell;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (_panelIsRetro) {
        return [self retroCellForRow:row tableView:tableView];
    }
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
    // Never read past the end of the list, even if the table is briefly out of date.
    if (row < 0 || row >= static_cast<NSInteger>(_shownItems.count)) {
        return cell;
    }
    GWSuggestion *item = _shownItems[static_cast<NSUInteger>(row)];
    NSString *symbol = nil;
    NSColor *color = nil;
    iconForKind(item.kind, &symbol, &color);
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
    cell.imageView.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
    cell.imageView.contentTintColor = color;
    if (item.deprecated) {
        NSDictionary *struck = @{NSStrikethroughStyleAttributeName: @(NSUnderlineStyleSingle),
                                 NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
        cell.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:item.label attributes:struck];
    } else {
        cell.textField.stringValue = item.label;
    }
    NSTextField *detail = objc_getAssociatedObject(cell, "detail");
    detail.stringValue = item.detail ?: @"";
    return cell;
}

@end

// ---------------------------------------------------------------------------
// MARK: Hover

static NSPopover *gHoverPopover = nil;
static GWSuggestionPanel *gRetroHover = nil;  // bitmap mode's hover box

@implementation GWHoverPopover

+ (void)hide {
    [gHoverPopover close];
    gHoverPopover = nil;
    [gRetroHover.parentWindow removeChildWindow:gRetroHover];
    [gRetroHover orderOut:nil];
}

/// Bitmap mode: problems and the hover text as pixel lines in a grey box just under the word.
+ (void)showRetroMarkdown:(NSString *)markdown problems:(NSArray<NSString *> *)problems relativeToRect:(NSRect)rect ofView:(NSView *)view {
    NSWindow *parent = view.window;
    if (parent == nil) {
        return;
    }
    GWRetroTextView *text = [GWRetroTextView new];
    for (NSString *problem in problems) {
        [text addLine:problem color:GWColor(Colors().barHotkey) indent:0];
    }
    if (markdown.length > 0 && AddPlainLines(text, markdown, GWColor(Colors().barText)) && problems.count == 0) {
        text.bandLines = 1;  // the declaration on the title strip
    }
    GWRetroBox *box = RetroBoxAround(text, 56, 20);
    NSSize size = box.frame.size;

    if (gRetroHover == nil) {
        gRetroHover = [[GWSuggestionPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100)
                                                           styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                             backing:NSBackingStoreBuffered
                                                               defer:YES];
        gRetroHover.opaque = NO;
        gRetroHover.backgroundColor = NSColor.clearColor;  // the box's shadow leaves its corners empty
        gRetroHover.hasShadow = NO;
        gRetroHover.level = NSFloatingWindowLevel;
        gRetroHover.hidesOnDeactivate = YES;
        gRetroHover.releasedWhenClosed = NO;
    }
    gRetroHover.contentView = box;
    NSRect word = [parent convertRectToScreen:[view convertRect:rect toView:nil]];
    NSRect visible = (parent.screen ?: NSScreen.mainScreen).visibleFrame;
    NSRect frame = NSMakeRect(NSMinX(word), NSMinY(word) - 4 - size.height, size.width, size.height);
    if (NSMinY(frame) < NSMinY(visible)) {
        frame.origin.y = NSMaxY(word) + 4;  // no room below: above the word
    }
    frame.origin.x = std::max(NSMinX(visible) + 4, std::min(NSMinX(frame), NSMaxX(visible) - size.width - 4));
    [gRetroHover setFrame:frame display:YES];
    if (gRetroHover.parentWindow != parent) {
        [gRetroHover.parentWindow removeChildWindow:gRetroHover];
        [parent addChildWindow:gRetroHover ordered:NSWindowAbove];
    }
    [gRetroHover orderFront:nil];
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
        markdown = [PrefixOfString(markdown, 2400) stringByAppendingString:@"\n\n…"];
    }
    if (UsesBitmapLook()) {
        [self showRetroMarkdown:markdown problems:problems relativeToRect:rect ofView:view];
        return;
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
    NSWindow *parent = view.window;
    NSResponder *typing = parent.firstResponder;
    [popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMaxY];
    // The bubble's own window may take the keys, and then nothing typed reaches the editor until it
    // is clicked. A hint is only to be read, so the editor keeps the keyboard, now and a moment later
    // (the window can claim it after this returns).
    auto giveBackTheKeyboard = ^{
        if (parent.isKeyWindow && parent.firstResponder == typing) {
            return;
        }
        [parent makeKeyWindow];
        if (typing != nil) {
            [parent makeFirstResponder:typing];
        }
    };
    giveBackTheKeyboard();
    dispatch_async(dispatch_get_main_queue(), giveBackTheKeyboard);
}

@end
