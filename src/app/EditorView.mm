#import "EditorView.h"

#include "SelectionExpand.hpp"
#include "TextTransforms.hpp"

#import "Services.h"
#import "StartupTiming.h"

#import <Carbon/Carbon.h>  // key codes (kVK_Escape and the like)
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <map>
#include <set>
#include <cmath>
#include <optional>
#include <unordered_map>

#include "Folding.hpp"
#include "RowMap.hpp"
#include "Wrap.hpp"

/// At the start of a command: with several cursors, runs the whole command once for each
/// (see forEachSelection) and returns.
#define GW_FOR_EACH_CURSOR(...)                                                              \
    if (_multiDepth == 0 && _document && !_document->extraSelections.empty()) {              \
        [self forEachSelection:^{ __VA_ARGS__ } mergingLines:NO];                            \
        return;                                                                              \
    }

/// The same for commands that act on whole lines: cursors on one line count once.
#define GW_FOR_EACH_CURSOR_LINE(...)                                                         \
    if (_multiDepth == 0 && _document && !_document->extraSelections.empty()) {              \
        [self forEachSelection:^{ __VA_ARGS__ } mergingLines:YES];                           \
        return;                                                                              \
    }

namespace {

/// Lines of tokenizing allowed per call while drawing; beyond it, lines draw plain and
/// the highlighter catches up over the next frames instead of stalling the UI.
constexpr size_t kHighlightBudget = 400;
/// Padding between the line-number ruler and the text.
constexpr CGFloat kTextInset = 14;

/// One decoration as it applies to one line: the bytes it covers there and how it looks.
struct LineDecoration {
    size_t startByte = 0;
    size_t endByte = 0;      // clipped to the line's length when drawn
    bool toEndOfLine = false;
    GWDecoration look;       // the colors and styling (its range is the whole decoration's)
    bool showsNote = false;  // the note is drawn on the decoration's last line only
};

/// A laid-out line plus maps between UTF-8 byte offsets (the document's units) and UTF-16
/// offsets (CoreText's units).
struct LineLayout {
    /// A background highlight behind part of the line, in UTF-16 units.
    struct Highlight {
        uint32_t startUnit = 0;
        uint32_t endUnit = 0;
        gw::Color color = 0;
    };

    CTLineRef line = nullptr;
    std::vector<uint32_t> byteToUnit;  // bytes + 1 entries
    std::vector<uint32_t> unitToByte;  // units + 1 entries
    std::vector<Highlight> highlights;
    bool highlighted = false;

    /// Soft wrapping: where each row starts (UTF-16 units, plus the total at the end) and one
    /// CoreText line per row. Both stay empty for a line that fits on one row.
    std::vector<uint32_t> rowStartUnits;
    std::vector<CTLineRef> rowLines;
    CGFloat continuationIndent = 0;

    /// Room opened before a character for an inlay hint (by that character's UTF-16 unit). It is made
    /// with kerning on the character before, and CoreText reports the character's position half way
    /// through that gap, so offsets are corrected by half of it.
    std::map<uint32_t, CGFloat> gapBefore;

    LineLayout() = default;
    LineLayout(const LineLayout &) = delete;
    LineLayout &operator=(const LineLayout &) = delete;
    LineLayout(LineLayout &&other) noexcept
        : line(other.line),
          byteToUnit(std::move(other.byteToUnit)),
          unitToByte(std::move(other.unitToByte)),
          highlights(std::move(other.highlights)),
          highlighted(other.highlighted),
          rowStartUnits(std::move(other.rowStartUnits)),
          rowLines(std::move(other.rowLines)),
          continuationIndent(other.continuationIndent),
          gapBefore(std::move(other.gapBefore)) {
        other.line = nullptr;
        other.rowLines.clear();
    }
    LineLayout &operator=(LineLayout &&other) noexcept {
        if (this != &other) {
            releaseLines();
            line = other.line;
            other.line = nullptr;
            byteToUnit = std::move(other.byteToUnit);
            unitToByte = std::move(other.unitToByte);
            highlights = std::move(other.highlights);
            highlighted = other.highlighted;
            rowStartUnits = std::move(other.rowStartUnits);
            rowLines = std::move(other.rowLines);
            other.rowLines.clear();
            continuationIndent = other.continuationIndent;
            gapBefore = std::move(other.gapBefore);
        }
        return *this;
    }
    ~LineLayout() { releaseLines(); }

    void releaseLines() {
        if (line) CFRelease(line);
        line = nullptr;
        for (CTLineRef rowLine : rowLines) {
            CFRelease(rowLine);
        }
        rowLines.clear();
    }

    // ---- Rows (a line that isn't wrapped has exactly one)
    size_t rowCount() const { return rowStartUnits.empty() ? 1 : rowStartUnits.size() - 1; }
    uint32_t rowStart(size_t row) const { return rowStartUnits.empty() ? 0 : rowStartUnits[row]; }
    /// Where the row ends (the next row's start); the last row is unbounded.
    uint32_t rowEnd(size_t row) const {
        if (rowStartUnits.empty() || row + 1 >= rowCount()) {
            return UINT32_MAX;
        }
        return rowStartUnits[row + 1];
    }
    CTLineRef lineForRow(size_t row) const { return rowLines.empty() ? line : rowLines[row]; }
    CGFloat indentForRow(size_t row) const { return row == 0 ? 0 : continuationIndent; }
    /// The row a UTF-16 position is drawn on. A position at a wrap point belongs to the row it starts.
    size_t rowForUnit(uint32_t unit) const {
        if (rowStartUnits.empty()) {
            return 0;
        }
        size_t rows = rowCount();
        auto after = std::upper_bound(rowStartUnits.begin(), rowStartUnits.begin() + static_cast<long>(rows), unit);
        return static_cast<size_t>(after - rowStartUnits.begin()) - 1;
    }
    /// Distance from the left edge of the text to a position, measured on the given row.
    CGFloat offsetInRow(size_t row, uint32_t unit) const {
        uint32_t start = rowStart(row);
        uint32_t local = unit > start ? unit - start : 0;
        CGFloat offset = indentForRow(row) + CTLineGetOffsetForStringIndex(lineForRow(row), local, nullptr);
        auto gap = gapBefore.find(unit);
        if (gap != gapBefore.end()) {
            offset += gap->second / 2;  // CoreText puts the character half way through its kerned gap
        }
        return offset;
    }
    CGFloat offsetForUnit(uint32_t unit) const { return offsetInRow(rowForUnit(unit), unit); }

    uint32_t unitForByte(size_t byte) const { return byteToUnit[std::min(byte, byteToUnit.size() - 1)]; }
    size_t byteForUnit(CFIndex unit) const {
        if (unit < 0) return 0;
        return unitToByte[std::min(static_cast<size_t>(unit), unitToByte.size() - 1)];
    }
};

void buildOffsetMaps(std::string_view text, bool utf8, LineLayout &layout) {
    layout.byteToUnit.assign(text.size() + 1, 0);
    layout.unitToByte.clear();
    uint32_t unit = 0;
    size_t index = 0;
    while (index < text.size()) {
        unsigned char lead = static_cast<unsigned char>(text[index]);
        size_t length = 1;
        if (utf8) {
            if ((lead >> 5) == 0x6) length = 2;
            else if ((lead >> 4) == 0xE) length = 3;
            else if ((lead >> 3) == 0x1E) length = 4;
            if (index + length > text.size()) length = 1;
        }
        uint32_t units = length == 4 ? 2 : 1;  // outside the BMP takes a surrogate pair
        for (size_t k = 0; k < length; ++k) layout.byteToUnit[index + k] = unit;
        for (uint32_t k = 0; k < units; ++k) layout.unitToByte.push_back(static_cast<uint32_t>(index));
        unit += units;
        index += length;
    }
    layout.byteToUnit[text.size()] = unit;
    layout.unitToByte.push_back(static_cast<uint32_t>(text.size()));
}

bool isOpeningBracket(const std::string &text) { return text == "{" || text == "[" || text == "("; }
bool isOpenerByte(char c) { return c == '(' || c == '[' || c == '{'; }
bool isCloserByte(char c) { return c == ')' || c == ']' || c == '}'; }
char matchingByte(char c) {
    switch (c) {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        case ')': return '(';
        case ']': return '[';
        case '}': return '{';
        default: return 0;
    }
}

/// Visual indent columns of a line's leading whitespace, or nullopt for a blank line.
std::optional<size_t> indentColumns(std::string_view text, size_t tabSize) {
    size_t columns = 0;
    for (char c : text) {
        if (c == ' ') {
            columns += 1;
        } else if (c == '\t') {
            columns += tabSize - (columns % tabSize);
        } else {
            return columns;
        }
    }
    return std::nullopt;
}

}  // namespace

@interface GWEditorView ()
@property (nonatomic, readonly) CGFloat lineHeight;
@property (nonatomic, readonly) size_t tabSize;
@property (nonatomic, readonly) NSFont *lineNumberFont;
@property (nonatomic, readonly) NSColor *backgroundColor;
@property (nonatomic, readonly) NSColor *lineNumberColor;
@property (nonatomic, readonly) NSColor *activeLineNumberColor;
- (gw::Document *)document;
- (gw::Highlighter *)highlighter;
- (CGFloat)yForLine:(size_t)line;
- (size_t)lineAtY:(CGFloat)y subrow:(nullable size_t *)subrow;
- (double)fractionalLineAtY:(CGFloat)y;
- (uint32_t)rowsForLine:(size_t)line;
- (BOOL)isLineHidden:(size_t)line;
- (BOOL)isLineFolded:(size_t)line;
- (BOOL)isLineFoldable:(size_t)line;
- (void)toggleFoldAtLine:(size_t)line;
- (int)diagnosticSeverityForLine:(size_t)line;
- (BOOL)hasBreakpointAtLine:(size_t)line;
- (BOOL)isExecutionLine:(size_t)line;
- (void)drawStickyInBounds:(NSRect)bounds;
- (void)clickedStickyRow:(size_t)row;
@property (nonatomic) BOOL gutterHover;
- (const std::vector<gw::LineChange> &)lineChanges;
- (const std::vector<gw::Section> &)sectionList;
- (NSColor *)colorForScopes:(const gw::tm::ScopeNode *)scopes;
@end

// MARK: - Line numbers

/// Line numbers, in a plain view the window places beside the scroll view (never over the
/// code). It follows the editor's scroll position.
@interface GWGutterView : NSView
@property (nonatomic, weak) GWEditorView *editor;
@end

@implementation GWGutterView

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        // Views don't clip their drawing by default (since macOS 14); without this the
        // background fill below spilled over the whole editor card and hid the code.
        self.clipsToBounds = YES;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)drawRect:(NSRect)dirtyRect {
    GWEditorView *editor = self.editor;
    [editor.backgroundColor setFill];
    NSRectFillUsingOperation(NSIntersectionRect(dirtyRect, self.bounds), NSCompositingOperationSourceOver);
    gw::Document *document = editor.document;
    if (!document) return;

    CGFloat lineHeight = editor.lineHeight;
    NSRect visible = editor.visibleRect;
    size_t count = document->buffer().lineCount();
    size_t first = [editor lineAtY:NSMinY(visible) subrow:nullptr];
    size_t last = std::min(count - 1, [editor lineAtY:NSMaxY(visible) subrow:nullptr]);
    size_t caretLine = document->selection.caret.line;

    NSMutableParagraphStyle *right = [NSMutableParagraphStyle new];
    right.alignment = NSTextAlignmentRight;
    NSDictionary *normal = @{NSFontAttributeName: editor.lineNumberFont, NSForegroundColorAttributeName: editor.lineNumberColor,
                             NSParagraphStyleAttributeName: right};
    NSDictionary *active = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:editor.lineNumberFont.pointSize weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: editor.activeLineNumberColor, NSParagraphStyleAttributeName: right};
    CGFloat textHeight = editor.lineNumberFont.ascender - editor.lineNumberFont.descender;
    for (size_t line = first; line <= last && first < count; ++line) {
        if ([editor isLineHidden:line]) {
            continue;
        }
        CGFloat top = [editor yForLine:line] - NSMinY(visible);  // follow the editor's scroll
        NSRect label = NSMakeRect(0, top + (lineHeight - textHeight) / 2 - 1, NSWidth(self.bounds) - 26, textHeight + 2);
        NSString *number = [NSString stringWithFormat:@"%zu", line + 1];
        NSDictionary *numberAttributes = line == caretLine ? active : normal;
        // Each number sits in a soft rounded bubble, so it stands out from the code beside it.
        CGFloat numberWidth = [number sizeWithAttributes:numberAttributes].width;
        CGFloat bubbleWidth = numberWidth + 14;
        CGFloat bubbleRight = NSMaxX(label) + 7;
        NSRect bubble = NSMakeRect(bubbleRight - bubbleWidth, top + 3, bubbleWidth, lineHeight - 6);
        NSColor *bubbleColor = line == caretLine ? [NSColor.controlAccentColor colorWithAlphaComponent:0.38]
                                                 : [editor.lineNumberColor colorWithAlphaComponent:0.13];
        [bubbleColor setFill];
        CGFloat bubbleRadius = NSHeight(bubble) / 2;
        [[NSBezierPath bezierPathWithRoundedRect:bubble xRadius:bubbleRadius yRadius:bubbleRadius] fill];
        [number drawInRect:label withAttributes:numberAttributes];
        BOOL hasBreakpoint = [editor hasBreakpointAtLine:line];
        BOOL isExecution = [editor isExecutionLine:line];
        if (hasBreakpoint) {
            [NSColor.systemRedColor setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(3, top + (lineHeight - 10) / 2, 10, 10)] fill];
        }
        if (isExecution) {
            // A yellow arrow, drawn over the breakpoint dot if there is one.
            [NSColor.systemYellowColor setFill];
            NSBezierPath *arrow = [NSBezierPath bezierPath];
            CGFloat middle = top + lineHeight / 2;
            [arrow moveToPoint:NSMakePoint(2, middle - 6)];
            [arrow lineToPoint:NSMakePoint(13, middle)];
            [arrow lineToPoint:NSMakePoint(2, middle + 6)];
            [arrow closePath];
            [arrow fill];
        }
        int severity = [editor diagnosticSeverityForLine:line];
        if (!hasBreakpoint && !isExecution && severity > 0 && severity <= 2) {
            [(severity == 1 ? NSColor.systemRedColor : NSColor.systemOrangeColor) setFill];
            NSRect dot = NSMakeRect(10, top + (lineHeight - 6) / 2, 6, 6);
            [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        }
        [self drawFoldMarkerForLine:line top:top lineHeight:lineHeight];
    }
    [self drawChangeBarsWithLineHeight:lineHeight visible:visible];
}

/// A small arrow beside blocks that can fold: always for folded ones, and for the rest while the
/// pointer is over the line numbers.
- (void)drawFoldMarkerForLine:(size_t)line top:(CGFloat)top lineHeight:(CGFloat)lineHeight {
    GWEditorView *editor = self.editor;
    BOOL folded = [editor isLineFolded:line];
    BOOL showOpen = editor.gutterHover && [editor isLineFoldable:line];
    if (!folded && !showOpen) {
        return;
    }
    NSColor *color = folded ? editor.activeLineNumberColor : editor.lineNumberColor;
    NSImageSymbolConfiguration *sizeConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:8.5 weight:NSFontWeightBold];
    NSImageSymbolConfiguration *colorConfiguration = [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]];
    NSImage *image = [NSImage imageWithSystemSymbolName:folded ? @"chevron.right" : @"chevron.down" accessibilityDescription:nil];
    image = [image imageWithSymbolConfiguration:[sizeConfiguration configurationByApplyingConfiguration:colorConfiguration]];
    NSSize size = image.size;
    NSRect target = NSMakeRect(NSWidth(self.bounds) - 22, top + (lineHeight - size.height) / 2, size.width, size.height);
    [image drawInRect:target];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
    self.editor.gutterHover = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    self.editor.gutterHover = NO;
    self.needsDisplay = YES;
}

/// Version control marks: a bar for added and modified lines, a small triangle where lines
/// were deleted. They sit on the gutter's right edge, next to the code.
- (void)drawChangeBarsWithLineHeight:(CGFloat)lineHeight visible:(NSRect)visible {
    const std::vector<gw::LineChange> &changes = self.editor.lineChanges;
    if (changes.empty()) {
        return;
    }
    NSColor *added = [NSColor colorWithSRGBRed:0.34 green:0.78 blue:0.45 alpha:1];
    NSColor *modified = [NSColor colorWithSRGBRed:0.36 green:0.62 blue:1.0 alpha:1];
    NSColor *removed = [NSColor colorWithSRGBRed:0.96 green:0.40 blue:0.42 alpha:1];
    CGFloat barX = NSWidth(self.bounds) - 6;

    GWEditorView *editor = self.editor;
    for (const gw::LineChange &change : changes) {
        CGFloat changeTop = [editor yForLine:change.firstLine];
        CGFloat top = changeTop - NSMinY(visible);
        CGFloat height = [editor yForLine:change.firstLine + change.lineCount] - changeTop;
        if (change.kind == gw::LineChangeKind::Removed) {
            if (top < -lineHeight || top > NSHeight(self.bounds) + lineHeight) {
                continue;
            }
            [removed setFill];
            NSBezierPath *triangle = [NSBezierPath bezierPath];
            [triangle moveToPoint:NSMakePoint(barX - 1, top - 4)];
            [triangle lineToPoint:NSMakePoint(barX + 5, top)];
            [triangle lineToPoint:NSMakePoint(barX - 1, top + 4)];
            [triangle closePath];
            [triangle fill];
            continue;
        }
        if (top + height < 0 || top > NSHeight(self.bounds)) {
            continue;
        }
        [change.kind == gw::LineChangeKind::Added ? added : modified setFill];
        NSRect bar = NSMakeRect(barX, top + 1, 3, height - 2);
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.5 yRadius:1.5] fill];
    }
}

- (void)mouseDown:(NSEvent *)event {
    // A click on a change bar opens its details instead of selecting the line.
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    GWEditorView *editor = self.editor;
    // A click at the far left of the line numbers puts a breakpoint there (or takes it away).
    if (point.x < 15 && editor.document != nullptr) {
        size_t clickedLine = [editor lineAtY:point.y + NSMinY(editor.visibleRect) subrow:nullptr];
        if (clickedLine < editor.document->buffer().lineCount()) {
            [editor toggleBreakpointAtLine:clickedLine];
            return;
        }
    }
    // A click on the fold arrow folds or opens the block.
    BOOL onFoldArrow = point.x >= NSWidth(self.bounds) - 28 && point.x < NSWidth(self.bounds) - 12;
    if (onFoldArrow && editor.document != nullptr) {
        size_t clickedLine = [editor lineAtY:point.y + NSMinY(editor.visibleRect) subrow:nullptr];
        bool inRange = clickedLine < editor.document->buffer().lineCount();
        if (inRange && ([editor isLineFolded:clickedLine] || [editor isLineFoldable:clickedLine])) {
            [editor toggleFoldAtLine:clickedLine];
            return;
        }
    }
    if (editor.onChangeMarkerClick != nil && point.x >= NSWidth(self.bounds) - 14 && !editor.lineChanges.empty()) {
        CGFloat lineHeight = editor.lineHeight;
        size_t line = [editor lineAtY:point.y + NSMinY(editor.visibleRect) subrow:nullptr];
        for (const gw::LineChange &change : editor.lineChanges) {
            bool covers = line >= change.firstLine && line < change.firstLine + std::max<size_t>(change.lineCount, 1);
            bool nearRemoval = change.kind == gw::LineChangeKind::Removed && (line == change.firstLine || line + 1 == change.firstLine);
            if ((change.lineCount > 0 && covers) || nearRemoval) {
                CGFloat barTop = [editor yForLine:change.firstLine];
                CGFloat barHeight = [editor yForLine:change.firstLine + change.lineCount] - barTop;
                NSRect bar = NSMakeRect(NSWidth(self.bounds) - 6, barTop - NSMinY(editor.visibleRect),
                                        6, std::max<CGFloat>(barHeight, lineHeight));
                editor.onChangeMarkerClick(change.firstLine, bar);
                return;
            }
        }
    }
    [editor mouseDown:event];  // clicking a line number selects the line
}

@end

// MARK: - Minimap

/// The whole file in miniature, each token a sliver of its color, with the visible region
/// outlined. Clicking or dragging scrolls the editor there.
@interface GWMinimapView : NSView
@property (nonatomic, weak) GWEditorView *editor;
@end

@implementation GWMinimapView

static constexpr CGFloat kMiniLine = 2.6;
static constexpr CGFloat kMiniChar = 1.25;

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) self.clipsToBounds = YES;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

/// Where the minimap is scrolled to: it tracks the editor proportionally when the whole
/// file doesn't fit.
- (CGFloat)offsetForLines:(size_t)lines {
    GWEditorView *editor = self.editor;
    CGFloat total = lines * kMiniLine;
    CGFloat height = NSHeight(self.bounds);
    if (total <= height) return 0;
    NSRect visible = editor.visibleRect;
    CGFloat scrollable = std::max(1.0, NSHeight(editor.frame) - NSHeight(visible));
    return std::min(1.0, NSMinY(visible) / scrollable) * (total - height);
}

- (void)drawRect:(NSRect)dirtyRect {
    GWEditorView *editor = self.editor;
    gw::Document *document = editor.document;
    if (!document) return;
    const auto &buffer = document->buffer();
    size_t count = buffer.lineCount();
    CGFloat offset = [self offsetForLines:count];
    size_t first = static_cast<size_t>(offset / kMiniLine);
    size_t last = std::min(count - 1, first + static_cast<size_t>(NSHeight(self.bounds) / kMiniLine) + 1);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    gw::Highlighter *highlighter = editor.highlighter;
    NSColor *plain = [editor.lineNumberColor colorWithAlphaComponent:0.9];

    for (size_t line = first; line <= last; ++line) {
        std::string_view text = buffer.line(line);
        if (text.empty()) continue;
        CGFloat y = line * kMiniLine - offset;
        // Only use tokens the editor has already computed; the minimap never forces work.
        const std::vector<gw::tm::Token> *tokens =
            highlighter && line < highlighter->validLines() ? highlighter->tokens(buffer, line, 0) : nullptr;
        auto paint = [&](size_t start, size_t end, NSColor *color) {
            // Draw runs of visible characters (skip spaces) as small bars.
            CGContextSetFillColorWithColor(context, [color colorWithAlphaComponent:0.75].CGColor);
            size_t column = 0;
            for (size_t index = 0; index < start && index < text.size(); ++index) {
                column += text[index] == '\t' ? editor.tabSize : 1;
            }
            size_t runStart = std::string::npos;
            for (size_t index = start; index <= end; ++index) {
                bool visibleChar = index < end && text[index] != ' ' && text[index] != '\t';
                if (visibleChar && runStart == std::string::npos) runStart = column;
                if (!visibleChar && runStart != std::string::npos) {
                    CGContextFillRect(context, CGRectMake(6 + runStart * kMiniChar, y, (column - runStart) * kMiniChar, kMiniLine * 0.72));
                    runStart = std::string::npos;
                }
                if (index < end) {
                    column += text[index] == '\t' ? editor.tabSize : 1;
                }
                if (6 + column * kMiniChar > NSWidth(self.bounds)) break;
            }
        };
        if (tokens) {
            for (const auto &token : *tokens) {
                paint(token.start, std::min<size_t>(token.end, text.size()), [editor colorForScopes:token.scopes]);
            }
        } else {
            paint(0, text.size(), plain);
        }
    }

    [self drawSectionsWithOffset:offset];

    // The part of the file currently on screen.
    NSRect visible = editor.visibleRect;
    double topLine = [editor fractionalLineAtY:NSMinY(visible)];
    double bottomLine = [editor fractionalLineAtY:NSMaxY(visible)];
    CGFloat top = topLine * kMiniLine - offset;
    CGFloat height = (bottomLine - topLine) * kMiniLine;
    NSRect window = NSMakeRect(1, top, NSWidth(self.bounds) - 2, height);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:window xRadius:4 yRadius:4];
    [[NSColor.labelColor colorWithAlphaComponent:0.07] setFill];
    [path fill];
    [[NSColor.labelColor colorWithAlphaComponent:0.14] setStroke];
    path.lineWidth = 0.75;
    [path stroke];
}

