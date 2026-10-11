#import "TerminalView.h"

#import "Services.h"
#import "TerminalSession.h"

#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>

#include <unordered_map>
#include <vector>

using gw::term::Cell;
using gw::term::Row;
using gw::term::TermColor;

// ===========================================================================
// What is drawn for one row, kept until the row changes

namespace {

constexpr CGFloat kPadding = 10;

struct BackgroundSpan {
    int firstColumn = 0;
    int endColumn = 0;
    CGColorRef color = nullptr;  // owned by the palette or retained below
};

struct TextRun {
    CTLineRef line = nullptr;
    int column = 0;
    int width = 0;  // in cells
    CGColorRef color = nullptr;
    bool underline = false;
    bool strike = false;
};

struct BoxCell {
    int column = 0;
    int width = 1;
    uint32_t character = 0;
    CGColorRef color = nullptr;
};

struct RowDrawing {
    std::vector<BackgroundSpan> backgrounds;
    std::vector<TextRun> runs;
    std::vector<BoxCell> boxes;

    RowDrawing() = default;
    RowDrawing(const RowDrawing&) = delete;
    RowDrawing& operator=(const RowDrawing&) = delete;
    RowDrawing(RowDrawing&& other) noexcept = default;
    RowDrawing& operator=(RowDrawing&& other) noexcept = default;
    ~RowDrawing() {
        for (TextRun& run : runs) {
            if (run.line != nullptr) CFRelease(run.line);
        }
    }
};

/// Box-drawing and block characters are drawn as shapes, not glyphs, so lines meet exactly and
/// there are no gaps between rows (tmux, htop and friends depend on it).
bool isDrawnAsShape(uint32_t c) {
    return (c >= 0x2500 && c <= 0x257F) || (c >= 0x2580 && c <= 0x259F);
}

/// Pieces of a box-drawing character: 0 none, 1 light, 2 heavy, 3 double, for each side.
struct Lines {
    uint8_t left = 0, right = 0, up = 0, down = 0;
    bool rounded = false;
};

Lines linesFor(uint32_t c) {
    switch (c) {
        case 0x2500: return {1, 1, 0, 0, false};
        case 0x2501: return {2, 2, 0, 0, false};
        case 0x2502: return {0, 0, 1, 1, false};
        case 0x2503: return {0, 0, 2, 2, false};
        case 0x250C: return {0, 1, 0, 1, false};
        case 0x250F: return {0, 2, 0, 2, false};
        case 0x2510: return {1, 0, 0, 1, false};
        case 0x2513: return {2, 0, 0, 2, false};
        case 0x2514: return {0, 1, 1, 0, false};
        case 0x2517: return {0, 2, 2, 0, false};
        case 0x2518: return {1, 0, 1, 0, false};
        case 0x251B: return {2, 0, 2, 0, false};
        case 0x251C: return {0, 1, 1, 1, false};
        case 0x2523: return {0, 2, 2, 2, false};
        case 0x2524: return {1, 0, 1, 1, false};
        case 0x252B: return {2, 0, 2, 2, false};
        case 0x252C: return {1, 1, 0, 1, false};
        case 0x2533: return {2, 2, 0, 2, false};
        case 0x2534: return {1, 1, 1, 0, false};
        case 0x253B: return {2, 2, 2, 0, false};
        case 0x253C: return {1, 1, 1, 1, false};
        case 0x254B: return {2, 2, 2, 2, false};
        case 0x2550: return {3, 3, 0, 0, false};
        case 0x2551: return {0, 0, 3, 3, false};
        case 0x2554: return {0, 3, 0, 3, false};
        case 0x2557: return {3, 0, 0, 3, false};
        case 0x255A: return {0, 3, 3, 0, false};
        case 0x255D: return {3, 0, 3, 0, false};
        case 0x2560: return {0, 3, 3, 3, false};
        case 0x2563: return {3, 0, 3, 3, false};
        case 0x2566: return {3, 3, 0, 3, false};
        case 0x2569: return {3, 3, 3, 0, false};
        case 0x256C: return {3, 3, 3, 3, false};
        case 0x256D: return {0, 1, 0, 1, true};
        case 0x256E: return {1, 0, 0, 1, true};
        case 0x256F: return {1, 0, 1, 0, true};
        case 0x2570: return {0, 1, 1, 0, true};
        case 0x2574: return {1, 0, 0, 0, false};
        case 0x2575: return {0, 0, 1, 0, false};
        case 0x2576: return {0, 1, 0, 0, false};
        case 0x2577: return {0, 0, 0, 1, false};
        case 0x2578: return {2, 0, 0, 0, false};
        case 0x2579: return {0, 0, 2, 0, false};
        case 0x257A: return {0, 2, 0, 0, false};
        case 0x257B: return {0, 0, 0, 2, false};
        case 0x2504: case 0x2508: return {1, 1, 0, 0, false};
        case 0x2506: case 0x250A: return {0, 0, 1, 1, false};
        default: return {};
    }
}

}  // namespace

// ===========================================================================
// The view

typedef struct {
    long row;
    int column;
} GWTermPoint;

static BOOL pointBefore(GWTermPoint a, GWTermPoint b) {
    return a.row < b.row || (a.row == b.row && a.column < b.column);
}

@implementation GWTerminalView {
    GWTerminalSession *_session;

    CTFontRef _fonts[4];  // regular, bold, italic, bold italic
    CGFloat _cellWidth;
    CGFloat _cellHeight;
    CGFloat _baseline;
    CGFloat _fontSize;

    CGColorRef _palette[256];
    CGColorRef _foreground;
    CGColorRef _background;
    CGColorRef _cursorColor;
    CGColorRef _selectionColor;
    NSColor *_selectionNSColor;

    std::unordered_map<uint64_t, RowDrawing> _cache;
    std::unordered_map<CGColorRef, CGColorRef> _dimmedColors;  // faint versions, kept for as long as rows use them

    long _scrollOffset;  // lines scrolled back into history; 0 shows the live screen
    CGFloat _scrollRemainder;
    long _lastHistoryCount;

    BOOL _hasSelection;
    GWTermPoint _selectionAnchor;
    GWTermPoint _selectionHead;
    NSInteger _selectionGranularity;  // 1 characters, 2 words, 3 lines
    BOOL _selecting;
    BOOL _focused;
    BOOL _reportingMouse;
    NSString *_markedText;
}

// ---------------------------------------------------------------------------
// MARK: Setup

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        for (int index = 0; index < 4; ++index) _fonts[index] = nullptr;
        for (int index = 0; index < 256; ++index) _palette[index] = nullptr;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        [self reloadAppearance];
        for (NSNotificationName name in @[GWThemeDidChangeNotification, GWEditorSettingsDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appearanceChanged:) name:name object:nil];
        }
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self releaseAppearance];
}

