#import "EditorView.h"

#import "Services.h"
#import "StartupTiming.h"

#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <unordered_map>

namespace {

/// Lines of tokenizing allowed per call while drawing; beyond it, lines draw plain and
/// the highlighter catches up over the next frames instead of stalling the UI.
constexpr size_t kHighlightBudget = 400;
/// Padding between the line-number ruler and the text.
constexpr CGFloat kTextInset = 14;

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

    LineLayout() = default;
    LineLayout(const LineLayout &) = delete;
    LineLayout &operator=(const LineLayout &) = delete;
    LineLayout(LineLayout &&other) noexcept
        : line(other.line),
          byteToUnit(std::move(other.byteToUnit)),
          unitToByte(std::move(other.unitToByte)),
          highlights(std::move(other.highlights)),
          highlighted(other.highlighted) {
        other.line = nullptr;
    }
    LineLayout &operator=(LineLayout &&other) noexcept {
        if (this != &other) {
            if (line) CFRelease(line);
            line = other.line;
            other.line = nullptr;
            byteToUnit = std::move(other.byteToUnit);
            unitToByte = std::move(other.unitToByte);
            highlights = std::move(other.highlights);
            highlighted = other.highlighted;
        }
        return *this;
    }
    ~LineLayout() {
        if (line) CFRelease(line);
    }

    uint32_t unitForByte(size_t byte) const { return byteToUnit[std::min(byte, byteToUnit.size() - 1)]; }
    size_t byteForUnit(CFIndex unit) const {
        if (unit < 0) return 0;
        return unitToByte[std::min(static_cast<size_t>(unit), unitToByte.size() - 1)];
    }
};

void buildOffsetMaps(const std::string &text, bool utf8, LineLayout &layout) {
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
std::optional<size_t> indentColumns(const std::string &text, size_t tabSize) {
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

- (void)drawRect:(NSRect)dirtyRect {
    GWEditorView *editor = self.editor;
    [editor.backgroundColor setFill];
    NSRectFillUsingOperation(NSIntersectionRect(dirtyRect, self.bounds), NSCompositingOperationSourceOver);
    gw::Document *document = editor.document;
    if (!document) return;

    CGFloat lineHeight = editor.lineHeight;
    NSRect visible = editor.visibleRect;
    size_t count = document->buffer().lineCount();
    size_t first = static_cast<size_t>(std::max(0.0, std::floor(NSMinY(visible) / lineHeight)));
    size_t last = std::min(count - 1, static_cast<size_t>(std::floor(NSMaxY(visible) / lineHeight)));
    size_t caretLine = document->selection.caret.line;

    NSMutableParagraphStyle *right = [NSMutableParagraphStyle new];
    right.alignment = NSTextAlignmentRight;
    NSDictionary *normal = @{NSFontAttributeName: editor.lineNumberFont, NSForegroundColorAttributeName: editor.lineNumberColor,
                             NSParagraphStyleAttributeName: right};
    NSDictionary *active = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:editor.lineNumberFont.pointSize weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: editor.activeLineNumberColor, NSParagraphStyleAttributeName: right};
    CGFloat textHeight = editor.lineNumberFont.ascender - editor.lineNumberFont.descender;
    for (size_t line = first; line <= last && first < count; ++line) {
        CGFloat top = line * lineHeight - NSMinY(visible);  // follow the editor's scroll
        NSRect label = NSMakeRect(0, top + (lineHeight - textHeight) / 2 - 1, NSWidth(self.bounds) - 12, textHeight + 2);
        if (line == caretLine) {
            // A small accent bar marks the current line.
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.9] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4, top + 5, 3, lineHeight - 10) xRadius:1.5 yRadius:1.5] fill];
        }
        [[NSString stringWithFormat:@"%zu", line + 1] drawInRect:label withAttributes:line == caretLine ? active : normal];
    }
    [self drawChangeBarsWithLineHeight:lineHeight visible:visible];
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

    for (const gw::LineChange &change : changes) {
        CGFloat top = change.firstLine * lineHeight - NSMinY(visible);
        CGFloat height = change.lineCount * lineHeight;
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
    if (editor.onChangeMarkerClick != nil && point.x >= NSWidth(self.bounds) - 14 && !editor.lineChanges.empty()) {
        CGFloat lineHeight = editor.lineHeight;
        size_t line = static_cast<size_t>(std::max(0.0, std::floor((point.y + NSMinY(editor.visibleRect)) / lineHeight)));
        for (const gw::LineChange &change : editor.lineChanges) {
            bool covers = line >= change.firstLine && line < change.firstLine + std::max<size_t>(change.lineCount, 1);
            bool nearRemoval = change.kind == gw::LineChangeKind::Removed && (line == change.firstLine || line + 1 == change.firstLine);
            if ((change.lineCount > 0 && covers) || nearRemoval) {
                NSRect bar = NSMakeRect(NSWidth(self.bounds) - 6, change.firstLine * lineHeight - NSMinY(editor.visibleRect),
                                        6, std::max<CGFloat>(change.lineCount * lineHeight, lineHeight));
                editor.onChangeMarkerClick(change.firstLine, bar);
                return;
            }
        }
    }
    [editor mouseDown:event];  // clicking a line number selects the line
}