/// Xcode-style: section names from MARK comments down the minimap, dividers as lines, and
/// small markers for TODO (amber) and FIXME (red).
- (void)drawSectionsWithOffset:(CGFloat)offset {
    GWEditorView *editor = self.editor;
    NSDictionary *labelAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:0.9],
    };
    CGFloat width = NSWidth(self.bounds);

    for (const gw::Section &section : editor.sectionList) {
        CGFloat y = section.line * kMiniLine - offset;
        if (y < -12 || y > NSHeight(self.bounds)) {
            continue;
        }
        if (section.kind == gw::Section::Kind::Todo || section.kind == gw::Section::Kind::Fixme) {
            NSColor *color = section.kind == gw::Section::Kind::Todo ? NSColor.systemOrangeColor : NSColor.systemRedColor;
            [color setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(width - 6, y - 1, 4, 5) xRadius:2 yRadius:2] fill];
            continue;
        }
        if (section.divider) {
            [[NSColor.labelColor colorWithAlphaComponent:0.25] setFill];
            NSRectFill(NSMakeRect(2, std::round(y) - 1, width - 4, 1));
        }
        if (section.title.empty()) {
            continue;
        }
        NSString *title = @(section.title.c_str());
        NSSize size = [title sizeWithAttributes:labelAttributes];
        NSRect label = NSMakeRect(3, y, std::min(size.width + 8, width - 6), size.height + 2);
        [[editor.backgroundColor colorWithAlphaComponent:0.9] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:label xRadius:4 yRadius:4] fill];
        [title drawInRect:NSInsetRect(label, 4, 1) withAttributes:labelAttributes];
    }
}

- (void)scrollToPoint:(NSPoint)point {
    GWEditorView *editor = self.editor;
    gw::Document *document = editor.document;
    if (!document) return;
    size_t count = document->buffer().lineCount();
    CGFloat offset = [self offsetForLines:count];
    size_t line = static_cast<size_t>(std::max(0.0, (point.y + offset) / kMiniLine));
    [editor scrollToLineCentered:std::min(line, count - 1)];
}

- (void)mouseDown:(NSEvent *)event {
    [self scrollToPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseDragged:(NSEvent *)event {
    [self scrollToPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

@end

// MARK: - Sticky scroll

/// The pinned header lines. It only shows what the editor tells it to.
@interface GWStickyView : NSView
@property (nonatomic, weak) GWEditorView *editor;
@end

@implementation GWStickyView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)drawRect:(NSRect)dirtyRect {
    [self.editor drawStickyInBounds:self.bounds];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    GWEditorView *editor = self.editor;
    CGFloat height = editor.lineHeight;
    [editor clickedStickyRow:static_cast<size_t>(std::max(0.0, point.y / height))];
}

@end

// MARK: - Editor

@implementation GWEditorView {
    gw::Document *_document;
    gw::Highlighter *_highlighter;
    CGFloat _lastScrolledX;  // the horizontal scroll position last drawn at
    gw::LanguageConfiguration _configuration;
    std::unordered_map<size_t, LineLayout> _layouts;
    bool _highlightBlocked;  // this frame ran out of highlighting budget
    bool _useTabs;
    bool _detectedUseTabs;        // what the file's own indentation suggests
    int _useTabsOverride;         // from .editorconfig: -1 none, 0 spaces, 1 tabs
    size_t _tabSizeOverride;      // from .editorconfig: 0 none
    size_t _longestLine;

    // Vim mode: the engine reads and edits the document; the view only feeds it keys and draws
    // the block cursor.
    gw::VimEngine _vim;
    BOOL _vimEnabled;
    NSString *_vimShownStatus;

    // The Vim cursor's smear: a quadrilateral whose four corners chase the cursor's new place at
    // different speeds, the leading ones first, so it stretches and then catches up.
    CAShapeLayer *_smearLayer;
    CADisplayLink *_smearLink;
    CGPoint _smearCorners[4];
    CGPoint _smearTargets[4];
    NSRect _lastCaretRect;
    BOOL _hasLastCaretRect;

    // Soft wrap and folding. The row map exists only while either is in use; with it empty,
    // line N is simply at row N.
    gw::RowMap _rowMap;
    gw::FoldSet _folds;
    BOOL _wrapEnabled;
    uint32_t _wrapColumns;
    BOOL _gutterHover;

    // Multi-cursor editing: while a command runs at each cursor in turn, the view isn't refreshed
    // until the last one is done.
    int _multiDepth;
    BOOL _multiEdited;
    BOOL _multiMoved;
    size_t _cursorIndexInLoop;
    size_t _cursorCountInLoop;

    NSInteger _executionLine;  // where the debugger is stopped, or -1

    // Pinned headers (sticky scroll).
    GWStickyView *_stickyView;
    std::vector<size_t> _stickyLines;
    size_t _stickyTopLine;
    uint64_t _stickyVersion;

    // Semantic highlighting from the language server, and the style each token kind gets.
    gw::SemanticTokenSet _semantic;
    std::unordered_map<uint32_t, std::optional<gw::TextStyle>> _semanticStyles;
    /// Syntax colors after the contrast check, keyed by the theme's color; emptied when the theme changes.
    std::unordered_map<gw::Color, NSColor *> _readableColors;
    /// The solid color the code sits on, used to judge how readable a color is.
    NSColor *_contrastBackground;

    // Language intelligence: problems to underline, hover, typing notifications.
    std::vector<GWDiagnostic> _diagnostics;
    NSString *_pendingTyped;
    gw::Range _hoverWord;
    BOOL _hoverActive;
    NSPoint _hoverPoint;

    // Bracket nesting depth at the start of each line, for coloring brackets by depth.
    std::vector<int> _depthAt;
    size_t _depthValid;
    std::unordered_map<const gw::tm::ScopeNode *, bool> _inertScopes;  // strings and comments
    // The bracket pair around the caret, cached per document version and caret position.
    uint64_t _matchVersion;
    gw::Position _matchCaret;
    std::optional<std::pair<gw::Position, gw::Position>> _match;
    std::vector<gw::Selection> _expandHistory;  // what Shrink Selection goes back to
    gw::Selection _lastExpanded;                // the selection Expand left, to notice when it was changed since

    NSFont *_font;
    CGFloat _charWidth;
    CGFloat _baseline;
    NSColor *_foreground, *_selectionColor, *_lineHighlight, *_caretColor, *_guideColor, *_matchColor;
    NSColor *_occurrenceColor;
    NSColor *_dividerColor;
    size_t _tabSize;
    std::vector<gw::Section> _sections;  // MARK / TODO / FIXME, refreshed shortly after edits
    NSArray<NSColor *> *_bracketColors;
    NSParagraphStyle *_paragraph;

    std::vector<gw::LineChange> _lineChanges;
    std::vector<gw::Color> _lineTints;
    /// Extension decorations, spread over the lines they touch (a range of 3 lines is 3 entries).
    std::unordered_map<size_t, std::vector<LineDecoration>> _decorationsByLine;
    /// Language server hints by line, in column order.
    std::unordered_map<size_t, std::vector<GWInlayHint>> _inlayByLine;
    std::vector<gw::Range> _findMatches;
    long _currentFindMatch;

    GWGutterView *_gutter;
    GWMinimapView *_minimap;
    CALayer *_caretLayer;
    NSTimer *_blinkTimer;
    NSString *_markedText;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        self.wantsLayer = YES;
        _useTabsOverride = -1;
        _executionLine = -1;
        _matchVersion = UINT64_MAX;
        _minimap = [[GWMinimapView alloc] initWithFrame:NSZeroRect];
        _minimap.editor = self;
        _gutter = [[GWGutterView alloc] initWithFrame:NSZeroRect];
        _gutter.editor = self;
        _stickyView = [[GWStickyView alloc] initWithFrame:NSZeroRect];
        _stickyView.editor = self;
        _stickyView.hidden = YES;

        // The caret is its own glowing layer, so it can glide between positions and blink
        // without redrawing any text.
        _caretLayer = [CALayer layer];
        _caretLayer.cornerRadius = 1;
        _caretLayer.shadowRadius = 6;
        _caretLayer.shadowOpacity = 0.9;
        _caretLayer.shadowOffset = CGSizeZero;
        _caretLayer.zPosition = 10;
        _caretLayer.hidden = YES;
        [self.layer addSublayer:_caretLayer];

        _smearLayer = [CAShapeLayer layer];
        _smearLayer.zPosition = 9;  // just under the caret
        _smearLayer.shadowRadius = 6;
        _smearLayer.shadowOpacity = 0.9;
        _smearLayer.shadowOffset = CGSizeZero;
        _smearLayer.hidden = YES;
        [self.layer addSublayer:_smearLayer];

        _vim.readClipboard = [] {
            NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            return std::string(text.UTF8String ?: "");
        };
        _vim.writeClipboard = [](const std::string &text) {
            NSString *copied = [NSString stringWithUTF8String:text.c_str()];
            if (copied != nil) {
                [NSPasteboard.generalPasteboard clearContents];
                [NSPasteboard.generalPasteboard setString:copied forType:NSPasteboardTypeString];
            }
        };
        __weak GWEditorView *weakSelf = self;
        _vim.onCommand = [weakSelf](const std::string &command) -> std::string {
            GWEditorView *strongSelf = weakSelf;
            if (strongSelf == nil || !strongSelf.onVimCommand) return "E492: Not an editor command: " + command;
            NSString *error = strongSelf.onVimCommand(@(command.c_str()));
            return error.length > 0 ? std::string(error.UTF8String) : std::string();
        };
        _vim.onAction = [weakSelf](gw::VimAction action) {
            GWEditorView *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf.onVimAction) {
                strongSelf.onVimAction(action);
            }
        };

        [self reloadAppearance];
        for (NSNotificationName name in @[GWThemeDidChangeNotification, GWEditorSettingsDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appearanceChanged:) name:name object:nil];
        }
    }
    return self;
}

- (void)dealloc {
    [_smearLink invalidate];
    [_blinkTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
// Without this, dragging to select text would move the whole window (see-through views let drags through).
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
}
- (gw::Document *)document { return _document; }
- (gw::Document *)currentDocument { return _document; }
- (gw::Highlighter *)highlighter { return _highlighter; }
- (NSView *)minimapView { return _minimap; }
- (NSView *)gutterView { return _gutter; }
- (const std::vector<gw::Section> &)sectionList { return _sections; }
- (std::vector<gw::Section>)sections { return _sections; }
- (const std::vector<gw::LineChange> &)lineChanges { return _lineChanges; }

- (void)setLineChanges:(std::vector<gw::LineChange>)changes {
    _lineChanges = std::move(changes);
    _gutter.needsDisplay = YES;
}

- (void)setInlayHints:(std::vector<GWInlayHint>)hints {
    _inlayByLine.clear();
    for (GWInlayHint &hint : hints) {
        _inlayByLine[hint.position.line].push_back(std::move(hint));
    }
    _layouts.clear();  // each hint reserves space in its line
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
}

/// How hints look: a little smaller than the code, muted.
- (NSDictionary *)inlayHintAttributes {
    return @{NSFontAttributeName: [NSFont systemFontOfSize:std::max<CGFloat>(9, _font.pointSize - 2.5) weight:NSFontWeightRegular],
             NSForegroundColorAttributeName: [NSColor.secondaryLabelColor colorWithAlphaComponent:0.95]};
}

static constexpr CGFloat kInlayChipPadding = 5;  // inside the chip, each side
static constexpr CGFloat kInlayGap = 3;          // between the chip and the code

/// The room a hint takes in its line: its text, the chip's padding and a gap.
- (CGFloat)inlayWidthForHint:(const GWInlayHint &)hint {
    NSString *label = @(hint.label.c_str());
    CGFloat text = ceil([label sizeWithAttributes:[self inlayHintAttributes]].width);
    return text + kInlayChipPadding * 2 + kInlayGap * (hint.padLeft ? 2 : 1) + (hint.padRight ? kInlayGap : 0);
}

/// Opens a gap in the line for each hint, without adding any characters: the character before it
/// gets extra kerning, which moves everything after it, so every position in the line stays valid.
- (void)applyInlayHintsToLine:(size_t)line
                         text:(std::string_view)text
                   attributed:(NSMutableAttributedString *)attributed
                       layout:(LineLayout &)layout {
    auto found = _inlayByLine.find(line);
    if (found == _inlayByLine.end() || _wrapEnabled) {
        return;
    }
    std::map<NSUInteger, CGFloat> gapAfterCharacter;
    for (const GWInlayHint &hint : found->second) {
        size_t column = hint.position.column;
        if (column == 0 || column >= text.size()) {
            continue;  // at the very start the gap has no character to hang on; at the end it is drawn outside the line
        }
        uint32_t unit = layout.unitForByte(column);
        if (unit == 0 || unit > attributed.length) {
            continue;
        }
        NSRange composed = [attributed.string rangeOfComposedCharacterSequenceAtIndex:unit - 1];
        CGFloat width = [self inlayWidthForHint:hint];
        gapAfterCharacter[composed.location] += width;
        layout.gapBefore[unit] += width;
    }
    for (const auto &[location, width] : gapAfterCharacter) {
        NSRange composed = [attributed.string rangeOfComposedCharacterSequenceAtIndex:location];
        [attributed addAttribute:NSKernAttributeName value:@(width) range:composed];
    }
}

/// The hints themselves, drawn as small chips in the gaps opened above.
- (void)drawInlayHintsFromLine:(size_t)first toLine:(size_t)last {
    if (_inlayByLine.empty() || _wrapEnabled) {
        return;
    }
    const auto &buffer = _document->buffer();
    NSDictionary *attributes = [self inlayHintAttributes];
    for (size_t line = first; line <= last; ++line) {
        auto found = _inlayByLine.find(line);
        if (found == _inlayByLine.end() || [self isLineHidden:line] || [self rowsForLine:line] != 1) {
            continue;
        }
        LineLayout *layout = [self layoutForLine:line];
        size_t size = buffer.line(line).size();
        // Hints that share a spot sit side by side, the first one furthest left.
        std::map<size_t, CGFloat> usedAtColumn;
        std::map<size_t, CGFloat> totalAtColumn;
        for (const GWInlayHint &hint : found->second) {
            if (hint.position.column > 0 && hint.position.column < size) {
                totalAtColumn[hint.position.column] += [self inlayWidthForHint:hint];
            }
        }
        for (const GWInlayHint &hint : found->second) {
            size_t column = std::min(hint.position.column, size);
            CGFloat width = [self inlayWidthForHint:hint];
            CGFloat x;
            if (column == 0) {
                continue;
            } else if (column >= size) {
                x = self.textLeft + layout->offsetForUnit(layout->unitForByte(size)) + kInlayGap * (hint.padLeft ? 2 : 1);
            } else {
                CGFloat spot = self.textLeft + layout->offsetForUnit(layout->unitForByte(column));
                x = spot - totalAtColumn[column] + usedAtColumn[column] + kInlayGap * (hint.padLeft ? 2 : 1);
                usedAtColumn[column] += width;
            }
            NSString *label = @(hint.label.c_str());
            NSSize textSize = [label sizeWithAttributes:attributes];
            CGFloat top = [self yForLine:line];
            NSRect chip = NSMakeRect(x, top + 4, textSize.width + kInlayChipPadding * 2, _lineHeight - 8);
            [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.14] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:4 yRadius:4] fill];
            [label drawAtPoint:NSMakePoint(x + kInlayChipPadding, top + (_lineHeight - textSize.height) / 2) withAttributes:attributes];
        }
    }
}

- (void)setDecorationGroups:(const std::map<std::string, std::vector<GWDecoration>> &)groups {
    _decorationsByLine.clear();
    constexpr size_t kMostLinesPerDecoration = 5000;
    for (const auto &[key, decorations] : groups) {
        for (const GWDecoration &decoration : decorations) {
            gw::Range range = decoration.range.normalized();
            size_t lastLine = std::min(range.end.line, range.start.line + kMostLinesPerDecoration);
            for (size_t line = range.start.line; line <= lastLine; ++line) {
                LineDecoration entry;
                entry.look = decoration;
                entry.startByte = line == range.start.line ? range.start.column : 0;
                entry.toEndOfLine = line < range.end.line;
                entry.endByte = line == range.end.line ? range.end.column : 0;
                entry.showsNote = line == lastLine;
                _decorationsByLine[line].push_back(std::move(entry));
            }
        }
    }
    _layouts.clear();  // text colors and styles are part of a laid-out line
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
}

- (void)setLineTints:(std::vector<gw::Color>)tints {
    _lineTints = std::move(tints);
    self.needsDisplay = YES;
}

- (void)setFindMatches:(std::vector<gw::Range>)matches current:(long)current {
    _findMatches = std::move(matches);
    _currentFindMatch = current;
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
}

- (void)selectRange:(gw::Range)range {
    if (!_document) {
        return;
    }
    range = range.normalized();
    range.start = _document->buffer().clamp(range.start);
    range.end = _document->buffer().clamp(range.end);
    _document->extraSelections.clear();
    _document->selection = {range.start, range.end};
    _document->preferredX.reset();
    NSRect visible = self.visibleRect;
    if (!_folds.empty() && _folds.unfoldHiding(range.start.line)) {
        [self rowLayoutChanged];
    }
    CGFloat top = [self yForLine:range.start.line];
    BOOL onScreen = top >= NSMinY(visible) + _lineHeight && top <= NSMaxY(visible) - 2 * _lineHeight;
    if (onScreen) {
        [self scrollCaretToVisible];
    } else {
        [self scrollToLineCentered:range.start.line];
    }
    [self selectionDidChange];
}

- (std::string)selectedText {
    if (!_document) {
        return std::string();
    }
    if (!_document->selection.empty()) {
        return _document->buffer().text(_document->selection.range());
    }
    return [self wordAtCaret];
}

- (void)flashLines:(size_t)first count:(size_t)count {
    if (!_document || count == 0) {
        return;
    }
    NSColor *glow = [NSColor.controlAccentColor colorWithAlphaComponent:0.55];
    CALayer *flash = [CALayer layer];
    CGFloat flashTop = [self yForLine:first];
    CGFloat flashHeight = [self yForLine:first + count] - flashTop;
    flash.frame = CGRectMake(NSMinX(self.visibleRect) + 4, flashTop, NSWidth(self.visibleRect) - 8, flashHeight);
    flash.backgroundColor = glow.CGColor;
    flash.cornerRadius = 7;
    flash.zPosition = 5;
    [self.layer addSublayer:flash];

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.duration = 2.0;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    fade.fillMode = kCAFillModeForwards;
    fade.removedOnCompletion = NO;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [flash removeFromSuperlayer];
    }];
    [flash addAnimation:fade forKey:@"fade"];
    [CATransaction commit];
}

// MARK: Indentation from .editorconfig

- (void)setIndentationOverrideUsesTabs:(int)usesTabs tabSize:(size_t)tabSize {
    BOOL changedSize = tabSize != _tabSizeOverride;
    _useTabsOverride = usesTabs;
    _tabSizeOverride = tabSize;
    _useTabs = usesTabs >= 0 ? usesTabs == 1 : _detectedUseTabs;
    if (changedSize) {
        // The tab width affects how text is measured and drawn.
        [self reloadAppearance];
    }
}

// MARK: Setup

- (void)setDocument:(gw::Document *)document
        highlighter:(gw::Highlighter *)highlighter
      configuration:(const gw::LanguageConfiguration &)configuration {
    _vim.reset(_document);  // the file being left: an insert in progress ends with it
    [self stopSmear];
    _hasLastCaretRect = NO;
    _document = document;
    _highlighter = highlighter;
    _configuration = configuration;
    _folds.clear();
    _markedText = nil;
    _lineChanges.clear();
    _lineTints.clear();
    _findMatches.clear();
    _currentFindMatch = -1;
    _useTabs = false;
    _depthAt.clear();
    _depthValid = 0;
    _matchVersion = UINT64_MAX;
    if (document) {
        // Indent with tabs if the file already mostly does.
        size_t tabs = 0, spaces = 0;
        const auto &buffer = document->buffer();
        for (size_t line = 0; line < std::min<size_t>(buffer.lineCount(), 2000); ++line) {
            std::string_view text = buffer.line(line);
            if (!text.empty() && text[0] == '\t') ++tabs;
            if (text.size() >= 2 && text[0] == ' ' && text[1] == ' ') ++spaces;
        }
        _detectedUseTabs = tabs > spaces;
        _useTabs = _detectedUseTabs;
    }
    [self refreshSections];
    [self invalidateLayout];
    [self vimStatusDidChange];
    [self updateCaretAnimated:NO];
}

/// Re-reads MARK / TODO / FIXME comments. Cheap, but done a moment after typing stops
/// rather than on every keystroke.
- (void)refreshSections {
    if (_document) {
        _sections = gw::findSections(_document->buffer());
    } else {
        _sections.clear();
    }
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
    if (self.onSectionsChange) {
        self.onSectionsChange();
    }
}

- (void)scheduleSectionsRefresh {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshSections) object:nil];
    [self performSelector:@selector(refreshSections) withObject:nil afterDelay:0.3];
}

- (void)document:(gw::Document *)document changedFromLine:(size_t)line {
    if (document != _document) return;
    _depthValid = std::min(_depthValid, line);
    _matchVersion = UINT64_MAX;
}

- (void)appearanceChanged:(NSNotification *)notification {
    [self reloadAppearance];
}