- (void)releaseAppearance {
    for (int index = 0; index < 4; ++index) {
        if (_fonts[index]) CFRelease(_fonts[index]);
        _fonts[index] = nullptr;
    }
    for (int index = 0; index < 256; ++index) {
        if (_palette[index]) CGColorRelease(_palette[index]);
        _palette[index] = nullptr;
    }
    if (_foreground) CGColorRelease(_foreground);
    if (_background) CGColorRelease(_background);
    if (_cursorColor) CGColorRelease(_cursorColor);
    if (_selectionColor) CGColorRelease(_selectionColor);
    _foreground = _background = _cursorColor = _selectionColor = nullptr;
    _cache.clear();
    for (auto &entry : _dimmedColors) CGColorRelease(entry.second);
    _dimmedColors.clear();
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)appearanceChanged:(NSNotification *)notification { [self reloadAppearance]; }

static CGColorRef makeColor(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: color;
    CGFloat components[4] = {rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef result = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return result;
}

static CGColorRef makeRGB(uint8_t red, uint8_t green, uint8_t blue) {
    CGFloat components[4] = {red / 255.0, green / 255.0, blue / 255.0, 1};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef result = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return result;
}

- (void)reloadAppearance {
    GWServices *services = GWServices.shared;
    [self releaseAppearance];

    // Fonts: the editor's family, a little smaller.
    double configuredSize = services.settings.terminalFontSize;
    if (configuredSize > 0) {
        _fontSize = configuredSize;
    } else {
        _fontSize = MAX(10.0, services.settings.fontSize - 1);
    }
    NSFont *regular = [services editorFontBold:NO italic:NO];
    NSFont *bold = [services editorFontBold:YES italic:NO];
    NSFont *italic = [services editorFontBold:NO italic:YES];
    NSFont *boldItalic = [services editorFontBold:YES italic:YES];
    NSFont *variants[4] = {regular, bold, italic, boldItalic};
    for (int index = 0; index < 4; ++index) {
        _fonts[index] = CTFontCreateCopyWithAttributes((__bridge CTFontRef)variants[index], _fontSize, nullptr, nullptr);
    }
    CGGlyph glyph = 0;
    UniChar letter = 'M';
    CTFontGetGlyphsForCharacters(_fonts[0], &letter, &glyph, 1);
    CGSize advance = CGSizeZero;
    CTFontGetAdvancesForGlyphs(_fonts[0], kCTFontOrientationHorizontal, &glyph, &advance, 1);
    _cellWidth = advance.width > 1 ? advance.width : _fontSize * 0.6;
    CGFloat ascent = CTFontGetAscent(_fonts[0]);
    CGFloat descent = CTFontGetDescent(_fonts[0]);
    CGFloat leading = CTFontGetLeading(_fonts[0]);
    _cellHeight = ceil((ascent + descent + leading) * 1.12);
    _baseline = round((_cellHeight - (ascent + descent)) / 2 + ascent);

    // Colors: the theme's terminal colors, else a familiar palette.
    static const uint8_t fallback[16][3] = {
        {0x00, 0x00, 0x00}, {0xCD, 0x31, 0x31}, {0x0D, 0xBC, 0x79}, {0xE5, 0xE5, 0x10},
        {0x24, 0x72, 0xC8}, {0xBC, 0x3F, 0xBC}, {0x11, 0xA8, 0xCD}, {0xE5, 0xE5, 0xE5},
        {0x66, 0x66, 0x66}, {0xF1, 0x4C, 0x4C}, {0x23, 0xD1, 0x8B}, {0xF5, 0xF5, 0x43},
        {0x3B, 0x8E, 0xEA}, {0xD6, 0x70, 0xD6}, {0x29, 0xB8, 0xDB}, {0xFF, 0xFF, 0xFF},
    };
    NSArray<NSString *> *names = @[@"Black", @"Red", @"Green", @"Yellow", @"Blue", @"Magenta", @"Cyan", @"White",
                                   @"BrightBlack", @"BrightRed", @"BrightGreen", @"BrightYellow", @"BrightBlue",
                                   @"BrightMagenta", @"BrightCyan", @"BrightWhite"];
    for (int index = 0; index < 16; ++index) {
        NSColor *fallbackColor = [NSColor colorWithSRGBRed:fallback[index][0] / 255.0 green:fallback[index][1] / 255.0
                                                      blue:fallback[index][2] / 255.0 alpha:1];
        NSColor *color = [services color:[@"terminal.ansi" stringByAppendingString:names[static_cast<NSUInteger>(index)]]
                                fallback:fallbackColor];
        _palette[index] = makeColor(color);
    }
    // 6x6x6 color cube, then 24 greys.
    for (int index = 16; index < 232; ++index) {
        int value = index - 16;
        auto level = [](int step) -> uint8_t { return step == 0 ? 0 : static_cast<uint8_t>(55 + step * 40); };
        _palette[index] = makeRGB(level(value / 36), level((value / 6) % 6), level(value % 6));
    }
    for (int index = 232; index < 256; ++index) {
        uint8_t grey = static_cast<uint8_t>(8 + (index - 232) * 10);
        _palette[index] = makeRGB(grey, grey, grey);
    }
    NSColor *foreground = [services color:@"terminal.foreground"
                                 fallback:[services color:@"editor.foreground" fallback:NSColor.labelColor]];
    NSColor *background = [services color:@"terminal.background"
                                 fallback:[services color:@"editor.background" fallback:NSColor.blackColor]];
    _foreground = makeColor(foreground);
    _background = makeColor(background);
    _cursorColor = makeColor([services color:@"terminalCursor.foreground" fallback:NSColor.controlAccentColor]);
    _selectionNSColor = [services color:@"terminal.selectionBackground" fallback:[NSColor.controlAccentColor colorWithAlphaComponent:0.35]];
    _selectionColor = makeColor(_selectionNSColor);

    if (_session) {
        NSColor *fg = [foreground colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *bg = [background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (fg && bg) {
            _session.screen.setDefaultColors(TermColor::rgb(static_cast<uint8_t>(fg.redComponent * 255), static_cast<uint8_t>(fg.greenComponent * 255),
                                                             static_cast<uint8_t>(fg.blueComponent * 255)),
                                              TermColor::rgb(static_cast<uint8_t>(bg.redComponent * 255), static_cast<uint8_t>(bg.greenComponent * 255),
                                                             static_cast<uint8_t>(bg.blueComponent * 255)));
        }
    }
    [self updateGridSize];
    self.needsDisplay = YES;
}

// ---------------------------------------------------------------------------
// MARK: Session

- (GWTerminalSession *)session { return _session; }

- (void)setSession:(GWTerminalSession *)session {
    if (_session == session) {
        return;
    }
    _session.onChange = nil;
    _session = session;
    _scrollOffset = 0;
    _hasSelection = NO;
    _cache.clear();
    _lastHistoryCount = session ? static_cast<long>(session.screen.historyCount()) : 0;
    __weak GWTerminalView *weakSelf = self;
    session.onChange = ^{
        [weakSelf sessionChanged];
    };
    [self reloadAppearance];  // also gives the screen its default colors and fits it
    self.needsDisplay = YES;
}

- (void)sessionChanged {
    if (_session == nil) {
        return;
    }
    // Scrolled back: keep looking at the same text as new lines arrive.
    long history = static_cast<long>(_session.screen.historyCount());
    if (_scrollOffset > 0) {
        _scrollOffset = std::min(_scrollOffset + (history - _lastHistoryCount), history);
        if (_scrollOffset < 0) _scrollOffset = 0;
    }
    _lastHistoryCount = history;
    if (_cache.size() > 3000) {
        _cache.clear();
    }
    self.needsDisplay = YES;
}

- (void)scrollToBottom {
    if (_scrollOffset != 0) {
        _scrollOffset = 0;
        self.needsDisplay = YES;
    }
}

- (IBAction)clearTerminal:(id)sender {
    if (_session == nil) {
        return;
    }
    _session.screen.write("\x1b[3J");  // forget the history
    [_session sendBytes:std::string("\x0c")];  // and let the shell redraw its prompt
    _scrollOffset = 0;
    _hasSelection = NO;
    _cache.clear();
    self.needsDisplay = YES;
}

// ---------------------------------------------------------------------------
// MARK: Size

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateGridSize];
}

- (void)updateGridSize {
    if (_session == nil || _cellWidth < 1 || _cellHeight < 1) {
        return;
    }
    int columns = static_cast<int>(floor((NSWidth(self.bounds) - kPadding * 2) / _cellWidth));
    int rows = static_cast<int>(floor((NSHeight(self.bounds) - kPadding) / _cellHeight));
    if (columns >= 2 && rows >= 1) {
        [_session resizeToColumns:columns
                             rows:rows
                       pixelWidth:static_cast<int>(NSWidth(self.bounds))
                      pixelHeight:static_cast<int>(NSHeight(self.bounds))];
    }
}

// ---------------------------------------------------------------------------
// MARK: Colors

- (CGColorRef)colorForTerm:(TermColor)color isForeground:(BOOL)isForeground bold:(BOOL)bold {
    if (color.isIndexed()) {
        uint8_t index = color.index();
        if (isForeground && bold && index < 8) index += 8;  // bold text is bright
        return _palette[index];
    }
    if (color.isRgb()) {
        // A one-off color; cached by value in a small map so it lives long enough to draw.
        static NSMutableDictionary<NSNumber *, id> *custom;
        if (custom == nil) custom = [NSMutableDictionary dictionary];
        if (custom.count > 2000) [custom removeAllObjects];
        NSNumber *key = @(color.packed);
        id existing = custom[key];
        if (existing == nil) {
            CGColorRef made = makeRGB(color.red(), color.green(), color.blue());
            existing = CFBridgingRelease(made);
            custom[key] = existing;
        }
        return (__bridge CGColorRef)existing;
    }
    return isForeground ? _foreground : nullptr;  // background: none (the glass shows through)
}

// ---------------------------------------------------------------------------
// MARK: Building a row's drawing

- (RowDrawing &)drawingForRow:(const Row &)row {
    auto found = _cache.find(row.revision);
    if (found != _cache.end()) {
        return found->second;
    }
    RowDrawing drawing;
    int columns = _session.screen.columns();

    struct Style {
        CGColorRef foreground = nullptr;
        BOOL bold = NO, italic = NO, underline = NO, strike = NO;
        bool operator==(const Style &o) const {
            return foreground == o.foreground && bold == o.bold && italic == o.italic && underline == o.underline && strike == o.strike;
        }
    };

    int runStart = -1;
    Style runStyle;
    NSMutableString *runText = [NSMutableString string];
    auto finishRun = [&](int endColumn) {
        if (runStart < 0) return;
        bool onlySpaces = true;
        for (NSUInteger index = 0; index < runText.length; ++index) {
            if ([runText characterAtIndex:index] != ' ') {
                onlySpaces = false;
                break;
            }
        }
        if (!onlySpaces || runStyle.underline || runStyle.strike) {
            int fontIndex = (runStyle.bold ? 1 : 0) + (runStyle.italic ? 2 : 0);
            NSDictionary *attributes = @{
                (__bridge id)kCTFontAttributeName: (__bridge id)_fonts[fontIndex],
                (__bridge id)kCTForegroundColorAttributeName: (__bridge id)runStyle.foreground,
                (__bridge id)kCTLigatureAttributeName: @0,
            };
            NSAttributedString *text = [[NSAttributedString alloc] initWithString:runText attributes:attributes];
            TextRun run;
            run.line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
            run.column = runStart;
            run.width = endColumn - runStart;
            run.color = runStyle.foreground;
            run.underline = runStyle.underline;
            run.strike = runStyle.strike;
            drawing.runs.push_back(run);
        }
        runStart = -1;
        [runText setString:@""];
    };

    // Background spans merge neighbouring cells of the same color.
    int backgroundStart = -1;
    CGColorRef backgroundColor = nullptr;
    auto finishBackground = [&](int endColumn) {
        if (backgroundStart >= 0 && backgroundColor != nullptr) {
            drawing.backgrounds.push_back({backgroundStart, endColumn, backgroundColor});
        }
        backgroundStart = -1;
        backgroundColor = nullptr;
    };

    for (int column = 0; column < columns; ++column) {
        Cell cell = static_cast<size_t>(column) < row.cells.size() ? row.cells[static_cast<size_t>(column)] : Cell{};
        if (cell.attributes & gw::term::kWideEnd) {
            continue;  // the second half of a wide character; the first half covers it
        }
        int cellWidth = (cell.attributes & gw::term::kWideStart) ? 2 : 1;
        BOOL bold = (cell.attributes & gw::term::kBold) != 0;
        BOOL inverse = (cell.attributes & gw::term::kInverse) != 0;

        CGColorRef foreground = [self colorForTerm:cell.foreground isForeground:YES bold:bold];
        CGColorRef background = [self colorForTerm:cell.background isForeground:NO bold:NO];
        if (inverse) {
            CGColorRef swappedForeground = background != nullptr ? background : _background;
            CGColorRef swappedBackground = foreground;
            foreground = swappedForeground;
            background = swappedBackground;
        }
        if (cell.attributes & gw::term::kHidden) {
            foreground = background != nullptr ? background : _background;
        }
        if ((cell.attributes & gw::term::kDim) && foreground != nullptr) {
            auto dimmed = _dimmedColors.find(foreground);
            if (dimmed == _dimmedColors.end()) {
                dimmed = _dimmedColors.emplace(foreground, CGColorCreateCopyWithAlpha(foreground, 0.6)).first;
            }
            foreground = dimmed->second;
        }

        // Background
        if (background != backgroundColor || backgroundStart < 0) {
            finishBackground(column);
            if (background != nullptr) {
                backgroundStart = column;
                backgroundColor = background;
            }
        }

        // Text
        uint32_t character = cell.character == 0 ? ' ' : cell.character;
        if (isDrawnAsShape(character)) {
            finishRun(column);
            drawing.boxes.push_back({column, cellWidth, character, foreground});
            column += cellWidth - 1;
            continue;
        }
        Style style;
        style.foreground = foreground;
        style.bold = bold;
        style.italic = (cell.attributes & gw::term::kItalic) != 0;
        style.underline = (cell.attributes & gw::term::kUnderline) != 0;
        style.strike = (cell.attributes & gw::term::kStrike) != 0;

        bool simple = cellWidth == 1 && character < 0x2000 && character != 0xFFFD;
        if (!simple) {
            // Wide and unusual characters get their own spot on the grid, so a font that draws
            // them at a different width can't push the rest of the row out of line.
            finishRun(column);
            runStart = column;
            runStyle = style;
            [runText appendString:[[NSString alloc] initWithBytes:&character length:4 encoding:NSUTF32LittleEndianStringEncoding]];
            finishRun(column + cellWidth);
            column += cellWidth - 1;
            continue;
        }
        if (runStart >= 0 && !(runStyle == style)) {
            finishRun(column);
        }
        if (runStart < 0) {
            runStart = column;
            runStyle = style;
        }
        [runText appendString:[[NSString alloc] initWithBytes:&character length:4 encoding:NSUTF32LittleEndianStringEncoding]];
    }
    finishRun(columns);
    finishBackground(columns);

    auto inserted = _cache.emplace(row.revision, std::move(drawing));
    return inserted.first->second;
}

// ---------------------------------------------------------------------------
// MARK: Drawing

- (long)visibleRowCount {
    return _session ? _session.screen.rows() : 0;
}

/// Draws the shape of a box-drawing or block character inside one cell.
- (void)drawShape:(uint32_t)c inRect:(CGRect)rect color:(CGColorRef)color context:(CGContextRef)context {
    CGContextSetFillColorWithColor(context, color);
    CGContextSetStrokeColorWithColor(context, color);
    CGFloat x = rect.origin.x, y = rect.origin.y, w = rect.size.width, h = rect.size.height;

    if (c >= 0x2580 && c <= 0x259F) {
        // Block elements: fractions of the cell.
        auto fill = [&](CGFloat fx, CGFloat fy, CGFloat fw, CGFloat fh, CGFloat alpha = 1) {
            CGContextSetAlpha(context, alpha);
            CGContextFillRect(context, CGRectMake(x + w * fx, y + h * fy, w * fw, h * fh));
            CGContextSetAlpha(context, 1);
        };
        switch (c) {
            case 0x2580: fill(0, 0, 1, 0.5); break;
            case 0x2581: fill(0, 7.0 / 8, 1, 1.0 / 8); break;
            case 0x2582: fill(0, 6.0 / 8, 1, 2.0 / 8); break;
            case 0x2583: fill(0, 5.0 / 8, 1, 3.0 / 8); break;
            case 0x2584: fill(0, 0.5, 1, 0.5); break;
            case 0x2585: fill(0, 3.0 / 8, 1, 5.0 / 8); break;
            case 0x2586: fill(0, 2.0 / 8, 1, 6.0 / 8); break;
            case 0x2587: fill(0, 1.0 / 8, 1, 7.0 / 8); break;
            case 0x2588: fill(0, 0, 1, 1); break;
            case 0x2589: fill(0, 0, 7.0 / 8, 1); break;
            case 0x258A: fill(0, 0, 6.0 / 8, 1); break;
            case 0x258B: fill(0, 0, 5.0 / 8, 1); break;
            case 0x258C: fill(0, 0, 0.5, 1); break;
            case 0x258D: fill(0, 0, 3.0 / 8, 1); break;
            case 0x258E: fill(0, 0, 2.0 / 8, 1); break;
            case 0x258F: fill(0, 0, 1.0 / 8, 1); break;
            case 0x2590: fill(0.5, 0, 0.5, 1); break;
            case 0x2591: fill(0, 0, 1, 1, 0.25); break;
            case 0x2592: fill(0, 0, 1, 1, 0.5); break;
            case 0x2593: fill(0, 0, 1, 1, 0.75); break;
            case 0x2594: fill(0, 0, 1, 1.0 / 8); break;
            case 0x2595: fill(7.0 / 8, 0, 1.0 / 8, 1); break;
            case 0x2596: fill(0, 0.5, 0.5, 0.5); break;
            case 0x2597: fill(0.5, 0.5, 0.5, 0.5); break;
            case 0x2598: fill(0, 0, 0.5, 0.5); break;
            case 0x2599: fill(0, 0, 0.5, 1); fill(0.5, 0.5, 0.5, 0.5); break;
            case 0x259A: fill(0, 0, 0.5, 0.5); fill(0.5, 0.5, 0.5, 0.5); break;
            case 0x259B: fill(0, 0, 1, 0.5); fill(0, 0.5, 0.5, 0.5); break;
            case 0x259C: fill(0, 0, 1, 0.5); fill(0.5, 0.5, 0.5, 0.5); break;
            case 0x259D: fill(0.5, 0, 0.5, 0.5); break;
            case 0x259E: fill(0.5, 0, 0.5, 0.5); fill(0, 0.5, 0.5, 0.5); break;
            case 0x259F: fill(0.5, 0, 0.5, 1); fill(0, 0.5, 0.5, 0.5); break;
            default: break;
        }
        return;
    }

    Lines lines = linesFor(c);
    if (lines.left == 0 && lines.right == 0 && lines.up == 0 && lines.down == 0) {
        // Dashed and diagonal lines: fall back to a plain line through the middle.
        if (c == 0x2504 || c == 0x2508 || c == 0x254C) {
            CGContextFillRect(context, CGRectMake(x, y + floor(h / 2), w, 1));
        }
        return;
    }
    CGFloat lightWidth = MAX(1.0, round(_fontSize / 13.0));
    CGFloat heavyWidth = lightWidth * 2;
    CGFloat midX = x + floor(w / 2);
    CGFloat midY = y + floor(h / 2);

    auto thickness = [&](uint8_t kind) { return kind == 2 ? heavyWidth : lightWidth; };
    CGFloat overlap = MAX(lightWidth, heavyWidth) / 2;

    if (lines.rounded) {
        // A quarter circle joining the two sides.
        CGFloat radius = MIN(w, h) / 2;
        CGContextSetLineWidth(context, lightWidth);
        CGContextBeginPath(context);
        if (lines.right && lines.down) {
            CGContextMoveToPoint(context, x + w, midY);
            CGContextAddArcToPoint(context, midX, midY, midX, y + h, radius);
            CGContextAddLineToPoint(context, midX, y + h);
        } else if (lines.left && lines.down) {
            CGContextMoveToPoint(context, x, midY);
            CGContextAddArcToPoint(context, midX, midY, midX, y + h, radius);
            CGContextAddLineToPoint(context, midX, y + h);
        } else if (lines.left && lines.up) {
            CGContextMoveToPoint(context, x, midY);
            CGContextAddArcToPoint(context, midX, midY, midX, y, radius);
            CGContextAddLineToPoint(context, midX, y);
        } else {
            CGContextMoveToPoint(context, x + w, midY);
            CGContextAddArcToPoint(context, midX, midY, midX, y, radius);
            CGContextAddLineToPoint(context, midX, y);
        }
        CGContextStrokePath(context);
        return;
    }

    // Straight pieces from the middle to each side; double lines are two thin ones.
    auto horizontal = [&](CGFloat fromX, CGFloat toX, uint8_t kind) {
        if (kind == 3) {
            CGContextFillRect(context, CGRectMake(fromX, midY - 2, toX - fromX, lightWidth));
            CGContextFillRect(context, CGRectMake(fromX, midY + 1, toX - fromX, lightWidth));
        } else {
            CGFloat lineThickness = thickness(kind);
            CGContextFillRect(context, CGRectMake(fromX, midY - floor(lineThickness / 2), toX - fromX, lineThickness));
        }
    };
    auto vertical = [&](CGFloat fromY, CGFloat toY, uint8_t kind) {
        if (kind == 3) {
            CGContextFillRect(context, CGRectMake(midX - 2, fromY, lightWidth, toY - fromY));
            CGContextFillRect(context, CGRectMake(midX + 1, fromY, lightWidth, toY - fromY));
        } else {
            CGFloat lineThickness = thickness(kind);
            CGContextFillRect(context, CGRectMake(midX - floor(lineThickness / 2), fromY, lineThickness, toY - fromY));
        }
    };
    if (lines.left) horizontal(x, midX + overlap, lines.left);
    if (lines.right) horizontal(midX - overlap, x + w, lines.right);
    if (lines.up) vertical(y, midY + overlap, lines.up);
    if (lines.down) vertical(midY - overlap, y + h, lines.down);
}

- (BOOL)selectionContainsRow:(long)row column:(int)column {
    if (!_hasSelection) return NO;
    GWTermPoint start = _selectionAnchor, end = _selectionHead;
    if (pointBefore(end, start)) std::swap(start, end);
    GWTermPoint here = {row, column};
    return !pointBefore(here, start) && pointBefore(here, {end.row, end.column + 1});
}

- (void)drawRect:(NSRect)dirtyRect {
    if (_session == nil) {
        return;
    }
    gw::term::Screen &screen = _session.screen;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));  // flipped view
    int rows = screen.rows();
    int columns = screen.columns();

    long firstVisible = std::max<long>(0, static_cast<long>(floor((NSMinY(dirtyRect) - kPadding) / _cellHeight)));
    long lastVisible = std::min<long>(rows - 1, static_cast<long>(floor((NSMaxY(dirtyRect) - kPadding) / _cellHeight)));

    for (long line = firstVisible; line <= lastVisible; ++line) {
        long rowIndex = line - _scrollOffset;
        const Row &row = screen.row(rowIndex);
        CGFloat y = kPadding + line * _cellHeight;

        RowDrawing &drawing = [self drawingForRow:row];
        for (const BackgroundSpan &span : drawing.backgrounds) {
            CGContextSetFillColorWithColor(context, span.color);
            CGContextFillRect(context, CGRectMake(kPadding + span.firstColumn * _cellWidth, y, (span.endColumn - span.firstColumn) * _cellWidth, _cellHeight));
        }

        // Selection sits behind the text.
        if (_hasSelection) {
            CGContextSetFillColorWithColor(context, _selectionColor);
            int spanStart = -1;
            for (int column = 0; column <= columns; ++column) {
                BOOL inside = column < columns && [self selectionContainsRow:rowIndex column:column];
                if (inside && spanStart < 0) spanStart = column;
                if (!inside && spanStart >= 0) {
                    CGContextFillRect(context, CGRectMake(kPadding + spanStart * _cellWidth, y, (column - spanStart) * _cellWidth, _cellHeight));
                    spanStart = -1;
                }
            }
        }

        for (const TextRun &run : drawing.runs) {
            CGFloat x = kPadding + run.column * _cellWidth;
            CGContextSetTextPosition(context, x, y + _baseline);
            CTLineDraw(run.line, context);
            if (run.underline || run.strike) {
                CGContextSetFillColorWithColor(context, run.color);
                if (run.underline) CGContextFillRect(context, CGRectMake(x, y + _baseline + 2, run.width * _cellWidth, 1));
                if (run.strike) CGContextFillRect(context, CGRectMake(x, y + _cellHeight / 2, run.width * _cellWidth, 1));
            }
        }
        for (const BoxCell &box : drawing.boxes) {
            CGRect cellRect = CGRectMake(kPadding + box.column * _cellWidth, y, box.width * _cellWidth, _cellHeight);
            [self drawShape:box.character inRect:cellRect color:box.color context:context];
        }
    }

    // The cursor.
    if (_scrollOffset == 0 && screen.cursorVisible()) {
        int cursorColumn = screen.cursorColumn();
        int cursorLine = screen.cursorRow();
        CGRect rect = CGRectMake(kPadding + cursorColumn * _cellWidth, kPadding + cursorLine * _cellHeight, _cellWidth, _cellHeight);
        if (CGRectIntersectsRect(rect, dirtyRect)) {
            if (_focused) {
                CGContextSetFillColorWithColor(context, _cursorColor);
                CGContextSetAlpha(context, 0.9);
                CGContextFillRect(context, rect);
                CGContextSetAlpha(context, 1);
                // The character under the cursor in the background color, so it stays readable.
                Cell under = screen.cellAt(cursorLine, cursorColumn);
                if (under.character > ' ' && !isDrawnAsShape(under.character)) {
                    uint32_t character = under.character;
                    NSString *text = [[NSString alloc] initWithBytes:&character length:4 encoding:NSUTF32LittleEndianStringEncoding];
                    NSDictionary *attributes = @{
                        (__bridge id)kCTFontAttributeName: (__bridge id)_fonts[(under.attributes & gw::term::kBold) ? 1 : 0],
                        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)_background,
                    };
                    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:text attributes:attributes]);
                    CGContextSetTextPosition(context, rect.origin.x, rect.origin.y + _baseline);
                    CTLineDraw(line, context);
                    CFRelease(line);
                }
            } else {
                CGContextSetStrokeColorWithColor(context, _cursorColor);
                CGContextSetLineWidth(context, 1);
                CGContextStrokeRect(context, CGRectInset(rect, 0.5, 0.5));
            }
        }
    }

    // A slim indicator when looking at history.
    if (_scrollOffset > 0 && screen.historyCount() > 0) {
        CGFloat total = static_cast<CGFloat>(screen.historyCount() + rows);
        CGFloat trackHeight = NSHeight(self.bounds) - 2 * kPadding;
        CGFloat thumbHeight = MAX(24.0, trackHeight * rows / total);
        CGFloat thumbTop = kPadding + (trackHeight - thumbHeight) * (1.0 - static_cast<CGFloat>(_scrollOffset) / screen.historyCount());
        CGContextSetFillColorWithColor(context, _selectionColor);
        CGContextFillRect(context, CGRectMake(NSWidth(self.bounds) - 5, thumbTop, 3, thumbHeight));
    }
    (void)columns;
}