@end

// MARK: - Minimap

/// The whole file in miniature, each token a sliver of its colour, with the visible region
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
        const std::string &text = buffer.line(line);
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
            for (const auto &token : *tokens) paint(token.start, std::min<size_t>(token.end, text.size()), [editor colorForScopes:token.scopes]);
        } else {
            paint(0, text.size(), plain);
        }
    }

    [self drawSectionsWithOffset:offset];

    // The part of the file currently on screen.
    NSRect visible = editor.visibleRect;
    CGFloat top = NSMinY(visible) / editor.lineHeight * kMiniLine - offset;
    CGFloat height = NSHeight(visible) / editor.lineHeight * kMiniLine;
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

// MARK: - Editor

@implementation GWEditorView {
    gw::Document *_document;
    gw::Highlighter *_highlighter;
    gw::LanguageConfiguration _configuration;
    std::unordered_map<size_t, LineLayout> _layouts;
    bool _highlightBlocked;  // this frame ran out of highlighting budget
    bool _useTabs;
    size_t _longestLine;

    // Bracket nesting depth at the start of each line, for colouring brackets by depth.
    std::vector<int> _depthAt;
    size_t _depthValid;
    std::unordered_map<const gw::tm::ScopeNode *, bool> _inertScopes;  // strings and comments
    // The bracket pair around the caret, cached per document version and caret position.
    uint64_t _matchVersion;
    gw::Position _matchCaret;
    std::optional<std::pair<gw::Position, gw::Position>> _match;

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
        _matchVersion = UINT64_MAX;
        _minimap = [[GWMinimapView alloc] initWithFrame:NSZeroRect];
        _minimap.editor = self;
        _gutter = [[GWGutterView alloc] initWithFrame:NSZeroRect];
        _gutter.editor = self;

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

        [self reloadAppearance];
        for (NSNotificationName name in @[GWThemeDidChangeNotification, GWEditorSettingsDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appearanceChanged:) name:name object:nil];
        }
    }
    return self;
}