- (void)reloadAppearance {
    GWServices *services = GWServices.shared;
    _tabSize = _tabSizeOverride > 0 ? _tabSizeOverride : static_cast<size_t>(std::max(1, services.settings.tabSize));
    _wrapEnabled = services.settings.wordWrap;
    _semanticStyles.clear();
    if (services.settings.vimMode != _vimEnabled) {
        _vim.reset(_document);  // (a command in progress, or an insert, ends when Vim is switched)
        _vimEnabled = services.settings.vimMode;
    }
    // A new font size changes every row height, so the line at the top of the view is noted now
    // and put back at the top afterward; without that the text would jump.
    NSClipView *clip = self.enclosingScrollView.contentView;
    BOOL keepTopLine = clip != nil && _document != nullptr && _lineHeight > 0;
    size_t topLine = keepTopLine ? [self lineAtY:NSMinY(clip.bounds) subrow:nullptr] : 0;
    _font = [services editorFontBold:NO italic:NO];
    _charWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName: _font}].width;
    _lineHeight = std::ceil(_font.pointSize * 1.65);
    _baseline = std::round((_lineHeight - (_font.ascender - _font.descender)) / 2 + _font.ascender);
    _lineNumberFont = [NSFont monospacedDigitSystemFontOfSize:_font.pointSize - 1.5 weight:NSFontWeightRegular];

    CGFloat opacity = services.editorOpacity;
    const gw::Theme &theme = services.theme;
    NSColor *base = theme.isDark() ? NSColor.whiteColor : NSColor.blackColor;
    NSColor *editorBackground = [services color:@"editor.background" fallback:theme.isDark() ? NSColor.blackColor : NSColor.whiteColor];
    _backgroundColor = [editorBackground colorWithAlphaComponent:editorBackground.alphaComponent * opacity];
    // The editor is often see-through, and themes pick their colors for a solid background, so
    // anything dim (plain text, line numbers, comments) can vanish. Each color is checked against
    // the solid background and brightened just enough to read.
    _contrastBackground = [editorBackground colorWithAlphaComponent:1];
    _readableColors.clear();
    NSColor *themeForeground = GWColor(theme.color("editor.foreground", theme.isDark() ? 0xD4D4D4FF : 0x1E1E1EFF));
    _foreground = GWReadableColor(themeForeground, _contrastBackground, 7.0);
    _selectionColor = [services color:@"editor.selectionBackground"
                             fallback:[NSColor.selectedTextBackgroundColor colorWithAlphaComponent:0.6]];
    _lineHighlight = [services color:@"editor.lineHighlightBackground" fallback:[base colorWithAlphaComponent:0.055]];
    _caretColor = [services color:@"editorCursor.foreground" fallback:NSColor.controlAccentColor];
    // Line numbers look the same in every theme: only light versus dark decides the color, so
    // switching themes never changes how readable they are.
    if (theme.isDark()) {
        _lineNumberColor = [NSColor colorWithSRGBRed:0.92 green:0.93 blue:0.96 alpha:1];
        _activeLineNumberColor = NSColor.whiteColor;
    } else {
        _lineNumberColor = [NSColor colorWithSRGBRed:0.10 green:0.11 blue:0.14 alpha:1];
        _activeLineNumberColor = NSColor.blackColor;
    }
    // The guides' color when bracket colorization is off: one color (light or dark only).
    _guideColor = theme.isDark() ? [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.42]
                                 : [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0.42];
    _matchColor = [services color:@"editorBracketMatch.border" fallback:[NSColor.controlAccentColor colorWithAlphaComponent:0.8]];
    _occurrenceColor = [services color:@"editor.wordHighlightBackground"
                              fallback:[NSColor.controlAccentColor colorWithAlphaComponent:0.22]];
    _dividerColor = [_foreground colorWithAlphaComponent:0.22];
    // Bracket pair colors, as in VS Code (gold, orchid, blue unless the theme says otherwise).
    NSArray *fallbacks = @[GWColor(0xFFD700FF), GWColor(0xDA70D6FF), GWColor(0x179FFFFF)];
    NSMutableArray *brackets = [NSMutableArray array];
    for (int index = 1; index <= 3; ++index) {
        NSString *key = [NSString stringWithFormat:@"editorBracketHighlight.foreground%d", index];
        [brackets addObject:[services color:key fallback:fallbacks[static_cast<NSUInteger>(index - 1)]]];
    }
    _bracketColors = brackets;

    _caretLayer.backgroundColor = _caretColor.CGColor;
    _caretLayer.shadowColor = _caretColor.CGColor;

    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.defaultTabInterval = _charWidth * _tabSize;
    paragraph.tabStops = @[];
    _paragraph = paragraph;
    _wrapColumns = 0;
    [self invalidateLayout];
    if (keepTopLine) {
        [clip scrollToPoint:NSMakePoint(NSMinX(clip.bounds), [self yForLine:topLine])];
        [self.enclosingScrollView reflectScrolledClipView:clip];
    }
    [self updateCaretAnimated:NO];  // the caret is its own layer, so it must be moved to the new metrics
    [self vimStatusDidChange];
    _gutter.needsDisplay = YES;
}

- (void)invalidateLayout {
    _layouts.clear();
    [self rebuildRowMap];
    _longestLine = 0;
    if (_document) {
        const auto &buffer = _document->buffer();
        for (size_t line = 0; line < buffer.lineCount(); ++line) _longestLine = std::max(_longestLine, buffer.line(line).size());
    }
    [self updateFrameSize];
    self.needsDisplay = YES;
    _gutter.needsDisplay = YES;
    _minimap.needsDisplay = YES;
    _stickyVersion = UINT64_MAX;  // force a fresh look
    [self updateStickyScroll];
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    NSScrollView *scrollView = self.enclosingScrollView;
    if (!scrollView) return;
    scrollView.contentView.postsBoundsChangedNotifications = YES;
    scrollView.contentView.postsFrameChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewChanged:)
                                               name:NSViewFrameDidChangeNotification object:scrollView.contentView];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewScrolled:)
                                               name:NSViewBoundsDidChangeNotification object:scrollView.contentView];
    [self updateFrameSize];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:name object:nil];
        if (self.window) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowKeyChanged:) name:name object:self.window];
        }
    }
}

- (void)windowKeyChanged:(NSNotification *)notification { [self updateCaretAnimated:NO]; }

- (void)clipViewChanged:(NSNotification *)notification { [self updateFrameSize]; }

- (void)clipViewScrolled:(NSNotification *)notification {
    // AppKit moves the old pixels when scrolling and only draws the newly exposed strip. That is
    // right for vertical scrolling, but the current-line band is as wide as the visible area, so
    // after a sideways scroll its old ends would be left behind as dark smudges. Redraw instead.
    CGFloat scrolledX = NSMinX(self.visibleRect);
    if (scrolledX != _lastScrolledX) {
        _lastScrolledX = scrolledX;
        self.needsDisplay = YES;
    }
    [self updateStickyScroll];
    [self.window invalidateCursorRectsForView:self];
    _gutter.needsDisplay = YES;
    _minimap.needsDisplay = YES;
}

- (CGFloat)gutterWidth {
    size_t count = _document ? _document->buffer().lineCount() : 1;
    int digits = std::max(3, static_cast<int>(std::log10(static_cast<double>(count))) + 1);
    return std::ceil(digits * _charWidth + 40);  // room for the fold arrow beside the numbers
}

- (CGFloat)textLeft { return kTextInset; }

- (void)updateFrameSize {
    NSScrollView *scrollView = self.enclosingScrollView;
    if (!scrollView) return;
    // The window lays the gutter out beside the scroll view; tell it when the width changes.
    if (std::abs(NSWidth(_gutter.frame) - self.gutterWidth) > 0.5) _gutter.superview.needsLayout = YES;
    NSSize clip = scrollView.contentView.bounds.size;
    if (_wrapEnabled) {
        uint32_t columns = [self computeWrapColumns];
        if (columns != _wrapColumns) {
            // The window was resized: lines wrap differently now.
            _wrapColumns = columns;
            _layouts.clear();
            [self rebuildRowMap];
            self.needsDisplay = YES;
            _gutter.needsDisplay = YES;
            _minimap.needsDisplay = YES;
        }
    }
    size_t lines = _document ? _document->buffer().lineCount() : 1;
    uint64_t rows = _rowMap.empty() ? lines : _rowMap.totalRows();
    // Allow scrolling the last line up to the middle of the view, like most code editors.
    CGFloat height = std::max(clip.height, rows * _lineHeight + clip.height * 0.5);
    CGFloat width = std::max(clip.width, self.textLeft + _longestLine * _charWidth + 80);
    if (_wrapEnabled) {
        width = clip.width;  // wrapped text never scrolls sideways
    }
    if (!NSEqualSizes(self.frame.size, NSMakeSize(width, height))) {
        [self setFrameSize:NSMakeSize(width, height)];
        // Growing (the window was laid out bigger than it started) must repaint the new area;
        // otherwise only the part that was drawn before shows.
        self.needsDisplay = YES;
        _gutter.needsDisplay = YES;
    }
}

// MARK: Indent guides

/// How many indentation levels a line is inside, for the guide lines. A line indented more than
/// one level past the nearest less-indented line above it is lining arguments up under a
/// bracket, not opening a block, so it counts at that line's level and adds no guide of its own.
/// Blank lines take the smaller level of the code around them, so a block's guide runs through
/// them unbroken.
- (size_t)indentLevelsForLine:(size_t)line {
    const auto &buffer = _document->buffer();
    size_t count = buffer.lineCount();
    std::optional<size_t> columns = indentColumns(buffer.line(line), _tabSize);
    if (!columns) {
        std::optional<size_t> above, below;
        for (size_t look = line; look-- > 0 && line - look < 100;) {
            if ((above = indentColumns(buffer.line(look), _tabSize))) break;
        }
        for (size_t look = line + 1; look < count && look - line < 100; ++look) {
            if ((below = indentColumns(buffer.line(look), _tabSize))) break;
        }
        return std::min(above.value_or(0), below.value_or(0)) / _tabSize;
    }
    size_t levels = *columns / _tabSize;
    for (size_t look = line; look-- > 0 && line - look < 100;) {
        std::optional<size_t> other = indentColumns(buffer.line(look), _tabSize);
        if (other && *other / _tabSize < levels) {
            size_t parent = *other / _tabSize;
            return levels <= parent + 1 ? levels : parent;
        }
    }
    return levels;
}

/// The color of the guide at `level` for the block that starts at `firstLine`: the color of the
/// bracket the block's opening line starts, which is the same color its { and } are drawn in.
/// It depends only on the text, never on which part of the view is being redrawn.
- (NSColor *)guideColorForLevel:(size_t)level blockStartingAtLine:(size_t)firstLine {
    if (!(GWServices.shared.settings.bracketPairColors && _bracketColors.count > 0)) {
        return _guideColor;
    }
    const auto &buffer = _document->buffer();
    size_t colorIndex = level;
    // Every line inside the block is indented deeper than `level`, so the first line above that
    // isn't is the one that opens it.
    for (size_t look = firstLine; look-- > 0 && firstLine - look < 3000;) {
        std::optional<size_t> columns = indentColumns(buffer.line(look), _tabSize);
        if (columns && *columns / _tabSize <= level) {
            if (std::optional<int> depth = [self depthAtLine:look]) {
                colorIndex = static_cast<size_t>(std::max(0, *depth));
            }
            break;
        }
    }
    return _bracketColors[colorIndex % _bracketColors.count];
}

/// Draws a guide for every block that shows in lines [first, last]: a thick square bracket "["
/// at each indentation level, in the color of the brackets that open that block (the same
/// colors as the bracket pair colorization), and brighter for the block the caret is in.
///
/// Only part of the view may be redrawn at a time, so a block that goes on past the lines being
/// drawn is drawn open at that end, without the bracket's arm.
- (void)drawIndentGuidesFromLine:(size_t)first toLine:(size_t)last {
    size_t lineCount = _document->buffer().lineCount();
    CGFloat step = _tabSize * _charWidth;

    std::vector<size_t> levels;
    for (size_t line = first; line <= last; ++line) {
        levels.push_back([self isLineHidden:line] ? 0 : [self indentLevelsForLine:line]);
    }
    size_t levelsAbove = first > 0 ? [self indentLevelsForLine:first - 1] : 0;
    size_t levelsBelow = last + 1 < lineCount ? [self indentLevelsForLine:last + 1] : 0;
    size_t deepest = 0;
    for (size_t value : levels) deepest = std::max(deepest, value);

    // The block the caret is in, found from the caret outward so it doesn't depend on which
    // lines are being drawn: the guide level and the lines it covers.
    size_t caretLine = _document->selection.caret.line;
    size_t caretLevels = [self indentLevelsForLine:caretLine];
    size_t activeLevel = caretLevels > 0 ? caretLevels - 1 : SIZE_MAX;
    size_t activeStart = caretLine, activeEnd = caretLine;
    if (activeLevel != SIZE_MAX) {
        while (activeStart > 0 && caretLine - activeStart < 1500 && [self indentLevelsForLine:activeStart - 1] > activeLevel) --activeStart;
        while (activeEnd + 1 < lineCount && activeEnd - caretLine < 1500 && [self indentLevelsForLine:activeEnd + 1] > activeLevel) ++activeEnd;
    }
    CGFloat tick = std::min<CGFloat>(5, step * 0.4);  // the short arms of the bracket

    for (size_t level = 0; level < deepest; ++level) {
        CGFloat x = std::round(self.textLeft + level * step) + 1.5;
        size_t index = 0;
        while (index < levels.size()) {
            if (levels[index] <= level || [self isLineHidden:first + index]) {
                ++index;
                continue;
            }
            // A run of lines inside this block.
            size_t runStart = index;
            size_t runEnd = index;
            while (runEnd + 1 < levels.size() && levels[runEnd + 1] > level) ++runEnd;
            index = runEnd + 1;

            size_t firstLine = first + runStart;
            size_t lastLine = first + runEnd;
            BOOL openAtTop = runStart == 0 && levelsAbove > level;
            BOOL openAtBottom = runEnd + 1 == levels.size() && levelsBelow > level;
            CGFloat top = [self yForLine:firstLine] + (openAtTop ? 0 : 3);
            CGFloat bottom = [self yForLine:lastLine] + [self rowsForLine:lastLine] * _lineHeight - (openAtBottom ? 0 : 3);

            NSColor *base = [self guideColorForLevel:level blockStartingAtLine:firstLine];
            BOOL holdsCaret = level == activeLevel && firstLine <= activeEnd && lastLine >= activeStart;
            [[base colorWithAlphaComponent:holdsCaret ? 0.9 : 0.32] setStroke];

            NSBezierPath *guide = [NSBezierPath bezierPath];
            guide.lineWidth = 2.5;
            guide.lineCapStyle = NSLineCapStyleButt;
            guide.lineJoinStyle = NSLineJoinStyleMiter;
            [guide moveToPoint:NSMakePoint(openAtTop ? x : x + tick, top)];
            if (!openAtTop) [guide lineToPoint:NSMakePoint(x, top)];
            [guide lineToPoint:NSMakePoint(x, bottom)];
            if (!openAtBottom) [guide lineToPoint:NSMakePoint(x + tick, bottom)];
            [guide stroke];
        }
    }
}

// MARK: Syntax colors and brackets

- (NSColor *)colorForScopes:(const gw::tm::ScopeNode *)scopes {
    return GWColor(GWServices.shared.theme.styleFor(scopes).foreground);
}

/// Strings and comments: brackets inside them don't count.
- (bool)isInert:(const gw::tm::ScopeNode *)scopes {
    auto found = _inertScopes.find(scopes);
    if (found != _inertScopes.end()) return found->second;
    bool inert = false;
    for (const gw::tm::ScopeNode *node = scopes; node && !inert; node = node->parent) {
        inert = node->name.rfind("string", 0) == 0 || node->name.rfind("comment", 0) == 0;
    }
    _inertScopes[scopes] = inert;
    return inert;
}

/// Byte-wise mask of which characters are code (not strings or comments) on a line.
- (std::vector<bool>)codeMaskForLine:(size_t)line tokens:(const std::vector<gw::tm::Token> *)tokens {
    std::string_view text = _document->buffer().line(line);
    std::vector<bool> mask(text.size(), true);
    if (tokens) {
        for (const auto &token : *tokens) {
            if (![self isInert:token.scopes]) continue;
            for (size_t index = token.start; index < token.end && index < mask.size(); ++index) mask[index] = false;
        }
    }
    return mask;
}

/// Bracket depth at the start of `line`, computed incrementally; nullopt if the highlighter
/// hasn't reached that far yet (brackets then draw uncolored for a frame).
- (std::optional<int>)depthAtLine:(size_t)line {
    const auto &buffer = _document->buffer();
    if (_depthAt.size() != buffer.lineCount() + 1) {
        _depthAt.resize(buffer.lineCount() + 1, 0);
        _depthValid = std::min(_depthValid, buffer.lineCount());
    }
    bool hasGrammar = _highlighter && _highlighter->grammar();
    while (_depthValid < line) {
        const std::vector<gw::tm::Token> *tokens = nullptr;
        if (hasGrammar) {
            if (_depthValid >= _highlighter->validLines()) return std::nullopt;
            tokens = _highlighter->tokens(buffer, _depthValid, 0);
        }
        std::string_view text = buffer.line(_depthValid);
        std::vector<bool> code = [self codeMaskForLine:_depthValid tokens:tokens];
        int depth = _depthAt[_depthValid];
        for (size_t index = 0; index < text.size(); ++index) {
            if (!code[index]) continue;
            if (isOpenerByte(text[index])) ++depth;
            else if (isCloserByte(text[index])) depth = std::max(0, depth - 1);
        }
        _depthAt[++_depthValid] = depth;
    }
    return _depthAt[line];
}

/// The matching pair when the caret touches a bracket.
- (std::optional<std::pair<gw::Position, gw::Position>>)bracketMatch {
    if (!_document || !_document->selection.empty()) return std::nullopt;
    gw::Position caret = _document->selection.caret;
    if (_matchVersion == _document->version() && _matchCaret == caret) return _match;
    _matchVersion = _document->version();
    _matchCaret = caret;
    _match.reset();

    const auto &buffer = _document->buffer();
    auto codeMask = [&](size_t line) {
        const std::vector<gw::tm::Token> *tokens =
            _highlighter && line < _highlighter->validLines() ? _highlighter->tokens(buffer, line, 0) : nullptr;
        return [self codeMaskForLine:line tokens:tokens];
    };
    std::vector<gw::Position> candidates;
    if (caret.column > 0) candidates.push_back({caret.line, caret.column - 1});
    candidates.push_back(caret);
    for (gw::Position at : candidates) {
        std::string_view text = buffer.line(at.line);
        if (at.column >= text.size()) continue;
        char bracket = text[at.column];
        char partner = matchingByte(bracket);
        if (!partner || !codeMask(at.line)[at.column]) continue;
        bool forward = isOpenerByte(bracket);
        int depth = 0;
        long line = static_cast<long>(at.line);
        long limit = 3000;  // don't scan huge files forever
        long column = static_cast<long>(at.column);
        while (line >= 0 && line < static_cast<long>(buffer.lineCount()) && limit-- > 0) {
            std::string_view scan = buffer.line(static_cast<size_t>(line));
            std::vector<bool> code = codeMask(static_cast<size_t>(line));
            if (forward) {
                for (long index = column; index < static_cast<long>(scan.size()); ++index) {
                    if (!code[static_cast<size_t>(index)]) continue;
                    if (scan[static_cast<size_t>(index)] == bracket) ++depth;
                    else if (scan[static_cast<size_t>(index)] == partner && --depth == 0) {
                        _match = std::make_pair(at, gw::Position{static_cast<size_t>(line), static_cast<size_t>(index)});
                        return _match;
                    }
                }
                ++line;
                column = 0;
            } else {
                for (long index = column; index >= 0; --index) {
                    if (index >= static_cast<long>(scan.size()) || !code[static_cast<size_t>(index)]) continue;
                    if (scan[static_cast<size_t>(index)] == bracket) ++depth;
                    else if (scan[static_cast<size_t>(index)] == partner && --depth == 0) {
                        _match = std::make_pair(gw::Position{static_cast<size_t>(line), static_cast<size_t>(index)}, at);
                        return _match;
                    }
                }
                --line;
                column = line >= 0 ? static_cast<long>(buffer.line(static_cast<size_t>(line)).size()) - 1 : 0;
            }
        }
    }
    return std::nullopt;
}

// MARK: Layout

- (LineLayout *)layoutForLine:(size_t)index {
    const auto &buffer = _document->buffer();
    const std::vector<gw::tm::Token> *tokens = nullptr;
    if (_highlighter && _highlighter->grammar() && !_highlightBlocked) {
        tokens = _highlighter->tokens(buffer, index, kHighlightBudget);
        if (!tokens) {
            _highlightBlocked = true;
            [self performSelector:@selector(continueHighlighting) withObject:nil afterDelay:0.01];
        }
    }
    auto found = _layouts.find(index);
    if (found != _layouts.end() && (found->second.highlighted || !tokens)) return &found->second;

    std::string_view text = buffer.line(index);
    NSString *string = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    bool utf8 = string != nil;
    if (!string) string = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSISOLatin1StringEncoding];

    LineLayout layout;
    buildOffsetMaps(text, utf8, layout);
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:string attributes:@{
        NSFontAttributeName: _font,
        NSForegroundColorAttributeName: _foreground,
        NSParagraphStyleAttributeName: _paragraph,
        (NSString *)kCTLigatureAttributeName: @0,
    }];
    if (tokens) {
        // The stylist combines the theme, the user's color rules, rainbow variables and
        // colors set for specific names into one look per run of the line.
        std::vector<gw::StyledSpan> spans = GWServices.shared.stylist.styleLine(text, *tokens);
        for (const gw::StyledSpan &span : spans) {
            uint32_t start = layout.unitForByte(span.start);
            uint32_t end = layout.unitForByte(span.end);
            if (end <= start || end > string.length) {
                continue;
            }
            NSRange range = NSMakeRange(start, end - start);
            [self applyStyle:span.style toString:attributed range:range];
            if (span.style.background) {
                layout.highlights.push_back({start, end, *span.style.background});
            }
        }
        layout.highlighted = true;
    }
    [self applySemanticTokensToLine:index text:attributed unitCount:string.length];
    [self applyDecorationsToLine:index text:text attributed:attributed layout:layout];
    [self applyInlayHintsToLine:index text:text attributed:attributed layout:layout];
    // Color brackets by nesting depth (skipping strings and comments).
    bool bracketColors = GWServices.shared.settings.bracketPairColors;
    std::optional<int> depth;
    if (bracketColors) {
        depth = [self depthAtLine:index];
    }
    if (depth && (tokens || !_highlighter || !_highlighter->grammar())) {
        std::vector<bool> code = [self codeMaskForLine:index tokens:tokens];
        int level = *depth;
        NSUInteger count = _bracketColors.count;
        for (size_t byte = 0; byte < text.size(); ++byte) {
            if (!code[byte]) continue;
            char c = text[byte];
            if (isOpenerByte(c)) {
                [attributed addAttribute:NSForegroundColorAttributeName value:_bracketColors[static_cast<NSUInteger>(level) % count]
                                   range:NSMakeRange(layout.unitForByte(byte), 1)];
                ++level;
            } else if (isCloserByte(c)) {
                level = std::max(0, level - 1);
                [attributed addAttribute:NSForegroundColorAttributeName value:_bracketColors[static_cast<NSUInteger>(level) % count]
                                   range:NSMakeRange(layout.unitForByte(byte), 1)];
            }
        }
    }
    layout.line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    if (_wrapEnabled) {
        [self addWrapRowsToLayout:layout text:text attributed:attributed];
    }
    auto inserted = _layouts.insert_or_assign(index, std::move(layout));
    return &inserted.first->second;
}