// ---------------------------------------------------------------------------
// MARK: Focus

- (BOOL)becomeFirstResponder {
    _focused = YES;
    if (_session && _session.screen.focusReporting()) [_session sendBytes:std::string("\x1b[I")];
    self.needsDisplay = YES;
    return YES;
}

- (BOOL)resignFirstResponder {
    _focused = NO;
    if (_session && _session.screen.focusReporting()) [_session sendBytes:std::string("\x1b[O")];
    self.needsDisplay = YES;
    return YES;
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

- (void)windowKeyChanged:(NSNotification *)notification {
    _focused = self.window.isKeyWindow && self.window.firstResponder == self;
    self.needsDisplay = YES;
}

// ---------------------------------------------------------------------------
// MARK: Keyboard

/// The bytes a special key sends, or an empty string for ordinary typing.
- (std::string)sequenceForEvent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    bool applicationKeys = _session.screen.applicationCursorKeys();

    // xterm's numbers for modifiers: 1 + shift 1 + alt 2 + control 4.
    int modifier = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0);
    auto arrow = [&](char letter) {
        if (modifier > 1) return "\x1b[1;" + std::to_string(modifier) + letter;
        return std::string(applicationKeys ? "\x1bO" : "\x1b[") + letter;
    };
    auto tilde = [&](int number) {
        if (modifier > 1) return "\x1b[" + std::to_string(number) + ";" + std::to_string(modifier) + "~";
        return "\x1b[" + std::to_string(number) + "~";
    };

    // Terminal.app's conveniences: Command with arrows and delete edit the command line.
    if (command && !control) {
        switch (event.keyCode) {
            case 123: return "\x01";  // Cmd-Left: line start
            case 124: return "\x05";  // Cmd-Right: line end
            case 51: return "\x15";   // Cmd-Delete: delete to line start
            default: return "";
        }
    }
    if (option && !control) {
        switch (event.keyCode) {
            case 123: return "\x1b" "b";      // Option-Left: back a word
            case 124: return "\x1b" "f";      // Option-Right: forward a word
            case 51: return "\x1b\x7f";       // Option-Delete: delete a word
            case 117: return "\x1b" "d";      // Option-forward-delete
            default: break;
        }
    }

    switch (event.keyCode) {
        case 126: return arrow('A');
        case 125: return arrow('B');
        case 124: return arrow('C');
        case 123: return arrow('D');
        case 115: return modifier > 1 ? "\x1b[1;" + std::to_string(modifier) + "H" : std::string(applicationKeys ? "\x1bOH" : "\x1b[H");
        case 119: return modifier > 1 ? "\x1b[1;" + std::to_string(modifier) + "F" : std::string(applicationKeys ? "\x1bOF" : "\x1b[F");
        case 116: return tilde(5);
        case 121: return tilde(6);
        case 117: return tilde(3);
        case 114: return tilde(2);  // help / insert
        case 51: return control ? std::string("\x08") : std::string("\x7f");
        case 36: case 76: return option ? std::string("\x1b\r") : std::string("\r");
        case 48: return shift ? std::string("\x1b[Z") : std::string("\t");
        case 53: return "\x1b";
        case 122: return modifier > 1 ? "\x1b[1;" + std::to_string(modifier) + "P" : std::string("\x1bOP");
        case 120: return modifier > 1 ? "\x1b[1;" + std::to_string(modifier) + "Q" : std::string("\x1bOQ");
        case 99: return modifier > 1 ? "\x1b[1;" + std::to_string(modifier) + "R" : std::string("\x1bOR");
        case 118: return modifier > 1 ? "\x1b[1;" + std::to_string(modifier) + "S" : std::string("\x1bOS");
        case 96: return tilde(15);
        case 97: return tilde(17);
        case 98: return tilde(18);
        case 100: return tilde(19);
        case 101: return tilde(20);
        case 109: return tilde(21);
        case 103: return tilde(23);
        case 111: return tilde(24);
        default: break;
    }

    // Control with a letter or symbol sends the matching control character.
    if (control && !command) {
        NSString *characters = event.charactersIgnoringModifiers;
        if (characters.length == 1) {
            unichar c = [characters characterAtIndex:0];
            if (c >= 'a' && c <= 'z') return std::string(1, static_cast<char>(c - 'a' + 1));
            if (c >= 'A' && c <= 'Z') return std::string(1, static_cast<char>(c - 'A' + 1));
            switch (c) {
                case ' ': case '@': case '2': return std::string(1, '\0');
                case '[': case '3': return "\x1b";
                case '\\': case '4': return "\x1c";
                case ']': case '5': return "\x1d";
                case '^': case '6': return "\x1e";
                case '_': case '/': case '7': return "\x1f";
                case '8': return "\x7f";
                default: break;
            }
        }
    }
    return "";
}