- (void)dealloc {
    [_blinkTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
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
    _document->selection = {range.start, range.end};
    _document->preferredX.reset();
    NSRect visible = self.visibleRect;
    CGFloat top = range.start.line * _lineHeight;
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
    flash.frame = CGRectMake(NSMinX(self.visibleRect) + 4, first * _lineHeight, NSWidth(self.visibleRect) - 8, count * _lineHeight);
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

// MARK: Setup

- (void)setDocument:(gw::Document *)document
        highlighter:(gw::Highlighter *)highlighter
      configuration:(const gw::LanguageConfiguration &)configuration {
    _document = document;
    _highlighter = highlighter;
    _configuration = configuration;
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
            const std::string &text = buffer.line(line);
            if (!text.empty() && text[0] == '\t') ++tabs;
            if (text.size() >= 2 && text[0] == ' ' && text[1] == ' ') ++spaces;
        }
        _useTabs = tabs > spaces;
    }
    [self refreshSections];
    [self invalidateLayout];
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
    _tabSize = static_cast<size_t>(std::max(1, services.settings.tabSize));
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
    _foreground = GWColor(theme.color("editor.foreground", theme.isDark() ? 0xD4D4D4FF : 0x1E1E1EFF));
    _selectionColor = [services color:@"editor.selectionBackground"
                             fallback:[NSColor.selectedTextBackgroundColor colorWithAlphaComponent:0.6]];
    _lineHighlight = [services color:@"editor.lineHighlightBackground" fallback:[base colorWithAlphaComponent:0.055]];
    _caretColor = [services color:@"editorCursor.foreground" fallback:NSColor.controlAccentColor];
    _lineNumberColor = [services color:@"editorLineNumber.foreground" fallback:[_foreground colorWithAlphaComponent:0.4]];
    _activeLineNumberColor = [services color:@"editorLineNumber.activeForeground" fallback:_foreground];
    _guideColor = [services color:@"editorIndentGuide.background1"
                         fallback:[services color:@"editorIndentGuide.background" fallback:[base colorWithAlphaComponent:0.08]]];
    _matchColor = [services color:@"editorBracketMatch.border" fallback:[NSColor.controlAccentColor colorWithAlphaComponent:0.8]];
    _occurrenceColor = [services color:@"editor.wordHighlightBackground"
                              fallback:[NSColor.controlAccentColor colorWithAlphaComponent:0.22]];
    _dividerColor = [_foreground colorWithAlphaComponent:0.22];
    // Bracket pair colours, as in VS Code (gold, orchid, blue unless the theme says otherwise).
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
    [self invalidateLayout];
    _gutter.needsDisplay = YES;
}

- (void)invalidateLayout {
    _layouts.clear();
    _longestLine = 0;
    if (_document) {
        const auto &buffer = _document->buffer();
        for (size_t line = 0; line < buffer.lineCount(); ++line) _longestLine = std::max(_longestLine, buffer.line(line).size());
    }
    [self updateFrameSize];
    self.needsDisplay = YES;
    _gutter.needsDisplay = YES;
    _minimap.needsDisplay = YES;
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
    [self.window invalidateCursorRectsForView:self];
    _gutter.needsDisplay = YES;
    _minimap.needsDisplay = YES;
}

- (CGFloat)gutterWidth {
    size_t count = _document ? _document->buffer().lineCount() : 1;
    int digits = std::max(3, static_cast<int>(std::log10(static_cast<double>(count))) + 1);
    return std::ceil(digits * _charWidth + 26);
}

- (CGFloat)textLeft { return kTextInset; }

- (void)updateFrameSize {
    NSScrollView *scrollView = self.enclosingScrollView;
    if (!scrollView) return;
    // The window lays the gutter out beside the scroll view; tell it when the width changes.
    if (std::abs(NSWidth(_gutter.frame) - self.gutterWidth) > 0.5) _gutter.superview.needsLayout = YES;
    NSSize clip = scrollView.contentView.bounds.size;
    size_t lines = _document ? _document->buffer().lineCount() : 1;
    // Allow scrolling the last line up to the middle of the view, like most code editors.
    CGFloat height = std::max(clip.height, lines * _lineHeight + clip.height * 0.5);
    CGFloat width = std::max(clip.width, self.textLeft + _longestLine * _charWidth + 80);
    if (!NSEqualSizes(self.frame.size, NSMakeSize(width, height))) [self setFrameSize:NSMakeSize(width, height)];
}

// MARK: Syntax colours and brackets

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
    const std::string &text = _document->buffer().line(line);
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
/// hasn't reached that far yet (brackets then draw uncoloured for a frame).
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
        const std::string &text = buffer.line(_depthValid);
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
        const std::string &text = buffer.line(at.line);
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
            const std::string &scan = buffer.line(static_cast<size_t>(line));
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

    const std::string &text = buffer.line(index);
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
        // The stylist combines the theme, the user's colour rules, rainbow variables and
        // colours set for specific names into one look per run of the line.
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
    // Colour brackets by nesting depth (skipping strings and comments).
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
    auto inserted = _layouts.insert_or_assign(index, std::move(layout));
    return &inserted.first->second;
}