/// Text color and styling from extension decorations.
- (void)applyDecorationsToLine:(size_t)line
                          text:(std::string_view)text
                    attributed:(NSMutableAttributedString *)attributed
                        layout:(LineLayout &)layout {
    auto found = _decorationsByLine.find(line);
    if (found == _decorationsByLine.end()) {
        return;
    }
    for (const LineDecoration &entry : found->second) {
        const GWDecoration &look = entry.look;
        bool changesText = look.foreground || look.bold || look.italic || look.underline || look.strikethrough;
        if (!changesText) {
            continue;
        }
        size_t startByte = std::min(entry.startByte, text.size());
        size_t endByte = entry.toEndOfLine ? text.size() : std::min(entry.endByte, text.size());
        if (endByte <= startByte) {
            continue;
        }
        uint32_t start = layout.unitForByte(startByte);
        uint32_t end = layout.unitForByte(endByte);
        if (end <= start || end > attributed.length) {
            continue;
        }
        NSRange range = NSMakeRange(start, end - start);
        if (look.foreground) {
            [attributed addAttribute:NSForegroundColorAttributeName value:[self readableColor:*look.foreground] range:range];
        }
        if (look.bold || look.italic) {
            [attributed addAttribute:NSFontAttributeName value:[GWServices.shared editorFontBold:look.bold italic:look.italic] range:range];
        }
        if (look.underline) {
            [attributed addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
        }
        if (look.strikethrough) {
            [attributed addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
        }
    }
}

/// Backgrounds and outlines from extension decorations, drawn behind the text.
- (void)drawDecorationsFromLine:(size_t)first toLine:(size_t)last {
    if (_decorationsByLine.empty()) {
        return;
    }
    NSRect visible = self.visibleRect;
    const auto &buffer = _document->buffer();
    for (size_t line = first; line <= last; ++line) {
        auto found = _decorationsByLine.find(line);
        if (found == _decorationsByLine.end() || [self isLineHidden:line]) {
            continue;
        }
        for (const LineDecoration &entry : found->second) {
            const GWDecoration &look = entry.look;
            if (look.background && look.wholeLine) {
                [GWColor(*look.background) setFill];
                CGFloat bandHeight = [self rowsForLine:line] * _lineHeight - 2;
                NSRect band = NSMakeRect(NSMinX(visible) + 4, [self yForLine:line] + 1, NSWidth(visible) - 8, bandHeight);
                [[NSBezierPath bezierPathWithRoundedRect:band xRadius:5 yRadius:5] fill];
                continue;
            }
            if (!look.background && !look.border) {
                continue;
            }
            size_t size = buffer.line(line).size();
            size_t startByte = std::min(entry.startByte, size);
            size_t endByte = entry.toEndOfLine ? size : std::min(entry.endByte, size);
            if (endByte <= startByte) {
                continue;
            }
            [self enumerateSegmentsInLine:line fromByte:startByte toByte:endByte continuesPastEnd:NO
                                    block:^(CGFloat left, CGFloat right, CGFloat top) {
                NSRect box = NSMakeRect(left - 1, top + 2, right - left + 2, self->_lineHeight - 4);
                NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3];
                if (look.background) {
                    [GWColor(*look.background) setFill];
                    [path fill];
                }
                if (look.border) {
                    [GWColor(*look.border) setStroke];
                    path.lineWidth = 1;
                    [path stroke];
                }
            }];
        }
    }
}

/// Notes extensions put after the end of a line (an error message, a blame line…). A line that
/// already shows a language server's message inline keeps that one, rather than two notes overlapping.
- (void)drawDecorationNotesFromLine:(size_t)first toLine:(size_t)last {
    if (_decorationsByLine.empty() || _wrapEnabled) {
        return;
    }
    std::set<size_t> linesWithDiagnostics;
    if (GWServices.shared.settings.inlineDiagnostics) {
        for (const GWDiagnostic &diagnostic : _diagnostics) {
            linesWithDiagnostics.insert(diagnostic.range.start.line);
        }
    }
    for (size_t line = first; line <= last; ++line) {
        auto found = _decorationsByLine.find(line);
        bool hasDecorations = found != _decorationsByLine.end();
        // Notes after the line's end only fit on a plain, visible, single-row line without a problem marker.
        if (!hasDecorations || [self isLineHidden:line] || [self rowsForLine:line] != 1 || linesWithDiagnostics.count(line) > 0) {
            continue;
        }
        for (const LineDecoration &entry : found->second) {
            if (!entry.showsNote || entry.look.afterText.empty()) {
                continue;
            }
            NSString *note = @(entry.look.afterText.c_str());
            NSRange newline = [note rangeOfString:@"\n"];
            if (newline.location != NSNotFound) {
                note = [note substringToIndex:newline.location];
            }
            LineLayout *layout = [self layoutForLine:line];
            CGFloat endX = self.textLeft + layout->offsetInRow(0, static_cast<uint32_t>(layout->unitToByte.size() - 1));
            CGFloat left = endX + _charWidth * 3;
            CGFloat available = NSMaxX(self.visibleRect) - left - 24;
            if (available < 60 || note.length == 0) {
                continue;
            }
            NSColor *color = entry.look.afterColor ? GWColor(*entry.look.afterColor) : [NSColor.secondaryLabelColor colorWithAlphaComponent:0.9];
            NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:_font.pointSize - 1.5],
                                         NSForegroundColorAttributeName: color};
            NSSize size = [note sizeWithAttributes:attributes];
            CGFloat top = [self yForLine:line];
            NSRect textRect = NSMakeRect(left, top + (_lineHeight - size.height) / 2, std::min(size.width, available), size.height);
            [note drawWithRect:textRect
                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                    attributes:attributes];
            break;  // one note per line
        }
    }
}

/// Splits a long line into rows that fit the editor's width, each with its own CoreText line.
- (void)addWrapRowsToLayout:(LineLayout &)layout text:(std::string_view)text attributed:(NSAttributedString *)attributed {
    gw::WrapResult wrapped = gw::wrapLine(text, _wrapColumns, static_cast<uint32_t>(_tabSize));
    if (wrapped.rowStarts.size() < 2) {
        return;
    }
    for (uint32_t startByte : wrapped.rowStarts) {
        layout.rowStartUnits.push_back(layout.unitForByte(startByte));
    }
    layout.rowStartUnits.push_back(static_cast<uint32_t>(attributed.length));

    size_t rowCount = wrapped.rowStarts.size();
    for (size_t row = 0; row < rowCount; ++row) {
        NSUInteger start = layout.rowStartUnits[row];
        NSUInteger end = layout.rowStartUnits[row + 1];
        NSAttributedString *piece = [attributed attributedSubstringFromRange:NSMakeRange(start, end - start)];
        CTLineRef rowLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)piece);
        layout.rowLines.push_back(rowLine);
    }
    layout.continuationIndent = wrapped.continuationIndent * _charWidth;
}

/// A syntax color made readable against the editor background. Remembered, because the same few
/// colors are asked for again and again while lines are laid out.
- (NSColor *)readableColor:(gw::Color)themeColor {
    auto found = _readableColors.find(themeColor);
    if (found != _readableColors.end()) {
        return found->second;
    }
    NSColor *readable = GWReadableColor(GWColor(themeColor), _contrastBackground, 4.5);
    _readableColors[themeColor] = readable;
    return readable;
}

- (void)applyStyle:(const gw::TextStyle &)style toString:(NSMutableAttributedString *)string range:(NSRange)range {
    [string addAttribute:NSForegroundColorAttributeName value:[self readableColor:style.foreground] range:range];
    if (style.bold || style.italic) {
        NSFont *font = [GWServices.shared editorFontBold:style.bold italic:style.italic];
        [string addAttribute:NSFontAttributeName value:font range:range];
    }
    if (style.underline) {
        [string addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
    }
    if (style.strikethrough) {
        [string addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
    }
}

- (void)continueHighlighting {
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
}

- (CGFloat)xForPosition:(gw::Position)position {
    LineLayout *layout = [self layoutForLine:position.line];
    return self.textLeft + layout->offsetForUnit(layout->unitForByte(position.column));
}

/// Top of the screen row a position is drawn on.
- (CGFloat)yForPosition:(gw::Position)position {
    LineLayout *layout = [self layoutForLine:position.line];
    size_t row = layout->rowForUnit(layout->unitForByte(position.column));
    return [self yForLine:position.line] + row * _lineHeight;
}

- (gw::Position)positionForPoint:(NSPoint)point {
    const auto &buffer = _document->buffer();
    if (point.y < 0) return {0, 0};
    size_t subrow = 0;
    size_t line = [self lineAtY:point.y subrow:&subrow];
    if (line >= buffer.lineCount()) return buffer.end();
    LineLayout *layout = [self layoutForLine:line];
    subrow = std::min(subrow, layout->rowCount() - 1);
    CGFloat x = point.x - self.textLeft - layout->indentForRow(subrow);
    CFIndex local = CTLineGetStringIndexForPosition(layout->lineForRow(subrow), CGPointMake(x, 0));
    if (local == kCFNotFound) local = 0;
    uint32_t unit = layout->rowStart(subrow) + static_cast<uint32_t>(local);
    bool notLastRow = subrow + 1 < layout->rowCount();
    if (notLastRow) {
        // Clicking past the end of a wrapped row puts the caret at its end, not on the next row.
        unit = std::min(unit, layout->rowEnd(subrow) - 1);
    }
    return buffer.clamp({line, layout->byteForUnit(unit)});
}

- (NSRect)caretRect {
    if (self.vimBlockCursor) {
        gw::Position cursor = _vim.cursor(*_document);
        return NSMakeRect(std::round([self xForPosition:cursor]), [self yForPosition:cursor] + 2, _charWidth, _lineHeight - 4);
    }
    gw::Position caret = _document->selection.caret;
    return NSMakeRect(std::round([self xForPosition:caret]) - 1, [self yForPosition:caret] + 3, 2, _lineHeight - 6);
}

// MARK: Rows (soft wrap and folding)

- (BOOL)mapActive { return !_rowMap.empty(); }

- (CGFloat)yForLine:(size_t)line {
    if (_rowMap.empty()) {
        return line * _lineHeight;
    }
    return _rowMap.firstRow(line) * _lineHeight;
}

- (uint32_t)rowsForLine:(size_t)line {
    if (_rowMap.empty() || line >= _rowMap.lineCount()) {
        return 1;
    }
    return _rowMap.rows(line);
}

- (BOOL)isLineHidden:(size_t)line {
    if (_rowMap.empty() || line >= _rowMap.lineCount()) {
        return NO;
    }
    return _rowMap.rows(line) == 0;
}

/// The line drawn at height `y`, and which of its rows that is. A `y` below the last row gives
/// a line number past the end.
- (size_t)lineAtY:(CGFloat)y subrow:(size_t *)subrow {
    if (y < 0) {
        y = 0;
    }
    uint64_t row = static_cast<uint64_t>(y / _lineHeight);
    if (_rowMap.empty()) {
        if (subrow != nullptr) {
            *subrow = 0;
        }
        return static_cast<size_t>(row);
    }
    if (row >= _rowMap.totalRows()) {
        if (subrow != nullptr) {
            *subrow = 0;
        }
        return _rowMap.lineCount();
    }
    size_t line = _rowMap.lineForRow(row);
    if (subrow != nullptr) {
        *subrow = static_cast<size_t>(row - _rowMap.firstRow(line));
    }
    return line;
}

/// Like lineAtY, but with the fraction of the way through the line (the minimap needs it).
- (double)fractionalLineAtY:(CGFloat)y {
    if (y < 0) {
        y = 0;
    }
    if (_rowMap.empty()) {
        return y / _lineHeight;
    }
    double rowPosition = y / _lineHeight;
    uint64_t row = static_cast<uint64_t>(rowPosition);
    if (row >= _rowMap.totalRows()) {
        return static_cast<double>(_rowMap.lineCount());
    }
    size_t line = _rowMap.lineForRow(row);
    double within = rowPosition - static_cast<double>(_rowMap.firstRow(line));
    double rows = std::max(1u, _rowMap.rows(line));
    return static_cast<double>(line) + within / rows;
}

/// Width available for text, in character cells, when wrapping.
- (uint32_t)computeWrapColumns {
    NSScrollView *scrollView = self.enclosingScrollView;
    CGFloat available = scrollView ? NSWidth(scrollView.contentView.bounds) : 800;
    CGFloat usable = available - self.textLeft - 24;
    if (_charWidth <= 0) {
        return 80;
    }
    return static_cast<uint32_t>(std::max(8.0, std::floor(usable / _charWidth)));
}

/// Recomputes how many rows each line takes. Cheap when neither wrapping nor folding is on:
/// the map is dropped and line N is at row N.
- (void)rebuildRowMap {
    if (!_document || (!_wrapEnabled && _folds.empty())) {
        _rowMap.clear();
        return;
    }
    const auto &buffer = _document->buffer();
    size_t count = buffer.lineCount();
    std::vector<uint32_t> rows(count, 1);
    if (_wrapEnabled) {
        if (_wrapColumns == 0) {
            _wrapColumns = [self computeWrapColumns];
        }
        for (size_t line = 0; line < count; ++line) {
            rows[line] = gw::countWrapRows(buffer.line(line), _wrapColumns, static_cast<uint32_t>(_tabSize));
        }
    }
    for (const gw::Fold &fold : _folds.all()) {
        for (size_t line = fold.first + 1; line <= fold.last && line < count; ++line) {
            rows[line] = 0;
        }
    }
    _rowMap.assign(std::move(rows));
}

/// Something about the layout changed (wrap on/off, folds): update everything that depends on it.
- (void)rowLayoutChanged {
    _layouts.clear();
    [self rebuildRowMap];
    _stickyVersion = UINT64_MAX;
    [self updateFrameSize];
    self.needsDisplay = YES;
    _gutter.needsDisplay = YES;
    _minimap.needsDisplay = YES;
    [self updateCaretAnimated:NO];
}

/// Rows of the lines an edit touched changed length; keep the map in step.
- (void)document:(gw::Document *)document changed:(const gw::Change &)change {
    if (document != _document) return;
    _depthValid = std::min(_depthValid, change.firstLine);
    _matchVersion = UINT64_MAX;

    size_t foldCountBefore = _folds.all().size();
    if (foldCountBefore > 0) {
        _folds.adjustForEdit(change.firstLine, change.lastLine, change.lineDelta);
    }
    if (!_wrapEnabled && _folds.empty() && _rowMap.empty()) {
        return;
    }
    if (!_semantic.tokens.empty()) {
        size_t lastLineBefore = change.lastLine >= static_cast<size_t>(std::max(0L, change.lineDelta))
                                    ? static_cast<size_t>(static_cast<long>(change.lastLine) - change.lineDelta)
                                    : change.firstLine;
        gw::adjustSemanticTokensForEdit(_semantic.tokens, change.firstLine, std::max(change.firstLine, lastLineBefore), change.lineDelta);
    }
    bool linesMoved = change.lineDelta != 0;
    bool foldsChanged = _folds.all().size() != foldCountBefore;
    const auto &editedBuffer = document->buffer();
    size_t expectedOldCount = static_cast<size_t>(static_cast<long>(editedBuffer.lineCount()) - change.lineDelta);
    bool mapMatchesEdit = _rowMap.lineCount() == expectedOldCount;
    if (foldsChanged || !_folds.empty() || !mapMatchesEdit) {
        [self rebuildRowMap];
        return;
    }
    if (linesMoved) {
        // Lines were added or removed: recount only the lines the edit touched.
        size_t touchedNow = change.lastLine - change.firstLine + 1;
        size_t touchedBefore = static_cast<size_t>(static_cast<long>(touchedNow) - change.lineDelta);
        std::vector<uint32_t> newRows;
        for (size_t line = change.firstLine; line <= change.lastLine && line < editedBuffer.lineCount(); ++line) {
            uint32_t rows = 1;
            if (_wrapEnabled) {
                rows = gw::countWrapRows(editedBuffer.line(line), _wrapColumns, static_cast<uint32_t>(_tabSize));
            }
            newRows.push_back(rows);
        }
        _rowMap.replaceLines(change.firstLine, touchedBefore, newRows);
        return;
    }
    if (_wrapEnabled) {
        const auto &buffer = document->buffer();
        size_t last = std::min(change.lastLine, buffer.lineCount() - 1);
        for (size_t line = change.firstLine; line <= last; ++line) {
            if (_rowMap.rows(line) == 0) {
                continue;  // hidden inside a fold
            }
            _rowMap.setRows(line, gw::countWrapRows(buffer.line(line), _wrapColumns, static_cast<uint32_t>(_tabSize)));
        }
    }
}

// MARK: Drawing

/// Calls `block` once for each screen row a stretch of a line covers, with the left and right
/// edge of the covered part and the row's top. A range that ends where the line continues
/// (a selection running on into the next line) gets a little extra at its end.
- (void)enumerateSegmentsInLine:(size_t)line
                       fromUnit:(uint32_t)startUnit
                         toUnit:(uint32_t)endUnit
               continuesPastEnd:(BOOL)continues
                          block:(void (^)(CGFloat left, CGFloat right, CGFloat top))block {
    LineLayout *layout = [self layoutForLine:line];
    CGFloat lineTop = [self yForLine:line];
    size_t rows = layout->rowCount();
    size_t lastRow = rows - 1;
    BOOL emptyRange = startUnit >= endUnit;

    if (emptyRange) {
        size_t row = layout->rowForUnit(startUnit);
        CGFloat x = self.textLeft + layout->offsetInRow(row, startUnit);
        if (continues && row == lastRow) {
            block(x, x + _charWidth * 0.6, lineTop + row * _lineHeight);
        } else {
            block(x, x, lineTop + row * _lineHeight);
        }
        return;
    }
    for (size_t row = 0; row < rows; ++row) {
        uint32_t rowStart = layout->rowStart(row);
        uint32_t rowEnd = layout->rowEnd(row);
        uint32_t from = std::max(startUnit, rowStart);
        uint32_t to = std::min(endUnit, rowEnd);
        if (from >= to) {
            continue;
        }
        CGFloat left = self.textLeft + layout->offsetInRow(row, from);
        CGFloat right = self.textLeft + layout->offsetInRow(row, to);
        BOOL endsHere = row == lastRow && to == endUnit;
        if (endsHere && continues) {
            right += _charWidth * 0.6;
        }
        block(left, right, lineTop + row * _lineHeight);
    }
}

/// The same, with the range given in bytes of the line.
- (void)enumerateSegmentsInLine:(size_t)line
                       fromByte:(size_t)startByte
                         toByte:(size_t)endByte
               continuesPastEnd:(BOOL)continues
                          block:(void (^)(CGFloat left, CGFloat right, CGFloat top))block {
    LineLayout *layout = [self layoutForLine:line];
    [self enumerateSegmentsInLine:line
                         fromUnit:layout->unitForByte(startByte)
                           toUnit:layout->unitForByte(endByte)
                 continuesPastEnd:continues
                            block:block];
}

- (void)drawRect:(NSRect)dirtyRect {
    // Replace what was there instead of drawing over it: the background is see-through, so
    // drawing over old pixels would leave a faint echo of the previous text.
    [_backgroundColor setFill];
    NSRectFillUsingOperation(dirtyRect, NSCompositingOperationCopy);
    if (!_document) return;
    _highlightBlocked = false;

    const auto &buffer = _document->buffer();
    size_t count = buffer.lineCount();
    size_t first = [self lineAtY:NSMinY(dirtyRect) subrow:nullptr];
    size_t last = std::min(count - 1, [self lineAtY:NSMaxY(dirtyRect) subrow:nullptr]);
    if (first >= count) return;
    NSRect visible = self.visibleRect;
    gw::Range selection = _document->selection.range();
    gw::Position caretPosition = _document->selection.caret;
    size_t caretLine = caretPosition.line;

    // Every selection that covers text: the main one and those of extra cursors.
    std::vector<gw::Range> selectionRanges;
    if (!selection.empty()) {
        selectionRanges.push_back(selection);
    }
    for (const gw::Selection &extra : _document->extraSelections) {
        if (!extra.empty()) {
            selectionRanges.push_back(extra.range());
        }
    }
    bool hasExtraCursors = !_document->extraSelections.empty();

    // Current line: a soft rounded band on the row the caret is on.
    if (selection.empty() && !hasExtraCursors && caretLine >= first && caretLine <= last) {
        [_lineHighlight setFill];
        NSRect band = NSMakeRect(NSMinX(visible) + 4, [self yForPosition:caretPosition] + 1, NSWidth(visible) - 8, _lineHeight - 2);
        [[NSBezierPath bezierPathWithRoundedRect:band xRadius:7 yRadius:7] fill];
    }

    if (_executionLine >= 0 && static_cast<size_t>(_executionLine) >= first && static_cast<size_t>(_executionLine) <= last &&
        ![self isLineHidden:static_cast<size_t>(_executionLine)]) {
        [[NSColor.systemYellowColor colorWithAlphaComponent:0.16] setFill];
        NSRect band = NSMakeRect(NSMinX(visible) + 4, [self yForLine:static_cast<size_t>(_executionLine)] + 1, NSWidth(visible) - 8,
                                 [self rowsForLine:static_cast<size_t>(_executionLine)] * _lineHeight - 2);
        [[NSBezierPath bezierPathWithRoundedRect:band xRadius:7 yRadius:7] fill];
    }
    [self drawLineTintsFromLine:first toLine:last];
    [self drawFindMatchesFromLine:first toLine:last];

    const gw::EditorSettings &settings = GWServices.shared.settings;
    if (settings.sectionDividers) {
        [self drawSectionDividersFromLine:first toLine:last];
    }
    [self drawHighlightsFromLine:first toLine:last];
    [self drawDecorationsFromLine:first toLine:last];
    if (settings.highlightOccurrences) {
        [self drawOccurrencesFromLine:first toLine:last];
    }

    if (settings.indentGuides) {
        [self drawIndentGuidesFromLine:first toLine:last];
    }

    static BOOL markedFirstDraw = NO;
    if (!markedFirstDraw) {
        markedFirstDraw = YES;
        GWStartupMark(@"first code drawn");
    }
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));  // flipped view
    for (size_t line = first; line <= last; ++line) {
        if ([self isLineHidden:line]) continue;
        CGFloat y = [self yForLine:line];
        // Selections behind the text, with softly rounded ends.
        for (const gw::Range &covered : selectionRanges) {
            if (line < covered.start.line || line > covered.end.line) {
                continue;
            }
            size_t startByte = line == covered.start.line ? covered.start.column : 0;
            size_t endByte = line == covered.end.line ? covered.end.column : buffer.line(line).size();
            BOOL continues = line < covered.end.line;
            [_selectionColor setFill];
            [self enumerateSegmentsInLine:line fromByte:startByte toByte:endByte continuesPastEnd:continues
                                    block:^(CGFloat left, CGFloat right, CGFloat top) {
                NSRect band = NSMakeRect(left, top + 1, std::max(0.0, right - left), self->_lineHeight - 2);
                [[NSBezierPath bezierPathWithRoundedRect:band xRadius:4 yRadius:4] fill];
            }];
        }
        LineLayout *layout = [self layoutForLine:line];
        size_t rows = layout->rowCount();
        for (size_t row = 0; row < rows; ++row) {
            CGContextSetTextPosition(context, self.textLeft + layout->indentForRow(row), y + row * _lineHeight + _baseline);
            CTLineDraw(layout->lineForRow(row), context);
        }
        if (_folds.isFoldHeader(line)) {
            [self drawFoldPillForLine:line];
        }
    }

    [self drawDiagnosticsFromLine:first toLine:last];
    [self drawInlayHintsFromLine:first toLine:last];
    [self drawDecorationNotesFromLine:first toLine:last];

    // The other cursors are plain bars (only the main one blinks).
    for (const gw::Selection &extra : _document->extraSelections) {
        gw::Position at = _document->buffer().clamp(extra.caret);
        if (at.line < first || at.line > last || [self isLineHidden:at.line]) {
            continue;
        }
        NSRect bar = NSMakeRect(std::round([self xForPosition:at]) - 1, [self yForPosition:at] + 3, 2, _lineHeight - 6);
        [[_caretColor colorWithAlphaComponent:0.9] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1 yRadius:1] fill];
    }

    // Matching brackets get a thin rounded outline.
    if (auto match = [self bracketMatch]) {
        [_matchColor setStroke];
        for (gw::Position at : {match->first, match->second}) {
            if (at.line < first || at.line > last || [self isLineHidden:at.line]) continue;
            [self enumerateSegmentsInLine:at.line fromByte:at.column toByte:at.column + 1 continuesPastEnd:NO
                                    block:^(CGFloat left, CGFloat right, CGFloat top) {
                NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(left - 0.5, top + 3, right - left + 1, self->_lineHeight - 6)
                                                                   xRadius:3 yRadius:3];
                box.lineWidth = 1;
                [box stroke];
            }];
        }
    }

    // Text being composed with an input method, drawn at the caret.
    if (_markedText.length && self.window.firstResponder == self) {
        NSRect caret = self.caretRect;
        NSDictionary *attributes = @{NSFontAttributeName: _font, NSForegroundColorAttributeName: _foreground,
                                     NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                                     NSBackgroundColorAttributeName: _backgroundColor};
        [_markedText drawAtPoint:NSMakePoint(NSMaxX(caret), caret.origin.y - 3 + _baseline - _font.ascender) withAttributes:attributes];
    }
}