- (void)keyDown:(NSEvent *)event {
    if (_session == nil) {
        return;
    }
    [self scrollToBottom];
    _hasSelection = NO;
    std::string sequence = [self sequenceForEvent:event];
    if (!sequence.empty() || event.keyCode == 51) {
        [_session sendBytes:sequence];
        return;
    }
    if ((event.modifierFlags & NSEventModifierFlagCommand) != 0) {
        return;  // a menu shortcut nobody claimed
    }
    [self interpretKeyEvents:@[event]];
}

/// Control shortcuts belong to the program in the terminal (Ctrl-G, Ctrl-R…), not to the menus.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    if (control && !command && self.window.firstResponder == self && event.keyCode != 50 /* the ` key opens the terminal */) {
        [self keyDown:event];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (void)doCommandBySelector:(SEL)selector {
    // Keys with no text (already handled above); nothing more to do.
}

// ---------------------------------------------------------------------------
// MARK: Text input (typing, dead keys, input methods)

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    _markedText = nil;
    if (_session && text.length > 0) {
        [_session sendText:text];
    }
    self.needsDisplay = YES;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    _markedText = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    self.needsDisplay = YES;
}

- (void)unmarkText { _markedText = nil; }
- (BOOL)hasMarkedText { return _markedText.length > 0; }
- (NSRange)markedRange { return _markedText.length > 0 ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return 0; }

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // The input method's popup appears at the cursor.
    NSRect rect = NSMakeRect(kPadding + _session.screen.cursorColumn() * _cellWidth, kPadding + _session.screen.cursorRow() * _cellHeight,
                             _cellWidth, _cellHeight);
    return [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
}