- (void)applyStyle:(const gw::TextStyle &)style toString:(NSMutableAttributedString *)string range:(NSRange)range {
    [string addAttribute:NSForegroundColorAttributeName value:GWColor(style.foreground) range:range];
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
    return self.textLeft + CTLineGetOffsetForStringIndex(layout->line, layout->unitForByte(position.column), nullptr);
}

- (gw::Position)positionForPoint:(NSPoint)point {
    const auto &buffer = _document->buffer();
    if (point.y < 0) return {0, 0};
    size_t line = static_cast<size_t>(point.y / _lineHeight);
    if (line >= buffer.lineCount()) return buffer.end();
    LineLayout *layout = [self layoutForLine:line];
    CFIndex unit = CTLineGetStringIndexForPosition(layout->line, CGPointMake(point.x - self.textLeft, 0));
    if (unit == kCFNotFound) unit = 0;
    return buffer.clamp({line, layout->byteForUnit(unit)});
}

- (NSRect)caretRect {
    gw::Position caret = _document->selection.caret;
    return NSMakeRect(std::round([self xForPosition:caret]) - 1, caret.line * _lineHeight + 3, 2, _lineHeight - 6);
}

// MARK: Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [_backgroundColor setFill];
    NSRectFillUsingOperation(dirtyRect, NSCompositingOperationSourceOver);
    if (!_document) return;
    _highlightBlocked = false;

    const auto &buffer = _document->buffer();
    size_t count = buffer.lineCount();
    size_t first = static_cast<size_t>(std::max(0.0, std::floor(NSMinY(dirtyRect) / _lineHeight)));
    size_t last = std::min(count - 1, static_cast<size_t>(std::max(0.0, std::floor(NSMaxY(dirtyRect) / _lineHeight))));
    if (first >= count) return;
    NSRect visible = self.visibleRect;
    gw::Range selection = _document->selection.range();
    size_t caretLine = _document->selection.caret.line;

    // Current line: a soft rounded band.
    if (selection.empty() && caretLine >= first && caretLine <= last) {
        [_lineHighlight setFill];
        NSRect band = NSMakeRect(NSMinX(visible) + 4, caretLine * _lineHeight + 1, NSWidth(visible) - 8, _lineHeight - 2);
        [[NSBezierPath bezierPathWithRoundedRect:band xRadius:7 yRadius:7] fill];
    }

    [self drawLineTintsFromLine:first toLine:last];
    [self drawFindMatchesFromLine:first toLine:last];

    const gw::EditorSettings &settings = GWServices.shared.settings;
    if (settings.sectionDividers) {
        [self drawSectionDividersFromLine:first toLine:last];
    }
    [self drawHighlightsFromLine:first toLine:last];
    if (settings.highlightOccurrences) {
        [self drawOccurrencesFromLine:first toLine:last];
    }

    // Indent guides: faint verticals at each indentation level.
    [_guideColor setFill];
    CGFloat step = _tabSize * _charWidth;
    for (size_t line = first; line <= last && settings.indentGuides; ++line) {
        std::optional<size_t> columns = indentColumns(buffer.line(line), _tabSize);
        if (!columns) {
            // Blank lines continue the guides of the code around them.
            std::optional<size_t> above, below;
            for (size_t look = line; look-- > 0 && line - look < 100;) {
                if ((above = indentColumns(buffer.line(look), _tabSize))) break;
            }
            for (size_t look = line + 1; look < count && look - line < 100; ++look) {
                if ((below = indentColumns(buffer.line(look), _tabSize))) break;
            }
            columns = std::min(above.value_or(0), below.value_or(0));
        }
        for (size_t level = 0; level < *columns / _tabSize; ++level) {
            NSRectFillUsingOperation(NSMakeRect(std::round(self.textLeft + level * step), line * _lineHeight, 1, _lineHeight),
                                     NSCompositingOperationSourceOver);
        }
    }

    static BOOL markedFirstDraw = NO;
    if (!markedFirstDraw) {
        markedFirstDraw = YES;
        GWStartupMark(@"first code drawn");
    }
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));  // flipped view
    for (size_t line = first; line <= last; ++line) {
        CGFloat y = line * _lineHeight;
        // Selection behind the text, with softly rounded ends.
        if (!selection.empty() && line >= selection.start.line && line <= selection.end.line) {
            CGFloat from = line == selection.start.line ? [self xForPosition:selection.start] : self.textLeft;
            CGFloat to = line == selection.end.line ? [self xForPosition:selection.end]
                                                    : [self xForPosition:{line, buffer.line(line).size()}] + _charWidth * 0.6;
            [_selectionColor setFill];
            NSRect band = NSMakeRect(from, y + 1, std::max(0.0, to - from), _lineHeight - 2);
            [[NSBezierPath bezierPathWithRoundedRect:band xRadius:4 yRadius:4] fill];
        }
        LineLayout *layout = [self layoutForLine:line];
        CGContextSetTextPosition(context, self.textLeft, y + _baseline);
        CTLineDraw(layout->line, context);
    }

    // Matching brackets get a thin rounded outline.
    if (auto match = [self bracketMatch]) {
        [_matchColor setStroke];
        for (gw::Position at : {match->first, match->second}) {
            if (at.line < first || at.line > last) continue;
            CGFloat x = [self xForPosition:at];
            CGFloat width = [self xForPosition:buffer.nextCharacter(at)] - x;
            NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x - 0.5, at.line * _lineHeight + 3, width + 1, _lineHeight - 6)
                                                               xRadius:3 yRadius:3];
            box.lineWidth = 1;
            [box stroke];
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