// MARK: Problems (squiggles)

- (void)setDiagnostics:(std::vector<GWDiagnostic>)diagnostics {
    std::sort(diagnostics.begin(), diagnostics.end(), [](const GWDiagnostic &a, const GWDiagnostic &b) {
        if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
        return a.severity < b.severity;
    });
    _diagnostics = std::move(diagnostics);
    self.needsDisplay = YES;
    _gutter.needsDisplay = YES;
}

- (int)diagnosticSeverityForLine:(size_t)line {
    auto begin = std::lower_bound(_diagnostics.begin(), _diagnostics.end(), line,
                                  [](const GWDiagnostic &item, size_t value) { return item.range.start.line < value; });
    if (begin == _diagnostics.end() || begin->range.start.line != line) {
        return 0;
    }
    return begin->severity;  // sorted: the first one is the most severe
}

- (NSColor *)colorForSeverity:(int)severity {
    switch (severity) {
        case 1: return NSColor.systemRedColor;
        case 2: return NSColor.systemOrangeColor;
        case 3: return NSColor.systemBlueColor;
        default: return [NSColor.secondaryLabelColor colorWithAlphaComponent:0.9];
    }
}

/// A wavy line under a stretch of text.
- (void)drawSquiggleFrom:(CGFloat)left to:(CGFloat)right top:(CGFloat)top color:(NSColor *)color {
    CGFloat baselineY = top + _baseline + 3;
    CGFloat width = std::max(right - left, _charWidth * 0.8);
    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 1.1;
    path.lineCapStyle = NSLineCapStyleRound;
    const CGFloat step = 2.5;
    [path moveToPoint:NSMakePoint(left, baselineY)];
    BOOL up = YES;
    for (CGFloat x = left + step; x <= left + width + step; x += step) {
        [path lineToPoint:NSMakePoint(std::min(x, left + width), baselineY + (up ? -1.6 : 1.0))];
        up = !up;
    }
    [color setStroke];
    [path stroke];
}

- (void)drawDiagnosticsFromLine:(size_t)first toLine:(size_t)last {
    if (_diagnostics.empty()) {
        return;
    }
    auto begin = std::lower_bound(_diagnostics.begin(), _diagnostics.end(), first,
                                  [](const GWDiagnostic &item, size_t value) { return item.range.start.line < value; });
    const auto &buffer = _document->buffer();
    BOOL showInline = GWServices.shared.settings.inlineDiagnostics && !_wrapEnabled;
    size_t lastInlineLine = SIZE_MAX;
    for (auto item = begin; item != _diagnostics.end() && item->range.start.line <= last; ++item) {
        size_t line = item->range.start.line;
        if (line >= buffer.lineCount() || [self isLineHidden:line]) {
            continue;
        }
        NSColor *color = [self colorForSeverity:item->severity];
        std::string_view text = buffer.line(line);
        size_t startByte = std::min(item->range.start.column, text.size());
        size_t endByte = item->range.end.line == line ? std::min(item->range.end.column, text.size()) : text.size();
        if (endByte <= startByte) {
            // A point: underline the word there, or the next character.
            gw::Range word = buffer.wordAt({line, startByte});
            if (word.start.line == line && word.end.column > word.start.column) {
                startByte = word.start.column;
                endByte = word.end.column;
            } else {
                endByte = std::min(text.size(), buffer.nextCharacter({line, startByte}).column);
            }
        }
        [self enumerateSegmentsInLine:line fromByte:startByte toByte:endByte continuesPastEnd:NO
                                block:^(CGFloat left, CGFloat right, CGFloat top) {
            [self drawSquiggleFrom:left to:right top:top color:color];
        }];
        if (showInline && line != lastInlineLine && [self rowsForLine:line] == 1 && !_folds.isFoldHeader(line)) {
            lastInlineLine = line;
            [self drawInlineMessage:item->message severity:item->severity forLine:line];
        }
    }
}

/// The problem's text after the end of the line, tinted like the squiggle (like Error Lens).
- (void)drawInlineMessage:(const std::string &)message severity:(int)severity forLine:(size_t)line {
    NSString *full = @(message.c_str());
    NSRange newline = [full rangeOfString:@"\n"];
    if (newline.location != NSNotFound) {
        full = [full substringToIndex:newline.location];
    }
    if (full.length == 0) {
        return;
    }
    NSColor *color = [self colorForSeverity:severity];
    LineLayout *layout = [self layoutForLine:line];
    CGFloat endX = self.textLeft + layout->offsetInRow(0, static_cast<uint32_t>(layout->unitToByte.size() - 1));
    CGFloat left = endX + _charWidth * 3;
    CGFloat available = NSMaxX(self.visibleRect) - left - 24;
    if (available < 60) {
        return;
    }
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:_font.pointSize - 1.5],
                                 NSForegroundColorAttributeName: [color colorWithAlphaComponent:0.85]};
    NSSize size = [full sizeWithAttributes:attributes];
    CGFloat width = std::min(size.width, available);
    CGFloat top = [self yForLine:line];
    NSRect chip = NSMakeRect(left - 6, top + 3, width + 12, _lineHeight - 6);
    [[color colorWithAlphaComponent:0.10] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:5 yRadius:5] fill];
    NSRect textRect = NSMakeRect(left, top + (_lineHeight - size.height) / 2, width, size.height);
    [full drawWithRect:textRect
               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:attributes];
}

// MARK: Semantic highlighting

- (void)setSemanticTokens:(std::shared_ptr<const gw::SemanticTokenSet>)tokens {
    if (tokens != nullptr) {
        _semantic = *tokens;
    } else {
        _semantic = gw::SemanticTokenSet();
    }
    _semanticStyles.clear();
    _layouts.clear();
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
}

/// The look for a kind of token, or nothing if the grammar's own color should stay.
- (std::optional<gw::TextStyle>)styleForSemanticType:(uint32_t)type {
    auto cached = _semanticStyles.find(type);
    if (cached != _semanticStyles.end()) {
        return cached->second;
    }
    std::optional<gw::TextStyle> result;
    if (type < _semantic.typeNames.size()) {
        std::string scope = gw::scopeForSemanticType(_semantic.typeNames[type], _semantic.modifierNames);
        if (!scope.empty()) {
            const gw::Theme &theme = GWServices.shared.theme;
            gw::TextStyle style = theme.styleFor(std::vector<std::string>{"source", scope});
            gw::Color plain = theme.color("editor.foreground", theme.isDark() ? 0xD4D4D4FF : 0x1E1E1EFF);
            if (style.foreground != plain) {
                result = style;  // the theme really has a color for this kind of name
            }
        }
    }
    _semanticStyles[type] = result;
    return result;
}

/// Paints the tokens the language server knows the meaning of, over the grammar's colors.
- (void)applySemanticTokensToLine:(size_t)line text:(NSMutableAttributedString *)text unitCount:(NSUInteger)unitCount {
    if (_semantic.tokens.empty() || !GWServices.shared.settings.semanticHighlighting) {
        return;
    }
    auto first = std::lower_bound(_semantic.tokens.begin(), _semantic.tokens.end(), line,
                                  [](const gw::SemanticToken &token, size_t value) { return token.line < value; });
    for (auto token = first; token != _semantic.tokens.end() && token->line == line; ++token) {
        std::optional<gw::TextStyle> style = [self styleForSemanticType:token->type];
        if (!style || token->startUnit >= unitCount) {
            continue;
        }
        NSUInteger length = std::min<NSUInteger>(token->lengthUnits, unitCount - token->startUnit);
        if (length == 0) {
            continue;
        }
        [self applyStyle:*style toString:text range:NSMakeRange(token->startUnit, length)];
    }
}

// MARK: Breakpoints

- (BOOL)hasBreakpointAtLine:(size_t)line {
    return _document != nullptr && _document->breakpointLines.count(line) > 0;
}

- (BOOL)isExecutionLine:(size_t)line {
    return _executionLine >= 0 && static_cast<size_t>(_executionLine) == line;
}

- (void)toggleBreakpointAtLine:(size_t)line {
    if (!_document || line >= _document->buffer().lineCount()) {
        return;
    }
    if (_document->breakpointLines.count(line) > 0) {
        _document->breakpointLines.erase(line);
    } else {
        _document->breakpointLines.insert(line);
    }
    _gutter.needsDisplay = YES;
    if (self.onBreakpointsChange) {
        self.onBreakpointsChange();
    }
}

- (void)setExecutionLine:(NSInteger)line {
    if (line == _executionLine) {
        return;
    }
    _executionLine = line;
    self.needsDisplay = YES;
    _gutter.needsDisplay = YES;
}

// MARK: Sticky scroll

/// "public:", "private:" and "protected:" sit inside the class rather than heading a block.
static bool isAccessLabel(std::string_view line) {
    size_t start = line.find_first_not_of(" \t");
    if (start == std::string::npos) {
        return false;
    }
    std::string_view text(line.data() + start, line.size() - start);
    for (std::string_view label : {"public:", "private:", "protected:", "public slots:", "signals:"}) {
        if (text.substr(0, label.size()) == label) {
            return true;
        }
    }
    return false;
}

- (NSView *)stickyView { return _stickyView; }
- (CGFloat)stickyHeight { return _stickyLines.size() * _lineHeight; }

/// The lines that open the blocks around `line`, outermost first: the nearest earlier line indented
/// less, then the one before it indented less than that, and so on (at most three).
- (std::vector<size_t>)headersEnclosingLine:(size_t)line {
    std::vector<size_t> headers;
    const auto &buffer = _document->buffer();
    if (line >= buffer.lineCount()) {
        return headers;
    }
    // A blank line takes the indentation of the next code below it.
    std::optional<size_t> indent = indentColumns(buffer.line(line), _tabSize);
    for (size_t look = line + 1; !indent && look < buffer.lineCount() && look < line + 60; ++look) {
        indent = indentColumns(buffer.line(look), _tabSize);
    }
    if (!indent) {
        return headers;
    }
    size_t currentIndent = *indent;
    size_t cursor = line;
    while (headers.size() < 3 && currentIndent > 0) {
        bool found = false;
        size_t limit = cursor > 400 ? cursor - 400 : 0;
        for (size_t candidate = cursor; candidate-- > limit;) {
            std::optional<size_t> candidateIndent = indentColumns(buffer.line(candidate), _tabSize);
            if (candidateIndent && *candidateIndent < currentIndent && !isAccessLabel(buffer.line(candidate))) {
                headers.insert(headers.begin(), candidate);
                currentIndent = *candidateIndent;
                cursor = candidate;
                found = true;
                break;
            }
        }
        if (!found) {
            break;
        }
    }
    return headers;
}

/// Works out which header lines belong at the top for the current scroll position.
- (void)updateStickyScroll {
    std::vector<size_t> lines;
    if (_document && GWServices.shared.settings.stickyScroll) {
        NSRect visible = self.visibleRect;
        if (NSMinY(visible) > _lineHeight) {
            size_t topLine = [self lineAtY:NSMinY(visible) subrow:nullptr];
            if (topLine == _stickyTopLine && _document->version() == _stickyVersion) {
                return;  // nothing that matters has moved
            }
            _stickyTopLine = topLine;
            _stickyVersion = _document->version();
            std::vector<size_t> first = [self headersEnclosingLine:topLine];
            // The code just below the pinned lines is what should decide what is pinned.
            size_t below = [self lineAtY:NSMinY(visible) + first.size() * _lineHeight subrow:nullptr];
            lines = below == topLine ? first : [self headersEnclosingLine:below];
            // Headers that are themselves on screen below the band aren't pinned again.
            while (!lines.empty() && lines.back() >= below) {
                lines.pop_back();
            }
        }
    }
    if (lines == _stickyLines) {
        return;
    }
    bool heightChanged = lines.size() != _stickyLines.size();
    _stickyLines = std::move(lines);
    _stickyView.needsDisplay = YES;
    if (heightChanged && self.onStickyChange) {
        self.onStickyChange();
    }
}

- (void)drawStickyInBounds:(NSRect)bounds {
    if (_stickyLines.empty() || !_document) {
        return;
    }
    CGFloat gutter = self.gutterWidth;
    CGFloat scrollX = NSMinX(self.visibleRect);
    NSColor *solid = [_backgroundColor colorWithAlphaComponent:1];
    // The editor background is see-through; the pinned lines sit on something solid so the code
    // scrolling underneath doesn't show through them.
    NSColor *base = [NSColor.windowBackgroundColor blendedColorWithFraction:0.35 ofColor:solid] ?: solid;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));

    NSMutableParagraphStyle *right = [NSMutableParagraphStyle new];
    right.alignment = NSTextAlignmentRight;
    NSDictionary *numberAttributes = @{NSFontAttributeName: _lineNumberFont, NSForegroundColorAttributeName: _lineNumberColor,
                                       NSParagraphStyleAttributeName: right};
    CGFloat numberHeight = _lineNumberFont.ascender - _lineNumberFont.descender;

    [base setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, NSWidth(bounds), _stickyLines.size() * _lineHeight), NSCompositingOperationSourceOver);
    for (size_t row = 0; row < _stickyLines.size(); ++row) {
        size_t line = _stickyLines[row];
        CGFloat y = row * _lineHeight;
        NSRect label = NSMakeRect(0, y + (_lineHeight - numberHeight) / 2 - 1, gutter - 26, numberHeight + 2);
        [[NSString stringWithFormat:@"%zu", line + 1] drawInRect:label withAttributes:numberAttributes];
        LineLayout *layout = [self layoutForLine:line];
        CGContextSetTextPosition(context, gutter + self.textLeft - scrollX, y + _baseline);
        CTLineDraw(layout->lineForRow(0), context);
    }
    // A hairline and a soft shadow under the last pinned line.
    CGFloat bottom = _stickyLines.size() * _lineHeight;
    [_dividerColor setFill];
    NSRectFillUsingOperation(NSMakeRect(0, bottom - 1, NSWidth(bounds), 1), NSCompositingOperationSourceOver);
}

- (void)clickedStickyRow:(size_t)row {
    if (row >= _stickyLines.size() || !_document) {
        return;
    }
    [self jumpToPosition:{_stickyLines[row], 0}];
}

// MARK: Hover

/// The rectangle a stretch of one line covers, in the editor's own coordinates.
- (NSRect)viewRectForRange:(gw::Range)range {
    if (!_document) {
        return NSZeroRect;
    }
    gw::Position start = _document->buffer().clamp(range.start);
    gw::Position end = _document->buffer().clamp(range.end);
    CGFloat left = [self xForPosition:start];
    CGFloat right = end.line == start.line ? [self xForPosition:end] : left + _charWidth;
    return NSMakeRect(left, [self yForPosition:start], std::max<CGFloat>(right - left, _charWidth), _lineHeight);
}

- (NSRect)screenRectForPosition:(gw::Position)position {
    if (!_document) {
        return NSZeroRect;
    }
    position = _document->buffer().clamp(position);
    NSRect rect = NSMakeRect([self xForPosition:position], [self yForPosition:position], _charWidth, _lineHeight);
    NSRect inWindow = [self convertRect:rect toView:nil];
    return [self.window convertRectToScreen:inWindow];
}

- (void)cancelHover {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hoverTimerFired) object:nil];
    if (_hoverActive) {
        _hoverActive = NO;
        if (self.onHoverEnd) self.onHoverEnd();
    }
}

- (void)mouseMoved:(NSEvent *)event {
    if (!_document || !self.onHoverRequest) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (point.x < self.textLeft) {
        [self cancelHover];
        _hoverWord = gw::Range{{SIZE_MAX, 0}, {SIZE_MAX, 0}};
        return;
    }
    gw::Position position = [self positionForPoint:point];
    const auto &buffer = _document->buffer();
    gw::Range word = buffer.wordAt(position);
    std::string_view text = buffer.line(position.line);
    bool onWord = word.start.line == position.line && word.end.column > word.start.column &&
                  position.column < text.size() && !std::isspace(static_cast<unsigned char>(text[position.column]));
    // The pointer must really be over the text, not just to the right of the line.
    if (onWord) {
        CGFloat endX = [self xForPosition:{position.line, text.size()}];
        onWord = point.x <= endX + _charWidth || [self rowsForLine:position.line] > 1;
    }
    if (!onWord) {
        [self cancelHover];
        _hoverWord = gw::Range{{SIZE_MAX, 0}, {SIZE_MAX, 0}};
        return;
    }
    if (_hoverWord.start == word.start && _hoverWord.end == word.end) {
        return;  // still on the same word
    }
    [self cancelHover];
    _hoverWord = word;
    _hoverPoint = point;
    [self performSelector:@selector(hoverTimerFired) withObject:nil afterDelay:0.5];
}

- (void)hoverTimerFired {
    if (!_document || !self.onHoverRequest || _hoverWord.start.line == SIZE_MAX) return;
    _hoverActive = YES;
    self.onHoverRequest(_hoverWord.start, _hoverWord);
}

- (void)mouseExited:(NSEvent *)event {
    _hoverWord = gw::Range{{SIZE_MAX, 0}, {SIZE_MAX, 0}};
    [self cancelHover];
}

// MARK: Folding

/// Where the "…" marker after a folded line goes.
- (NSRect)foldPillRectForLine:(size_t)line {
    LineLayout *layout = [self layoutForLine:line];
    size_t lastRow = layout->rowCount() - 1;
    uint32_t endUnit = static_cast<uint32_t>(layout->unitToByte.size() - 1);
    CGFloat x = self.textLeft + layout->offsetInRow(lastRow, endUnit) + 8;
    CGFloat y = [self yForLine:line] + lastRow * _lineHeight;
    return NSMakeRect(x, y + 5, _charWidth * 3.2, _lineHeight - 10);
}

- (void)drawFoldPillForLine:(size_t)line {
    NSRect pill = [self foldPillRectForLine:line];
    [[_foreground colorWithAlphaComponent:0.14] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:5 yRadius:5] fill];
    NSDictionary *attributes = @{NSFontAttributeName: _font, NSForegroundColorAttributeName: [_foreground colorWithAlphaComponent:0.7]};
    NSString *dots = @"\u2026";
    NSSize size = [dots sizeWithAttributes:attributes];
    NSPoint origin = NSMakePoint(NSMidX(pill) - size.width / 2, NSMidY(pill) - size.height / 2);
    [dots drawAtPoint:origin withAttributes:attributes];
}

- (BOOL)isLineFolded:(size_t)line { return _folds.isFoldHeader(line); }

- (BOOL)isLineFoldable:(size_t)line {
    if (!_document || line >= _document->buffer().lineCount()) {
        return NO;
    }
    return gw::isFoldable(_document->buffer(), line, _tabSize);
}

/// Folds the block that starts on `line`, or opens it if it is folded.
- (void)toggleFoldAtLine:(size_t)line {
    if (!_document) return;
    if (_folds.isFoldHeader(line)) {
        _folds.unfold(line);
        [self rowLayoutChanged];
        return;
    }
    if (![self isLineFoldable:line]) return;
    size_t end = gw::foldEnd(_document->buffer(), line, _tabSize);
    _folds.fold(line, end);
    [self moveCaretOutOfHiddenLines];
    [self rowLayoutChanged];
}

/// After folding, a caret inside the hidden lines moves to the end of the line that stays visible.
- (void)moveCaretOutOfHiddenLines {
    gw::Selection selection = _document->selection;
    for (const gw::Fold &fold : _folds.all()) {
        bool caretHidden = selection.caret.line > fold.first && selection.caret.line <= fold.last;
        bool anchorHidden = selection.anchor.line > fold.first && selection.anchor.line <= fold.last;
        if (caretHidden || anchorHidden) {
            gw::Position header = {fold.first, _document->buffer().line(fold.first).size()};
            _document->selection = {header, header};
            return;
        }
    }
}

/// The nearest line at or above `line` that starts a foldable block containing it.
- (std::optional<size_t>)foldableLineContaining:(size_t)line {
    const auto &buffer = _document->buffer();
    if (gw::isFoldable(buffer, line, _tabSize)) {
        return line;
    }
    size_t limit = line > 5000 ? line - 5000 : 0;
    for (size_t candidate = line; candidate-- > limit;) {
        if (gw::isFoldable(buffer, candidate, _tabSize) && gw::foldEnd(buffer, candidate, _tabSize) >= line) {
            return candidate;
        }
    }
    return std::nullopt;
}

- (IBAction)foldCode:(id)sender {
    if (!_document) return;
    std::optional<size_t> line = [self foldableLineContaining:_document->selection.caret.line];
    if (!line) {
        NSBeep();
        return;
    }
    if (_folds.isFoldHeader(*line)) {
        // Already folded: fold the block around it instead.
        std::optional<size_t> outer;
        const auto &buffer = _document->buffer();
        for (size_t candidate = *line; candidate-- > 0 && *line - candidate < 5000;) {
            if (gw::isFoldable(buffer, candidate, _tabSize) && gw::foldEnd(buffer, candidate, _tabSize) >= *line) {
                outer = candidate;
                break;
            }
        }
        if (!outer) return;
        line = outer;
    }
    [self toggleFoldAtLine:*line];
}

- (IBAction)unfoldCode:(id)sender {
    if (!_document) return;
    if (_folds.unfoldContaining(_document->selection.caret.line)) {
        [self rowLayoutChanged];
    }
}