// ---------------------------------------------------------------------------
// MARK: Copy and paste

- (GWTermPoint)pointForEvent:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    int rows = _session.screen.rows();
    int columns = _session.screen.columns();
    long line = std::clamp<long>(static_cast<long>(floor((local.y - kPadding) / _cellHeight)), 0, rows - 1);
    int column = std::clamp<int>(static_cast<int>(floor((local.x - kPadding) / _cellWidth)), 0, columns - 1);
    return {line - _scrollOffset, column};
}

- (NSString *)selectedString {
    if (!_hasSelection) return nil;
    GWTermPoint start = _selectionAnchor, end = _selectionHead;
    if (pointBefore(end, start)) std::swap(start, end);
    return @(_session.screen.textInRange(start.row, start.column, end.row, end.column + 1).c_str());
}

- (void)copy:(id)sender {
    NSString *text = [self selectedString];
    if (text.length == 0) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

- (void)paste:(id)sender {
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (text.length > 0 && _session) {
        [self scrollToBottom];
        [_session pasteText:text];
    }
}

- (void)selectAll:(id)sender {
    if (!_session) return;
    gw::term::Screen &screen = _session.screen;
    _selectionAnchor = {-static_cast<long>(screen.historyCount()), 0};
    _selectionHead = {screen.rows() - 1, screen.columns() - 1};
    _hasSelection = YES;
    self.needsDisplay = YES;
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if (item.action == @selector(copy:)) return _hasSelection;
    return YES;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationCopy; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray<NSString *> *quoted = [NSMutableArray array];
    for (NSURL *url in urls) {
        // Single-quote, so spaces and symbols in the name are safe.
        NSString *escaped = [url.path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        [quoted addObject:[NSString stringWithFormat:@"'%@'", escaped]];
    }
    if (quoted.count == 0 || !_session) return NO;
    [_session pasteText:[[quoted componentsJoinedByString:@" "] stringByAppendingString:@" "]];
    return YES;
}

// ---------------------------------------------------------------------------
// MARK: Mouse

/// Sends a mouse event to a program that asked for them. Returns YES if sent.
- (BOOL)reportMouse:(NSEvent *)event button:(int)button pressed:(BOOL)pressed motion:(BOOL)motion {
    gw::term::Screen &screen = _session.screen;
    if (screen.mouseMode() == gw::term::MouseMode::None) return NO;
    NSEventModifierFlags flags = event.modifierFlags;
    if (flags & (NSEventModifierFlagOption | NSEventModifierFlagShift)) return NO;  // these select text instead

    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    int column = std::clamp<int>(static_cast<int>(floor((local.x - kPadding) / _cellWidth)), 0, screen.columns() - 1) + 1;
    int line = std::clamp<int>(static_cast<int>(floor((local.y - kPadding) / _cellHeight)), 0, screen.rows() - 1) + 1;
    int code = button;
    if (motion) code += 32;
    if (flags & NSEventModifierFlagControl) code += 16;
    std::string message;
    if (screen.mouseSgr()) {
        message = "\x1b[<" + std::to_string(code) + ";" + std::to_string(column) + ";" + std::to_string(line) + (pressed ? "M" : "m");
    } else {
        int legacy = pressed ? code : 3;  // in the old encoding a release has no button number
        message = "\x1b[M";
        message += static_cast<char>(32 + legacy);
        message += static_cast<char>(32 + std::min(column, 223));
        message += static_cast<char>(32 + std::min(line, 223));
    }
    [_session sendBytes:message];
    return YES;
}

/// A range of columns making up the word at a spot.
- (void)wordRangeAt:(GWTermPoint)point start:(int *)start end:(int *)end {
    gw::term::Screen &screen = _session.screen;
    auto isWordCharacter = [](uint32_t c) {
        if (c == 0) return false;
        if (c > 0x7F) return true;
        return isalnum(static_cast<int>(c)) != 0 || strchr("_-./~:@%+=#?&,", static_cast<int>(c)) != nullptr;
    };
    int from = point.column, to = point.column;
    if (!isWordCharacter(screen.cellAt(point.row, point.column).character)) {
        *start = *end = point.column;
        return;
    }
    while (from > 0 && isWordCharacter(screen.cellAt(point.row, from - 1).character)) --from;
    while (to < screen.columns() - 1 && isWordCharacter(screen.cellAt(point.row, to + 1).character)) ++to;
    *start = from;
    *end = to;
}

- (void)mouseDown:(NSEvent *)event {
    if (_session == nil) return;
    [self.window makeFirstResponder:self];
    if ([self reportMouse:event button:0 pressed:YES motion:NO]) {
        _reportingMouse = YES;
        return;
    }
    GWTermPoint point = [self pointForEvent:event];

    if (event.modifierFlags & NSEventModifierFlagCommand) {
        [self openLinkAt:point];
        return;
    }
    _selecting = YES;
    _selectionGranularity = MIN(event.clickCount, 3);
    if (_selectionGranularity == 2) {
        int start = 0, end = 0;
        [self wordRangeAt:point start:&start end:&end];
        _selectionAnchor = {point.row, start};
        _selectionHead = {point.row, end};
    } else if (_selectionGranularity >= 3) {
        _selectionAnchor = {point.row, 0};
        _selectionHead = {point.row, _session.screen.columns() - 1};
    } else {
        _selectionAnchor = point;
        _selectionHead = point;
    }
    _hasSelection = _selectionGranularity > 1;
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_session == nil) return;
    if (_reportingMouse) {
        if (_session.screen.mouseMode() == gw::term::MouseMode::Drag || _session.screen.mouseMode() == gw::term::MouseMode::Motion) {
            [self reportMouse:event button:0 pressed:YES motion:YES];
        }
        return;
    }
    if (!_selecting) return;

    // Dragging above or below scrolls the history.
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    if (local.y < 0) {
        _scrollOffset = std::min<long>(_scrollOffset + 1, static_cast<long>(_session.screen.historyCount()));
    } else if (local.y > NSHeight(self.bounds)) {
        _scrollOffset = std::max<long>(_scrollOffset - 1, 0);
    }
    GWTermPoint point = [self pointForEvent:event];
    if (_selectionGranularity == 2) {
        int start = 0, end = 0;
        [self wordRangeAt:point start:&start end:&end];
        _selectionHead = pointBefore(point, _selectionAnchor) ? GWTermPoint{point.row, start} : GWTermPoint{point.row, end};
    } else if (_selectionGranularity >= 3) {
        _selectionHead = {point.row, pointBefore(point, _selectionAnchor) ? 0 : _session.screen.columns() - 1};
    } else {
        _selectionHead = point;
    }
    _hasSelection = YES;
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    if (_reportingMouse) {
        [self reportMouse:event button:0 pressed:NO motion:NO];
        _reportingMouse = NO;
        return;
    }
    if (_selecting && _selectionGranularity == 1 && _selectionAnchor.row == _selectionHead.row &&
        _selectionAnchor.column == _selectionHead.column) {
        _hasSelection = NO;  // a plain click selects nothing
        self.needsDisplay = YES;
    }
    _selecting = NO;
}

- (void)rightMouseDown:(NSEvent *)event {
    if ([self reportMouse:event button:2 pressed:YES motion:NO]) return;
    [NSMenu popUpContextMenu:[self contextMenu] withEvent:event forView:self];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self reportMouse:event button:2 pressed:NO motion:NO];
}