/// Whole-line colours, for added and removed lines in a diff.
- (void)drawLineTintsFromLine:(size_t)first toLine:(size_t)last {
    if (_lineTints.empty()) {
        return;
    }
    NSRect visible = self.visibleRect;
    for (size_t line = first; line <= last && line < _lineTints.size(); ++line) {
        if (_lineTints[line] == 0) {
            continue;
        }
        [GWColor(_lineTints[line]) setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(visible), line * _lineHeight, NSWidth(visible), _lineHeight),
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
        if (match->start.line != match->end.line) {
            continue;
        }
        CGFloat x = [self xForPosition:match->start];
        CGFloat width = [self xForPosition:match->end] - x;
        NSRect box = NSMakeRect(x - 1, match->start.line * _lineHeight + 2, std::max<CGFloat>(width, 3) + 2, _lineHeight - 4);
        BOOL isCurrent = static_cast<long>(match - _findMatches.begin()) == _currentFindMatch;
        [isCurrent ? currentColor : matchColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
        if (isCurrent) {
            [[NSColor.systemOrangeColor colorWithAlphaComponent:0.9] setStroke];
            NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3];
            outline.lineWidth = 1;
            [outline stroke];
        }
    }
}

/// Xcode-style: a thin line across the editor above every "// MARK: - Title".
- (void)drawSectionDividersFromLine:(size_t)first toLine:(size_t)last {
    NSRect visible = self.visibleRect;
    [_dividerColor setFill];
    for (const gw::Section &section : _sections) {
        if (!section.divider || section.line < first || section.line > last) {
            continue;
        }
        CGFloat y = std::round(section.line * _lineHeight) + 0.5;
        NSRect line = NSMakeRect(NSMinX(visible) + 6, y - 0.5, NSWidth(visible) - 12, 1);
        NSRectFillUsingOperation(line, NSCompositingOperationSourceOver);
    }
}