- (IBAction)foldAllCode:(id)sender {
    if (!_document) return;
    const auto &buffer = _document->buffer();
    _folds.clear();
    size_t line = 0;
    while (line < buffer.lineCount()) {
        if (gw::isFoldable(buffer, line, _tabSize)) {
            size_t end = gw::foldEnd(buffer, line, _tabSize);
            _folds.fold(line, end);
            line = end + 1;
        } else {
            ++line;
        }
    }
    [self moveCaretOutOfHiddenLines];
    [self rowLayoutChanged];
}

- (IBAction)unfoldAllCode:(id)sender {
    if (_folds.empty()) return;
    _folds.clear();
    [self rowLayoutChanged];
}

- (IBAction)toggleWordWrap:(id)sender {
    [GWServices.shared updateSettings:^(gw::EditorSettings &settings) {
        settings.wordWrap = !settings.wordWrap;
    }];
}

/// Whole-line colors, for added and removed lines in a diff.
- (void)drawLineTintsFromLine:(size_t)first toLine:(size_t)last {
    if (_lineTints.empty()) {
        return;
    }
    NSRect visible = self.visibleRect;
    for (size_t line = first; line <= last && line < _lineTints.size(); ++line) {
        if (_lineTints[line] == 0 || [self isLineHidden:line]) {
            continue;
        }
        [GWColor(_lineTints[line]) setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(visible), [self yForLine:line], NSWidth(visible), [self rowsForLine:line] * _lineHeight),
                                 NSCompositingOperationSourceOver);
    }
}

/// Find results: a soft box behind every match, stronger on the current one.
- (void)drawFindMatchesFromLine:(size_t)first toLine:(size_t)last {
    if (_findMatches.empty()) {
        return;
    }
    // Matches are sorted; skip to the first visible one.
    auto begin = std::lower_bound(_findMatches.begin(), _findMatches.end(), first,
                                  [](const gw::Range &range, size_t line) { return range.end.line < line; });
    NSColor *matchColor = [NSColor.systemYellowColor colorWithAlphaComponent:0.28];
    NSColor *currentColor = [NSColor.systemOrangeColor colorWithAlphaComponent:0.55];
    for (auto match = begin; match != _findMatches.end() && match->start.line <= last; ++match) {
        if (match->start.line != match->end.line || [self isLineHidden:match->start.line]) {
            continue;
        }
        BOOL isCurrent = static_cast<long>(match - _findMatches.begin()) == _currentFindMatch;
        [self enumerateSegmentsInLine:match->start.line fromByte:match->start.column toByte:match->end.column continuesPastEnd:NO
                                block:^(CGFloat left, CGFloat right, CGFloat top) {
            NSRect box = NSMakeRect(left - 1, top + 2, std::max<CGFloat>(right - left, 3) + 2, self->_lineHeight - 4);
            [isCurrent ? currentColor : matchColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
            if (isCurrent) {
                [[NSColor.systemOrangeColor colorWithAlphaComponent:0.9] setStroke];
                NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3];
                outline.lineWidth = 1;
                [outline stroke];
            }
        }];
    }
}

/// Xcode-style: a thin line across the editor above every "// MARK: - Title".
- (void)drawSectionDividersFromLine:(size_t)first toLine:(size_t)last {
    NSRect visible = self.visibleRect;
    [_dividerColor setFill];
    for (const gw::Section &section : _sections) {
        if (!section.divider || section.line < first || section.line > last || [self isLineHidden:section.line]) {
            continue;
        }
        CGFloat y = std::round([self yForLine:section.line]) + 0.5;
        NSRect line = NSMakeRect(NSMinX(visible) + 6, y - 0.5, NSWidth(visible) - 12, 1);
        NSRectFillUsingOperation(line, NSCompositingOperationSourceOver);
    }
}

/// Backgrounds from the user's color rules ("highlight this name", scope backgrounds).
- (void)drawHighlightsFromLine:(size_t)first toLine:(size_t)last {
    for (size_t line = first; line <= last; ++line) {
        if ([self isLineHidden:line]) continue;
        LineLayout *layout = [self layoutForLine:line];
        for (const LineLayout::Highlight &highlight : layout->highlights) {
            NSColor *color = GWColor(highlight.color);
            [self enumerateSegmentsInLine:line fromUnit:highlight.startUnit toUnit:highlight.endUnit continuesPastEnd:NO
                                    block:^(CGFloat left, CGFloat right, CGFloat top) {
                NSRect box = NSMakeRect(left - 1, top + 2, right - left + 2, self->_lineHeight - 4);
                [color setFill];
                [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
            }];
        }
    }
}

/// Every whole-word occurrence of the name under the caret, softly highlighted.
- (void)drawOccurrencesFromLine:(size_t)first toLine:(size_t)last {
    if (!_document->selection.empty()) {
        return;
    }
    std::string word = [self wordAtCaret];
    if (word.size() < 2) {
        return;
    }
    const auto &buffer = _document->buffer();
    [_occurrenceColor setFill];
    for (size_t line = first; line <= last; ++line) {
        if ([self isLineHidden:line]) continue;
        std::string_view text = buffer.line(line);
        size_t found = text.find(word);
        while (found != std::string::npos) {
            size_t end = found + word.size();
            bool startsWord = found == 0 || !gw::isWordByte(static_cast<unsigned char>(text[found - 1]));
            bool endsWord = end >= text.size() || !gw::isWordByte(static_cast<unsigned char>(text[end]));
            if (startsWord && endsWord) {
                [self enumerateSegmentsInLine:line fromByte:found toByte:end continuesPastEnd:NO
                                        block:^(CGFloat left, CGFloat right, CGFloat top) {
                    NSRect box = NSMakeRect(left - 1, top + 2, right - left + 2, self->_lineHeight - 4);
                    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
                }];
            }
            found = text.find(word, found + 1);
        }
    }
}

// MARK: Caret context (for the color inspector and the breadcrumb)

- (std::string)wordAtCaret {
    if (!_document) {
        return std::string();
    }
    const auto &buffer = _document->buffer();
    gw::Range range = buffer.wordAt(_document->selection.caret);
    std::string word = buffer.text(range);
    if (word.empty() || std::isdigit(static_cast<unsigned char>(word[0]))) {
        return std::string();
    }
    for (char character : word) {
        if (!gw::isWordByte(static_cast<unsigned char>(character))) {
            return std::string();  // punctuation, not a name
        }
    }
    return word;
}

/// The highlighted token under the caret (at the very end of a line, the last one).
- (const gw::tm::Token *)tokenAtCaret {
    if (!_document || !_highlighter || !_highlighter->grammar()) {
        return nullptr;
    }
    gw::Position caret = _document->selection.caret;
    const std::vector<gw::tm::Token> *tokens = _highlighter->tokens(_document->buffer(), caret.line);
    if (!tokens || tokens->empty()) {
        return nullptr;
    }
    for (const gw::tm::Token &token : *tokens) {
        if (caret.column >= token.start && caret.column < token.end) {
            return &token;
        }
    }
    return &tokens->back();
}

- (std::vector<std::string>)scopesAtCaret {
    std::vector<std::string> scopes;
    const gw::tm::Token *under = [self tokenAtCaret];
    if (!under) {
        return scopes;
    }
    for (const gw::tm::ScopeNode *node = under->scopes; node != nullptr; node = node->parent) {
        scopes.push_back(node->name);
    }
    return scopes;
}

- (std::optional<gw::TextStyle>)styleAtCaret {
    if ([self tokenAtCaret] == nullptr) {
        return std::nullopt;
    }
    gw::Position caret = _document->selection.caret;
    std::string_view text = _document->buffer().line(caret.line);
    const std::vector<gw::tm::Token> *tokens = _highlighter->tokens(_document->buffer(), caret.line);
    std::vector<gw::StyledSpan> spans = GWServices.shared.stylist.styleLine(text, *tokens);
    if (spans.empty()) {
        return std::nullopt;
    }
    for (const gw::StyledSpan &span : spans) {
        if (caret.column >= span.start && caret.column < span.end) {
            return span.style;
        }
    }
    return spans.back().style;
}

- (std::optional<gw::TextStyle>)styleForScopeAtCaret:(const std::string &)scope {
    const gw::tm::Token *under = [self tokenAtCaret];
    if (!under) {
        return std::nullopt;
    }
    for (const gw::tm::ScopeNode *node = under->scopes; node != nullptr; node = node->parent) {
        if (node->name == scope) {
            return GWServices.shared.stylist.styleForScopes(node);
        }
    }
    return std::nullopt;
}

- (void)jumpToLine:(size_t)line {
    [self jumpToPosition:{line, 0}];
}

- (void)jumpToPosition:(gw::Position)position {
    if (!_document) {
        return;
    }
    gw::Position target = _document->buffer().clamp(position);
    _document->extraSelections.clear();
    _document->selection = {target, target};
    [self scrollToLineCentered:target.line];
    [self selectionDidChange];
    [self.window makeFirstResponder:self];
}

- (void)editDocument:(void (^)(gw::Document &))edits {
    if (!_document || _document->readOnly) {
        return;
    }
    _document->beginUndoGroup();
    edits(*_document);
    _document->endUndoGroup();
    [self invalidateLayout];
    [self scheduleSectionsRefresh];
    [self selectionDidChange];
    if (self.onEdit) {
        self.onEdit();
    }
}

- (void)replaceRange:(gw::Range)range withText:(const std::string &)text {
    if (!_document) {
        return;
    }
    gw::Position caret = _document->replace(range, text);
    _document->selection = {caret, caret};
    [self didEdit];
    [self selectionDidChange];
    [self.window makeFirstResponder:self];
}

// MARK: Right-click menu

- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (!_document) {
        return nil;
    }
    // Right-clicking outside the selection moves the caret there first.
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    gw::Position position = [self positionForPoint:point];
    gw::Range selection = _document->selection.range();
    bool insideSelection = !selection.empty() && position >= selection.start && position <= selection.end;
    if (!insideSelection) {
        _document->selection = {position, position};
        [self selectionDidChange];
    }

    NSMenu *menu = [NSMenu new];
    std::string word = [self wordAtCaret];
    if (!word.empty()) {
        NSString *name = @(word.c_str());
        [menu addItemWithTitle:[NSString stringWithFormat:@"Color “%@”…", name] action:@selector(inspectColors:) keyEquivalent:@""];
        [menu addItemWithTitle:[NSString stringWithFormat:@"Highlight Every “%@”", name]
                        action:@selector(highlightName:)
                 keyEquivalent:@""];
        const auto &identifiers = GWServices.shared.settings.colors.identifiers;
        if (identifiers.count(word) > 0) {
            [menu addItemWithTitle:[NSString stringWithFormat:@"Clear Colors for “%@”", name]
                            action:@selector(clearNameColors:)
                     keyEquivalent:@""];
        }
        [menu addItem:NSMenuItem.separatorItem];
    }
    [menu addItemWithTitle:@"Inspect Colors at Caret…" action:@selector(inspectColors:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Toggle Line Comment" action:@selector(toggleLineComment:) keyEquivalent:@""];
    for (NSMenuItem *item in menu.itemArray) {
        item.target = self;
    }
    return menu;
}

- (IBAction)inspectColors:(id)sender {
    if (self.onInspectColors) {
        self.onInspectColors();
    }
}

/// Gives the name under the caret a highlight in its own rainbow color, everywhere.
- (IBAction)highlightName:(id)sender {
    std::string word = [self wordAtCaret];
    if (word.empty()) {
        return;
    }
    bool dark = GWServices.shared.theme.isDark();
    gw::Color color = gw::Stylist::rainbowColor(word, dark);
    gw::Color translucent = (color & 0xFFFFFF00) | 0x50;
    [GWServices.shared updateSettings:^(gw::EditorSettings &settings) {
        settings.colors.identifiers[word].background = translucent;
    }];
}

- (IBAction)clearNameColors:(id)sender {
    std::string word = [self wordAtCaret];
    [GWServices.shared updateSettings:^(gw::EditorSettings &settings) {
        settings.colors.identifiers.erase(word);
    }];
}

- (void)resetCursorRects {
    [self addCursorRect:self.visibleRect cursor:NSCursor.IBeamCursor];
}

// MARK: Caret

- (BOOL)becomeFirstResponder {
    [self updateCaretAnimated:NO];
    return YES;
}

- (BOOL)resignFirstResponder {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateCaretAnimated:NO]; });
    return YES;
}

/// Moves the caret layer to the caret, gliding there when `animated`, and restarts blinking.
- (void)updateCaretAnimated:(BOOL)animated {
    BOOL show = _document && self.window.isKeyWindow && self.window.firstResponder == self && !_markedText.length;
    [_blinkTimer invalidate];
    _blinkTimer = nil;
    NSRect target = show ? self.caretRect : NSZeroRect;
    // The Vim cursor smears when it moves; the real caret then jumps at once and the trail
    // does the moving.
    BOOL smear = show && animated && _vimEnabled && GWServices.shared.settings.vimCursorSmear &&
                 _hasLastCaretRect && !NSEqualRects(_lastCaretRect, target);
    if (smear) {
        [self startSmearFrom:_lastCaretRect to:target];
    } else if (!show || !animated || !_vimEnabled) {
        [self stopSmear];
    }
    _lastCaretRect = target;
    _hasLastCaretRect = show;

    [CATransaction begin];
    if (animated && !smear) {
        [CATransaction setAnimationDuration:0.085];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _caretLayer.hidden = !show;
    _caretLayer.opacity = 1;
    // A block sits over a character, so it lets the character show through.
    _caretLayer.backgroundColor = (self.vimBlockCursor ? [_caretColor colorWithAlphaComponent:0.55] : _caretColor).CGColor;
    if (show) _caretLayer.frame = target;
    [CATransaction commit];
    if (!show) return;

    // Blink with a gentle fade, twice a second; the text itself is never redrawn for it.
    __weak CALayer *caret = _caretLayer;
    _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:0.55 repeats:YES block:^(NSTimer *timer) {
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.18];
        caret.opacity = caret.opacity > 0.5 ? 0 : 1;
        [CATransaction commit];
    }];
}

// MARK: Cursor smear

static void CornersOfRect(NSRect rect, CGPoint corners[4]) {
    corners[0] = CGPointMake(NSMinX(rect), NSMinY(rect));
    corners[1] = CGPointMake(NSMaxX(rect), NSMinY(rect));
    corners[2] = CGPointMake(NSMaxX(rect), NSMaxY(rect));
    corners[3] = CGPointMake(NSMinX(rect), NSMaxY(rect));
}

- (void)startSmearFrom:(NSRect)from to:(NSRect)to {
    if (self.window == nil) return;
    if (_smearLink == nil) {
        CornersOfRect(from, _smearCorners);  // (while a smear is still running it carries on from where it is)
        _smearLink = [self displayLinkWithTarget:self selector:@selector(smearStep:)];
        [_smearLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    CornersOfRect(to, _smearTargets);
    NSColor *color = [_caretColor colorWithAlphaComponent:self.vimBlockCursor ? 0.55 : 0.85];
    _smearLayer.fillColor = color.CGColor;
    _smearLayer.shadowColor = _caretColor.CGColor;
    _smearLayer.hidden = NO;
    [self drawSmearPath];
}

- (void)stopSmear {
    [_smearLink invalidate];
    _smearLink = nil;
    _smearLayer.hidden = YES;
}

- (void)drawSmearPath {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, nullptr, _smearCorners, 4);
    CGPathCloseSubpath(path);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _smearLayer.path = path;
    [CATransaction commit];
    CGPathRelease(path);
}

/// One frame: every corner moves part of the way to its target. A corner on the side the cursor
/// is heading for moves fast and one on the far side slowly, which stretches the shape along the
/// jump and then lets the tail catch up.
- (void)smearStep:(CADisplayLink *)link {
    constexpr CGFloat kLeadingRate = 70;   // per second: about 50 ms to arrive
    constexpr CGFloat kTrailingRate = 15;  // about 200 ms

    CFTimeInterval elapsed = std::max<CFTimeInterval>(link.targetTimestamp - link.timestamp, 1.0 / 240);
    CGPoint currentCenter = CGPointZero, targetCenter = CGPointZero;
    for (int corner = 0; corner < 4; ++corner) {
        currentCenter.x += _smearCorners[corner].x / 4;
        currentCenter.y += _smearCorners[corner].y / 4;
        targetCenter.x += _smearTargets[corner].x / 4;
        targetCenter.y += _smearTargets[corner].y / 4;
    }
    CGFloat headingX = targetCenter.x - currentCenter.x;
    CGFloat headingY = targetCenter.y - currentCenter.y;
    CGFloat heading = std::hypot(headingX, headingY);

    CGFloat farthest = 0;
    for (int corner = 0; corner < 4; ++corner) {
        CGFloat offsetX = _smearTargets[corner].x - targetCenter.x;
        CGFloat offsetY = _smearTargets[corner].y - targetCenter.y;
        CGFloat length = std::hypot(offsetX, offsetY);
        // -1 for a corner on the far side of the heading, +1 for one on the near side.
        CGFloat facing = heading > 0.5 && length > 0 ? (headingX * offsetX + headingY * offsetY) / (heading * length) : 1;
        CGFloat rate = kTrailingRate + (kLeadingRate - kTrailingRate) * (facing + 1) / 2;
        CGFloat step = 1 - std::exp(-rate * elapsed);
        _smearCorners[corner].x += (_smearTargets[corner].x - _smearCorners[corner].x) * step;
        _smearCorners[corner].y += (_smearTargets[corner].y - _smearCorners[corner].y) * step;
        farthest = std::max(farthest, std::hypot(_smearTargets[corner].x - _smearCorners[corner].x,
                                                 _smearTargets[corner].y - _smearCorners[corner].y));
    }
    if (farthest < 0.4) {
        [self stopSmear];
        return;
    }
    [self drawSmearPath];
}

- (void)scrollCaretToVisible {
    if (!_document) return;
    NSRect target = NSInsetRect(self.caretRect, -_charWidth * 4, -_lineHeight * 2);
    target.origin.y -= self.stickyHeight;
    target.size.height += self.stickyHeight;
    [self scrollRectToVisible:target];
}

- (void)scrollToLineCentered:(size_t)line {
    NSClipView *clip = self.enclosingScrollView.contentView;
    if (!clip) return;
    CGFloat y = [self yForLine:line] - NSHeight(clip.bounds) / 2;
    y = std::max(0.0, std::min(y, NSHeight(self.frame) - NSHeight(clip.bounds)));
    [clip scrollToPoint:NSMakePoint(NSMinX(clip.bounds), y)];
    [self.enclosingScrollView reflectScrolledClipView:clip];
}

- (void)selectionDidChange {
    if (_multiDepth > 0) {
        _multiMoved = YES;
        return;
    }
    [self cancelHover];
    if (_document && !_folds.empty()) {
        // A caret can't sit on a hidden line: opening the fold that hides it shows it.
        if (_folds.unfoldHiding(_document->selection.caret.line)) {
            [self rowLayoutChanged];
        }
    }
    [self scrollCaretToVisible];
    [self updateCaretAnimated:YES];
    self.needsDisplay = YES;  // current-line band and bracket match
    _gutter.needsDisplay = YES;
    if (self.onSelectionChange) self.onSelectionChange();
}

- (void)didEdit {
    if (_multiDepth > 0) {
        _multiEdited = YES;
        return;
    }
    _layouts.clear();
    const auto &buffer = _document->buffer();
    size_t caretLine = _document->selection.caret.line;
    _longestLine = std::max(_longestLine, buffer.line(std::min(caretLine, buffer.lineCount() - 1)).size());
    [self updateFrameSize];
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
    [self scheduleSectionsRefresh];
    [self updateStickyScroll];
    NSString *typed = _pendingTyped;
    _pendingTyped = nil;
    [self selectionDidChange];
    if (self.onEdit) self.onEdit();
    if (self.onTypedText) self.onTypedText(typed);
}

- (void)moveCaretTo:(gw::Position)position extend:(BOOL)extend {
    if (!_document) return;
    if (_multiDepth == 0) {
        _document->extraSelections.clear();
    }
    position = _document->buffer().clamp(position);
    if (extend) {
        _document->selection.caret = position;
    } else {
        _document->selection = {position, position};
    }
    [self selectionDidChange];
}

// MARK: Multiple cursors

- (std::vector<gw::Selection>)selectionsInOrder {
    std::vector<gw::Selection> all;
    all.push_back(_document->selection);
    for (const gw::Selection &extra : _document->extraSelections) {
        all.push_back(extra);
    }
    std::stable_sort(all.begin(), all.end(), [](const gw::Selection &a, const gw::Selection &b) {
        return a.range().start < b.range().start;
    });
    return all;
}

/// Two selections that overlap, or carets in the same place, are really one.
static bool selectionsOverlap(const gw::Selection &a, const gw::Selection &b) {
    gw::Range first = a.range();
    gw::Range second = b.range();
    if (first.start < second.end && second.start < first.end) {
        return true;
    }
    if (a.empty() && second.start <= first.start && first.start <= second.end) {
        return true;
    }
    if (b.empty() && first.start <= second.start && second.start <= first.end) {
        return true;
    }
    return false;
}

/// Drops extra cursors that landed on top of the main one or on each other.
- (void)normalizeCursors {
    std::vector<gw::Selection> kept;
    std::vector<gw::Selection> extras = _document->extraSelections;
    std::stable_sort(extras.begin(), extras.end(), [](const gw::Selection &a, const gw::Selection &b) {
        return a.range().start < b.range().start;
    });
    for (const gw::Selection &extra : extras) {
        if (selectionsOverlap(extra, _document->selection)) {
            continue;
        }
        bool duplicate = false;
        for (const gw::Selection &existing : kept) {
            if (selectionsOverlap(extra, existing)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            kept.push_back(extra);
        }
    }
    _document->extraSelections = kept;
}

/// Runs `body` once with each cursor as the only one, last cursor first. Edits made for one
/// cursor move the others (the document keeps them in place), and the whole run is one undo
/// step. With `mergingLines`, cursors on the same line count as one (for commands that act on
/// whole lines).
- (void)forEachSelection:(void (^)(void))body mergingLines:(BOOL)mergeLines {
    gw::Document &document = *_document;
    struct Entry {
        gw::Selection selection;
        bool primary;
    };
    std::vector<Entry> entries;
    entries.push_back({document.selection, true});
    for (const gw::Selection &extra : document.extraSelections) {
        entries.push_back({extra, false});
    }
    std::stable_sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) {
        return a.selection.range().start < b.selection.range().start;
    });
    if (mergeLines) {
        std::vector<Entry> merged;
        for (const Entry &entry : entries) {
            if (!merged.empty() && entry.selection.range().start.line <= merged.back().selection.range().end.line) {
                if (entry.primary) {
                    merged.back().primary = true;
                }
                continue;
            }
            merged.push_back(entry);
        }
        entries = merged;
    }
    std::vector<gw::Selection> current;
    size_t primaryIndex = 0;
    for (size_t index = 0; index < entries.size(); ++index) {
        current.push_back(entries[index].selection);
        if (entries[index].primary) {
            primaryIndex = index;
        }
    }

    ++_multiDepth;
    _multiEdited = NO;
    _multiMoved = NO;
    document.beginUndoGroup();
    _cursorCountInLoop = entries.size();
    for (size_t index = entries.size(); index-- > 0;) {
        _cursorIndexInLoop = index;
        document.selection = current[index];
        document.extraSelections.clear();
        for (size_t other = 0; other < current.size(); ++other) {
            if (other != index) {
                document.extraSelections.push_back(current[other]);
            }
        }
        document.preferredX.reset();
        body();
        current[index] = document.selection;
        if (document.extraSelections.size() == current.size() - 1) {
            size_t next = 0;
            for (size_t other = 0; other < current.size(); ++other) {
                if (other != index) {
                    current[other] = document.extraSelections[next++];
                }
            }
        }
    }
    document.endUndoGroup();
    --_multiDepth;

    document.selection = current[primaryIndex];
    document.extraSelections.clear();
    for (size_t index = 0; index < current.size(); ++index) {
        if (index != primaryIndex) {
            document.extraSelections.push_back(current[index]);
        }
    }
    [self normalizeCursors];
    if (_multiEdited) {
        [self didEdit];
    } else if (_multiMoved) {
        [self selectionDidChange];
    }
    self.needsDisplay = YES;
}