- (NSMenu *)contextMenu {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *copy = [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    copy.target = self;
    copy.enabled = _hasSelection;
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Clear" action:@selector(clearTerminal:) keyEquivalent:@""].target = self;
    return menu;
}

- (void)scrollWheel:(NSEvent *)event {
    if (_session == nil) return;
    gw::term::Screen &screen = _session.screen;
    CGFloat lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / _cellHeight : event.scrollingDeltaY * 3;
    _scrollRemainder += lines;
    long whole = static_cast<long>(_scrollRemainder);
    if (whole == 0) return;
    _scrollRemainder -= static_cast<CGFloat>(whole);

    // A program that wants the mouse gets wheel "buttons".
    if (screen.mouseMode() != gw::term::MouseMode::None && !(event.modifierFlags & NSEventModifierFlagShift)) {
        for (long step = 0; step < labs(whole); ++step) {
            [self reportMouse:event button:whole > 0 ? 64 : 65 pressed:YES motion:NO];
        }
        return;
    }
    // Full-screen programs without mouse support (less, man) scroll with the arrow keys.
    if (screen.onAlternateScreen()) {
        std::string key = std::string(screen.applicationCursorKeys() ? "\x1bO" : "\x1b[") + (whole > 0 ? "A" : "B");
        std::string keys;
        for (long step = 0; step < std::min<long>(labs(whole), 10); ++step) keys += key;
        [_session sendBytes:keys];
        return;
    }
    long maximum = static_cast<long>(screen.historyCount());
    _scrollOffset = std::clamp<long>(_scrollOffset + whole, 0, maximum);
    self.needsDisplay = YES;
}

// ---------------------------------------------------------------------------
// MARK: Links and file paths

/// Whatever looks like a path or web address at a spot, widest reading first.
- (NSString *)tokenAt:(GWTermPoint)point {
    gw::term::Screen &screen = _session.screen;
    auto isTokenCharacter = [](uint32_t c) {
        if (c == 0 || c == ' ') return false;
        if (c > 0x7F) return true;
        return strchr("\"'`<>|{}[]\\^", static_cast<int>(c)) == nullptr && c > ' ';
    };
    if (!isTokenCharacter(screen.cellAt(point.row, point.column).character)) return nil;
    int from = point.column, to = point.column;
    while (from > 0 && isTokenCharacter(screen.cellAt(point.row, from - 1).character)) --from;
    while (to < screen.columns() - 1 && isTokenCharacter(screen.cellAt(point.row, to + 1).character)) ++to;
    NSString *token = @(screen.textInRange(point.row, from, point.row, to + 1).c_str());
    // Sentence punctuation and wrapping brackets aren't part of it.
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?()"];
    while (token.length > 0 && [trim characterIsMember:[token characterAtIndex:token.length - 1]] &&
           ![token hasSuffix:@")"]) {
        token = [token substringToIndex:token.length - 1];
    }
    while (token.length > 0 && [token hasPrefix:@"("]) token = [token substringFromIndex:1];
    while (token.length > 0 && [token hasSuffix:@")"] && [token rangeOfString:@"("].location == NSNotFound) {
        token = [token substringToIndex:token.length - 1];
    }
    return token;
}

- (void)openLinkAt:(GWTermPoint)point {
    NSString *token = [self tokenAt:point];
    if (token.length == 0) return;
    if ([token hasPrefix:@"http://"] || [token hasPrefix:@"https://"]) {
        NSURL *url = [NSURL URLWithString:token];
        if (url) [NSWorkspace.sharedWorkspace openURL:url];
        return;
    }
    // path, path:line, path:line:column, or path(line,column)
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^(.+?)(?::(\\d+)(?::(\\d+))?|\\((\\d+)(?:,(\\d+))?\\))?:?$" options:0 error:nil];
    });
    NSTextCheckingResult *match = [pattern firstMatchInString:token options:0 range:NSMakeRange(0, token.length)];
    if (match == nil) return;
    NSString *path = [token substringWithRange:[match rangeAtIndex:1]];
    NSInteger line = 0, column = 0;
    for (NSUInteger group : {2, 4}) {
        if ([match rangeAtIndex:group].location != NSNotFound) line = [token substringWithRange:[match rangeAtIndex:group]].integerValue;
    }
    for (NSUInteger group : {3, 5}) {
        if ([match rangeAtIndex:group].location != NSNotFound) column = [token substringWithRange:[match rangeAtIndex:group]].integerValue;
    }
    path = [path stringByExpandingTildeInPath];
    NSString *base = self.baseFolderProvider ? self.baseFolderProvider() : nil;
    NSString *directory = [_session currentDirectory] ?: base ?: NSHomeDirectory();
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if ([path hasPrefix:@"/"]) {
        [candidates addObject:path];
    } else {
        [candidates addObject:[directory stringByAppendingPathComponent:path]];
        if (base != nil) [candidates addObject:[base stringByAppendingPathComponent:path]];
    }
    for (NSString *candidate in candidates) {
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory) {
            if (self.onOpenPath) self.onOpenPath(candidate.stringByStandardizingPath, line, column);
            return;
        }
    }
    NSBeep();
}

@end