/// Backgrounds from the user's colour rules ("highlight this name", scope backgrounds).
- (void)drawHighlightsFromLine:(size_t)first toLine:(size_t)last {
    for (size_t line = first; line <= last; ++line) {
        LineLayout *layout = [self layoutForLine:line];
        for (const LineLayout::Highlight &highlight : layout->highlights) {
            CGFloat start = self.textLeft + CTLineGetOffsetForStringIndex(layout->line, highlight.startUnit, nullptr);
            CGFloat end = self.textLeft + CTLineGetOffsetForStringIndex(layout->line, highlight.endUnit, nullptr);
            NSRect box = NSMakeRect(start - 1, line * _lineHeight + 2, end - start + 2, _lineHeight - 4);
            [GWColor(highlight.color) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
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
        const std::string &text = buffer.line(line);
        size_t found = text.find(word);
        while (found != std::string::npos) {
            size_t end = found + word.size();
            bool startsWord = found == 0 || !gw::isWordByte(static_cast<unsigned char>(text[found - 1]));
            bool endsWord = end >= text.size() || !gw::isWordByte(static_cast<unsigned char>(text[end]));
            if (startsWord && endsWord) {
                CGFloat x = [self xForPosition:{line, found}];
                CGFloat width = [self xForPosition:{line, end}] - x;
                NSRect box = NSMakeRect(x - 1, line * _lineHeight + 2, width + 2, _lineHeight - 4);
                [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
            }
            found = text.find(word, found + 1);
        }
    }
}

// MARK: Caret context (for the colour inspector and the breadcrumb)

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
    const std::string &text = _document->buffer().line(caret.line);
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
        [menu addItemWithTitle:[NSString stringWithFormat:@"Colour “%@”…", name] action:@selector(inspectColors:) keyEquivalent:@""];
        [menu addItemWithTitle:[NSString stringWithFormat:@"Highlight Every “%@”", name] action:@selector(highlightName:) keyEquivalent:@""];
        const auto &identifiers = GWServices.shared.settings.colors.identifiers;
        if (identifiers.count(word) > 0) {
            [menu addItemWithTitle:[NSString stringWithFormat:@"Clear Colours for “%@”", name] action:@selector(clearNameColours:) keyEquivalent:@""];
        }
        [menu addItem:NSMenuItem.separatorItem];
    }
    [menu addItemWithTitle:@"Inspect Colours at Caret…" action:@selector(inspectColors:) keyEquivalent:@""];
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

/// Gives the name under the caret a highlight in its own rainbow colour, everywhere.
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

- (IBAction)clearNameColours:(id)sender {
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
    [CATransaction begin];
    if (animated) {
        [CATransaction setAnimationDuration:0.085];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _caretLayer.hidden = !show;
    _caretLayer.opacity = 1;
    if (show) _caretLayer.frame = self.caretRect;
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

- (void)scrollCaretToVisible {
    if (!_document) return;
    NSRect target = NSInsetRect(self.caretRect, -_charWidth * 4, -_lineHeight * 2);
    [self scrollRectToVisible:target];
}

- (void)scrollToLineCentered:(size_t)line {
    NSClipView *clip = self.enclosingScrollView.contentView;
    if (!clip) return;
    CGFloat y = line * _lineHeight - NSHeight(clip.bounds) / 2;
    y = std::max(0.0, std::min(y, NSHeight(self.frame) - NSHeight(clip.bounds)));
    [clip scrollToPoint:NSMakePoint(NSMinX(clip.bounds), y)];
    [self.enclosingScrollView reflectScrolledClipView:clip];
}

- (void)selectionDidChange {
    [self scrollCaretToVisible];
    [self updateCaretAnimated:YES];
    self.needsDisplay = YES;  // current-line band and bracket match
    _gutter.needsDisplay = YES;
    if (self.onSelectionChange) self.onSelectionChange();
}

- (void)didEdit {
    _layouts.clear();
    const auto &buffer = _document->buffer();
    size_t caretLine = _document->selection.caret.line;
    _longestLine = std::max(_longestLine, buffer.line(std::min(caretLine, buffer.lineCount() - 1)).size());
    [self updateFrameSize];
    self.needsDisplay = YES;
    _minimap.needsDisplay = YES;
    [self scheduleSectionsRefresh];
    [self selectionDidChange];
    if (self.onEdit) self.onEdit();
}

- (void)moveCaretTo:(gw::Position)position extend:(BOOL)extend {
    if (!_document) return;
    position = _document->buffer().clamp(position);
    if (extend) {
        _document->selection.caret = position;
    } else {
        _document->selection = {position, position};
    }
    [self selectionDidChange];
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
            gw::Position end = endLine + 1 < buffer.lineCount() ? gw::Position{endLine + 1, 0} : gw::Position{endLine, buffer.line(endLine).size()};
            return at.line < anchor.line ? gw::Selection{end, start} : gw::Selection{start, end};
        }
        if (event.clickCount == 2) {  // whole words
            gw::Range first = buffer.wordAt(anchor), last = buffer.wordAt(at);
            return at < anchor ? gw::Selection{first.end, last.start} : gw::Selection{first.start, last.end};
        }
        return gw::Selection{anchor, at};
    };

    if (event.modifierFlags & NSEventModifierFlagShift) anchor = _document->selection.anchor;
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

// MARK: Keyboard

- (void)keyDown:(NSEvent *)event {
    if (!_document) return;
    [self interpretKeyEvents:@[event]];
}

- (void)doCommandBySelector:(SEL)selector {
    if ([self respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))[self methodForSelector:selector])(self, selector, nil);
    }
}

// Horizontal movement.
- (void)moveHorizontally:(int)direction byWord:(BOOL)word extend:(BOOL)extend {
    const auto &buffer = _document->buffer();
    gw::Selection selection = _document->selection;
    _document->preferredX.reset();
    if (!extend && !selection.empty() && !word) {
        gw::Range range = selection.range();
        [self moveCaretTo:direction < 0 ? range.start : range.end extend:NO];
        return;
    }
    gw::Position caret = selection.caret;
    gw::Position target = direction < 0 ? (word ? buffer.previousWordStart(caret) : buffer.previousCharacter(caret))
                                        : (word ? buffer.nextWordEnd(caret) : buffer.nextCharacter(caret));
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

// Vertical movement keeps the column the caret "wants" across short lines.
- (void)moveVertically:(long)lines extend:(BOOL)extend {
    const auto &buffer = _document->buffer();
    gw::Position caret = _document->selection.caret;
    double x = _document->preferredX.value_or([self xForPosition:caret]);
    long target = static_cast<long>(caret.line) + lines;
    gw::Position position;
    if (target < 0) {
        position = {0, 0};
    } else if (target >= static_cast<long>(buffer.lineCount())) {
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
    gw::Position caret = _document->selection.caret;
    size_t indent = _document->buffer().indentEnd(caret.line);
    _document->preferredX.reset();
    [self moveCaretTo:{caret.line, caret.column == indent ? 0 : indent} extend:extend];
}
- (void)moveToLineEndExtend:(BOOL)extend {
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
    _document->selection = {{0, 0}, _document->buffer().end()};
    [self selectionDidChange];
}

- (void)cancelOperation:(id)sender {
    if (!_document) return;
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
    _markedText = nil;
    NSString *plain = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
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
    gw::Position caret = _document->selection.range().start;
    const std::string &line = _document->buffer().line(caret.line);
    size_t indentEnd = std::min(_document->buffer().indentEnd(caret.line), caret.column);
    std::string indent = line.substr(0, indentEnd);
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

- (void)insertBacktab:(id)sender { [self outdentLines:sender]; }

- (void)deleteBackward:(id)sender {
    if (!_document) return;
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
    const std::string &line = buffer.line(caret.line);
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
    gw::Position caret = _document->selection.caret;
    _document->deleteSelectionOr({caret, _document->buffer().nextCharacter(caret)});
    [self didEdit];
}

- (void)deleteWordBackward:(id)sender {
    if (!_document) return;
    gw::Position caret = _document->selection.caret;
    _document->deleteSelectionOr({_document->buffer().previousWordStart(caret), caret});
    [self didEdit];
}

- (void)deleteWordForward:(id)sender {
    if (!_document) return;
    gw::Position caret = _document->selection.caret;
    _document->deleteSelectionOr({caret, _document->buffer().nextWordEnd(caret)});
    [self didEdit];
}

- (void)deleteToBeginningOfLine:(id)sender {
    if (!_document) return;
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

/// Rewrites whole lines as one undoable edit, then selects them if several were involved.
- (void)transformLines:(std::string (^)(const std::string &line, size_t index))transform {
    if (!_document) return;
    auto [first, last] = [self selectedLines];
    const auto &buffer = _document->buffer();
    gw::Selection before = _document->selection;
    std::string replacement;
    for (size_t line = first; line <= last; ++line) {
        if (line > first) replacement += "\n";
        replacement += transform(buffer.line(line), line);
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
    std::string unit = [self indentUnit];
    [self transformLines:^std::string(const std::string &line, size_t) { return line.empty() ? line : unit + line; }];
}

- (IBAction)outdentLines:(id)sender {
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
        const std::string &text = buffer.line(line);
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
    auto [first, last] = [self selectedLines];
    if (first == 0) return;

    gw::Selection before = _document->selection;
    const auto &buffer = _document->buffer();
    std::string lineAbove = buffer.line(first - 1);
    std::string movedBlock = [self joinedTextOfLinesFrom:first to:last];
    gw::Range whole = {{first - 1, 0}, {last, buffer.line(last).size()}};
    _document->replace(whole, movedBlock + "\n" + lineAbove);

    _document->selection = {{before.anchor.line - 1, before.anchor.column}, {before.caret.line - 1, before.caret.column}};
    [self didEdit];
}

/// Moves the selected lines down one line (the line below goes above them).
- (IBAction)moveLinesDown:(id)sender {
    if (!_document || _document->readOnly) return;
    auto [first, last] = [self selectedLines];
    if (last + 1 >= _document->buffer().lineCount()) return;

    gw::Selection before = _document->selection;
    const auto &buffer = _document->buffer();
    std::string lineBelow = buffer.line(last + 1);
    std::string movedBlock = [self joinedTextOfLinesFrom:first to:last];
    gw::Range whole = {{first, 0}, {last + 1, buffer.line(last + 1).size()}};
    _document->replace(whole, lineBelow + "\n" + movedBlock);

    _document->selection = {{before.anchor.line + 1, before.anchor.column}, {before.caret.line + 1, before.caret.column}};
    [self didEdit];
}

/// Copies the selected lines below themselves; the selection moves to the copy.
- (IBAction)duplicateLinesDown:(id)sender {
    if (!_document || _document->readOnly) return;
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
    std::string indent = buffer.line(line).substr(0, buffer.indentEnd(line));
    _document->replace({{line, 0}, {line, 0}}, indent + "\n");
    gw::Position caret = {line, indent.size()};
    _document->selection = {caret, caret};
    [self didEdit];
}

/// ⌘D: with nothing selected, select the word at the caret; otherwise jump to the next place the
/// selected text appears (wrapping around at the end of the file).
- (IBAction)selectNextOccurrence:(id)sender {
    if (!_document) return;
    const auto &buffer = _document->buffer();
    gw::Selection selection = _document->selection;

    if (selection.empty()) {
        const std::string &text = buffer.line(selection.caret.line);
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
    size_t lineCount = buffer.lineCount();
    size_t startLine = range.end.line;
    // Look after the selection on its own line first, then each following line, then wrap.
    for (size_t step = 0; step <= lineCount; ++step) {
        size_t line = (startLine + step) % lineCount;
        const std::string &text = buffer.line(line);
        size_t searchFrom = 0;
        if (step == 0) {
            searchFrom = range.end.column;
        }
        size_t found = text.find(needle, searchFrom);
        if (step == lineCount) {
            // Back on the starting line after wrapping: only matches before the selection count.
            found = text.find(needle, 0);
        }
        if (found == std::string::npos) {
            continue;
        }
        gw::Position from = {line, found};
        gw::Position to = {line, found + needle.size()};
        [self selectRange:{from, to}];
        return;
    }
    NSBeep();
}

// MARK: Clipboard and undo

- (void)copy:(id)sender {
    if (!_document) return;
    gw::Selection selection = _document->selection;
    std::string text = selection.empty() ? _document->buffer().line(selection.caret.line) + "\n"
                                         : _document->buffer().text(selection.range());
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:@(text.c_str()) forType:NSPasteboardTypeString];
}

- (void)cut:(id)sender {
    if (!_document) return;
    [self copy:sender];
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
    [self didEdit];
}

- (void)paste:(id)sender {
    if (!_document) return;
    NSString *string = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!string.length) return;
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