/// ⌥⌘↑ / ⌥⌘↓: another cursor on the line above or below, at the same column.
- (void)addCursorInDirection:(long)direction {
    if (!_document) return;
    gw::Position caret = _document->selection.caret;
    double x = _document->preferredX.value_or([self xForPosition:caret]);
    double top = [self yForPosition:caret];
    long row = static_cast<long>(std::floor(top / _lineHeight + 0.5)) + direction;
    long totalRows = _rowMap.empty() ? static_cast<long>(_document->buffer().lineCount()) : static_cast<long>(_rowMap.totalRows());
    if (row < 0 || row >= totalRows) {
        NSBeep();
        return;
    }
    gw::Position target = [self positionForPoint:NSMakePoint(x, row * _lineHeight + _lineHeight / 2)];
    if (target == caret) {
        return;
    }
    _document->extraSelections.push_back(_document->selection);
    _document->selection = {target, target};
    _document->preferredX = x;
    [self normalizeCursors];
    [self selectionDidChange];
    self.needsDisplay = YES;
}

- (NSUInteger)cursorCount { return _document ? 1 + _document->extraSelections.size() : 0; }

- (IBAction)addCursorAbove:(id)sender { [self addCursorInDirection:-1]; }
- (IBAction)addCursorBelow:(id)sender { [self addCursorInDirection:1]; }

/// ⌃⌘G: a cursor on every occurrence of the selected text (or the word at the caret).
- (IBAction)selectAllOccurrences:(id)sender {
    if (!_document) return;
    const auto &buffer = _document->buffer();
    gw::Selection selection = _document->selection;
    std::string needle;
    if (selection.empty()) {
        needle = [self wordAtCaret];
    } else if (selection.range().start.line == selection.range().end.line) {
        needle = buffer.text(selection.range());
    }
    if (needle.empty()) {
        NSBeep();
        return;
    }
    std::vector<gw::Selection> found;
    for (size_t line = 0; line < buffer.lineCount(); ++line) {
        std::string_view text = buffer.line(line);
        size_t at = text.find(needle);
        while (at != std::string::npos) {
            bool wholeWord = true;
            if (selection.empty()) {
                bool startsWord = at == 0 || !gw::isWordByte(static_cast<unsigned char>(text[at - 1]));
                size_t end = at + needle.size();
                bool endsWord = end >= text.size() || !gw::isWordByte(static_cast<unsigned char>(text[end]));
                wholeWord = startsWord && endsWord;
            }
            if (wholeWord) {
                found.push_back({{line, at}, {line, at + needle.size()}});
            }
            at = text.find(needle, at + needle.size());
        }
    }
    if (found.size() < 1) {
        return;
    }
    _document->selection = found.front();
    _document->extraSelections.assign(found.begin() + 1, found.end());
    [self normalizeCursors];
    [self selectionDidChange];
    self.needsDisplay = YES;
}

// MARK: Mouse

- (void)mouseDown:(NSEvent *)event {
    if (!_document) return;
    [self.window makeFirstResponder:self];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const auto &buffer = _document->buffer();
    BOOL inGutter = point.x < NSMinX(self.visibleRect);  // clicks forwarded from the ruler
    if (inGutter) point.x = NSMinX(self.visibleRect);
    gw::Position position = [self positionForPoint:point];
    _document->preferredX.reset();

    gw::Position anchor = position;
    auto selectForClick = [&](gw::Position at) -> gw::Selection {
        if (inGutter || event.clickCount >= 3) {  // whole lines
            gw::Position start{std::min(anchor.line, at.line), 0};
            size_t endLine = std::max(anchor.line, at.line);
            // Up to the start of the next line, or the end of the text on the last line.
            bool hasNextLine = endLine + 1 < buffer.lineCount();
            gw::Position end = hasNextLine ? gw::Position{endLine + 1, 0} : gw::Position{endLine, buffer.line(endLine).size()};
            return at.line < anchor.line ? gw::Selection{end, start} : gw::Selection{start, end};
        }
        if (event.clickCount == 2) {  // whole words
            gw::Range first = buffer.wordAt(anchor), last = buffer.wordAt(at);
            return at < anchor ? gw::Selection{first.end, last.start} : gw::Selection{first.start, last.end};
        }
        return gw::Selection{anchor, at};
    };

    BOOL shiftHeld = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    BOOL optionHeld = (event.modifierFlags & NSEventModifierFlagOption) != 0;
    if (shiftHeld && optionHeld && !inGutter) {
        [self trackColumnSelectionFrom:point];  // ⇧⌥-drag: a rectangle of text
        return;
    }

    if (event.modifierFlags & NSEventModifierFlagShift) anchor = _document->selection.anchor;
    if (event.modifierFlags & NSEventModifierFlagOption) {
        // ⌥-click: keep what is selected and start another cursor here.
        _document->extraSelections.push_back(_document->selection);
    } else {
        _document->extraSelections.clear();
    }
    _document->selection = selectForClick(position);
    [self selectionDidChange];

    // Track the drag, scrolling when the pointer leaves the view.
    while (true) {
        NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                                 untilDate:NSDate.distantFuture
                                                    inMode:NSEventTrackingRunLoopMode
                                                   dequeue:YES];
        if (next.type == NSEventTypeLeftMouseUp) break;
        [self autoscroll:next];
        NSPoint dragPoint = [self convertPoint:next.locationInWindow fromView:nil];
        if (inGutter) dragPoint.x = NSMinX(self.visibleRect);
        _document->selection = selectForClick([self positionForPoint:dragPoint]);
        [self selectionDidChange];
    }
}

/// Column (rectangular) selection: every row between the two points gets one selection
/// running from the first point's x to the second point's x. Short rows get a selection that
/// ends where the row does. The row under the pointer is the main selection.
- (void)selectColumnFrom:(NSPoint)start to:(NSPoint)end {
    long totalRows = _rowMap.empty() ? static_cast<long>(_document->buffer().lineCount())
                                     : static_cast<long>(_rowMap.totalRows());
    long startRow = static_cast<long>(std::floor(start.y / _lineHeight));
    long endRow = static_cast<long>(std::floor(end.y / _lineHeight));
    startRow = std::clamp(startRow, 0L, totalRows - 1);
    endRow = std::clamp(endRow, 0L, totalRows - 1);

    // Walk from the row where the drag started to the row where it is now, so the last
    // selection made is the one under the pointer.
    long step = endRow >= startRow ? 1 : -1;
    std::vector<gw::Selection> selections;
    size_t previousLine = static_cast<size_t>(-1);
    for (long row = startRow;; row += step) {
        double rowMiddle = row * _lineHeight + _lineHeight / 2;
        gw::Position first = [self positionForPoint:NSMakePoint(start.x, rowMiddle)];
        gw::Position second = [self positionForPoint:NSMakePoint(end.x, rowMiddle)];
        bool sameLineAsBefore = first.line == previousLine;  // a wrapped line takes several rows
        if (!sameLineAsBefore) {
            selections.push_back(gw::Selection{first, second});
            previousLine = first.line;
        }
        if (row == endRow) break;
    }

    _document->selection = selections.back();
    _document->extraSelections.assign(selections.begin(), selections.end() - 1);
    [self normalizeCursors];
    [self selectionDidChange];
    self.needsDisplay = YES;
}

- (void)trackColumnSelectionFrom:(NSPoint)start {
    _document->preferredX.reset();
    [self selectColumnFrom:start to:start];
    while (true) {
        NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                                 untilDate:NSDate.distantFuture
                                                    inMode:NSEventTrackingRunLoopMode
                                                   dequeue:YES];
        if (next.type == NSEventTypeLeftMouseUp) break;
        [self autoscroll:next];
        NSPoint dragPoint = [self convertPoint:next.locationInWindow fromView:nil];
        [self selectColumnFrom:start to:dragPoint];
    }
}

// MARK: Keyboard

- (void)keyDown:(NSEvent *)event {
    if (!_document) return;
    if (_vimEnabled && [self handleVimKeyEvent:event]) return;
    [self interpretKeyEvents:@[event]];
}

// MARK: Vim

- (NSString *)vimStatus {
    if (!_vimEnabled) return nil;
    NSString *mode = @(_vim.modeName().c_str());
    std::string pending = _vim.pending();
    if (_vim.mode() == gw::VimMode::Command) {
        return @(pending.c_str());  // the command line: ":wq"
    }
    return pending.empty() ? mode : [NSString stringWithFormat:@"%@  %s", mode, pending.c_str()];
}

- (BOOL)insertsText {
    return !_vimEnabled || _vim.mode() == gw::VimMode::Insert;
}

- (void)vimStatusDidChange {
    NSString *status = self.vimStatus;
    if (status == _vimShownStatus || [status isEqualToString:_vimShownStatus]) return;
    _vimShownStatus = status;
    if (self.onVimStatusChange) self.onVimStatusChange();
}

/// Normal and visual mode draw a block over the character; insert mode draws the thin bar.
- (BOOL)vimBlockCursor {
    return _vimEnabled && _vim.mode() != gw::VimMode::Insert;
}

/// Turns a key into what the engine understands and lets it act. NO means the key isn't Vim's
/// (a shortcut, an arrow, or typing in insert mode) and goes the usual way.
- (BOOL)handleVimKeyEvent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL inserting = _vim.mode() == gw::VimMode::Insert;
    if ((flags & NSEventModifierFlagCommand) || _markedText.length > 0) return NO;

    std::string key;
    NSString *plain = event.charactersIgnoringModifiers;
    if (event.keyCode == kVK_Escape) {
        key = "\x1b";
    } else if (flags & NSEventModifierFlagControl) {
        if ([plain isEqualToString:@"["] || [plain isEqualToString:@"c"]) {
            key = "\x1b";
        } else if ([plain isEqualToString:@"r"]) {
            key = "\x12";
        } else {
            return NO;
        }
    } else if (flags & NSEventModifierFlagOption) {
        return !inserting;  // in normal mode an option key would only type a symbol
    } else if (event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter) {
        key = "\r";
    } else if (event.keyCode == kVK_Delete) {
        key = "\x7f";
    } else {
        NSString *characters = event.characters;
        if (characters.length == 0) return NO;
        unichar first = [characters characterAtIndex:0];
        if (first >= 0xF700 && first <= 0xF8FF) return NO;  // arrows and function keys
        if (first < 0x20) return !inserting;                // Tab and the like
        key = characters.UTF8String ?: "";
    }

    if (inserting && key == "\x1b" && self.onCompletionKey && self.onCompletionKey(@selector(cancelOperation:))) {
        return YES;  // Escape closed the suggestion list first
    }
    _vim.indentUnit = _useTabs ? "\t" : std::string(_tabSize, ' ');
    uint64_t version = _document->version();
    if (!_vim.handleKey(*_document, key)) return NO;
    if (_document->version() != version) {
        [self didEdit];
    } else {
        [self selectionDidChange];
    }
    [self vimStatusDidChange];
    return YES;
}

- (void)doCommandBySelector:(SEL)selector {
    if (self.onCompletionKey && self.onCompletionKey(selector)) {
        return;  // the completion list used the key
    }
    if ([self respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))[self methodForSelector:selector])(self, selector, nil);
    }
}

// Horizontal movement.
- (void)moveHorizontally:(int)direction byWord:(BOOL)word extend:(BOOL)extend {
    GW_FOR_EACH_CURSOR([self moveHorizontally:direction byWord:word extend:extend];)
    const auto &buffer = _document->buffer();
    gw::Selection selection = _document->selection;
    _document->preferredX.reset();
    if (!extend && !selection.empty() && !word) {
        gw::Range range = selection.range();
        [self moveCaretTo:direction < 0 ? range.start : range.end extend:NO];
        return;
    }
    gw::Position caret = selection.caret;
    gw::Position target;
    if (direction < 0) {
        target = word ? buffer.previousWordStart(caret) : buffer.previousCharacter(caret);
    } else {
        target = word ? buffer.nextWordEnd(caret) : buffer.nextCharacter(caret);
    }
    [self moveCaretTo:target extend:extend];
}

- (void)moveLeft:(id)sender { [self moveHorizontally:-1 byWord:NO extend:NO]; }
- (void)moveRight:(id)sender { [self moveHorizontally:1 byWord:NO extend:NO]; }
- (void)moveLeftAndModifySelection:(id)sender { [self moveHorizontally:-1 byWord:NO extend:YES]; }
- (void)moveRightAndModifySelection:(id)sender { [self moveHorizontally:1 byWord:NO extend:YES]; }
- (void)moveWordLeft:(id)sender { [self moveHorizontally:-1 byWord:YES extend:NO]; }
- (void)moveWordRight:(id)sender { [self moveHorizontally:1 byWord:YES extend:NO]; }
- (void)moveWordLeftAndModifySelection:(id)sender { [self moveHorizontally:-1 byWord:YES extend:YES]; }
- (void)moveWordRightAndModifySelection:(id)sender { [self moveHorizontally:1 byWord:YES extend:YES]; }

// Vertical movement keeps the column the caret "wants" across short lines. It moves by screen
// rows, so a wrapped line takes several presses and folded lines are stepped over.
- (void)moveVertically:(long)rows extend:(BOOL)extend {
    GW_FOR_EACH_CURSOR([self moveVertically:rows extend:extend];)
    const auto &buffer = _document->buffer();
    gw::Position caret = _document->selection.caret;
    double x = _document->preferredX.value_or([self xForPosition:caret]);
    double caretRowTop = [self yForPosition:caret];
    long caretRow = static_cast<long>(std::floor(caretRowTop / _lineHeight + 0.5));
    long totalRows = _rowMap.empty() ? static_cast<long>(buffer.lineCount()) : static_cast<long>(_rowMap.totalRows());
    long target = caretRow + rows;
    gw::Position position;
    if (target < 0) {
        position = {0, 0};
    } else if (target >= totalRows) {
        position = buffer.end();
    } else {
        position = [self positionForPoint:NSMakePoint(x, target * _lineHeight + _lineHeight / 2)];
    }
    [self moveCaretTo:position extend:extend];
    _document->preferredX = x;
}

- (void)moveUp:(id)sender { [self moveVertically:-1 extend:NO]; }
- (void)moveDown:(id)sender { [self moveVertically:1 extend:NO]; }
- (void)moveUpAndModifySelection:(id)sender { [self moveVertically:-1 extend:YES]; }
- (void)moveDownAndModifySelection:(id)sender { [self moveVertically:1 extend:YES]; }

- (long)pageLines { return std::max(1L, static_cast<long>(NSHeight(self.visibleRect) / _lineHeight) - 2); }
- (void)pageUp:(id)sender { [self moveVertically:-[self pageLines] extend:NO]; }
- (void)pageDown:(id)sender { [self moveVertically:[self pageLines] extend:NO]; }
- (void)pageUpAndModifySelection:(id)sender { [self moveVertically:-[self pageLines] extend:YES]; }
- (void)pageDownAndModifySelection:(id)sender { [self moveVertically:[self pageLines] extend:YES]; }
- (void)scrollPageUp:(id)sender { [self pageUp:sender]; }
- (void)scrollPageDown:(id)sender { [self pageDown:sender]; }

// Line start goes to the first non-blank character, then to column 0 ("smart home").
- (void)moveToLineStartExtend:(BOOL)extend {
    GW_FOR_EACH_CURSOR([self moveToLineStartExtend:extend];)
    gw::Position caret = _document->selection.caret;
    size_t indent = _document->buffer().indentEnd(caret.line);
    _document->preferredX.reset();
    [self moveCaretTo:{caret.line, caret.column == indent ? 0 : indent} extend:extend];
}
- (void)moveToLineEndExtend:(BOOL)extend {
    GW_FOR_EACH_CURSOR([self moveToLineEndExtend:extend];)
    gw::Position caret = _document->selection.caret;
    _document->preferredX.reset();
    [self moveCaretTo:{caret.line, _document->buffer().line(caret.line).size()} extend:extend];
}
- (void)moveToBeginningOfLine:(id)sender { [self moveToLineStartExtend:NO]; }
- (void)moveToLeftEndOfLine:(id)sender { [self moveToLineStartExtend:NO]; }
- (void)moveToBeginningOfLineAndModifySelection:(id)sender { [self moveToLineStartExtend:YES]; }
- (void)moveToLeftEndOfLineAndModifySelection:(id)sender { [self moveToLineStartExtend:YES]; }
- (void)moveToEndOfLine:(id)sender { [self moveToLineEndExtend:NO]; }
- (void)moveToRightEndOfLine:(id)sender { [self moveToLineEndExtend:NO]; }
- (void)moveToEndOfLineAndModifySelection:(id)sender { [self moveToLineEndExtend:YES]; }
- (void)moveToRightEndOfLineAndModifySelection:(id)sender { [self moveToLineEndExtend:YES]; }

- (void)moveToBeginningOfDocument:(id)sender { [self moveCaretTo:{0, 0} extend:NO]; }
- (void)moveToEndOfDocument:(id)sender { [self moveCaretTo:_document->buffer().end() extend:NO]; }
- (void)moveToBeginningOfDocumentAndModifySelection:(id)sender { [self moveCaretTo:{0, 0} extend:YES]; }
- (void)moveToEndOfDocumentAndModifySelection:(id)sender { [self moveCaretTo:_document->buffer().end() extend:YES]; }

- (void)selectAll:(id)sender {
    if (!_document) return;
    _document->extraSelections.clear();
    _document->selection = {{0, 0}, _document->buffer().end()};
    [self selectionDidChange];
}

- (void)cancelOperation:(id)sender {
    if (!_document) return;
    _document->endSnippet();
    if (!_document->extraSelections.empty()) {
        // Escape first goes back to a single cursor.
        _document->extraSelections.clear();
        self.needsDisplay = YES;
        [self updateCaretAnimated:NO];
        return;
    }
    [self moveCaretTo:_document->selection.caret extend:NO];
}

// MARK: Typing

- (std::string)indentUnit {
    if (_useTabs) {
        return std::string("\t");
    }
    return std::string(_tabSize, ' ');
}

- (std::string)textAround:(gw::Position)position before:(BOOL)before {
    const auto &buffer = _document->buffer();
    if (before) {
        gw::Position previous = buffer.previousCharacter(position);
        return previous.line == position.line ? buffer.text({previous, position}) : std::string();
    }
    gw::Position next = buffer.nextCharacter(position);
    return next.line == position.line ? buffer.text({position, next}) : std::string();
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    if (!_document) return;
    GW_FOR_EACH_CURSOR([self insertText:string replacementRange:replacementRange];)
    _markedText = nil;
    NSString *plain = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
    _pendingTyped = plain;  // didEdit reports it to the completion popup
    std::string text = plain.UTF8String ? plain.UTF8String : "";
    if (text.empty()) return;

    gw::Selection selection = _document->selection;
    std::string next = [self textAround:selection.caret before:NO];
    std::string previous = [self textAround:selection.caret before:YES];

    // Typing a closing character right before the same one just steps over it.
    for (const auto &[open, close] : _configuration.autoClosingPairs) {
        if (selection.empty() && text == close && next == close) {
            [self moveHorizontally:1 byWord:NO extend:NO];
            return;
        }
    }
    for (const auto &[open, close] : _configuration.autoClosingPairs) {
        if (text != open) continue;
        if (!selection.empty() && selection.range().start.line == selection.range().end.line) {
            // Wrap the selection: (selected) / "selected".
            gw::Range range = selection.range();
            std::string inner = _document->buffer().text(range);
            _document->replace(range, open + inner + close);
            gw::Position start = {range.start.line, range.start.column + open.size()};
            _document->selection = {start, {start.line, start.column + inner.size()}};
            [self didEdit];
            return;
        }
        bool nextAllowsClose = next.empty() || next == " " || next == "\t" || next == ")" || next == "]" ||
                               next == "}" || next == ";" || next == ",";
        bool isQuote = open == close;
        bool afterWord = !previous.empty() && gw::isWordByte(static_cast<unsigned char>(previous.back()));
        if (selection.empty() && nextAllowsClose && !(isQuote && afterWord)) {
            _document->typeText(open + close);
            gw::Position caret = _document->selection.caret;
            _document->selection.caret = {caret.line, caret.column - close.size()};
            _document->selection.anchor = _document->selection.caret;
            [self didEdit];
            return;
        }
    }
    _document->typeText(text);
    [self didEdit];
}

- (void)insertNewline:(id)sender {
    if (!_document) return;
    GW_FOR_EACH_CURSOR([self insertNewline:sender];)
    gw::Position caret = _document->selection.range().start;
    std::string_view line = _document->buffer().line(caret.line);
    size_t indentEnd = std::min(_document->buffer().indentEnd(caret.line), caret.column);
    std::string indent(line.substr(0, indentEnd));
    std::string previous = [self textAround:_document->selection.range().start before:YES];
    std::string next = [self textAround:_document->selection.range().end before:NO];

    if (isOpeningBracket(previous)) {
        std::string inner = "\n" + indent + [self indentUnit];
        bool closesRightAfter = (previous == "{" && next == "}") || (previous == "[" && next == "]") ||
                                (previous == "(" && next == ")");
        if (closesRightAfter) {
            // Put the closing bracket on its own line and the caret on an indented line between.
            _document->replace(_document->selection.range(), inner + "\n" + indent);
            gw::Position end = _document->selection.caret;
            _document->selection = {{end.line - 1, (inner.size() - 1)}, {end.line - 1, (inner.size() - 1)}};
        } else {
            _document->replace(_document->selection.range(), inner);
        }
    } else {
        _document->replace(_document->selection.range(), "\n" + indent);
    }
    [self didEdit];
}

- (void)insertLineBreak:(id)sender { [self insertNewline:sender]; }

- (void)insertTab:(id)sender {
    if (!_document) return;
    // While a snippet is being filled in, Tab moves to its next placeholder.
    if (_multiDepth == 0 && _document->jumpSnippetStop(+1)) {
        [self selectionDidChange];
        return;
    }
    GW_FOR_EACH_CURSOR([self insertTab:sender];)
    gw::Range range = _document->selection.range();
    if (range.start.line != range.end.line) {
        [self indentLines:sender];
        return;
    }
    if (_useTabs) {
        _document->typeText("\t");
    } else {
        size_t spaces = _tabSize - (range.start.column % _tabSize);
        _document->typeText(std::string(spaces, ' '));
    }
    [self didEdit];
}

- (void)insertBacktab:(id)sender {
    if (_document && _multiDepth == 0 && _document->jumpSnippetStop(-1)) {
        [self selectionDidChange];
        return;
    }
    [self outdentLines:sender];
}

- (void)deleteBackward:(id)sender {
    if (!_document) return;
    GW_FOR_EACH_CURSOR([self deleteBackward:sender];)
    const auto &buffer = _document->buffer();
    gw::Selection selection = _document->selection;
    if (!selection.empty()) {
        _document->deleteSelectionOr(selection.range());
        [self didEdit];
        return;
    }
    gw::Position caret = selection.caret;
    if (caret == gw::Position{0, 0}) return;
    // Backspace between an empty pair removes both halves: (|) → |
    std::string previous = [self textAround:caret before:YES];
    std::string next = [self textAround:caret before:NO];
    for (const auto &[open, close] : _configuration.autoClosingPairs) {
        if (previous == open && next == close) {
            _document->replace({buffer.previousCharacter(caret), buffer.nextCharacter(caret)}, "");
            [self didEdit];
            return;
        }
    }
    // In leading spaces, delete back to the previous indent stop.
    std::string_view line = buffer.line(caret.line);
    if (!_useTabs && caret.column > 0 && caret.column <= buffer.indentEnd(caret.line) &&
        line.find_first_not_of(' ', 0) >= caret.column) {
        size_t stop = ((caret.column - 1) / _tabSize) * _tabSize;
        _document->replace({{caret.line, stop}, caret}, "");
        [self didEdit];
        return;
    }
    _document->replace({buffer.previousCharacter(caret), caret}, "");
    [self didEdit];
}

- (void)deleteForward:(id)sender {
    if (!_document) return;
    GW_FOR_EACH_CURSOR([self deleteForward:sender];)
    gw::Position caret = _document->selection.caret;
    _document->deleteSelectionOr({caret, _document->buffer().nextCharacter(caret)});
    [self didEdit];
}

- (void)deleteWordBackward:(id)sender {
    if (!_document) return;
    GW_FOR_EACH_CURSOR([self deleteWordBackward:sender];)
    gw::Position caret = _document->selection.caret;
    _document->deleteSelectionOr({_document->buffer().previousWordStart(caret), caret});
    [self didEdit];
}

- (void)deleteWordForward:(id)sender {
    if (!_document) return;
    GW_FOR_EACH_CURSOR([self deleteWordForward:sender];)
    gw::Position caret = _document->selection.caret;
    _document->deleteSelectionOr({caret, _document->buffer().nextWordEnd(caret)});
    [self didEdit];
}

- (void)deleteToBeginningOfLine:(id)sender {
    if (!_document) return;
    GW_FOR_EACH_CURSOR([self deleteToBeginningOfLine:sender];)
    gw::Position caret = _document->selection.caret;
    gw::Position start = caret.column == 0 ? _document->buffer().previousCharacter(caret) : gw::Position{caret.line, 0};
    _document->deleteSelectionOr({start, caret});
    [self didEdit];
}

// MARK: Line commands

/// Lines covered by the selection (a selection ending at column 0 doesn't include that line).
- (std::pair<size_t, size_t>)selectedLines {
    gw::Range range = _document->selection.range();
    size_t last = range.end.line;
    if (last > range.start.line && range.end.column == 0) --last;
    return {range.start.line, last};
}

// MARK: Expand selection and brackets

static bool sameSelection(const gw::Selection &a, const gw::Selection &b) {
    return a.anchor == b.anchor && a.caret == b.caret;
}

/// ⌃⇧⌘→: selects the word, then what is inside the brackets, the brackets, the line, and so on outwards.
- (IBAction)expandSelection:(id)sender {
    if (!_document) return;
    if (!sameSelection(_document->selection, _lastExpanded)) {
        _expandHistory.clear();  // the selection was changed by hand since
    }
    gw::Range bigger = gw::expandedSelection(_document->buffer(), _document->selection.range());
    gw::Range now = _document->selection.range();
    if (bigger.start == now.start && bigger.end == now.end) {
        NSBeep();
        return;
    }
    _expandHistory.push_back(_document->selection);
    _document->extraSelections.clear();
    _document->selection = {bigger.start, bigger.end};
    _lastExpanded = _document->selection;
    [self selectionDidChange];
}

/// ⌃⇧⌘←: goes back to the selection before the last Expand.
- (IBAction)shrinkSelection:(id)sender {
    if (!_document) return;
    if (_expandHistory.empty() || !sameSelection(_document->selection, _lastExpanded)) {
        _expandHistory.clear();
        NSBeep();
        return;
    }
    _document->extraSelections.clear();
    _document->selection = _expandHistory.back();
    _expandHistory.pop_back();
    _lastExpanded = _document->selection;
    [self selectionDidChange];
}

/// ⇧⌘\: jumps to the bracket that pairs with the one at the caret.
- (IBAction)goToMatchingBracket:(id)sender {
    if (!_document) return;
    auto match = [self bracketMatch];
    if (!match) {
        NSBeep();
        return;
    }
    gw::Position caret = _document->selection.caret;
    gw::Position opener = match->first, closer = match->second;
    bool touchingOpener = caret == opener || (caret.line == opener.line && caret.column == opener.column + 1);
    gw::Position target = touchingOpener ? gw::Position{closer.line, closer.column + 1} : opener;
    [self moveCaretTo:target extend:NO];
}

/// Replaces the selected text with `transform` of it, as one undo step, and keeps the new
/// text selected. With nothing selected the word at the caret is used, or with `wholeLines`
/// every line the selection touches (an empty selection then does nothing).
- (void)transformSelectedText:(std::string (*)(std::string_view))transform wholeLines:(BOOL)wholeLines {
    if (!_document || _document->readOnly) return;
    const auto &buffer = _document->buffer();
    gw::Range range = _document->selection.range();
    if (wholeLines) {
        if (_document->selection.empty()) {
            NSBeep();
            return;
        }
        auto [first, last] = [self selectedLines];
        range = {{first, 0}, {last, buffer.line(last).size()}};
    } else if (_document->selection.empty()) {
        gw::Position caret = _document->selection.caret;
        std::string_view line = buffer.line(caret.line);
        size_t start = std::min(caret.column, line.size());
        size_t end = start;
        while (start > 0 && gw::isWordByte(static_cast<unsigned char>(line[start - 1]))) --start;
        while (end < line.size() && gw::isWordByte(static_cast<unsigned char>(line[end]))) ++end;
        if (start == end) {
            NSBeep();
            return;
        }
        range = {{caret.line, start}, {caret.line, end}};
    }
    std::string original = buffer.text(range);
    std::string replacement = transform(original);
    if (replacement == original) return;

    _document->extraSelections.clear();
    _document->replace(range, replacement);
    gw::Position end = gw::endOfInsertion(range.start, replacement);
    _document->selection = {range.start, end};
    [self didEdit];
}

- (IBAction)makeUpperCase:(id)sender { [self transformSelectedText:gw::upperCaseText wholeLines:NO]; }
- (IBAction)makeLowerCase:(id)sender { [self transformSelectedText:gw::lowerCaseText wholeLines:NO]; }
- (IBAction)makeTitleCase:(id)sender { [self transformSelectedText:gw::titleCaseText wholeLines:NO]; }

static std::string sortAscending(std::string_view text) { return gw::sortLinesText(text, false); }
static std::string sortDescending(std::string_view text) { return gw::sortLinesText(text, true); }

- (IBAction)sortLinesAscending:(id)sender { [self transformSelectedText:sortAscending wholeLines:YES]; }
- (IBAction)sortLinesDescending:(id)sender { [self transformSelectedText:sortDescending wholeLines:YES]; }
- (IBAction)removeDuplicateLines:(id)sender { [self transformSelectedText:gw::uniqueLinesText wholeLines:YES]; }

/// Joins the selected lines into one; with nothing selected, the caret's line and the next.
- (IBAction)joinSelectedLines:(id)sender {
    if (!_document || _document->readOnly) return;
    if (_document->selection.empty()) {
        size_t line = _document->selection.caret.line;
        if (line + 1 >= _document->buffer().lineCount()) {
            NSBeep();
            return;
        }
        _document->selection = {{line, 0}, {line + 1, _document->buffer().line(line + 1).size()}};
    }
    [self transformSelectedText:gw::joinLinesText wholeLines:YES];
}

/// Rewrites whole lines as one undoable edit, then selects them if several were involved.
- (void)transformLines:(std::string (^)(const std::string &line, size_t index))transform {
    if (!_document) return;
    auto [first, last] = [self selectedLines];
    const auto &buffer = _document->buffer();
    gw::Selection before = _document->selection;
    std::string replacement;
    for (size_t line = first; line <= last; ++line) {
        if (line > first) replacement += "\n";
        replacement += transform(std::string(buffer.line(line)), line);
    }
    size_t oldLength = buffer.line(first).size();
    _document->replace({{first, 0}, {last, buffer.line(last).size()}}, replacement);
    const auto &after = _document->buffer();
    if (first == last && before.empty()) {
        long delta = static_cast<long>(after.line(first).size()) - static_cast<long>(oldLength);
        size_t column = static_cast<size_t>(std::max(0L, static_cast<long>(before.caret.column) + delta));
        _document->selection = {{first, column}, {first, column}};
    } else {
        _document->selection = {{first, 0}, {last, after.line(last).size()}};
    }
    [self didEdit];
}

- (IBAction)indentLines:(id)sender {
    GW_FOR_EACH_CURSOR_LINE([self indentLines:sender];)
    std::string unit = [self indentUnit];
    [self transformLines:^std::string(const std::string &line, size_t) { return line.empty() ? line : unit + line; }];
}

- (IBAction)outdentLines:(id)sender {
    GW_FOR_EACH_CURSOR_LINE([self outdentLines:sender];)
    bool tabs = _useTabs;
    size_t tabSize = _tabSize;
    [self transformLines:^std::string(const std::string &line, size_t) {
        if (tabs && !line.empty() && line[0] == '\t') {
            return line.substr(1);
        }
        size_t spaces = 0;
        while (spaces < tabSize && spaces < line.size() && line[spaces] == ' ') {
            ++spaces;
        }
        return line.substr(spaces);
    }];
}

- (IBAction)toggleLineComment:(id)sender {
    if (!_document) return;
    GW_FOR_EACH_CURSOR_LINE([self toggleLineComment:sender];)
    std::string marker = _configuration.lineComment;
    if (marker.empty()) {
        NSBeep();
        return;
    }
    auto [first, last] = [self selectedLines];
    const auto &buffer = _document->buffer();
    // Comment everything unless every non-blank line is already commented.
    bool allCommented = true;
    size_t minIndent = std::string::npos;
    for (size_t line = first; line <= last; ++line) {
        std::string_view text = buffer.line(line);
        size_t indent = buffer.indentEnd(line);
        if (indent == text.size()) continue;
        minIndent = std::min(minIndent, indent);
        if (text.compare(indent, marker.size(), marker) != 0) allCommented = false;
    }
    if (minIndent == std::string::npos) minIndent = 0;
    [self transformLines:^std::string(const std::string &line, size_t) {
        size_t indent = line.find_first_not_of(" \t");
        if (indent == std::string::npos) return line;  // blank lines stay blank
        if (allCommented) {
            size_t length = marker.size();
            if (line.size() > indent + length && line[indent + length] == ' ') ++length;
            return line.substr(0, indent) + line.substr(indent + length);
        }
        return line.substr(0, minIndent) + marker + " " + line.substr(minIndent);
    }];
}

// MARK: More line commands

/// The text of lines first...last joined with newlines.
- (std::string)joinedTextOfLinesFrom:(size_t)first to:(size_t)last {
    const auto &buffer = _document->buffer();
    std::string joined;
    for (size_t line = first; line <= last; ++line) {
        if (line > first) {
            joined += "\n";
        }
        joined += buffer.line(line);
    }
    return joined;
}

/// Moves the selected lines up one line (the line above goes below them).
- (IBAction)moveLinesUp:(id)sender {
    if (!_document || _document->readOnly) return;
    _document->extraSelections.clear();
    auto [first, last] = [self selectedLines];
    if (first == 0) return;

    gw::Selection before = _document->selection;
    const auto &buffer = _document->buffer();
    std::string lineAbove(buffer.line(first - 1));
    std::string movedBlock = [self joinedTextOfLinesFrom:first to:last];
    gw::Range whole = {{first - 1, 0}, {last, buffer.line(last).size()}};
    _document->replace(whole, movedBlock + "\n" + lineAbove);

    _document->selection = {{before.anchor.line - 1, before.anchor.column}, {before.caret.line - 1, before.caret.column}};
    [self didEdit];
}

/// Moves the selected lines down one line (the line below goes above them).
- (IBAction)moveLinesDown:(id)sender {
    if (!_document || _document->readOnly) return;
    _document->extraSelections.clear();
    auto [first, last] = [self selectedLines];
    if (last + 1 >= _document->buffer().lineCount()) return;

    gw::Selection before = _document->selection;
    const auto &buffer = _document->buffer();
    std::string lineBelow(buffer.line(last + 1));
    std::string movedBlock = [self joinedTextOfLinesFrom:first to:last];
    gw::Range whole = {{first, 0}, {last + 1, buffer.line(last + 1).size()}};
    _document->replace(whole, lineBelow + "\n" + movedBlock);

    _document->selection = {{before.anchor.line + 1, before.anchor.column}, {before.caret.line + 1, before.caret.column}};
    [self didEdit];
}

/// Copies the selected lines below themselves; the selection moves to the copy.
- (IBAction)duplicateLinesDown:(id)sender {
    if (!_document || _document->readOnly) return;
    _document->extraSelections.clear();
    auto [first, last] = [self selectedLines];
    gw::Selection before = _document->selection;
    size_t count = last - first + 1;
    std::string block = [self joinedTextOfLinesFrom:first to:last];
    gw::Position endOfLast = {last, _document->buffer().line(last).size()};
    _document->replace({endOfLast, endOfLast}, "\n" + block);

    _document->selection = {{before.anchor.line + count, before.anchor.column}, {before.caret.line + count, before.caret.column}};
    [self didEdit];
}

/// Copies the selected lines above themselves; the selection stays on the original lines.
- (IBAction)duplicateLinesUp:(id)sender {
    if (!_document || _document->readOnly) return;
    _document->extraSelections.clear();
    auto [first, last] = [self selectedLines];
    gw::Selection before = _document->selection;
    size_t count = last - first + 1;
    std::string block = [self joinedTextOfLinesFrom:first to:last];
    _document->replace({{first, 0}, {first, 0}}, block + "\n");

    // The original lines were pushed down by the copy, and the selection follows them.
    _document->selection = {{before.anchor.line + count, before.anchor.column}, {before.caret.line + count, before.caret.column}};
    [self didEdit];
}

/// Removes the selected lines entirely.
- (IBAction)deleteLines:(id)sender {
    if (!_document || _document->readOnly) return;
    _document->extraSelections.clear();
    auto [first, last] = [self selectedLines];
    const auto &buffer = _document->buffer();
    size_t lineCount = buffer.lineCount();

    gw::Range doomed;
    size_t caretLine = first;
    if (last + 1 < lineCount) {
        doomed = {{first, 0}, {last + 1, 0}};
    } else if (first > 0) {
        // Deleting through the end: take the newline before the block instead.
        doomed = {{first - 1, buffer.line(first - 1).size()}, {last, buffer.line(last).size()}};
        caretLine = first - 1;
    } else {
        doomed = {{0, 0}, {last, buffer.line(last).size()}};
    }
    _document->replace(doomed, "");
    _document->selection = {{caretLine, 0}, {caretLine, 0}};
    _document->preferredX.reset();
    [self didEdit];
}

/// ⌘↩: start a new line below the current one, indented like it.
- (IBAction)insertLineBelow:(id)sender {
    if (!_document || _document->readOnly) return;
    size_t line = _document->selection.range().end.line;
    gw::Position endOfLine = {line, _document->buffer().line(line).size()};
    _document->selection = {endOfLine, endOfLine};
    [self insertNewline:sender];
}

/// ⇧⌘↩: start a new line above the current one, indented like it.
- (IBAction)insertLineAbove:(id)sender {
    if (!_document || _document->readOnly) return;
    size_t line = _document->selection.range().start.line;
    const auto &buffer = _document->buffer();
    std::string indent(buffer.line(line).substr(0, buffer.indentEnd(line)));
    _document->replace({{line, 0}, {line, 0}}, indent + "\n");
    gw::Position caret = {line, indent.size()};
    _document->selection = {caret, caret};
    [self didEdit];
}

/// ⌘D: with nothing selected, select the word at the caret; otherwise jump to the next place the
/// selected text appears (wrapping around at the end of the file).
/// ⌘D: with nothing selected, select the word at the caret; after that, each press adds the next
/// place the selected text appears (wrapping around at the end of the file) as another cursor.
- (IBAction)selectNextOccurrence:(id)sender {
    if (!_document) return;
    const auto &buffer = _document->buffer();
    gw::Selection selection = _document->selection;

    if (selection.empty()) {
        std::string_view text = buffer.line(selection.caret.line);
        size_t start = selection.caret.column;
        size_t end = selection.caret.column;
        while (start > 0 && gw::isWordByte(static_cast<unsigned char>(text[start - 1]))) {
            --start;
        }
        while (end < text.size() && gw::isWordByte(static_cast<unsigned char>(text[end]))) {
            ++end;
        }
        if (start == end) {
            NSBeep();
            return;
        }
        gw::Position from = {selection.caret.line, start};
        gw::Position to = {selection.caret.line, end};
        [self selectRange:{from, to}];
        return;
    }

    gw::Range range = selection.range();
    if (range.start.line != range.end.line) {
        NSBeep();  // only single-line selections are searched for
        return;
    }
    std::string needle = buffer.text(range);

    // Search from the end of the last selection in the file.
    gw::Position searchFrom = range.end;
    for (const gw::Selection &extra : _document->extraSelections) {
        if (searchFrom < extra.range().end) {
            searchFrom = extra.range().end;
        }
    }
    size_t lineCount = buffer.lineCount();
    for (size_t step = 0; step <= lineCount; ++step) {
        size_t line = (searchFrom.line + step) % lineCount;
        std::string_view text = buffer.line(line);
        size_t from = step == 0 ? searchFrom.column : 0;
        size_t found = text.find(needle, from);
        if (found == std::string::npos) {
            continue;
        }
        gw::Selection match{{line, found}, {line, found + needle.size()}};
        bool alreadySelected = selectionsOverlap(match, selection);
        for (const gw::Selection &extra : _document->extraSelections) {
            alreadySelected = alreadySelected || selectionsOverlap(match, extra);
        }
        if (alreadySelected) {
            NSBeep();  // wrapped all the way round
            return;
        }
        _document->extraSelections.push_back(selection);
        _document->selection = match;
        _document->preferredX.reset();
        [self selectionDidChange];  // scrolls the new cursor into view
        self.needsDisplay = YES;
        return;
    }
    NSBeep();
}

// MARK: Clipboard and undo

/// The text of a selection, or the whole line when nothing is selected.
- (std::string)copyTextOfSelection:(gw::Selection)selection {
    if (selection.empty()) {
        return std::string(_document->buffer().line(selection.caret.line)) + "\n";
    }
    return _document->buffer().text(selection.range());
}

- (void)copy:(id)sender {
    if (!_document) return;
    std::string text;
    if (_document->extraSelections.empty()) {
        text = [self copyTextOfSelection:_document->selection];
    } else {
        // One piece per cursor, top to bottom, one per line.
        std::vector<gw::Selection> all = [self selectionsInOrder];
        for (size_t index = 0; index < all.size(); ++index) {
            std::string piece = [self copyTextOfSelection:all[index]];
            if (!piece.empty() && piece.back() == '\n' && all[index].empty()) {
                piece.pop_back();
            }
            if (index > 0) text += "\n";
            text += piece;
        }
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:@(text.c_str()) forType:NSPasteboardTypeString];
}

/// Removes the selection, or the whole line if nothing is selected.
- (void)deleteSelectionOrLineForCut {
    gw::Selection selection = _document->selection;
    if (selection.empty()) {  // cut the whole line, like VS Code
        size_t line = selection.caret.line;
        const auto &buffer = _document->buffer();
        gw::Range range = line + 1 < buffer.lineCount() ? gw::Range{{line, 0}, {line + 1, 0}}
                        : line > 0 ? gw::Range{{line - 1, buffer.line(line - 1).size()}, {line, buffer.line(line).size()}}
                                   : gw::Range{{0, 0}, {0, buffer.line(0).size()}};
        _document->replace(range, "");
    } else {
        _document->replace(selection.range(), "");
    }
}

- (void)cut:(id)sender {
    if (!_document) return;
    [self copy:sender];
    if (_multiDepth == 0 && !_document->extraSelections.empty()) {
        [self forEachSelection:^{
            [self deleteSelectionOrLineForCut];
            [self didEdit];
        } mergingLines:NO];
        return;
    }
    [self deleteSelectionOrLineForCut];
    [self didEdit];
}

- (void)paste:(id)sender {
    if (!_document) return;
    NSString *string = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!string.length) return;
    if (_multiDepth == 0 && !_document->extraSelections.empty()) {
        // As many lines as cursors: one line each, in order. Otherwise every cursor gets it all.
        NSArray<NSString *> *lines = [string componentsSeparatedByString:@"\n"];
        if (lines.count > 1 && [lines.lastObject length] == 0) {
            lines = [lines subarrayWithRange:NSMakeRange(0, lines.count - 1)];
        }
        BOOL distribute = lines.count == _document->extraSelections.size() + 1;
        [self forEachSelection:^{
            NSString *piece = distribute ? lines[self->_cursorIndexInLoop] : string;
            self->_document->replace(self->_document->selection.range(), piece.UTF8String);
            [self didEdit];
        } mergingLines:NO];
        return;
    }
    _document->replace(_document->selection.range(), string.UTF8String);
    [self didEdit];
}

- (void)undo:(id)sender {
    if (_document && _document->undo()) [self didEdit];
}

- (void)redo:(id)sender {
    if (_document && _document->redo()) [self didEdit];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;
    if (!_document) return NO;
    if (action == @selector(undo:)) return _document->canUndo();
    if (action == @selector(redo:)) return _document->canRedo();
    if (action == @selector(toggleLineComment:)) return !_configuration.lineComment.empty();
    return [self respondsToSelector:action];
}

// MARK: NSTextInputClient

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    NSString *plain = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
    _markedText = plain.length ? [plain copy] : nil;
    [self updateCaretAnimated:NO];
    self.needsDisplay = YES;
}

- (void)unmarkText {
    _markedText = nil;
    [self updateCaretAnimated:NO];
    self.needsDisplay = YES;
}

- (BOOL)hasMarkedText { return _markedText.length > 0; }
- (NSRange)markedRange { return _markedText.length ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0); }

- (NSRange)selectedRange {
    if (!_document) return NSMakeRange(NSNotFound, 0);
    LineLayout *layout = [self layoutForLine:_document->selection.caret.line];
    return NSMakeRange(layout->unitForByte(_document->selection.caret.column), 0);
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (!_document) return NSZeroRect;
    NSRect inWindow = [self convertRect:self.caretRect toView:nil];
    return [self.window convertRectToScreen:inWindow];
}

@end
